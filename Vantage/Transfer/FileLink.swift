import Foundation
import Network
import Observation
import VantageCore
import os

/// The file side of one Mac: its transfer queue (`files`) and the file channel that moves it.
///
/// The channel comes from the Mac's screen session while one is connected (its token), or else
/// from a files-only session this opens itself (`ClientFeatures.filesOnly`: authenticate, take a
/// token, attach the file channel, and keep that primary open beside it). On a Mac that says
/// `HostCapabilities.filesOnlySessions` the channel outlives the screen: Disconnect leaves the
/// screen, the files keep moving, and the link closes once nothing has moved for `idleTimeout`.
/// A dropped channel comes back through a files-only session while there is still work (or a
/// screen), and cut-off files resume. A Mac without it keeps the old rule: the channel lives and
/// dies with the screen session, which reconnects both.
@MainActor
@Observable
final class FileLink {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        /// Gave up; the reason is also on the files that were waiting.
        case unavailable(String)
    }

    let files: FileTransferController
    private(set) var device: SavedDevice?
    private(set) var phase: Phase = .idle
    /// What the Mac said last: it keeps file channels after sessions end and takes files-only
    /// sessions. Nil until a session with it has authenticated.
    private(set) var macKeepsFiles: Bool?
    /// A screen session with this Mac is connected, or is reconnecting after a drop.
    private(set) var screen: ScreenState = .none
    enum ScreenState: Equatable { case none, connected, reconnecting }
    private var screenConnected: Bool { screen == .connected }

    /// Nothing moving, nothing queued, no screen: close after this long.
    var idleTimeout: Duration = .seconds(30)
    /// Attempts to reach the Mac for queued files before they fail (about three minutes).
    var maxAttempts = 16
    /// A Mac without `filesOnlySessions` dropped the screen session's file channel after it had
    /// been up a while: drop the session too, so both come back together.
    var onLegacyChannelLost: (() -> Void)?

    private let identity: DeviceIdentity
    private let clientName: String
    private let clientModel: String
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "files")
    private var engine: FileTransferEngine?
    private var linkTask: Task<Void, Never>?
    private var primary: MessageChannel?

    init(files: FileTransferController, identity: DeviceIdentity, clientName: String, clientModel: String) {
        self.files = files
        self.identity = identity
        self.clientName = clientName
        self.clientModel = clientModel
        files.onWork = { [weak self] in self?.ensureConnected() }
    }

    /// The Mac's latest address and name (the saved device can be edited or synced).
    func update(_ device: SavedDevice) {
        self.device = device
    }

    var macName: String { device?.name ?? "the Mac" }
    /// Files can move without opening the screen (the Mac said so, or hasn't said otherwise yet).
    var canSendWithoutScreen: Bool { macKeepsFiles != false }
    var isConnected: Bool { engine != nil }

    // MARK: Screen session

    /// The screen session authenticated. `token` is its file channel ticket, if it got one.
    func screenDidConnect(token: Data?, capabilities: HostCapabilities?, host: String, port: NWEndpoint.Port) {
        screen = .connected
        macKeepsFiles = capabilities?.filesOnlySessions == true
        guard capabilities?.fileTransfer == true else {
            files.failWaiting("This Mac's Vantage Host can't receive files. Update Vantage Host on the Mac.")
            return
        }
        // One channel at a time: one that outlived an earlier screen session carries on.
        guard linkTask == nil, let token else { return }
        start { link in await link.runScreenChannel(token: token, host: host, port: port) }
    }

    /// The screen session ended. On a Mac that keeps files the channel stays for whatever is
    /// still moving; otherwise it goes with the screen.
    func screenDidEnd() {
        guard screen != .none else { return }
        screen = .none
        if macKeepsFiles != true { close() }
    }

    /// The screen session dropped and is reconnecting. An older Mac's channel goes with it and
    /// the files wait for the session's next one.
    func screenDidDrop() {
        guard screen == .connected else { return }
        screen = .reconnecting
        if macKeepsFiles != true { close() }
    }

    // MARK: Files-only

    /// Makes sure queued files have a way to the Mac: the channel that's up, the screen
    /// session's, or a files-only session of their own.
    func ensureConnected() {
        guard linkTask == nil, files.hasPendingWork else { return }
        if macKeepsFiles == false {
            // An older Mac only takes files over a screen session; that session connects them.
            if screen == .none { files.failWaiting("Update Vantage Host on \(macName) to send files without opening its screen.") }
            return
        }
        guard device != nil else { return }
        start { link in await link.runFilesOnly() }
    }

    /// Back in the foreground: anything waiting tries again straight away.
    func retryNow() {
        if case .unavailable = phase { phase = .idle }
        ensureConnected()
    }

    /// Stops moving files for now (the app is about to be suspended): the channel closes, both
    /// sides keep their partial files, and `retryNow` picks everything up where it stopped.
    func pause() {
        log.info("pausing file transfers with \(self.macName, privacy: .private)")
        close()
    }

    /// Closes the channel (and a files-only session's primary). Files still queued wait.
    func close() {
        linkTask?.cancel()
        linkTask = nil
        if let engine {
            self.engine = nil
            files.detach(engine)
            Task { await engine.close() }
        }
        if let primary {
            self.primary = nil
            Task { await primary.close() }
        }
        if phase == .connected || phase == .connecting { phase = .idle }
    }

    private func start(_ body: @escaping @MainActor (FileLink) async -> Void) {
        linkTask = Task { [weak self] in
            guard let self else { return }
            await body(self)
            // Ending on its own (not through `close`): let the next request start fresh.
            if !Task.isCancelled { self.linkTask = nil }
        }
    }

    /// The screen session's channel. On a Mac that keeps files, losing it while the screen is up
    /// or files are waiting falls through to a files-only session.
    private func runScreenChannel(token: Data, host: String, port: NWEndpoint.Port) async {
        phase = .connecting
        let opened = ContinuousClock.now
        await runChannel(token: token, host: host, port: port)
        guard !Task.isCancelled else { return }
        if macKeepsFiles == true {
            if screenConnected || files.hasPendingWork { await runFilesOnly() } else { phase = .idle }
        } else {
            phase = .idle
            if screenConnected, ContinuousClock.now - opened > .seconds(10) {
                log.error("file channel dropped mid-session; reconnecting the session")
                onLegacyChannelLost?()
            } else if screenConnected {
                log.error("the Mac closed the file channel; file transfer is off until the next connection")
            }
        }
    }

    /// Files-only sessions, again with backoff after each drop, for as long as there's something
    /// to move (or a screen session to receive for).
    private func runFilesOnly() async {
        var attempt = 0
        while !Task.isCancelled, screenConnected || files.hasPendingWork, let device {
            phase = .connecting
            do {
                let session = try await FilesOnlySession.open(to: device, identity: identity, clientName: clientName, clientModel: clientModel)
                guard !Task.isCancelled else { await session.primary.close(); return }
                guard session.capabilities?.filesOnlySessions == true, session.capabilities?.fileTransfer == true, let token = session.token else {
                    await session.primary.close()
                    macKeepsFiles = false
                    let reason = "Update Vantage Host on \(device.name) to send files without opening its screen."
                    files.failWaiting(reason)
                    phase = .unavailable(reason)
                    return
                }
                macKeepsFiles = true
                primary = session.primary
                let opened = ContinuousClock.now
                await runChannel(token: token, host: session.host, port: session.port)
                if let primary { self.primary = nil; await primary.close() }
                if ContinuousClock.now - opened > .seconds(10) { attempt = 0 }
            } catch let failure as FilesOnlySession.Failure {
                files.failWaiting(failure.message(macName: device.name))
                phase = .unavailable(failure.message(macName: device.name))
                return
            } catch {
                log.error("couldn't reach the Mac for files: \(error.localizedDescription, privacy: .public)")
            }
            guard !Task.isCancelled, screenConnected || files.hasPendingWork else { break }
            attempt += 1
            guard attempt <= maxAttempts || screenConnected else {
                let reason = "Couldn't reach \(device.name). Check that Vantage Host and Tailscale are running on both devices."
                files.failWaiting(reason)
                phase = .unavailable(reason)
                return
            }
            do { try await Task.sleep(for: .seconds(min(pow(1.6, Double(attempt)), 15))) } catch { return }
        }
        if !Task.isCancelled { phase = .idle }
    }

    /// Opens the file channel with `token`, runs it until it closes (or goes idle), and hands the
    /// queue back.
    private func runChannel(token: Data, host: String, port: NWEndpoint.Port) async {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: VantageNetwork.bulkParameters())
        let channel = MessageChannel(connection: connection, label: "vantage.client.files", maxBufferedMessages: 64)
        do {
            try await channel.start()
            try await channel.send(.attachMedia(AttachMedia(sessionToken: token)))
        } catch {
            log.error("file channel didn't open: \(error.localizedDescription, privacy: .public)")
            await channel.close()
            return
        }
        guard !Task.isCancelled else { await channel.close(); return }
        let engine = FileTransferEngine(channel: channel, role: .client, configuration: files.configuration)
        self.engine = engine
        phase = .connected
        files.attach(engine)
        let idle = Task { [weak self] in await self?.closeWhenIdle(engine) }
        await withTaskCancellationHandler {
            await engine.run()
        } onCancel: {
            Task { await engine.close() }
        }
        idle.cancel()
        files.detach(engine)
        if self.engine === engine { self.engine = nil }
    }

    /// Closes the channel once there's no screen and nothing has moved or waited for
    /// `idleTimeout`.
    private func closeWhenIdle(_ engine: FileTransferEngine) async {
        let step = min(idleTimeout / 4, .seconds(2))
        var idleSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            do { try await Task.sleep(for: step) } catch { return }
            let busy = await engine.isBusy
            guard screen == .none, !files.hasPendingWork, !busy else { idleSince = nil; continue }
            let since = idleSince ?? .now
            idleSince = since
            if ContinuousClock.now - since >= idleTimeout {
                log.info("closing the file channel to \(self.macName, privacy: .private): nothing to move")
                await engine.close()
                return
            }
        }
    }
}

/// A files-only session's handshake: `hello` with `features.filesOnly`, the challenge signed,
/// and the host's answer. Never sends a pairing code; a Mac that doesn't know this iPad yet says
/// so, and the user pairs by opening its screen once.
enum FilesOnlySession {
    struct Opened {
        let primary: MessageChannel
        let token: Data?
        let capabilities: HostCapabilities?
        let host: String
        let port: NWEndpoint.Port
    }

    enum Failure: Error, Equatable {
        case pairingRequired
        case incompatible
        case refused(String)

        func message(macName: String) -> String {
            switch self {
            case .pairingRequired: "Open \(macName) once in Vantage to pair it, then send again."
            case .incompatible: "Update Vantage Host on \(macName)."
            case .refused(let message): message
            }
        }
    }

    @MainActor
    static func open(to device: SavedDevice, identity: DeviceIdentity, clientName: String, clientModel: String,
                     timeout: Duration = .seconds(15)) async throws -> Opened {
        let address = try ConnectionAddress(host: device.host, port: String(device.port))
        guard let port = NWEndpoint.Port(rawValue: address.port) else { throw ConnectionAddress.AddressError.invalidPort }
        let channel = MessageChannel(connection: NWConnection(host: NWEndpoint.Host(address.host), port: port,
                                                              using: VantageNetwork.tcpParameters()),
                                     label: "vantage.client.filesOnly")
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            await channel.close()
        }
        defer { timer.cancel() }
        do {
            try await channel.start()
            try await channel.send(.hello(Hello(clientName: clientName, deviceModel: clientModel, appVersion: "1.0",
                                                clientPublicKey: identity.publicKeyData, supportedCodecs: [],
                                                maxDecodeWidth: 0, maxDecodeHeight: 0, viewport: nil,
                                                features: ClientFeatures(fileTransfer: true, filesOnly: true))))
            let first = try await channel.receive()
            if case .authResult(let result)? = first, result.status == .versionMismatch { throw Failure.incompatible }
            guard case .challenge(let challenge)? = first else { throw ClientHandshakeError.badHandshake }
            let signature = try identity.sign(AuthTranscript.bytes(nonce: challenge.nonce, hostPublicKey: challenge.hostPublicKey,
                                                                   clientPublicKey: identity.publicKeyData))
            try await channel.send(.authenticate(Authenticate(signature: signature)))
            guard case .authResult(let result)? = try await channel.receive() else { throw ClientHandshakeError.badHandshake }
            switch result.status {
            case .ok:
                return Opened(primary: channel, token: result.sessionToken, capabilities: result.capabilities, host: address.host, port: port)
            case .pairingRequired, .badPairingCode:
                throw Failure.pairingRequired
            case .versionMismatch:
                throw Failure.incompatible
            case .denied, .badSignature:
                throw Failure.refused(result.message ?? "\(device.hostNoun.theCapitalized) refused the connection.")
            }
        } catch {
            await channel.close()
            throw error
        }
    }
}

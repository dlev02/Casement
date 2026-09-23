import AppKit
import Foundation
import Network
import Observation
import VantageCore
import os

/// Top-level host runtime: owns the identity, trust store, listener, and active sessions.
/// Observable so the menu bar UI can reflect live status.
@MainActor
@Observable
final class HostController {
    enum Status: Equatable {
        case idle
        case listening
        case connected(clientCount: Int)
        case error(String)
    }

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "controller")
    private let identity: DeviceIdentity
    let trust = TrustStore()
    private let listener = TailscaleListener(port: HostOptions.shared.port)
    private var sessions: [HostSession] = []
    /// Tokens a session's second (file) connection presents to join it.
    private let attachTokens = AttachTokenRegistry<HostSession>()
    /// Connected clients with a file channel, most recent last.
    private(set) var fileChannels: [HostFileChannel] = []
    /// Files moving this run (both ways), newest last, for the menu.
    private(set) var transfers: [HostTransfer] = []
    let loginItem = LoginItem()
    private var displayObservers: [any NSObjectProtocol] = []

    private(set) var status: Status = .idle
    private(set) var tailscaleRunning = false
    private(set) var tailscaleSelfName: String = ""
    private(set) var hasScreenPermission = false
    private(set) var hasInputPermission = false
    private(set) var trustedClients: [TrustStore.TrustedClient] = []
    private(set) var readiness: Readiness.Report?
    var pairingCode: String?
    /// A FileVault unlock key is waiting for the next restart, so don't ask again.
    private(set) var safeRestartStaged = false

    var fingerprint: String { identity.fingerprint }
    var hasConnectedClients: Bool { !sessions.isEmpty }

    init() {
        let keychain = KeychainStore(service: "com.benjaminlevinson.vantage.host")
        self.identity = (try? keychain.loadOrCreateIdentity()) ?? DeviceIdentity()
        trust.onChange = { [weak self] in
            Task { @MainActor in self?.refreshTrusted() }
        }
        trust.onPairingCodeCleared = { [weak self] in
            Task { @MainActor in self?.pairingCode = nil }
        }
        refreshTrusted()
        refreshPermissions()
        refreshTailscale()
        refreshReadiness()
    }

    func start() {
        refreshPermissions()
        refreshTailscale()
        observeDisplayChanges()
        listener.onAccept = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.onStateChange = { [weak self] state in
            Task { @MainActor in self?.handleListenerState(state) }
        }
        do {
            try listener.start()
            status = .listening
        } catch {
            status = .error(error.localizedDescription)
            log.error("listener failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener.stop()
        sessions.removeAll()
        status = .idle
    }

    func refreshReadiness() {
        Task.detached {
            let report = Readiness.probe()
            await MainActor.run { self.readiness = report }
        }
    }

    /// Display wake / reconfiguration: rebuild capture on every active session.
    private func observeDisplayChanges() {
        guard displayObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        displayObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartSessions() }
        })
        displayObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartSessions() }
        })
    }

    private func restartSessions() {
        for session in sessions {
            Task { await session.restartCapture() }
        }
    }

    var canRestartSafely: Bool {
        readiness?.fileVaultOn == true && readiness?.authRestartSupported == true
    }

    /// Menu-bar "Restart Safely…": stage the unlock key, then let the user restart the usual way so
    /// every app gets to save first.
    func restartSafely() {
        guard SafeRestartPrompt.run(explanation: SafeRestart.promptExplanation) else { return }
        safeRestartStaged = true
        if SafeRestart.requestRestart() { return }
        let done = NSAlert()
        done.messageText = "Ready to Restart"
        done.informativeText = "Choose Restart from the Apple menu now. FileVault will unlock by itself for this one restart, and the Mac will come back at the login window."
        done.addButton(withTitle: "OK")
        NSApp.activate()
        done.runModal()
    }

    func generatePairingCode() {
        pairingCode = trust.newPairingCode()
    }

    func requestScreenPermission() {
        ScreenCapture.requestPermission()
        refreshPermissions()
    }

    func requestInputPermission() {
        InputInjector.requestPermission()
        refreshPermissions()
    }

    func revoke(_ fingerprint: String) {
        trust.revoke(fingerprint: fingerprint)
    }

    func openTailscaleAdmin() {
        NSWorkspace.shared.open(TailscaleCLI.adminConsoleURL)
    }

    /// Every connection starts by saying what it is: a `hello` opens a session; an
    /// `attachMedia` with a live token from the same address becomes that session's file channel.
    /// Anything else, or silence for 15 s, is dropped.
    private func accept(_ connection: NWConnection) {
        let peer = Self.describe(connection.endpoint)
        let peerHost = Self.hostPart(connection.endpoint)
        // Bounded so a file arriving faster than the disk takes it pushes back through TCP.
        let channel = MessageChannel(connection: connection, label: "vantage.host.session", maxBufferedMessages: 64)
        Task {
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await channel.close()
            }
            defer { timeout.cancel() }
            let first: Message?
            do {
                try await channel.start()
                first = try await channel.receive()
            } catch {
                log.error("connection from \(peer, privacy: .public) ended before it said anything")
                await channel.close()
                return
            }
            timeout.cancel()
            switch first {
            case .hello(let hello):
                startSession(hello: hello, channel: channel, peer: peer, peerHost: peerHost)
            case .attachMedia(let attach):
                guard let session = attachTokens.claim(attach.sessionToken, peer: peerHost) else {
                    log.error("refusing a file channel from \(peer, privacy: .public): unknown, used, or foreign token")
                    await channel.close()
                    return
                }
                log.info("file channel from \(peer, privacy: .public)")
                await session.attachFileChannel(channel)
            default:
                log.error("refusing a connection from \(peer, privacy: .public) that opened with \(String(describing: first?.kind), privacy: .public)")
                await channel.close()
            }
        }
    }

    private func startSession(hello: Hello, channel: MessageChannel, peer: String, peerHost: String) {
        let session = HostSession(channel: channel, identity: identity, trust: trust, peerDescription: peer, peerHost: peerHost,
                                  attachTokens: attachTokens,
                                  onFileChannel: { [weak self] fileChannel in Task { @MainActor in self?.fileChannelOpened(fileChannel) } },
                                  onEnded: { [weak self] ended in Task { @MainActor in self?.remove(ended) } })
        sessions.append(session)
        status = .connected(clientCount: sessions.count)
        log.info("session created for \(peer, privacy: .public)")
        Task { await session.run(hello: hello) }
    }

    private func remove(_ session: HostSession) {
        sessions.removeAll { $0 === session }
        fileChannels.removeAll { $0.session === session }
        status = sessions.isEmpty ? .listening : .connected(clientCount: sessions.count)
    }

    // MARK: File transfer

    private func fileChannelOpened(_ fileChannel: HostFileChannel) {
        guard sessions.contains(where: { $0 === fileChannel.session }) else { return }
        fileChannels.removeAll { $0.session === fileChannel.session }
        fileChannels.append(fileChannel)
        let engine = fileChannel.engine
        Task {
            for await event in engine.events { handle(event, on: fileChannel) }
            fileChannels.removeAll { $0.engine === engine }
        }
        #if DEBUG
        if let path = HostOptions.shared.sendFileOnConnect {
            send([URL(fileURLWithPath: path)], to: fileChannel)
        }
        #endif
    }

    private func handle(_ event: FileTransferEvent, on channel: HostFileChannel) {
        switch event {
        case .started(let item):
            if let index = transfers.firstIndex(where: { $0.id == item.id }) {
                transfers[index].state = .active
            } else {
                transfers.append(HostTransfer(id: item.id, name: item.name, byteCount: item.byteCount, direction: item.direction,
                                              deviceName: channel.clientName, state: .active))
            }
        case .progress(let id, let bytes):
            if let index = transfers.firstIndex(where: { $0.id == id }) { transfers[index].bytesDone = bytes }
        case .finished(let id, let outcome):
            guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
            transfers[index].finish(outcome)
            let transfer = transfers[index]
            guard !HostFileStore.current.isSynthetic else {
                if case .received(let url) = outcome { log.info("synthetic host saved a received file at \(url.path(percentEncoded: false), privacy: .public)") }
                return
            }
            switch outcome {
            case .received(let url): HostNotifications.shared.received(url, from: transfer.deviceName)
            case .sent: HostNotifications.shared.sent(transfer.name, to: transfer.deviceName)
            case .failed(let reason): HostNotifications.shared.failed(transfer.name, sending: transfer.direction == .sending, device: transfer.deviceName, reason: reason)
            case .cancelled: break
            }
        }
        trimTransfers()
    }

    /// Queues files for the iPad; they go one at a time, in order.
    func send(_ urls: [URL], to fileChannel: HostFileChannel) {
        let queued = urls.map { url in
            HostTransfer(id: UUID(), name: url.lastPathComponent, byteCount: Self.size(of: url), direction: .sending,
                         deviceName: fileChannel.clientName, state: .waiting, source: url)
        }
        transfers.append(contentsOf: queued)
        let engine = fileChannel.engine
        Task {
            for transfer in queued {
                let outcome = await engine.send(fileAt: transfer.source!, id: transfer.id)
                // A closed channel ends its event stream, so settle the row here too.
                if let index = transfers.firstIndex(where: { $0.id == transfer.id }), transfers[index].isActive {
                    transfers[index].finish(outcome)
                }
            }
        }
    }

    func cancelTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].isActive else { return }
        // One still waiting its turn is settled now; the engine skips it when the turn comes.
        if transfers[index].state == .waiting { transfers[index].finish(.cancelled(byPeer: false)) }
        for channel in fileChannels { Task { await channel.engine.cancel(id) } }
    }

    /// "Send File to ⟨iPad⟩…": an open panel, then the queue.
    func chooseFilesToSend(to fileChannel: HostFileChannel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.title = "Send to \(fileChannel.clientName)"
        panel.message = "Choose files to send to \(fileChannel.clientName). They'll be in Files, in the Vantage folder."
        panel.prompt = "Send"
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        // The session may have ended while the panel was open.
        guard let live = fileChannels.first(where: { $0.session === fileChannel.session }) else { return }
        send(panel.urls, to: live)
    }

    /// Keeps finished rows for a minute, and never more than a handful.
    private func trimTransfers() {
        let cutoff = Date.now.addingTimeInterval(-60)
        transfers.removeAll { !$0.isActive && ($0.finishedAt ?? .now) < cutoff }
        let finished = transfers.filter { !$0.isActive }
        if finished.count > 5 {
            let drop = Set(finished.prefix(finished.count - 5).map(\.id))
            transfers.removeAll { drop.contains($0.id) }
        }
    }

    private static func size(of url: URL) -> UInt64 {
        UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .failed(let error):
            status = .error(error.localizedDescription)
            log.error("listener failed: \(error.localizedDescription, privacy: .public); retrying in 3s")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.listener.stop()
                try? self.listener.start()
            }
        case .ready: if sessions.isEmpty { status = .listening }
        default: break
        }
    }

    private func refreshTrusted() {
        trustedClients = trust.trustedClients()
    }

    func refreshPermissions() {
        hasScreenPermission = ScreenCapture.preflightPermission()
        hasInputPermission = InputInjector.hasPermission()
    }

    private func refreshTailscale() {
        Task.detached {
            let running = TailscaleCLI.isRunning()
            let name = (try? TailscaleCLI.status())?.selfNode?.dnsName ?? ""
            await MainActor.run {
                self.tailscaleRunning = running
                self.tailscaleSelfName = name.hasSuffix(".") ? String(name.dropLast()) : name
            }
        }
    }

    /// The address alone ("100.101.1.40", "fd7a:…", "127.0.0.1"): what the file channel's peer
    /// must match.
    private static func hostPart(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return String(describing: endpoint) }
        switch host {
        case .ipv4(let address): return address.debugDescription
        case .ipv6(let address): return address.debugDescription
        case .name(let name, _): return name
        @unknown default: return String(describing: host)
        }
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        if case let .hostPort(host, port) = endpoint {
            return "\(host):\(port)"
        }
        return String(describing: endpoint)
    }
}

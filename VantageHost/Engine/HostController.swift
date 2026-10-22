import AppKit
import Foundation
import Network
import Observation
import SystemConfiguration
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
    /// Files-only sessions (Send Files from the iPad's device list): authenticated, no screen.
    private var fileSessions: [HostSession] = []
    /// Tokens a session's second (file) connection presents to join it.
    private let attachTokens = AttachTokenRegistry<HostSession>()
    /// Connected clients with a file channel, most recent last.
    private(set) var fileChannels: [HostFileChannel] = []
    /// Files moving this run (both ways), newest last, for the menu.
    private(set) var transfers: [HostTransfer] = []
    /// Notifications, the on-screen notice, Finder, and Dock progress for files as they move.
    private let arrivals = FileArrivals()
    let loginItem = LoginItem()
    private var displayObservers: [any NSObjectProtocol] = []

    private(set) var status: Status = .idle
    private(set) var tailscaleRunning = false
    private(set) var tailscaleSelfName: String = ""
    private(set) var hasScreenPermission = false
    private(set) var hasInputPermission = false
    /// The user has asked for Screen Recording since launch (Allow…), so if it's still missing,
    /// the UI explains the stale-entry fix (`HostPermission.staleEntryHelp`).
    private(set) var askedForScreenPermission = false
    /// The same for Accessibility.
    private(set) var askedForInputPermission = false
    private(set) var trustedClients: [TrustStore.TrustedClient] = []
    private(set) var readiness: Readiness.Report?
    /// The code on show, until it's used, burned, withdrawn (Done), or its ten minutes run out.
    private(set) var pairingCode: String?
    /// When `pairingCode` stops working; nil for a fixed DEBUG code, which never expires.
    private(set) var pairingCodeExpiresAt: Date?
    private var pairingExpiryTask: Task<Void, Never>?
    /// A device that paired a moment ago, for a short "Paired with ⟨name⟩" in the menu.
    private(set) var recentlyPaired: String?
    private var recentlyPairedTask: Task<Void, Never>?
    private var trustLoaded = false
    /// Who is watching right now: screen sessions that got past authentication, oldest first.
    private(set) var connectedDevices: [ConnectedDevice] = []
    /// A FileVault unlock key is waiting for the next restart, so don't ask again.
    private(set) var safeRestartStaged = false

    /// This Mac's name as Sharing settings has it ("Drew's MacBook Pro"); never `Host.current()`,
    /// which can block on DNS.
    let computerName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "This Mac"

    var fingerprint: String { identity.fingerprint }
    /// A screen session is up (files-only sessions live in `fileSessions` and never count): the
    /// restart guard and "is this Mac being watched" (`FileArrivals.isViewedRemotely`) go by it.
    var hasConnectedClients: Bool { !sessions.isEmpty }

    init() {
        let keychain = KeychainStore(service: "com.benjaminlevinson.vantage.host")
        self.identity = (try? keychain.loadOrCreateIdentity()) ?? DeviceIdentity()
        trust.onChange = { [weak self] in
            Task { @MainActor in self?.refreshTrusted() }
        }
        trust.onPairingCodeCleared = { [weak self] in
            Task { @MainActor in self?.pairingCodeCleared() }
        }
        arrivals.isViewedRemotely = { [weak self] in self?.hasConnectedClients ?? false }
        arrivals.onCancel = { [weak self] id in self?.cancelTransfer(id) }
        refreshTrusted()
        refreshPermissions()
        refreshTailscale()
        refreshReadiness()
    }

    func start() {
        refreshPermissions()
        refreshTailscale()
        monitorPermissions()
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
        fileSessions.removeAll()
        for channel in fileChannels { Task { await channel.engine.close() } }
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

    /// Shows a fresh code, replacing any old one, and hides it when its ten minutes are up.
    func generatePairingCode() {
        pairingCode = trust.newPairingCode()
        pairingExpiryTask?.cancel()
        guard HostOptions.shared.fixedPairingCode == nil else {
            pairingCodeExpiresAt = nil
            return
        }
        let expiry = Date().addingTimeInterval(TrustStore.pairingLifetime)
        pairingCodeExpiresAt = expiry
        pairingExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(expiry.timeIntervalSinceNow)) } catch { return }
            self?.cancelPairingCode()
        }
    }

    /// Done, or the code ran out: it stops working on the spot, not just off the screen.
    func cancelPairingCode() {
        trust.cancelPairingCode()
        pairingCodeCleared()
    }

    private func pairingCodeCleared() {
        // A new code may have replaced the one that cleared.
        guard trust.currentPairingCode == nil else { return }
        pairingCode = nil
        pairingCodeExpiresAt = nil
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
    }

    /// Opens the Tailscale app (whichever flavour is installed), for when it isn't running.
    func openTailscale() {
        let ids = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]
        if let url = ids.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
        }
    }

    /// Asks macOS (which adds Casement Host to the list) and opens the list itself: with a stale
    /// entry from another copy of the app, macOS shows no prompt at all, so the pane is the one
    /// place the user can fix it.
    func requestScreenPermission() {
        ScreenCapture.requestPermission()
        HostPermission.screenRecording.openSettings()
        askedForScreenPermission = true
        refreshPermissions()
    }

    func requestInputPermission() {
        InputInjector.requestPermission()
        HostPermission.accessibility.openSettings()
        askedForInputPermission = true
        refreshPermissions()
    }

    /// A permission was asked for and macOS still says no: time to explain the stale entry.
    var permissionStillMissingAfterAsking: Bool {
        (askedForScreenPermission && !hasScreenPermission) || (askedForInputPermission && !hasInputPermission)
    }

    func revoke(_ fingerprint: String) {
        trust.revoke(fingerprint: fingerprint)
        // A revoked device loses what it has open too, not just its next connection.
        for session in sessions + fileSessions { Task { await session.endIfClient(fingerprint) } }
        // A file channel can outlive its session, so it doesn't end with one: close it here.
        for channel in fileChannels where channel.clientKey == fingerprint { Task { await channel.engine.close() } }
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
                                  onStreaming: { [weak self] session, name, model, key in
                                      Task { @MainActor in
                                          self?.connectedDevices.append(ConnectedDevice(session: session, name: name, model: model, fingerprint: key))
                                      }
                                  },
                                  onEnded: { [weak self] ended in Task { @MainActor in self?.remove(ended) } })
        // A files-only session isn't a connected screen: it stays out of the status and the
        // restart guard, and shows up only as its transfers.
        if hello.features?.filesOnly == true {
            fileSessions.append(session)
            log.info("files-only session created for \(peer, privacy: .public)")
        } else {
            sessions.append(session)
            status = .connected(clientCount: sessions.count)
            log.info("session created for \(peer, privacy: .public)")
        }
        Task { await session.run(hello: hello) }
    }

    private func remove(_ session: HostSession) {
        sessions.removeAll { $0 === session }
        fileSessions.removeAll { $0 === session }
        connectedDevices.removeAll { $0.session === session }
        // Its file channel carries on until the iPad closes it.
        for index in fileChannels.indices where fileChannels[index].session === session {
            fileChannels[index].sessionEnded = true
            watchDetached(fileChannels[index].engine)
        }
        status = sessions.isEmpty ? .listening : .connected(clientCount: sessions.count)
    }

    // MARK: File transfer

    /// How long a file channel whose session has ended may sit with nothing moving before the Mac
    /// closes it. The iPad normally closes it itself after 30 s; this covers one that went away.
    static let detachedIdleLimit: Duration = .seconds(120)

    private func fileChannelOpened(_ fileChannel: HostFileChannel) {
        var fileChannel = fileChannel
        // The session may have ended between the attach and now; the channel still runs.
        fileChannel.sessionEnded = !(sessions + fileSessions).contains { $0 === fileChannel.session }
        fileChannels.removeAll { $0.session === fileChannel.session }
        fileChannels.append(fileChannel)
        if fileChannel.sessionEnded { watchDetached(fileChannel.engine) }
        log.info("file channel from \(fileChannel.clientName, privacy: .public) is up\(fileChannel.isFilesOnly ? " (files only)" : "", privacy: .public)")
        if let missing = HostFileStore.current.unavailableChoice {
            log.error("can't save received files to \(missing, privacy: .public); using Downloads")
        }
        let engine = fileChannel.engine
        Task {
            for await event in engine.events {
                // A file cut off by the connection waits for the iPad to come back and resume it,
                // rather than counting as failed. Sends are settled by `startSending`.
                if case .finished(let id, .failed) = event, await engine.hasClosed, holdForResume(id, on: fileChannel) { continue }
                handle(event, on: fileChannel)
            }
            fileChannels.removeAll { $0.engine === engine }
        }
        resumeInterruptedSends(on: fileChannel)
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
            if let transfer = transfers.first(where: { $0.id == item.id }) {
                // The folder this channel's engine saves into (Settings can change it for later
                // channels; a channel can outlive its session, so it travels with the channel), or
                // where a resumed file's partial already is.
                arrivals.started(transfer, receivingInto: ResumeFolders.shared.folder(for: item.id) ?? channel.receiveDirectory)
            }
        case .progress(let id, let bytes):
            if let index = transfers.firstIndex(where: { $0.id == id }) {
                transfers[index].record(bytes: bytes)
                arrivals.progressed(transfers[index])
            }
        case .finished(let id, let outcome):
            ResumeFolders.shared.set(nil, for: id)
            guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
            transfers[index].finish(outcome)
            // Notifications, the on-screen notice, and Finder, per Settings → Files.
            arrivals.finished(transfers[index], outcome)
        }
        trimTransfers()
    }

    /// Queues files for the iPad; they go one at a time, in order.
    func send(_ urls: [URL], to fileChannel: HostFileChannel) {
        let queued = urls.map { url in
            HostTransfer(id: UUID(), name: url.lastPathComponent, byteCount: Self.size(of: url), direction: .sending,
                         deviceName: fileChannel.clientName, state: .waiting, source: url, clientKey: fileChannel.clientKey,
                         destination: fileChannel.clientDestination)
        }
        transfers.append(contentsOf: queued)
        startSending(queued.map(\.id), on: fileChannel)
    }

    /// Sends the rows with these ids in order, each under its own id so the iPad can resume one
    /// it already has part of.
    private func startSending(_ ids: [UUID], on fileChannel: HostFileChannel) {
        let engine = fileChannel.engine
        Task {
            for id in ids {
                guard let row = transfers.first(where: { $0.id == id }), row.isActive, let source = row.source else { continue }
                let outcome = await engine.send(fileAt: source, id: id)
                // A closed channel ends its event stream, so settle the row here too.
                guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].isActive else { continue }
                if case .failed = outcome, await engine.hasClosed {
                    interrupt(index) // resumes on the iPad's next file channel
                } else {
                    transfers[index].finish(outcome)
                }
            }
        }
    }

    /// The iPad is back: carry on with the files that were on their way to it when it dropped.
    private func resumeInterruptedSends(on fileChannel: HostFileChannel) {
        expireInterruptions()
        let ids = transfers.filter { $0.direction == .sending && $0.interruptedAt != nil && $0.clientKey == fileChannel.clientKey }.map(\.id)
        guard !ids.isEmpty else { return }
        log.info("resuming \(ids.count, privacy: .public) interrupted file(s) to \(fileChannel.clientName, privacy: .public)")
        for id in ids {
            if let index = transfers.firstIndex(where: { $0.id == id }) { transfers[index].interruptedAt = nil }
        }
        startSending(ids, on: fileChannel)
    }

    /// Marks a file the connection cut off as waiting for its iPad; false if there's no such
    /// active row. A receive remembers where its partial is, and drops its Finder/Dock progress
    /// until it resumes (a bar stalled for up to an hour helps no one).
    private func holdForResume(_ id: UUID, on channel: HostFileChannel) -> Bool {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].isActive else { return false }
        if transfers[index].direction == .sending { return true } // `startSending` settles it
        if ResumeFolders.shared.folder(for: id) == nil { ResumeFolders.shared.set(channel.receiveDirectory, for: id) }
        interrupt(index)
        arrivals.paused(transfers[index])
        return true
    }

    private func interrupt(_ index: Int) {
        transfers[index].state = .waiting
        transfers[index].interruptedAt = .now
        scheduleInterruptionExpiry()
    }

    private var expiryTask: Task<Void, Never>?

    /// Checks every minute for interrupted files whose iPad hasn't come back in time.
    private func scheduleInterruptionExpiry() {
        guard expiryTask == nil else { return }
        expiryTask = Task {
            while transfers.contains(where: { $0.interruptedAt != nil }) {
                try? await Task.sleep(for: .seconds(60))
                expireInterruptions()
            }
            expiryTask = nil
        }
    }

    private func expireInterruptions() {
        let cutoff = Date.now.addingTimeInterval(-HostTransfer.resumeWindow)
        for index in transfers.indices {
            guard let since = transfers[index].interruptedAt, since < cutoff else { continue }
            let outcome = FileTransferOutcome.failed("The connection was lost.")
            transfers[index].finish(outcome)
            if transfers[index].direction == .receiving { Self.discardPartial(transfers[index].id) }
            // It never came back: now it's a failure, and says so like any other.
            arrivals.finished(transfers[index], outcome)
        }
        trimTransfers()
    }

    func cancelTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].isActive else { return }
        // A received file waiting for its iPad to come back has only a partial file here.
        if transfers[index].interruptedAt != nil, transfers[index].direction == .receiving { Self.discardPartial(id) }
        // One still waiting its turn is settled now; the engine skips it when the turn comes.
        if transfers[index].state == .waiting { transfers[index].finish(.cancelled(byPeer: false)) }
        for channel in fileChannels { Task { await channel.engine.cancel(id) } }
    }

    /// Deletes a paused receive's partial, wherever it was being written.
    private static func discardPartial(_ id: UUID) {
        let name = FileTransferEngine.partialPrefix + id.uuidString + FileTransferEngine.partialSuffix
        let folder = ResumeFolders.shared.folder(for: id) ?? HostFileStore.current.directory
        try? FileManager.default.removeItem(at: folder.appending(path: name))
        ResumeFolders.shared.set(nil, for: id)
    }

    /// "Send File to ⟨iPad⟩…": an open panel, then the queue.
    func chooseFilesToSend(to fileChannel: HostFileChannel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.title = "Send to \(fileChannel.clientName)"
        panel.message = "Choose files to send to \(fileChannel.clientName). They'll be in \(fileChannel.clientDestination)."
        panel.prompt = "Send"
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        // The channel may have closed while the panel was open; another from the same iPad will do.
        guard let live = fileChannels.first(where: { $0.engine === fileChannel.engine })
                ?? fileChannels.last(where: { $0.clientKey == fileChannel.clientKey }) else { return }
        send(panel.urls, to: live)
    }

    /// Closes a file channel whose session has ended once nothing has moved on it for
    /// `detachedIdleLimit`: the iPad normally closes it first, but it may have gone away.
    private func watchDetached(_ engine: FileTransferEngine) {
        Task {
            var idleSince = ContinuousClock.now
            while fileChannels.contains(where: { $0.engine === engine }) {
                try? await Task.sleep(for: .seconds(15))
                if await engine.isBusy { idleSince = .now; continue }
                if ContinuousClock.now - idleSince >= Self.detachedIdleLimit {
                    log.info("closing an idle file channel whose session ended")
                    await engine.close()
                    return
                }
            }
        }
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
        let known = Set(trustedClients.map(\.fingerprint))
        let clients = trust.trustedClients()
        // A device that wasn't trusted a moment ago just used the code (not the first load).
        if trustLoaded, let added = clients.last(where: { !known.contains($0.fingerprint) }) {
            showRecentlyPaired(added.name)
        }
        trustedClients = clients
        trustLoaded = true
    }

    private func showRecentlyPaired(_ name: String) {
        recentlyPaired = name
        recentlyPairedTask?.cancel()
        recentlyPairedTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            self?.recentlyPaired = nil
        }
    }

    /// Called when Screen Recording or Accessibility was allowed and no longer is (the setup
    /// window opens again).
    var onRequiredPermissionLost: (() -> Void)?
    private var permissionMonitor: Task<Void, Never>?

    /// Live: both checks ask macOS again every time (the views poll this while they're open).
    func refreshPermissions() {
        let screen = ScreenCapture.preflightPermission()
        let input = InputInjector.hasPermission()
        let lost = (hasScreenPermission && !screen) || (hasInputPermission && !input)
        if screen != hasScreenPermission { hasScreenPermission = screen }
        if input != hasInputPermission {
            hasInputPermission = input
            log.info("accessibility \(input ? "allowed" : "not allowed", privacy: .public)")
        }
        if lost { onRequiredPermissionLost?() }
    }

    /// A slow check in the background, so a permission turned off in System Settings is noticed
    /// without the menu being open.
    private func monitorPermissions() {
        guard permissionMonitor == nil else { return }
        permissionMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.refreshPermissions()
            }
        }
    }

    func refreshTailscale() {
        Task.detached {
            let running = TailscaleCLI.isRunning()
            let name = (try? TailscaleCLI.status())?.selfNode?.dnsName ?? ""
            await MainActor.run {
                self.tailscaleRunning = running
                self.tailscaleSelfName = name.hasSuffix(".") ? String(name.dropLast()) : name
            }
        }
    }

    /// The address alone ("100.64.0.40", "fd7a:…", "127.0.0.1"): what the file channel's peer
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

/// A device watching this Mac's screen, as the menu lists it.
struct ConnectedDevice: Identifiable {
    let session: HostSession
    let name: String
    /// The client's hardware model ("iPad16,6", "Mac16,1", "RealityDevice14,1").
    let model: String
    /// Its key's fingerprint, matching `TrustStore.TrustedClient.fingerprint`.
    let fingerprint: String
    var id: ObjectIdentifier { ObjectIdentifier(session) }

    var symbol: String { DeviceSymbol.for(model: model, name: name) }
}

/// The SF Symbol for a client device, from its hardware model ("iPhone17,1", "Mac16,1",
/// "RealityDevice14,1") or, for pairings saved before the model was, its name.
nonisolated enum DeviceSymbol {
    static func `for`(model: String?, name: String) -> String {
        if let model, !model.isEmpty {
            if model.hasPrefix("iPhone") { return "iphone" }
            if model.hasPrefix("Mac") { return "laptopcomputer" }
            if model.hasPrefix("RealityDevice") { return "vision.pro" }
            return "ipad.landscape"
        }
        // A name says "Drew's iPad Pro" or "Files Mac iPad": the most specific word wins.
        for (word, symbol) in [("iPad", "ipad.landscape"), ("iPhone", "iphone"), ("Vision", "vision.pro"),
                               ("MacBook", "laptopcomputer"), ("iMac", "desktopcomputer"), ("Mac", "desktopcomputer")]
        where name.localizedStandardContains(word) { return symbol }
        return "ipad.landscape"
    }
}

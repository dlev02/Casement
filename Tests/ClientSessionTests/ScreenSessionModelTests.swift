import Foundation
import Network
import Testing
import VantageCore
@testable import VantageClientLogic

// MARK: A loopback host for the screen session model

/// What the mock host's screen connection does once it's up.
private enum ScreenBehaviour: Sendable {
    case stay
    /// Drop the screen once the client has sent `count` messages after the stream request, then
    /// take the next connection and stay.
    case dropAfter(Int)
}

private final class MockOwner: Sendable {}

/// Stands in for Casement Host on loopback: authenticates, offers files (keeping them without the
/// screen or not, like a current or an older host), takes the file channel, and answers Curtain
/// as told.
private final class MockScreenHost: @unchecked Sendable {
    private let listener: NWListener
    private let registry = AttachTokenRegistry<MockOwner>()
    private let lock = NSLock()
    private let directory: URL
    private let keepsFiles: Bool
    private let behaviour: ScreenBehaviour
    /// Answer every `curtainRequest` with this (nil: the curtain goes up as asked).
    private let curtainRefusal: String?
    private let canManageVirtualDisplay: Bool
    private let platform: HostPlatform?
    enum DisplayEvent: Equatable, Sendable {
        case select(SelectDisplay)
        case restoreDisplays
    }

    private var screens = 0
    private var dropped = false
    private var engines: [FileTransferEngine] = []
    private var displayEvents: [DisplayEvent] = []
    private var screenChannel: MessageChannel?

    /// Answers the last stream request, as a host does once its display is fitted.
    func sendStreamConfig() async throws {
        let display = DisplayInfo(id: 1, name: "Display", pixelWidth: 2732, pixelHeight: 2048, pointWidth: 1366, pointHeight: 1024, scale: 2,
                                  originX: 0, originY: 0, isMain: true, isBuiltIn: false, isVirtual: false, refreshRate: 60)
        try await lock.withLock { screenChannel }?.send(.streamConfig(StreamConfig(display: display, codec: .hevc, fps: 60, bitrateKbps: 20_000)))
    }

    var port: UInt16 { listener.port!.rawValue }
    var screenCount: Int { lock.withLock { screens } }
    var receivedDisplayEvents: [DisplayEvent] { lock.withLock { displayEvents } }

    init(keepsFiles: Bool, behaviour: ScreenBehaviour = .stay, curtainRefusal: String? = nil,
         canManageVirtualDisplay: Bool = false, platform: HostPlatform? = nil) async throws {
        self.keepsFiles = keepsFiles
        self.behaviour = behaviour
        self.curtainRefusal = curtainRefusal
        self.canManageVirtualDisplay = canManageVirtualDisplay
        self.platform = platform
        directory = FileManager.default.temporaryDirectory.appending(path: "screen-mock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        listener = try NWListener(using: VantageNetwork.tcpParameters(), on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(MessageChannel(connection: connection, label: "mock.host", maxBufferedMessages: 64)) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume() }
                else if case .failed(let error) = state { listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
        let running = lock.withLock { engines }
        Task { for engine in running { await engine.close() } }
        try? FileManager.default.removeItem(at: directory)
    }

    private func accept(_ channel: MessageChannel) async {
        do {
            try await channel.start()
            guard let first = try await channel.receive() else { return }
            let peer = Self.host(channel.remoteEndpoint)
            switch first {
            case .hello(let hello):
                try await screen(channel, hello: hello, peer: peer)
            case .attachMedia(let attach):
                guard registry.claim(attach.sessionToken, peer: peer) != nil else { await channel.close(); return }
                let engine = FileTransferEngine(channel: channel, role: .host, configuration: .init(receiveDirectory: directory))
                lock.withLock { engines.append(engine) }
                await engine.run()
            default:
                await channel.close()
            }
        } catch {
            await channel.close()
        }
    }

    private func screen(_ channel: MessageChannel, hello: Hello, peer: String) async throws {
        let number = lock.withLock { screens += 1; screenChannel = channel; return screens }
        try await channel.send(.challenge(MockHost.challenge(for: hello, identity: DeviceIdentity(), hostName: "Mock Mac", isPaired: true,
                                                             hostPlatform: platform).0))
        guard case .authenticate? = try await channel.receive() else { throw ChannelError.closed }
        let owner = MockOwner()
        let token = registry.issue(for: owner, peer: peer)
        let capabilities = HostCapabilities(codecs: [.hevc], canManageVirtualDisplay: canManageVirtualDisplay, clipboard: true, maxFPS: 60,
                                            fileTransfer: true, filesOnlySessions: keepsFiles ? true : nil, platform: platform, curtain: true)
        try await channel.send(.authResult(AuthResult(status: .ok, sessionToken: token, capabilities: capabilities)))
        guard case .selectDisplay(let initial)? = try await channel.receive() else { throw ChannelError.closed }
        lock.withLock { displayEvents.append(.select(initial)) }
        var received = 0
        while let message = try await channel.receive() {
            received += 1
            switch message {
            case .curtainRequest(let request):
                let status = curtainRefusal.map { CurtainStatus(isUp: false, unavailable: $0) } ?? CurtainStatus(isUp: request.enabled)
                try await channel.send(.curtainStatus(status))
            case .selectDisplay(let select):
                lock.withLock { displayEvents.append(.select(select)) }
            case .hostCommand(let command) where command.command == .restoreDisplays:
                lock.withLock { displayEvents.append(.restoreDisplays) }
            default:
                break
            }
            if case .dropAfter(let count) = behaviour, number == 1, received >= count, !lock.withLock({ dropped }) {
                lock.withLock { dropped = true }
                break
            }
        }
        registry.revoke(owner: owner)
        await channel.close()
    }

    private static func host(_ endpoint: NWEndpoint?) -> String {
        guard case .hostPort(let host, _)? = endpoint else { return "?" }
        switch host {
        case .ipv4(let a): return a.debugDescription
        case .ipv6(let a): return a.debugDescription
        case .name(let n, _): return n
        @unknown default: return "?"
        }
    }
}

/// The saved computer and what the session records about it, in memory.
@MainActor private final class FakeStore: ScreenSessionStore {
    var device: SavedDevice
    var connections = 0
    init(device: SavedDevice) { self.device = device }
    func savedDevice(_ id: UUID) -> SavedDevice? { device.id == id ? device : nil }
    func markConnected(_ device: SavedDevice) { connections += 1 }
    func recordPlatform(_ platform: HostPlatform, for id: UUID) { device.os = platform.savedOS }
    func recordHostKey(_ key: Data, for id: UUID) { device.hostPublicKey = key }
    func adoptHostNaturalScroll(_ natural: Bool, for id: UUID) { if device.naturalScrollChosen != true { device.naturalScroll = natural } }
    func setPlayMacAudio(_ on: Bool, for id: UUID) { device.playMacAudio = on }
    func setCurtain(_ on: Bool, for id: UUID) { device.curtain = on }
    func setUseVirtualDisplay(_ on: Bool, for id: UUID) { device.useVirtualDisplay = on }
    func setQuality(_ preset: QualityPreset, for id: UUID) { device.quality = preset }
}

private enum Failure: Error { case timedOut(String) }

@MainActor
private func waitUntil(_ what: String, seconds: Double = 10, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw Failure.timedOut(what) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private func scratchFile(bytes: Int) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "screen-session-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "Holiday.mov")
    try Data(count: bytes).write(to: url)
    return url
}

private let viewport = Viewport(widthPoints: 800, heightPoints: 600, scale: 2)

/// A model on a fresh identity and its own files, against `host`.
@MainActor
private func makeModel(host: MockScreenHost, store: FakeStore) throws -> ScreenSessionModel {
    let files = FileTransferController(receiveDirectory: FileManager.default.temporaryDirectory.appending(path: "screen-received-\(UUID().uuidString)"))
    let session = ClientSession(identity: DeviceIdentity(), files: files)
    session.reconnectDelay = { _ in .milliseconds(50) }
    return ScreenSessionModel(device: store.device, store: store, session: session, viewport: viewport)
}

// MARK: Tests

/// What the screen session model decides by itself: where Type Password goes, when Disconnect
/// asks, what a refused Curtain does to the saved choice, and what a lost connection resets.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct ScreenSessionModelTests {
    private static let unlocked = HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native)
    private static let locked = HostStatus(isScreenLocked: true, isSecureInputActive: false, inputPath: .native)
    private static let secureField = HostStatus(isScreenLocked: false, isSecureInputActive: true, inputPath: .native)

    /// The whole routing table for the key button.
    @Test func typePasswordRouting() {
        let pc = HostNoun(.windows), mac = HostNoun.mac
        #expect(TypePasswordDecision.decide(host: pc, password: "hunter2", hasAccountName: true, status: Self.locked) == .nothing)
        #expect(TypePasswordDecision.decide(host: mac, password: nil, hasAccountName: true, status: nil) == .ask(.missing))
        #expect(TypePasswordDecision.decide(host: mac, password: "hunter2", hasAccountName: false, status: nil) == .type("hunter2"),
                "before the host has said anything, plain typing")
        #expect(TypePasswordDecision.decide(host: mac, password: "hunter2", hasAccountName: false, status: Self.unlocked) == .type("hunter2"))
        #expect(TypePasswordDecision.decide(host: mac, password: "hunter2", hasAccountName: false, status: Self.locked) == .ask(.needsAccount))
        #expect(TypePasswordDecision.decide(host: mac, password: "hunter2", hasAccountName: false, status: Self.secureField) == .ask(.needsAccount))
        #expect(TypePasswordDecision.decide(host: mac, password: "hunter2", hasAccountName: true, status: Self.locked) == .screenSharing)
        #expect(TypePasswordDecision.decide(host: mac, password: "hunter2", hasAccountName: true, status: Self.secureField) == .screenSharing)
    }

    /// Disconnect asks only when an older Mac, which keeps no file channel without the screen,
    /// would stop a file still moving; a current Mac keeps the files, so it ends at once.
    @Test @MainActor func disconnectAsksOnlyWhenAnOlderMacWouldStopFiles() async throws {
        for keepsFiles in [false, true] {
            let host = try await MockScreenHost(keepsFiles: keepsFiles)
            defer { host.stop() }
            let store = FakeStore(device: SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port))
            let model = try makeModel(host: host, store: store)
            model.session.files.chunkDelayForTesting = .milliseconds(40) // read when the file channel comes up
            model.start(viewport: viewport)
            try await waitUntil("file channel") { model.session.files.isConnected }
            #expect(model.session.fileLink.macKeepsFiles == keepsFiles)
            #expect(!model.disconnectWouldStopFiles, "nothing is moving yet")

            model.session.files.send([try scratchFile(bytes: 3 << 20)], securityScoped: false)
            try await waitUntil("under way") { (model.session.files.transfers.first?.bytesDone ?? 0) > 0 }
            #expect(model.disconnectWouldStopFiles == !keepsFiles)
            model.disconnect()
            if keepsFiles {
                #expect(model.isEnded && !model.isConfirmingDisconnect, "a current Mac keeps the files moving")
                #expect(model.phase == .stopped)
            } else {
                #expect(model.isConfirmingDisconnect && !model.isEnded, "an older Mac gets the one confirmation")
                #expect(model.phase == .running, "still connected while it asks")
                model.end()
                #expect(model.isEnded && model.phase == .stopped)
            }
            model.session.files.cancelAll()
        }
    }

    /// The saved Curtain choice asks on connect; a host that can't do it answers why, and the
    /// choice is cleared so the next connection doesn't ask again.
    @Test @MainActor func refusedCurtainClearsTheSavedChoice() async throws {
        let host = try await MockScreenHost(keepsFiles: true, curtainRefusal: "The Mac's displays can't be blacked out.")
        defer { host.stop() }
        var device = SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port)
        device.curtain = true
        let store = FakeStore(device: device)
        let model = try makeModel(host: host, store: store)
        #expect(model.wantsCurtain && model.isCurtainOn, "the saved choice, until the host answers")
        model.start(viewport: viewport)
        try await waitUntil("the host's answer") { model.session.curtainStatus != nil }
        try await waitUntil("the choice cleared") { store.device.curtain == false }
        #expect(!model.isCurtainOn)
        #expect(model.macAudioNotice.value == "The Mac's displays can't be blacked out.")
        #expect(store.connections == 1, "connecting was recorded")
        // Retry takes the saved choices as they are now, not as the session started.
        store.device.playMacAudio = false
        model.retry()
        #expect(!model.session.wantsCurtain && !model.session.wantsMacAudio)
        model.stop()
    }

    /// A dropped connection forgets the first frame (the overlay comes back until the next
    /// one) and tells dictation, which loses the recording on its way to the Mac; the
    /// reconnection starts clean.
    @Test @MainActor func reconnectResetsTheFirstFrameAndDictation() async throws {
        let host = try await MockScreenHost(keepsFiles: true, behaviour: .dropAfter(3))
        defer { host.stop() }
        let store = FakeStore(device: SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port))
        let model = try makeModel(host: host, store: store)
        model.start(viewport: viewport)
        try await waitUntil("connected") { model.isConnected }
        model.video.onFirstFrame?(model.pictureEpoch)
        try await waitUntil("first frame") { model.hasPicture }
        #expect(model.isLive)
        model.dictation.showFixture("macTranscribing") // a clip on its way to the Mac
        #expect(model.dictation.phase == .transcribing)

        // The next pings make the mock drop the screen; the session reconnects on its own.
        try await waitUntil("dropped") { !model.isConnected }
        #expect(!model.hasPicture && !model.isLive)
        // The recording in flight is lost (text under review would be kept).
        guard case .failed(let failure) = model.dictation.phase else { Issue.record("\(model.dictation.phase)"); return }
        #expect(failure.title == "Connection Lost")
        try await waitUntil("reconnected") { model.isConnected && host.screenCount == 2 }
        #expect(!model.hasPicture, "no picture until the new connection's first frame")
        #expect(store.connections == 2)
        model.dictation.showFixture("macTranscribing") // a clip on its way when the screen closes
        model.stop()
        #expect(model.phase == .stopped && !model.isEnded, "stopping isn't Disconnect")
        #expect(model.dictation.phase == .idle, "closing the screen drops the clip, so the mic can't open later")
    }

    /// With the display fitted, the first picture waits for the host's answer to the fitted
    /// request: a frame before it stays hidden, a view that changed shape meanwhile is asked for
    /// once more after the answer (one request at a time), and the picture shows only with a
    /// frame of that stream.
    @Test @MainActor func theFirstPictureWaitsForTheFittedDisplay() async throws {
        let host = try await MockScreenHost(keepsFiles: true, canManageVirtualDisplay: true, platform: .windows)
        defer { host.stop() }
        var device = SavedDevice(name: "Desk PC", host: "127.0.0.1", port: host.port, os: "Windows")
        device.useVirtualDisplay = true
        let model = try makeModel(host: host, store: FakeStore(device: device))
        model.start(viewport: viewport)
        try await waitUntil("connected") { model.isConnected && host.receivedDisplayEvents.count == 1 }
        #expect(model.session.isAwaitingFittedStream)
        model.video.onFirstFrame?(model.pictureEpoch) // a frame before the host answered
        let settled = Viewport(widthPoints: 1366, heightPoints: 1024, scale: 2)
        model.viewportChanged(settled) // the view settles into another shape meanwhile
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.receivedDisplayEvents.count == 1 && !model.hasPicture)

        try await host.sendStreamConfig()
        try await waitUntil("refit after the answer") { host.receivedDisplayEvents.count == 2 }
        guard case .select(let refit) = host.receivedDisplayEvents[1] else { Issue.record("expected the refit"); return }
        #expect(refit.selection == .fitViewport(settled) && refit.useVirtualDisplay == true)
        #expect(model.session.isAwaitingFittedStream && !model.hasPicture)

        try await host.sendStreamConfig()
        try await waitUntil("answered") { !model.session.isAwaitingFittedStream }
        model.video.onFirstFrame?(model.pictureEpoch - 1) // a late word from before the refit
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.hasPicture)
        model.video.onFirstFrame?(model.pictureEpoch)
        try await waitUntil("picture") { model.hasPicture && model.isLive }
        model.stop()
    }

    /// Toggling Fit Display / Virtual Display live updates the saved device, asks the host to fit
    /// or restore in the right order (a PC restores on `selectDisplay(useVirtualDisplay: false)`
    /// alone; a Mac switches capture back to the main display first and then sends
    /// `restoreDisplays`), and gates whether later viewport changes resend `selectDisplay`.
    @Test @MainActor func fitDisplayTogglesLiveAndGatesViewportRefits() async throws {
        // PC host: Fit Display on -> viewport refit -> Fit Display off (no `restoreDisplays`).
        do {
            let host = try await MockScreenHost(keepsFiles: true, canManageVirtualDisplay: true, platform: .windows)
            defer { host.stop() }
            let store = FakeStore(device: SavedDevice(name: "Desk PC", host: "127.0.0.1", port: host.port, os: "Windows"))
            let model = try makeModel(host: host, store: store)
            #expect(!model.isFitDisplayAvailable && !model.fitDisplayToggle.isAvailable, "disabled before connect")
            model.start(viewport: viewport)
            try await waitUntil("connected") { model.isConnected && host.receivedDisplayEvents.count == 1 }
            #expect(model.isFitDisplayAvailable && model.fitDisplayToggle.isAvailable && !model.isFittingDisplay)
            guard case .select(let initial) = host.receivedDisplayEvents[0] else { Issue.record("expected initial select"); return }
            #expect(initial.useVirtualDisplay == false)

            model.toggleFitDisplay()
            try await waitUntil("fit requested") { host.receivedDisplayEvents.count == 2 }
            #expect(store.device.useVirtualDisplay == true && model.isFittingDisplay)
            guard case .select(let turnedOn) = host.receivedDisplayEvents[1] else { Issue.record("expected select on"); return }
            #expect(turnedOn.useVirtualDisplay == true)

            let fullScreen = Viewport(widthPoints: 1728, heightPoints: 1080, scale: 2)
            model.viewportChanged(fullScreen)
            try await waitUntil("refit sent") { host.receivedDisplayEvents.count == 3 }
            guard case .select(let refit) = host.receivedDisplayEvents[2] else { Issue.record("expected refit"); return }
            #expect(refit.selection == .fitViewport(fullScreen) && refit.useVirtualDisplay == true)

            model.toggleFitDisplay()
            try await waitUntil("fit turned off") { host.receivedDisplayEvents.count == 4 }
            #expect(store.device.useVirtualDisplay == false && !model.isFittingDisplay)
            guard case .select(let turnedOff) = host.receivedDisplayEvents[3] else { Issue.record("expected select off"); return }
            #expect(turnedOff.useVirtualDisplay == false)

            // Later resizes while off stay quiet (`session.updateViewport` directly avoids a debounce sleep).
            model.session.updateViewport(Viewport(widthPoints: 1280, heightPoints: 800, scale: 2))
            model.stop()
            #expect(host.receivedDisplayEvents.count == 4)
        }

        // Mac host: turning Virtual Display off switches capture back to the main display BEFORE
        // sending `restoreDisplays` to disconnect the virtual display.
        do {
            let host = try await MockScreenHost(keepsFiles: true, canManageVirtualDisplay: true, platform: .macOS)
            defer { host.stop() }
            var device = SavedDevice(name: "Studio Mac", host: "127.0.0.1", port: host.port, os: "macOS")
            device.useVirtualDisplay = true
            let store = FakeStore(device: device)
            let model = try makeModel(host: host, store: store)
            model.start(viewport: viewport)
            try await waitUntil("connected") { model.isConnected && host.receivedDisplayEvents.count == 1 }
            #expect(model.isFittingDisplay)

            model.toggleFitDisplay()
            try await waitUntil("select off then restoreDisplays") { host.receivedDisplayEvents.count == 3 }
            guard case .select(let switchedToMain) = host.receivedDisplayEvents[1] else {
                Issue.record("expected selectDisplay before restoreDisplays, got \(host.receivedDisplayEvents)")
                return
            }
            #expect(switchedToMain.useVirtualDisplay == false)
            #expect(host.receivedDisplayEvents[2] == .restoreDisplays)
            model.stop()
        }
    }
}

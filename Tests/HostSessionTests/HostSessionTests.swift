import Foundation
import Network
import Synchronization
import Testing
import VantageCore
@testable import VantageHostSession

/// The Mac host's real `HostSession` over loopback, on `SyntheticHostEnvironment`: what the
/// Windows host's `HostListenerTests` check of its session, for the Mac's copy of the protocol.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct HostSessionTests {
    @Test func pairingThenStreamStartsWithStatusConfigAndAKeyframe() async throws {
        let host = try await TestHost()
        defer { host.stop() }
        let client = TestClient()
        // Not paired, no code: pairing required, and the session stays open for another try.
        let (first, result) = try await client.connect(to: host.port, pairingCode: nil)
        #expect(result.status == .pairingRequired)
        await first.close()
        // The right code pairs; the result carries the synthetic display and the Mac's abilities.
        let (connection, paired) = try await client.connect(to: host.port, pairingCode: "246810")
        #expect(paired.status == .ok)
        #expect(paired.displays?.first?.name == "Vantage Synthetic Display")
        #expect(paired.capabilities?.curtain == true)
        #expect(paired.capabilities?.platform == .macOS)
        #expect(host.trust.isTrusted(client.identity.publicKeyData))

        try await connection.send(.selectDisplay(SelectDisplay(selection: .fitViewport(Viewport(widthPoints: 1210, heightPoints: 834, scale: 2)),
                                                               targetFPS: 60, quality: .auto, preferredCodec: .h264)))
        var order: [MessageKind] = []
        var firstFrame: VideoFrame?
        var config: StreamConfig?
        while firstFrame == nil, let message = try await connection.receive() {
            order.append(message.kind)
            switch message {
            case .videoFrame(let frame): firstFrame = frame
            case .streamConfig(let stream): config = stream
            default: break
            }
        }
        let status = try #require(order.firstIndex(of: .hostStatus))
        let stream = try #require(order.firstIndex(of: .streamConfig))
        let video = try #require(order.firstIndex(of: .videoConfig))
        #expect(status < stream && stream < video && video == order.count - 2)
        #expect(config?.codec == .h264)
        #expect(config?.display.pointWidth == 1210)
        let frame = try #require(firstFrame)
        #expect(frame.isKeyframe && frame.sequence == 0 && frame.width == 2420)

        // A keyframe request is answered with an IDR within a moment.
        for _ in 0..<2 { _ = try await next(.videoFrame, on: connection) }
        try await connection.send(.requestKeyframe)
        let started = ContinuousClock.now
        var keyframe = false
        while !keyframe, ContinuousClock.now - started < .seconds(2) {
            if case .videoFrame(let frame) = try await next(.videoFrame, on: connection) { keyframe = frame.isKeyframe }
        }
        #expect(keyframe)

        // Pings are answered at once, even while frames flow.
        try await connection.send(.ping(Ping(sentAtNanos: 9_007_199_254_740_993)))
        guard case .pong(let pong) = try await next(.pong, on: connection) else { throw Failure.unexpected }
        #expect(pong.echoNanos == 9_007_199_254_740_993)
        await connection.close()
    }

    @Test func sleepingDisplayIsReportedAndWakeBringsThePictureBack() async throws {
        let host = try await TestHost(displayAsleep: true)
        defer { host.stop() }
        host.trust.trusted.insert(DeviceIdentity.fingerprint(of: TestClient.shared.identity.publicKeyData))
        let (connection, result) = try await TestClient.shared.connect(to: host.port, pairingCode: nil)
        #expect(result.status == .ok) // connecting woke the pretend display
        try await connection.send(.selectDisplay(SelectDisplay(selection: .display(1), targetFPS: 30, quality: .auto, preferredCodec: .h264)))
        guard case .videoFrame(let frame) = try await next(.videoFrame, on: connection) else { throw Failure.unexpected }
        #expect(frame.isKeyframe)

        try await connection.send(.hostCommand(HostCommandMessage(command: .sleepDisplay)))
        var status: HostStatus
        repeat {
            guard case .hostStatus(let next) = try await next(.hostStatus, on: connection) else { throw Failure.unexpected }
            status = next
        } while status.isDisplayAsleep != true
        #expect(status.isScreenUnavailable != true)
        #expect(host.display.isAsleep)

        try await connection.send(.hostCommand(HostCommandMessage(command: .wakeDisplay)))
        repeat {
            guard case .hostStatus(let next) = try await next(.hostStatus, on: connection) else { throw Failure.unexpected }
            status = next
        } while status.isDisplayAsleep != false
        guard case .videoFrame(let back) = try await next(.videoFrame, on: connection) else { throw Failure.unexpected }
        #expect(back.isKeyframe)
        await connection.close()
    }

    @Test func missingPictureIsExplainedUntilFramesReturn() async throws {
        let host = try await TestHost(captureFailsFor: .seconds(4))
        defer { host.stop() }
        host.trust.trusted.insert(DeviceIdentity.fingerprint(of: TestClient.shared.identity.publicKeyData))
        let (connection, _) = try await TestClient.shared.connect(to: host.port, pairingCode: nil)
        try await connection.send(.selectDisplay(SelectDisplay(selection: .display(1), targetFPS: 30, quality: .auto, preferredCodec: .h264)))
        var status: HostStatus
        repeat {
            guard case .hostStatus(let next) = try await next(.hostStatus, on: connection) else { throw Failure.unexpected }
            status = next
        } while status.isScreenUnavailable != true
        // The picture comes back (starting with an IDR) and the note is cleared, in either order.
        var frame: VideoFrame?
        var cleared = false
        let deadline = ContinuousClock.now + .seconds(15)
        while (frame == nil || !cleared), ContinuousClock.now < deadline, let message = try await connection.receive() {
            if case .videoFrame(let video) = message, frame == nil { frame = video }
            if case .hostStatus(let next) = message, next.isScreenUnavailable == false { cleared = true }
        }
        #expect(frame?.isKeyframe == true)
        #expect(cleared)
        await connection.close()
    }


    @Test func aSlowStopNeverErasesTheCaptureThatReplacedIt() async throws {
        // Sleep Display stops capture, and the real capture takes a while to stop. Wake arrives
        // meanwhile and starts a replacement. When the older stop returns, it must not clear the
        // replacement's capture, encoder and pacer: the picture would freeze, and the replacement
        // would never be stopped at teardown.
        let host = try await TestHost(stopDelay: .milliseconds(1500))
        defer { host.stop() }
        host.trust.trusted.insert(DeviceIdentity.fingerprint(of: TestClient.shared.identity.publicKeyData))
        let (connection, _) = try await TestClient.shared.connect(to: host.port, pairingCode: nil)
        try await connection.send(.selectDisplay(SelectDisplay(selection: .display(1), targetFPS: 30, quality: .auto, preferredCodec: .h264)))
        _ = try await next(.videoFrame, on: connection)
        try await connection.send(.hostCommand(HostCommandMessage(command: .sleepDisplay)))
        var status: HostStatus
        repeat {
            guard case .hostStatus(let next) = try await next(.hostStatus, on: connection) else { throw Failure.unexpected }
            status = next
        } while status.isDisplayAsleep != true
        try await connection.send(.hostCommand(HostCommandMessage(command: .wakeDisplay)))
        repeat {
            guard case .hostStatus(let next) = try await next(.hostStatus, on: connection) else { throw Failure.unexpected }
            status = next
        } while status.isDisplayAsleep != false
        // Frames must keep coming well past the moment the older stop returns.
        let awakeAt = ContinuousClock.now
        let closer = Task { try? await Task.sleep(for: .seconds(4)); await connection.close() }
        var late = 0
        while let message = try? await connection.receive() {
            if message.kind == .videoFrame, ContinuousClock.now - awakeAt > .milliseconds(2500) { late += 1 }
        }
        closer.cancel()
        #expect(late > 0, "the picture froze after the older stop returned")
        // Every capture the session made is stopped once the session ends.
        let ended = ContinuousClock.now + .seconds(3)
        while host.captures.unstopped > 0, ContinuousClock.now < ended { try await Task.sleep(for: .milliseconds(100)) }
        #expect(host.captures.made == 2 && host.captures.unstopped == 0)
    }

    /// The next message of that kind; anything else in between is skipped.
    private func next(_ kind: MessageKind, on connection: MessageChannel) async throws -> Message {
        while let message = try await connection.receive() {
            if message.kind == kind { return message }
        }
        throw Failure.closed
    }

    enum Failure: Error { case unexpected, closed }
}

/// A listener that runs one `HostSession` per connection on a synthetic environment.
final class TestHost: Sendable {
    let trust = MemoryTrust()
    let display: FakeDisplay
    let identity = DeviceIdentity()
    let port: UInt16
    /// The captures the session asked for, and whether each was stopped (`stopDelay` hosts only).
    let captures = CaptureLedger()
    private let listener: NWListener
    private let sessions = SessionKeeper()

    /// `stopDelay`: every capture's first `stop` takes this long, as a real ScreenCaptureKit stop can.
    init(displayAsleep: Bool = false, captureFailsFor: Duration? = nil, stopDelay: Duration? = nil) async throws {
        let display = FakeDisplay(asleep: displayAsleep)
        self.display = display
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "HostSessionTests-\(UUID().uuidString)")
        var made = SyntheticHostEnvironment.make(hostName: "Test Mac", display: display, fileDestination: {
            FileDestination(directory: folder, configuration: FileTransferConfiguration(receiveDirectory: folder))
        }, captureFailsFor: captureFailsFor)
        if let stopDelay { made.screen = SlowStopScreen(inner: made.screen, delay: stopDelay, ledger: captures) }
        let environment = made
        let listener = try NWListener(using: VantageNetwork.tcpParameters(), on: .any)
        let identity = self.identity, trust = self.trust, sessions = self.sessions
        let attachTokens = AttachTokenRegistry<HostSession>()
        // Set before `start`: a listener started without one fails with EINVAL.
        listener.newConnectionHandler = { connection in
            let channel = MessageChannel(connection: connection)
            let session = HostSession(channel: channel, identity: identity, trust: trust, environment: environment,
                                      peerDescription: "127.0.0.1", peerHost: "127.0.0.1", attachTokens: attachTokens,
                                      onFileChannel: { _ in }, onEnded: { sessions.remove($0) })
            sessions.add(session)
            Task {
                do {
                    try await channel.start()
                    guard case .hello(let hello)? = try await channel.receive() else { return await channel.close() }
                    await session.run(hello: hello)
                } catch {
                    await channel.close()
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                } else if case .failed(let error) = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            listener.start(queue: .global())
        }
        self.listener = listener
        port = listener.port!.rawValue
    }

    func stop() {
        listener.cancel()
    }
}


/// A screen whose captures take a while to stop the first time (a later stop of the same capture
/// returns at once, as ScreenCaptureKit's does), and which don't stop themselves when the pretend
/// display sleeps, so only the session's own stop ends them.
nonisolated struct SlowStopScreen: HostScreen {
    let inner: any HostScreen
    let delay: Duration
    let ledger: CaptureLedger

    var canRestartByDisplayID: Bool { inner.canRestartByDisplayID }
    var canManageVirtualDisplay: Bool { inner.canManageVirtualDisplay }
    func displays() async throws -> [DisplayInfo] { try await inner.displays() }
    func resolve(_ select: SelectDisplay) async throws -> DisplayInfo { try await inner.resolve(select) }
    func restoreDisplays() async { await inner.restoreDisplays() }

    func makeCapture(for display: DisplayInfo, fps: Int, excludingClientOnThisComputer: Bool) -> any FrameSource {
        let source = SlowStopFrameSource(source: SyntheticFrameSource(pixelWidth: display.pixelWidth, pixelHeight: display.pixelHeight, fps: fps),
                                         delay: delay, ledger: ledger)
        ledger.record(source)
        return source
    }
}

nonisolated final class SlowStopFrameSource: FrameSource, @unchecked Sendable {
    private let source: SyntheticFrameSource
    private let delay: Duration
    private let ledger: CaptureLedger
    private let stops = Mutex(0)

    init(source: SyntheticFrameSource, delay: Duration, ledger: CaptureLedger) {
        self.source = source
        self.delay = delay
        self.ledger = ledger
    }

    var pixelWidth: Int { source.pixelWidth }
    var pixelHeight: Int { source.pixelHeight }

    func start(onFrame: @escaping @Sendable (CapturedFrame) -> Void, onStop: @escaping @Sendable ((any Error)?) -> Void) async throws {
        try await source.start(onFrame: onFrame, onStop: onStop)
    }

    func updateFPS(_ fps: Int) { source.updateFPS(fps) }
    func refreshFilter() async {}

    func stop() async {
        let first = stops.withLock { $0 += 1; return $0 == 1 }
        if first { try? await Task.sleep(for: delay) }
        await source.stop()
        ledger.stopped(self)
    }
}

/// Which captures a test host made and which the session has stopped.
nonisolated final class CaptureLedger: Sendable {
    private let state = Mutex<(made: Int, stopped: Set<ObjectIdentifier>)>((0, []))
    var made: Int { state.withLock { $0.made } }
    var unstopped: Int { state.withLock { $0.made - $0.stopped.count } }
    func record(_ source: AnyObject) { state.withLock { $0.made += 1 } }
    func stopped(_ source: AnyObject) { state.withLock { _ = $0.stopped.insert(ObjectIdentifier(source)) } }
}

/// Keeps the sessions alive while the test runs.
nonisolated final class SessionKeeper: Sendable {
    private let sessions = Mutex<[HostSession]>([])
    func add(_ session: HostSession) { sessions.withLock { $0.append(session) } }
    func remove(_ session: HostSession) { sessions.withLock { $0.removeAll { $0 === session } } }
}

/// Paired devices in memory, with one fixed pairing code.
nonisolated final class MemoryTrust: HostTrust, @unchecked Sendable {
    private let lock = NSLock()
    private var _trusted: Set<String> = []
    var trusted: Set<String> {
        get { lock.withLock { _trusted } }
        set { lock.withLock { _trusted = newValue } }
    }
    var names: [String: String] = [:]
    var code: String? = "246810"

    func isTrusted(_ publicKey: Data) -> Bool { trusted.contains(DeviceIdentity.fingerprint(of: publicKey)) }

    func consumePairingCode(_ code: String) -> PairingCheck {
        lock.withLock {
            guard let active = self.code else { return .unavailable }
            guard active == code else { return .incorrect }
            self.code = nil
            return .accepted
        }
    }

    func trust(_ publicKey: Data, name: String, model: String?) {
        let fingerprint = DeviceIdentity.fingerprint(of: publicKey)
        lock.withLock {
            _trusted.insert(fingerprint)
            names[fingerprint] = name
        }
    }

    func name(ofFingerprint fingerprint: String) -> String? { lock.withLock { names[fingerprint] } }
    func adoptTailnetName(_ name: String, fingerprint: String) { lock.withLock { names[fingerprint] = name } }
}

/// A device: says hello with a nonce, checks the host's signature, signs the screen transcript.
nonisolated final class TestClient: Sendable {
    static let shared = TestClient()
    let identity = DeviceIdentity()

    func connect(to port: UInt16, pairingCode: String?) async throws -> (MessageChannel, AuthResult) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: VantageNetwork.tcpParameters())
        let channel = MessageChannel(connection: connection)
        try await channel.start()
        let nonce = AuthTranscript.randomNonce()
        let hello = Hello(clientName: "Test iPad", deviceModel: "iPad16,6", appVersion: "1.0", clientPublicKey: identity.publicKeyData,
                          supportedCodecs: [.hevc, .h264], maxDecodeWidth: 4096, maxDecodeHeight: 4096,
                          viewport: Viewport(widthPoints: 1210, heightPoints: 834, scale: 2),
                          features: ClientFeatures(curtain: true), clientNonce: nonce)
        try await channel.send(.hello(hello))
        guard case .challenge(let challenge)? = try await channel.receive() else { throw HostSessionTests.Failure.unexpected }
        _ = try HostIdentityCheck.verify(challenge, clientNonce: nonce, clientPublicKey: identity.publicKeyData, expected: nil)
        let signature = try identity.sign(AuthTranscript.clientBytes(clientNonce: nonce, hostNonce: challenge.nonce, hostPublicKey: challenge.hostPublicKey,
                                                                     clientPublicKey: identity.publicKeyData, purpose: .screen))
        try await channel.send(.authenticate(Authenticate(signature: signature, pairingCode: pairingCode)))
        guard case .authResult(let result)? = try await channel.receive() else { throw HostSessionTests.Failure.unexpected }
        return (channel, result)
    }
}

import Foundation
import Network
import Testing
import VantageCore
@testable import VantageClientLogic

/// The Mac's display sleeping must never turn into a reconnect loop: a host that says its display
/// is asleep keeps the session with no video, and a host that drops every stream request is
/// retried with growing waits instead of every 1.6 s forever.
@Suite(.timeLimit(.minutes(1)))
struct DisplaySleepSessionTests {
    private static func listen() async throws -> (NWListener, AsyncStream<MessageChannel>) {
        let listener = try NWListener(using: VantageNetwork.tcpParameters(), on: .any)
        let stream = AsyncStream<MessageChannel> { continuation in
            listener.newConnectionHandler = { continuation.yield(MessageChannel(connection: $0)) }
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
        return (listener, stream)
    }

    /// Plays a paired host up to the client's stream request.
    private static func acceptStreamRequest(_ channel: MessageChannel) async throws {
        try await channel.start()
        guard case .hello? = try await channel.receive() else { throw Failure.unexpected }
        let host = DeviceIdentity()
        try await channel.send(.challenge(Challenge(hostName: "Test Mac", hostVersion: "1.0", hostPublicKey: host.publicKeyData,
                                                    nonce: AuthTranscript.randomNonce(), isPaired: true)))
        guard case .authenticate? = try await channel.receive() else { throw Failure.unexpected }
        try await channel.send(.authResult(AuthResult(status: .ok)))
        guard case .selectDisplay? = try await channel.receive() else { throw Failure.unexpected }
    }

    private enum Failure: Error { case unexpected, timedOut }

    @MainActor
    private static func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor private static func device(_ port: UInt16) -> SavedDevice {
        SavedDevice(name: "Test Mac", host: "127.0.0.1", port: port)
    }
    private static let viewport = Viewport(widthPoints: 800, heightPoints: 600, scale: 2)

    @Test @MainActor func anAsleepDisplayKeepsTheSessionWithoutVideo() async throws {
        let (listener, channels) = try await Self.listen()
        defer { listener.cancel() }
        let asleep = HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native, isDisplayAsleep: true)
        let awake = HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native, isDisplayAsleep: false)
        let host = Task {
            var iterator = channels.makeAsyncIterator()
            let channel = try #require(await iterator.next())
            try await Self.acceptStreamRequest(channel)
            try await channel.send(.hostStatus(asleep))
            // The Wake button reaches the host as a command; then the display comes back.
            guard case .hostCommand(let command)? = try await channel.receive() else { throw Failure.unexpected }
            #expect(command.command == .wakeDisplay)
            try await channel.send(.hostStatus(awake))
            return channel
        }
        let session = ClientSession(identity: DeviceIdentity())
        defer { session.disconnect() }
        session.connect(to: Self.device(listener.port!.rawValue), viewport: Self.viewport)
        try await Self.eventually { session.isDisplayAsleep }
        // Seconds without a single frame: still the same connection, nothing retried.
        try await Task.sleep(for: .seconds(3))
        #expect(session.state == .connected && session.isDisplayAsleep)
        #expect(session.reconnectAttempts == 0)
        session.wakeDisplay()
        try await Self.eventually { !session.isDisplayAsleep }
        #expect(session.state == .connected && session.reconnectAttempts == 0)
        try await host.value.close()
    }

    @Test @MainActor func aMissingPictureIsExplainedAndRetryReachesTheHost() async throws {
        let (listener, channels) = try await Self.listen()
        defer { listener.cancel() }
        let waiting = HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native,
                                 isDisplayAsleep: false, isScreenUnavailable: true)
        let back = HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native,
                              isDisplayAsleep: false, isScreenUnavailable: false)
        let host = Task {
            var iterator = channels.makeAsyncIterator()
            let channel = try #require(await iterator.next())
            try await Self.acceptStreamRequest(channel)
            try await channel.send(.hostStatus(waiting))
            guard case .hostCommand(let command)? = try await channel.receive() else { throw Failure.unexpected }
            #expect(command.command == .wakeDisplay) // Retry
            try await channel.send(.hostStatus(back))
            return channel
        }
        let session = ClientSession(identity: DeviceIdentity())
        defer { session.disconnect() }
        session.connect(to: Self.device(listener.port!.rawValue), viewport: Self.viewport)
        try await Self.eventually { session.isScreenUnavailable }
        #expect(!session.isDisplayAsleep && session.reconnectAttempts == 0)
        session.wakeDisplay()
        try await Self.eventually { !session.isScreenUnavailable }
        #expect(session.state == .connected)
        try await host.value.close()
    }

    @Test @MainActor func aHostThatDropsEveryStreamRequestIsNotRetriedInALoop() async throws {
        let (listener, channels) = try await Self.listen()
        defer { listener.cancel() }
        let host = Task {
            var iterator = channels.makeAsyncIterator()
            for _ in 0..<4 {
                let channel = try #require(await iterator.next())
                try await Self.acceptStreamRequest(channel)
                await channel.close() // what an older host did while its display was asleep
            }
        }
        let session = ClientSession(identity: DeviceIdentity())
        var delays: [Int] = []
        session.reconnectDelay = { attempt in
            delays.append(attempt)
            return .milliseconds(50)
        }
        defer { session.disconnect() }
        session.connect(to: Self.device(listener.port!.rawValue), viewport: Self.viewport)
        try await host.value
        try await Self.eventually { delays.count >= 4 }
        // Each drop counts: the handshake alone doesn't reset the backoff any more.
        #expect(Array(delays.prefix(4)) == [1, 2, 3, 4])
    }

    @Test @MainActor func aHostThatAnswersResetsTheBackoff() async throws {
        let (listener, channels) = try await Self.listen()
        defer { listener.cancel() }
        let host = Task {
            var iterator = channels.makeAsyncIterator()
            let first = try #require(await iterator.next())
            try await Self.acceptStreamRequest(first)
            await first.close()
            let second = try #require(await iterator.next())
            try await Self.acceptStreamRequest(second)
            try await second.send(.hostStatus(HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native)))
            return second
        }
        let session = ClientSession(identity: DeviceIdentity())
        session.reconnectDelay = { _ in .milliseconds(50) }
        defer { session.disconnect() }
        session.connect(to: Self.device(listener.port!.rawValue), viewport: Self.viewport)
        try await Self.eventually { session.reconnectAttempts == 1 }
        let second = try await host.value
        try await Self.eventually { session.hostStatus != nil && session.reconnectAttempts == 0 }
        await second.close()
    }
}

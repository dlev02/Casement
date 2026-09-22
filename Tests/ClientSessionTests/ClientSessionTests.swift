import Foundation
import Network
import Testing
import VantageCore
@testable import VantageClientLogic

private func listen() async throws -> (NWListener, AsyncStream<MessageChannel>) {
    let listener = try NWListener(using: VantageNetwork.tcpParameters(), on: .any)
    let stream = AsyncStream<MessageChannel> { continuation in
        listener.newConnectionHandler = { connection in
            continuation.yield(MessageChannel(connection: connection))
        }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        // The local listener reaches ready once; later transitions belong to the test cleanup.
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

private func authenticate(_ channel: MessageChannel, status: AuthStatus, paired: Bool) async throws -> Authenticate {
    try await channel.start()
    guard case .hello(let hello)? = try await channel.receive() else { throw TestFailure.unexpectedMessage }
    let host = DeviceIdentity()
    let nonce = AuthTranscript.randomNonce()
    try await channel.send(.challenge(Challenge(hostName: "Test Mac", hostVersion: "1.0",
        hostPublicKey: host.publicKeyData, nonce: nonce, isPaired: paired)))
    guard case .authenticate(let auth)? = try await channel.receive() else { throw TestFailure.unexpectedMessage }
    #expect(AuthTranscript.verify(signature: auth.signature, nonce: nonce, hostPublicKey: host.publicKeyData,
                                  clientPublicKey: hello.clientPublicKey))
    try await channel.send(.authResult(AuthResult(status: status)))
    return auth
}

private enum TestFailure: Error { case unexpectedMessage, timedOut }

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw TestFailure.timedOut }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ClientSessionTests {
    @Test @MainActor func pairingRemainsVisibleAndAcceptsRetry() async throws {
        let (listener, channels) = try await listen()
        defer { listener.cancel() }
        let server = Task {
            var iterator = channels.makeAsyncIterator()
            for status in [AuthStatus.pairingRequired, .badPairingCode, .ok] {
                let channel = try #require(await iterator.next())
                let auth = try await authenticate(channel, status: status, paired: false)
                if status == .ok {
                    #expect(auth.pairingCode == "246810")
                    guard case .selectDisplay? = try await channel.receive() else { throw TestFailure.unexpectedMessage }
                }
                await channel.close()
            }
        }
        let session = ClientSession(identity: DeviceIdentity())
        defer { session.disconnect() }
        let device = SavedDevice(name: "Test Mac", host: "127.0.0.1", port: listener.port!.rawValue)
        let viewport = Viewport(widthPoints: 800, heightPoints: 600, scale: 2)
        session.connect(to: device, viewport: viewport)
        try await eventually { session.state == .pairingRequired }
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.state == .pairingRequired)
        session.connect(to: device, viewport: viewport, pairingCode: "000000")
        try await eventually { session.state == .pairingRequired }
        session.connect(to: device, viewport: viewport, pairingCode: "246810")
        try await server.value
    }

    @Test @MainActor func requestsVideoAgainAfterConnectionDrops() async throws {
        let (listener, channels) = try await listen()
        defer { listener.cancel() }
        let server = Task {
            var iterator = channels.makeAsyncIterator()
            for _ in 0..<2 {
                let channel = try #require(await iterator.next())
                _ = try await authenticate(channel, status: .ok, paired: true)
                guard case .selectDisplay(let selection)? = try await channel.receive() else { throw TestFailure.unexpectedMessage }
                if case .fitViewport(let viewport) = selection.selection {
                    #expect(viewport.widthPoints == 800)
                    #expect(viewport.heightPoints == 600)
                } else { Issue.record("Expected viewport selection") }
                await channel.close()
            }
        }
        let session = ClientSession(identity: DeviceIdentity())
        defer { session.disconnect() }
        session.connect(to: SavedDevice(name: "Test Mac", host: "127.0.0.1", port: listener.port!.rawValue),
                        viewport: Viewport(widthPoints: 800, heightPoints: 600, scale: 2))
        try await server.value
    }

    @Test @MainActor func disconnectCancelsPendingHandshake() async throws {
        let (listener, channels) = try await listen()
        defer { listener.cancel() }
        let session = ClientSession(identity: DeviceIdentity())
        session.connect(to: SavedDevice(name: "Test Mac", host: "127.0.0.1", port: listener.port!.rawValue),
                        viewport: Viewport(widthPoints: 800, heightPoints: 600, scale: 2))
        var iterator = channels.makeAsyncIterator()
        let channel = try #require(await iterator.next())
        try await channel.start()
        guard case .hello? = try await channel.receive() else { throw TestFailure.unexpectedMessage }
        session.disconnect()
        let end = try await channel.receive()
        #expect(end == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.state == .idle)
        await channel.close()
    }
}

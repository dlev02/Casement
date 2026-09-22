import Foundation
import Network
import Testing
@testable import VantageCore

/// Round-trips messages over a real loopback TCP connection to validate framing + the channel.
@Test func channelRoundTripsOverLoopback() async throws {
    let port = NWEndpoint.Port(rawValue: UInt16.random(in: 34_000 ... 44_000))!
    let parameters = VantageNetwork.tcpParameters()
    let listener = try NWListener(using: parameters, on: port)

    // Accept one connection and echo the first two messages back.
    let acceptedChannel = AsyncStream<MessageChannel> { continuation in
        listener.newConnectionHandler = { connection in
            let channel = MessageChannel(connection: connection, label: "test.server")
            continuation.yield(channel)
            continuation.finish()
        }
    }
    listener.start(queue: .global())
    defer { listener.cancel() }

    let clientConnection = NWConnection(host: .ipv4(.loopback), port: port, using: parameters)
    let client = MessageChannel(connection: clientConnection, label: "test.client")
    try await client.start()

    var serverIterator = acceptedChannel.makeAsyncIterator()
    guard let server = await serverIterator.next() else { Issue.record("no server channel"); return }
    try await server.start()

    // Client → server: a JSON control message and a binary hot-path message.
    let hello = Hello(clientName: "iPad", deviceModel: "iPad16,3", appVersion: "1.0", clientPublicKey: Data(repeating: 1, count: 32), supportedCodecs: [.hevc], maxDecodeWidth: 4096, maxDecodeHeight: 2304, viewport: Viewport(widthPoints: 1210, heightPoints: 834, scale: 2))
    try await client.send(.hello(hello))
    let pointer = PointerEvent(action: .down, button: .left, x: 100, y: 200, clickCount: 1)
    client.sendDetached(.pointerEvent(pointer))

    var received: [Message] = []
    while received.count < 2, let message = try await server.receive() {
        received.append(message)
    }
    #expect(received.count == 2)
    guard case .hello(let backHello) = received[0] else { Issue.record("expected hello"); return }
    #expect(backHello.clientName == "iPad")
    guard case .pointerEvent(let backPointer) = received[1] else { Issue.record("expected pointer"); return }
    #expect(backPointer == pointer)

    await client.close()
    await server.close()
}

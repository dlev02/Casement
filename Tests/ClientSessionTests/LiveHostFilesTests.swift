import Foundation
import Network
import Synchronization
import Testing
import VantageCore

/// Against a real Vantage Host (DEBUG, `--synthetic-capture`, fixed pairing code). Opt in:
/// `VANTAGE_TEST_HOST=127.0.0.1:47852 xcrun swift test --filter LiveHostFilesTests`
/// (`VANTAGE_TEST_PAIRING_CODE` if not 246810). The test identity is kept in the temp folder, so
/// only the first run against a host uses up its pairing code.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VANTAGE_TEST_HOST"] != nil), .timeLimit(.minutes(2)))
struct LiveHostFilesTests {
    /// A files-only session asks for the screen, audio, and clipboard anyway and gets nothing but
    /// pongs; its file channel carries files, and keeps carrying them after the session closes.
    @Test func filesOnlySessionNeverStartsTheScreenAndItsChannelOutlivesIt() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["VANTAGE_TEST_HOST"])
        let parts = address.split(separator: ":")
        let host = String(parts[0]), port = try #require(NWEndpoint.Port(String(parts[1])))
        let identity = try Self.identity()

        let primary = MessageChannel(connection: NWConnection(host: NWEndpoint.Host(host), port: port, using: VantageNetwork.tcpParameters()))
        try await primary.start()
        try await primary.send(.hello(Hello(clientName: "Live files test", deviceModel: "test", appVersion: "1.0",
                                            clientPublicKey: identity.publicKeyData, supportedCodecs: [],
                                            maxDecodeWidth: 0, maxDecodeHeight: 0, viewport: nil,
                                            features: ClientFeatures(fileTransfer: true, filesOnly: true))))
        guard case .challenge(let challenge)? = try await primary.receive() else { Issue.record("no challenge"); return }
        let signature = try identity.sign(AuthTranscript.bytes(nonce: challenge.nonce, hostPublicKey: challenge.hostPublicKey,
                                                               clientPublicKey: identity.publicKeyData))
        let code = ProcessInfo.processInfo.environment["VANTAGE_TEST_PAIRING_CODE"] ?? "246810"
        try await primary.send(.authenticate(Authenticate(signature: signature, pairingCode: challenge.isPaired ? nil : code)))
        guard case .authResult(let result)? = try await primary.receive() else { Issue.record("no auth result"); return }
        #expect(result.status == .ok, "\(result.message ?? "")")
        #expect(result.capabilities?.filesOnlySessions == true && result.capabilities?.fileTransfer == true)
        #expect(result.displays == nil, "no displays enumerated for a files-only session")
        #expect(challenge.peerTailnetName == nil, "no whois for a files-only session")
        let token = try #require(result.sessionToken)

        // Ask for everything a screen session would get.
        let seen = Mutex<[MessageKind]>([])
        let reader = Task {
            while let message = try await primary.receive() { seen.withLock { $0.append(message.kind) } }
        }
        try await primary.send(.selectDisplay(SelectDisplay(selection: .fitViewport(Viewport(widthPoints: 800, heightPoints: 600, scale: 2)),
                                                            targetFPS: 60, quality: .auto)))
        try await primary.send(.audioRequest(AudioRequest(enabled: true)))
        try await primary.send(.clipboard(ClipboardPayload(text: "should be ignored")))
        try await primary.send(.hostCommand(HostCommandMessage(command: .refreshDisplays)))
        try await primary.send(.ping(Ping(sentAtNanos: 42)))
        try await Task.sleep(for: .seconds(3))
        #expect(seen.withLock { $0 } == [.pong], "only the ping is answered")

        // The file channel, then a file with the session open and one after it has closed.
        let files = MessageChannel(connection: NWConnection(host: NWEndpoint.Host(host), port: port, using: VantageNetwork.bulkParameters()),
                                   maxBufferedMessages: 64)
        try await files.start()
        try await files.send(.attachMedia(AttachMedia(sessionToken: token)))
        let local = FileManager.default.temporaryDirectory.appending(path: "vantage-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let engine = FileTransferEngine(channel: files, role: .client, configuration: .init(receiveDirectory: local))
        let run = Task { await engine.run() }
        let first = local.appending(path: "Live \(UUID().uuidString.prefix(8)) A.bin")
        try Data(repeating: 0xA1, count: 700_000).write(to: first)
        let sentFirst = await engine.send(fileAt: first)
        #expect(sentFirst.isSuccess, "\(sentFirst)")

        try await primary.send(.disconnect(DisconnectMessage(reason: "done with the session")))
        await primary.close()
        _ = await reader.result
        try await Task.sleep(for: .seconds(1))
        let second = local.appending(path: "Live \(UUID().uuidString.prefix(8)) B.bin")
        try Data(repeating: 0xB2, count: 900_000).write(to: second)
        let sentSecond = await engine.send(fileAt: second)
        #expect(sentSecond.isSuccess, "the channel outlives its session: \(sentSecond)")
        await engine.close()
        await run.value

        // The synthetic host saved them in its temp folder (same user): tidy up.
        let received = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "VantageSynthetic/Received")
        for case .sent(let name?) in [sentFirst, sentSecond] { try? FileManager.default.removeItem(at: received.appending(path: name)) }
    }

    private static func identity() throws -> DeviceIdentity {
        let file = FileManager.default.temporaryDirectory.appending(path: "vantage-live-files-identity.key")
        if let data = try? Data(contentsOf: file), let identity = try? DeviceIdentity(rawRepresentation: data) { return identity }
        let identity = DeviceIdentity()
        try identity.rawRepresentation.write(to: file)
        return identity
    }
}

import CryptoKit
import Foundation
import Network
import Testing
@testable import VantageCore

/// Local-network connections carry the screen, keystrokes and passwords with nothing but
/// Casement's own encryption around them, so this checks it end to end over loopback TCP: the
/// handshake both sides really run, sealed traffic both ways, and the attacks it must stop.
@Suite struct SessionEncryptionTests {
    private final class Trust: PairingAuthority, @unchecked Sendable {
        var trusted: Set<Data>
        init(trusted: Set<Data> = []) { self.trusted = trusted }
        func isTrusted(_ publicKey: Data) -> Bool { trusted.contains(publicKey) }
        func consumePairingCode(_ code: String) -> PairingCheck { code == "123456" ? .accepted : .incorrect }
        func trust(_ publicKey: Data, name: String, model: String?) { trusted.insert(publicKey) }
    }

    private static func hello(_ client: DeviceIdentity) -> Hello {
        Hello(clientName: "iPad", deviceModel: "iPad16,6", appVersion: "1.0", clientPublicKey: client.publicKeyData, supportedCodecs: [.hevc],
              maxDecodeWidth: 4096, maxDecodeHeight: 2304, viewport: nil)
    }

    /// A connected pair of channels over loopback TCP.
    private static func channelPair() async throws -> (client: MessageChannel, host: MessageChannel, listener: NWListener) {
        let listener = try NWListener(using: VantageNetwork.tcpParameters(), on: .any)
        let accepted = AsyncStream<MessageChannel> { continuation in
            listener.newConnectionHandler = { continuation.yield(MessageChannel(connection: $0, label: "test.host")); continuation.finish() }
        }
        let ready = AsyncStream<NWEndpoint.Port> { continuation in
            listener.stateUpdateHandler = { if case .ready = $0, let port = listener.port { continuation.yield(port); continuation.finish() } }
        }
        listener.start(queue: .global())
        var readyIterator = ready.makeAsyncIterator()
        let port = try #require(await readyIterator.next())
        let client = MessageChannel(connection: NWConnection(host: .ipv4(.loopback), port: port, using: VantageNetwork.tcpParameters()), label: "test.client")
        try await client.start()
        var iterator = accepted.makeAsyncIterator()
        let host = try #require(await iterator.next())
        try await host.start()
        return (client, host, listener)
    }

    /// Runs the real handshake both ways over a local-network peer and returns the open session.
    private static func handshake(paired: Bool = true) async throws -> (client: MessageChannel, host: MessageChannel, listener: NWListener,
                                                                         clientKeys: SessionKeys, hostKeys: SessionKeys) {
        let (client, host, listener) = try await channelPair()
        let clientIdentity = DeviceIdentity(), hostIdentity = DeviceIdentity()
        let trust = Trust(trusted: paired ? [clientIdentity.publicKeyData] : [])
        let handshake = ClientHandshake(clientPublicKey: clientIdentity.publicKeyData, offersEncryption: true, requiresEncryption: true)
        try await client.send(.hello(handshake.prepare(hello(clientIdentity))))

        guard case .hello(let received)? = try await host.receive() else { throw ClientHandshakeTestError.unexpected }
        guard case .challenged(let challenge, let pending) = try SessionAdmission.begin(hello: received, identity: hostIdentity, hostName: "Studio",
                                                                                        platform: .macOS, isPaired: trust.isTrusted(received.clientPublicKey),
                                                                                        peer: .localNetwork) else {
            throw ClientHandshakeTestError.unexpected
        }
        let hostKeys = try #require(pending.sessionKeys)
        try await host.send(.challenge(challenge), thenEncryptWith: hostKeys)

        guard case .challenge(let sentChallenge)? = try await client.receive() else { throw ClientHandshakeTestError.unexpected }
        _ = try handshake.verify(sentChallenge, expected: hostIdentity.publicKeyData)
        let clientKeys = try #require(try handshake.sessionKeys(for: sentChallenge))
        await client.encrypt(with: clientKeys)
        let signature = try clientIdentity.sign(handshake.transcript(for: sentChallenge, purpose: .screen))
        try await client.send(.authenticate(Authenticate(signature: signature)))

        guard case .authenticate(let auth)? = try await host.receive() else { throw ClientHandshakeTestError.unexpected }
        guard case .admitted(.screen, _) = pending.finish(auth, pairing: trust) else { throw ClientHandshakeTestError.unexpected }
        return (client, host, listener, clientKeys, hostKeys)
    }

    @Test func sealedTrafficFlowsBothWaysAfterTheHandshake() async throws {
        let (client, host, listener, _, _) = try await Self.handshake()
        defer { listener.cancel() }
        #expect(await client.isEncrypted)
        #expect(await host.isEncrypted)

        let keyframe = VideoFrame(sequence: 1, captureNanos: 9, isKeyframe: true, width: 3840, height: 2160,
                                  data: Data((0 ..< 3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        try await host.send(.authResult(AuthResult(status: .ok)))
        host.sendDetached(.videoFrame(keyframe))
        guard case .authResult(let result)? = try await client.receive() else { Issue.record("no authResult"); return }
        #expect(result.status == .ok)
        guard case .videoFrame(let frame)? = try await client.receive() else { Issue.record("no frame"); return }
        #expect(frame == keyframe)

        let pointer = PointerEvent(action: .moveBy, x: 3.5, y: -2, clickCount: 1)
        for _ in 0 ..< 200 { client.sendDetached(.pointerEvent(pointer)) }
        for _ in 0 ..< 200 {
            guard case .pointerEvent(let received)? = try await host.receive() else { Issue.record("lost a pointer event"); return }
            #expect(received == pointer)
        }
        await client.close()
        await host.close()
    }

    @Test func aPlainFrameAfterTheSwitchEndsTheChannel() async throws {
        let (client, host, listener, _, _) = try await Self.handshake()
        defer { listener.cancel() }
        // A raw, unsealed frame on the wire, as an attacker splicing into the stream would send.
        try await client.sendUnsealedForTesting(.ping(Ping(sentAtNanos: 1)))
        await #expect(throws: RecordError.plaintextAfterEncryption) { try await host.receive() }
        await client.close()
    }

    @Test func aTamperedRecordIsRefused() throws {
        let keys = SessionKeys(role: .client, clientToHost: SymmetricKey(size: .bits256), hostToClient: SymmetricKey(size: .bits256),
                               fileSecret: SymmetricKey(size: .bits256))
        var sealer = RecordSealer(key: keys.sendKey)
        var record = try sealer.seal(Message.ping(Ping(sentAtNanos: 7)).encodedFrame())
        let header = record.prefix(Frame.headerLength)
        var opener = RecordOpener(key: keys.sendKey)
        record[record.startIndex + 12] ^= 0x01
        #expect(throws: RecordError.authenticationFailed) { try opener.open(header: header, sealed: record.dropFirst(Frame.headerLength)) }

        // Replaying a good record is refused too: the counter has moved on.
        var fresh = RecordSealer(key: keys.sendKey)
        let first = try fresh.seal(Message.ping(Ping(sentAtNanos: 8)).encodedFrame())
        var receiver = RecordOpener(key: keys.sendKey)
        _ = try receiver.open(header: first.prefix(Frame.headerLength), sealed: first.dropFirst(Frame.headerLength))
        #expect(throws: RecordError.authenticationFailed) {
            try receiver.open(header: first.prefix(Frame.headerLength), sealed: first.dropFirst(Frame.headerLength))
        }
    }

    /// A device in the middle that swaps in its own key share can't make the host's signature
    /// cover it, so the device refuses before it signs anything.
    @Test func aSwappedKeyShareFailsTheHostCheck() throws {
        let clientIdentity = DeviceIdentity(), hostIdentity = DeviceIdentity()
        let handshake = ClientHandshake(clientPublicKey: clientIdentity.publicKeyData, offersEncryption: true, requiresEncryption: true)
        guard case .challenged(var challenge, _) = try SessionAdmission.begin(hello: handshake.prepare(Self.hello(clientIdentity)), identity: hostIdentity,
                                                                              hostName: "Studio", platform: .macOS, isPaired: true, peer: .localNetwork) else {
            Issue.record("refused"); return
        }
        challenge.hostKeyShare = SessionKeyShare().publicShare
        #expect(throws: HostIdentityCheck.Failure.badSignature) { try handshake.verify(challenge, expected: hostIdentity.publicKeyData) }

        // Stripping the share entirely leaves a connection the device won't use off the tailnet.
        challenge.hostKeyShare = nil
        #expect(throws: (any Error).self) { try handshake.verify(challenge, expected: hostIdentity.publicKeyData) }
    }

    @Test func theLocalNetworkTakesOnlyEncryptedAlreadyPairedDevices() throws {
        let clientIdentity = DeviceIdentity(), hostIdentity = DeviceIdentity()
        let plain = Hello(clientName: "iPad", deviceModel: "iPad16,6", appVersion: "1.0", clientPublicKey: clientIdentity.publicKeyData,
                          supportedCodecs: [.hevc], maxDecodeWidth: 4096, maxDecodeHeight: 2304, viewport: nil, clientNonce: AuthTranscript.randomNonce())
        guard case .refused(let unencrypted) = try SessionAdmission.begin(hello: plain, identity: hostIdentity, hostName: "Studio", platform: .macOS,
                                                                         isPaired: true, peer: .localNetwork) else {
            Issue.record("a plaintext local connection was challenged"); return
        }
        #expect(unencrypted.status == .denied)

        let offering = ClientHandshake(clientPublicKey: clientIdentity.publicKeyData, offersEncryption: true, requiresEncryption: true)
            .prepare(Self.hello(clientIdentity))
        guard case .refused(let unpaired) = try SessionAdmission.begin(hello: offering, identity: hostIdentity, hostName: "Studio", platform: .macOS,
                                                                      isPaired: false, peer: .localNetwork) else {
            Issue.record("an unpaired local device was offered pairing"); return
        }
        #expect(unpaired.status == .denied)

        // Inside Tailscale the share is ignored: the stream stays as it always was.
        guard case .challenged(let tailnet, let pending) = try SessionAdmission.begin(hello: offering, identity: hostIdentity, hostName: "Studio",
                                                                                     platform: .macOS, isPaired: false, peer: .tailnet) else {
            Issue.record("tailnet refused"); return
        }
        #expect(tailnet.hostKeyShare == nil)
        #expect(pending.sessionKeys == nil)
    }

    @Test func fileChannelKeysMatchOnBothSidesAndDependOnTheToken() throws {
        let client = SessionKeyShare(), host = SessionKeyShare()
        let nonceA = AuthTranscript.randomNonce(), nonceB = AuthTranscript.randomNonce()
        let hostKey = DeviceIdentity().publicKeyData, clientKey = DeviceIdentity().publicKeyData
        let clientKeys = try client.sessionKeys(peerShare: host.publicShare, role: .client, clientNonce: nonceA, hostNonce: nonceB,
                                                hostPublicKey: hostKey, clientPublicKey: clientKey)
        let hostKeys = try host.sessionKeys(peerShare: client.publicShare, role: .host, clientNonce: nonceA, hostNonce: nonceB,
                                            hostPublicKey: hostKey, clientPublicKey: clientKey)
        let token = Data(repeating: 9, count: 32)
        var sealer = RecordSealer(key: clientKeys.fileChannelKeys(token: token).sendKey)
        let record = try sealer.seal(Message.requestKeyframe.encodedFrame())
        var opener = RecordOpener(key: hostKeys.fileChannelKeys(token: token).receiveKey)
        _ = try opener.open(header: record.prefix(Frame.headerLength), sealed: record.dropFirst(Frame.headerLength))
        var wrongToken = RecordOpener(key: hostKeys.fileChannelKeys(token: Data(repeating: 8, count: 32)).receiveKey)
        #expect(throws: RecordError.authenticationFailed) {
            try wrongToken.open(header: record.prefix(Frame.headerLength), sealed: record.dropFirst(Frame.headerLength))
        }
    }
}

private enum ClientHandshakeTestError: Error { case unexpected }

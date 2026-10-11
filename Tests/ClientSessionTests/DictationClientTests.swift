import Foundation
import Network
import Testing
import VantageCore
@testable import VantageClientLogic

private enum DictationTestFailure: Error { case unexpectedMessage, timedOut }

/// A one-connection loopback host that answers the handshake with the given capabilities.
private func dictationHost(capabilities: HostCapabilities?,
                           then body: @escaping @Sendable (MessageChannel, Hello) async throws -> Void) async throws -> (NWListener, Task<Void, any Error>) {
    let listener = try NWListener(using: VantageNetwork.tcpParameters(), on: .any)
    let channels = AsyncStream<MessageChannel> { continuation in
        listener.newConnectionHandler = { continuation.yield(MessageChannel(connection: $0)) }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        listener.stateUpdateHandler = { state in
            if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume() }
            else if case .failed(let error) = state { listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
        }
        listener.start(queue: .global())
    }
    let server = Task {
        var iterator = channels.makeAsyncIterator()
        guard let channel = await iterator.next() else { throw DictationTestFailure.unexpectedMessage }
        try await channel.start()
        guard case .hello(let hello)? = try await channel.receive() else { throw DictationTestFailure.unexpectedMessage }
        let host = DeviceIdentity()
        try await channel.send(.challenge(Challenge(hostName: "Test Mac", hostVersion: "1.0", hostPublicKey: host.publicKeyData,
                                                    nonce: AuthTranscript.randomNonce(), isPaired: true)))
        guard case .authenticate? = try await channel.receive() else { throw DictationTestFailure.unexpectedMessage }
        try await channel.send(.authResult(AuthResult(status: .ok, displays: [], capabilities: capabilities)))
        guard case .selectDisplay? = try await channel.receive() else { throw DictationTestFailure.unexpectedMessage }
        try await body(channel, hello)
        await channel.close()
    }
    return (listener, server)
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw DictationTestFailure.timedOut }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DictationClientTests {
    @Test func routeUsesTheMacOnlyWhenMacWhisperIsAdvertised() {
        #expect(DictationRoute.resolve(preference: .mac, hostEngines: [.macWhisper, .apple]) == .mac(.macWhisper))
        #expect(DictationRoute.resolve(preference: .mac, hostEngines: nil) == .iPad)      // older host
        #expect(DictationRoute.resolve(preference: .mac, hostEngines: []) == .iPad)
        #expect(DictationRoute.resolve(preference: .mac, hostEngines: [.apple]) == .iPad)
        #expect(DictationRoute.resolve(preference: .iPad, hostEngines: [.macWhisper]) == .iPad)
    }

    @Test func theMacsFirstEngineIsTheOneUsed() {
        // The host lists the engine chosen in its Settings first.
        #expect(DictationRoute.resolve(preference: .mac, hostEngines: [.parakeet, .macWhisper, .apple]) == .mac(.parakeet))
        #expect(DictationRoute.resolve(preference: .mac, hostEngines: [.apple, .macWhisper]) == .mac(.apple))
        #expect(DictationRoute.resolve(preference: .mac, hostEngines: [.parakeet, .apple]) == .mac(.parakeet))
        #expect(DictationRoute.resolve(preference: .iPad, hostEngines: [.parakeet]) == .iPad)
        // A saved choice from before the Mac picked the engine reads as "On the Mac".
        #expect(DictationEnginePreference(rawValue: "parakeet") == nil)

        #expect(DictationRoute.mac(.parakeet).label == "Parakeet")
        #expect(DictationRoute.label(for: .apple) == "Apple on Mac")
        #expect(DictationRoute.label(for: DictationEngineID(rawValue: "future")) == "On Mac")
    }

    @Test func transcriptKeepsFinalTextAndReplacesVolatileGuesses() {
        var transcript = DictationTranscript(prefix: "Hello there. ")
        transcript.apply("please move", isFinal: false)
        #expect(transcript.display == "Hello there. please move")
        transcript.apply("Please move the meeting", isFinal: false)
        transcript.apply("Please move the meeting to Thursday.", isFinal: true)
        transcript.apply(" And send", isFinal: false)
        #expect(transcript.committed == "Hello there. Please move the meeting to Thursday.")
        #expect(transcript.display == "Hello there. Please move the meeting to Thursday. And send")
        transcript.apply(" And send the update.", isFinal: true)
        #expect(transcript.volatile.isEmpty)
        #expect(transcript.committed.hasSuffix("Thursday. And send the update."))
        #expect(DictationTranscript().display.isEmpty)
    }

    @Test func packetizerEmits20msPacketsInSequence() {
        var packetizer = MicPacketizer(dictationID: UUID())
        #expect(packetizer.push(Data(count: 500)).isEmpty)
        let packets = packetizer.push(Data(count: 1_000)) // 1 500 bytes pending → 2 packets + 220
        #expect(packets.map(\.sequence) == [0, 1])
        #expect(packets.allSatisfy { $0.samples.count == 640 && $0.format == .pcm16LE16k })
        let tail = packetizer.flush()
        #expect(tail?.samples.count == 220)
        #expect(tail?.sequence == 2)
        #expect(packetizer.flush() == nil)
    }

    @Test func languageCodeIsTheBareISOCode() {
        #expect(DictationLanguage.code(for: Locale(identifier: "en_US")) == "en")
        #expect(DictationLanguage.code(for: Locale(identifier: "de-CH")) == "de")
    }

    @Test @MainActor func dictationRoundTripsThroughTheSession() async throws {
        let id = UUID()
        let capabilities = HostCapabilities(codecs: [.hevc], canManageVirtualDisplay: false, clipboard: true, maxFPS: 60,
                                            dictationEngines: [.macWhisper, .apple])
        let (listener, server) = try await dictationHost(capabilities: capabilities) { channel, hello in
            #expect(hello.features?.dictation == true)
            guard case .dictationControl(let begin)? = try await channel.receive() else { throw DictationTestFailure.unexpectedMessage }
            #expect(begin.action == .begin && begin.id == id && begin.engine == .macWhisper && begin.language == "en")
            var bytes = 0
            while case .micAudio(let audio)? = try await channel.receive() {
                #expect(audio.dictationID == id)
                bytes += audio.samples.count
                if bytes >= 1_300 { break }
            }
            guard case .dictationControl(let commit)? = try await channel.receive() else { throw DictationTestFailure.unexpectedMessage }
            #expect(commit.action == .commit && commit.id == id)
            try await channel.send(.dictationResult(DictationResult(id: id, text: "Open the pull request.", engine: .macWhisper)))
            let next = try await channel.receive()
            #expect(next == nil)
        }
        defer { listener.cancel() }

        let session = ClientSession(identity: DeviceIdentity())
        defer { session.disconnect() }
        var received: DictationResult?
        session.onDictationResult = { received = $0 }
        session.connect(to: SavedDevice(name: "Test Mac", host: "127.0.0.1", port: listener.port!.rawValue),
                        viewport: Viewport(widthPoints: 800, heightPoints: 600, scale: 2))
        try await waitUntil { session.state == .connected }
        #expect(DictationRoute.resolve(preference: .mac, hostEngines: session.dictationEngines) == .mac(.macWhisper))

        session.send(.dictationControl(DictationControl(action: .begin, id: id, engine: .macWhisper, language: "en", format: .pcm16LE16k)))
        var packetizer = MicPacketizer(dictationID: id)
        for packet in packetizer.push(Data(count: 1_000)) { session.send(.micAudio(packet)) }
        if let tail = packetizer.flush() { session.send(.micAudio(tail)) }
        session.send(.micAudio(MicAudio(dictationID: id, sequence: 99, samples: Data(count: 300))))
        session.send(.dictationControl(DictationControl(action: .commit, id: id)))
        try await waitUntil { received != nil }
        #expect(received == DictationResult(id: id, text: "Open the pull request.", engine: .macWhisper))
        session.disconnect()
        try await server.value
    }

    @Test @MainActor func olderHostWithoutEnginesKeepsDictationOnTheIPad() async throws {
        let old = HostCapabilities(codecs: [.hevc], canManageVirtualDisplay: false, clipboard: true, maxFPS: 60)
        let (listener, server) = try await dictationHost(capabilities: old) { channel, _ in
            // The client must not send anything the older host can't decode.
            let next = try await channel.receive()
            #expect(next == nil)
        }
        defer { listener.cancel() }
        let session = ClientSession(identity: DeviceIdentity())
        session.connect(to: SavedDevice(name: "Old Mac", host: "127.0.0.1", port: listener.port!.rawValue),
                        viewport: Viewport(widthPoints: 800, heightPoints: 600, scale: 2))
        try await waitUntil { session.state == .connected }
        #expect(session.dictationEngines == nil)
        #expect(DictationRoute.resolve(preference: .mac, hostEngines: session.dictationEngines) == .iPad)
        session.disconnect()
        try await server.value
    }
}

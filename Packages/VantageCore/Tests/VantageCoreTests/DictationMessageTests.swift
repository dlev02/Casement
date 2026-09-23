import Foundation
import Testing
@testable import VantageCore

@Test func dictationMessagesRoundTrip() throws {
    let id = UUID()
    let begin = DictationControl(action: .begin, id: id, engine: .macWhisper, language: "en", format: .pcm16LE16k)
    let frame = try Message.dictationControl(begin).encodedFrame()
    let header = try Frame.Header.decode(frame.prefix(Frame.headerLength))
    #expect(header.kind == .dictationControl)
    #expect(!header.kind.isBinary)
    guard case .dictationControl(let back) = try Message.decode(kind: header.kind, payload: frame.dropFirst(Frame.headerLength)) else {
        Issue.record("wrong kind"); return
    }
    #expect(back == begin)

    let result = DictationResult(id: id, text: "Open the pull request.", engine: .apple, error: nil)
    guard case .dictationResult(let r) = try Message.decode(kind: .dictationResult, payload: try Message.dictationResult(result).encodedPayload()) else {
        Issue.record("wrong kind"); return
    }
    #expect(r == result)

    let samples = Data((0..<640).map { UInt8($0 & 0xFF) })
    let audio = MicAudio(dictationID: id, sequence: 7, samples: samples)
    let payload = try Message.micAudio(audio).encodedPayload()
    #expect(payload.count == 16 + 4 + 1 + 640)
    #expect(MessageKind.micAudio.isBinary)
    guard case .micAudio(let a) = try Message.decode(kind: .micAudio, payload: payload) else { Issue.record("wrong kind"); return }
    #expect(a == audio)
    #expect(a.dictationID == id)
}

@Test func micAudioDecodesFromSlicedPayload() throws {
    // MessageChannel hands decode a Data slice with a non-zero start index.
    let audio = MicAudio(dictationID: UUID(), sequence: 1, samples: Data([1, 2, 3, 4]))
    let frame = try Message.micAudio(audio).encodedFrame()
    guard case .micAudio(let a) = try Message.decode(kind: .micAudio, payload: frame.dropFirst(Frame.headerLength)) else {
        Issue.record("wrong kind"); return
    }
    #expect(a == audio)
}

@Test func micAudioRejectsUnknownFormatAndTruncation() {
    var bytes = Data(repeating: 0, count: 16)
    bytes.append(contentsOf: [1, 0, 0, 0, 9]) // sequence 1, format 9
    #expect(throws: BinaryDecodingError.self) { try Message.decode(kind: .micAudio, payload: bytes) }
    #expect(throws: BinaryDecodingError.self) { try Message.decode(kind: .micAudio, payload: Data(repeating: 0, count: 10)) }
}

@Test func dictationMetadataRemainsCompatibleWithOlderPeers() throws {
    // An older client's Hello has no `features`; an older host's capabilities have no engines.
    let oldHello = Data(#"{"protocolVersion":2,"clientName":"iPad","deviceModel":"iPad","appVersion":"1.0","clientPublicKey":"AQ==","supportedCodecs":["hevc"],"maxDecodeWidth":1,"maxDecodeHeight":1}"#.utf8)
    #expect(try JSONDecoder().decode(Hello.self, from: oldHello).features == nil)
    let oldCapabilities = Data(#"{"codecs":["hevc"],"canManageVirtualDisplay":false,"clipboard":true,"maxFPS":60}"#.utf8)
    #expect(try JSONDecoder().decode(HostCapabilities.self, from: oldCapabilities).dictationEngines == nil)

    // Newer fields are ignored by decoders that predate them (JSONDecoder skips unknown keys).
    struct LegacyCapabilities: Decodable { var codecs: [VideoCodec]; var clipboard: Bool; var maxFPS: Int }
    let newCapabilities = HostCapabilities(codecs: [.hevc], canManageVirtualDisplay: false, clipboard: true, maxFPS: 60,
                                           dictationEngines: [.macWhisper, .apple, DictationEngineID(rawValue: "future")])
    let encoded = try JSONEncoder().encode(newCapabilities)
    #expect(try JSONDecoder().decode(LegacyCapabilities.self, from: encoded).maxFPS == 60)
    // An engine this build doesn't know still decodes.
    let decoded = try JSONDecoder().decode(HostCapabilities.self, from: encoded)
    #expect(decoded.dictationEngines == [.macWhisper, .apple, DictationEngineID(rawValue: "future")])
    #expect(String(data: encoded, encoding: .utf8)!.contains(#""dictationEngines":["macwhisper","apple","future"]"#))

    let hello = Hello(clientName: "iPad", deviceModel: "iPad", appVersion: "1.0", clientPublicKey: Data([1]), supportedCodecs: [.hevc],
                      maxDecodeWidth: 1, maxDecodeHeight: 1, viewport: nil, features: ClientFeatures(dictation: true))
    #expect(try JSONDecoder().decode(Hello.self, from: JSONEncoder().encode(hello)).features?.dictation == true)
}

@Test func unknownKindIsRejectedByOlderDecoders() {
    // Documents the reason for the gating: a peer that doesn't know a kind drops the frame and
    // the session with it. 200 stands in for any kind added after this build.
    var header = Frame.Header(kind: .ping, length: 0).encoded()
    header[1] = 200
    #expect(throws: FrameError.unknownKind(200)) { try Frame.Header.decode(header) }
}

@Test func parakeetEngineChoiceTravelsInTheExistingEngineField() throws {
    // The client's engine choice already rides in `DictationControl.engine` on `begin`, so the
    // built-in Parakeet engine needs no new field: a newer client names it, an older client sends
    // "macwhisper" or nothing, and both decode everywhere.
    let id = UUID()
    let begin = DictationControl(action: .begin, id: id, engine: .parakeet, language: "en", format: .pcm16LE16k)
    let encoded = try JSONEncoder().encode(begin)
    #expect(String(data: encoded, encoding: .utf8)!.contains(#""engine":"parakeet""#))
    #expect(try JSONDecoder().decode(DictationControl.self, from: encoded) == begin)

    // An older client's begin (MacWhisper, or no engine at all) still decodes on a newer host.
    let oldBegin = Data(#"{"action":"begin","id":"\#(id.uuidString)","language":"en","format":0}"#.utf8)
    let decodedOld = try JSONDecoder().decode(DictationControl.self, from: oldBegin)
    #expect(decodedOld.engine == nil)
    #expect(decodedOld.format == .pcm16LE16k)

    // An older host's decoder (a plain string engine) accepts the new value, and an older client
    // decoding a newer host's result keeps the raw engine name.
    struct LegacyControl: Decodable { var action: String; var engine: String? }
    #expect(try JSONDecoder().decode(LegacyControl.self, from: encoded).engine == "parakeet")
    let result = DictationResult(id: id, text: "Open the pull request.", engine: .parakeet)
    let back = try JSONDecoder().decode(DictationResult.self, from: JSONEncoder().encode(result))
    #expect(back.engine == .parakeet)
    #expect(back.engine?.rawValue == "parakeet")

    // Advertised alongside the others only when the host has it ready.
    let capabilities = HostCapabilities(codecs: [.hevc], canManageVirtualDisplay: false, clipboard: true, maxFPS: 60,
                                        dictationEngines: [.macWhisper, .parakeet, .apple])
    let decodedCaps = try JSONDecoder().decode(HostCapabilities.self, from: JSONEncoder().encode(capabilities))
    #expect(decodedCaps.dictationEngines == [.macWhisper, .parakeet, .apple])
}

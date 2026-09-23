import Foundation
import Testing
@testable import VantageCore

@Test func audioControlMessagesRoundTrip() throws {
    let request = AudioRequest(enabled: true)
    let frame = try Message.audioRequest(request).encodedFrame()
    let header = try Frame.Header.decode(frame.prefix(Frame.headerLength))
    #expect(header.kind == .audioRequest)
    #expect(header.kind.rawValue == 63)
    #expect(!header.kind.isBinary)
    guard case .audioRequest(let back) = try Message.decode(kind: header.kind, payload: frame.dropFirst(Frame.headerLength)) else {
        Issue.record("wrong kind"); return
    }
    #expect(back == request)
    #expect(String(data: try Message.audioRequest(AudioRequest(enabled: false)).encodedPayload(), encoding: .utf8) == #"{"enabled":false}"#)

    let config = AudioConfig()
    #expect(MessageKind.audioConfig.rawValue == 73)
    guard case .audioConfig(let c) = try Message.decode(kind: .audioConfig, payload: try Message.audioConfig(config).encodedPayload()) else {
        Issue.record("wrong kind"); return
    }
    #expect(c == config)
    #expect(c.codec == "opus" && c.sampleRate == 48_000 && c.channels == 2 && c.framesPerPacket == 480 && c.bitrate == 128_000)
    #expect(c.unavailable == nil)

    let failed = AudioConfig.unavailable("Turn on Screen Recording for Vantage Host.")
    guard case .audioConfig(let f) = try Message.decode(kind: .audioConfig, payload: try Message.audioConfig(failed).encodedPayload()) else {
        Issue.record("wrong kind"); return
    }
    #expect(f.unavailable == "Turn on Screen Recording for Vantage Host.")
}

@Test func audioPacketLayoutIsFixedLittleEndian() throws {
    let opus = Data((0..<37).map { UInt8($0) })
    let packet = AudioPacket(sequence: 0x0102_0304_0506_0708, captureNanos: 0x1112_1314_1516_1718, frameCount: 480, data: opus)
    let payload = try Message.audioPacket(packet).encodedPayload()
    #expect(MessageKind.audioPacket.rawValue == 102)
    #expect(MessageKind.audioPacket.isBinary)
    #expect(payload.count == AudioPacket.headerLength + opus.count)
    #expect(Array(payload.prefix(8)) == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
    #expect(Array(payload[8..<16]) == [0x18, 0x17, 0x16, 0x15, 0x14, 0x13, 0x12, 0x11])
    #expect(Array(payload[16..<18]) == [0xE0, 0x01]) // 480
    #expect(payload.suffix(opus.count) == opus)
    guard case .audioPacket(let back) = try Message.decode(kind: .audioPacket, payload: payload) else { Issue.record("wrong kind"); return }
    #expect(back == packet)

    // MessageChannel hands decode a slice with a non-zero start index.
    let frame = try Message.audioPacket(packet).encodedFrame()
    guard case .audioPacket(let sliced) = try Message.decode(kind: .audioPacket, payload: frame.dropFirst(Frame.headerLength)) else {
        Issue.record("wrong kind"); return
    }
    #expect(sliced == packet)

    // An empty codec payload is legal (a stream end marker could use it); a short header isn't.
    let empty = AudioPacket(sequence: 1, captureNanos: 2, frameCount: 0, data: Data())
    guard case .audioPacket(let e) = try Message.decode(kind: .audioPacket, payload: try Message.audioPacket(empty).encodedPayload()) else {
        Issue.record("wrong kind"); return
    }
    #expect(e == empty)
    #expect(throws: BinaryDecodingError.self) { try Message.decode(kind: .audioPacket, payload: Data(repeating: 0, count: 17)) }
}

@Test func audioMetadataRemainsCompatibleWithOlderPeers() throws {
    // Older peers: a Hello whose features have only dictation, capabilities with no audio.
    let oldFeatures = Data(#"{"dictation":true}"#.utf8)
    #expect(try JSONDecoder().decode(ClientFeatures.self, from: oldFeatures).macAudio == nil)
    let oldCapabilities = Data(#"{"codecs":["hevc"],"canManageVirtualDisplay":false,"clipboard":true,"maxFPS":60,"dictationEngines":["apple"]}"#.utf8)
    #expect(try JSONDecoder().decode(HostCapabilities.self, from: oldCapabilities).audio == nil)

    // Older decoders skip the new keys.
    struct LegacyFeatures: Decodable { var dictation: Bool? }
    let features = ClientFeatures(dictation: true, macAudio: true)
    #expect(try JSONDecoder().decode(LegacyFeatures.self, from: JSONEncoder().encode(features)).dictation == true)
    let capabilities = HostCapabilities(codecs: [.hevc], canManageVirtualDisplay: false, clipboard: true, maxFPS: 60, audio: true)
    struct LegacyCapabilities: Decodable { var codecs: [VideoCodec]; var maxFPS: Int }
    #expect(try JSONDecoder().decode(LegacyCapabilities.self, from: JSONEncoder().encode(capabilities)).maxFPS == 60)
    #expect(try JSONDecoder().decode(HostCapabilities.self, from: JSONEncoder().encode(capabilities)).audio == true)

    // A newer host's config with a codec this build doesn't know still decodes (the client then
    // treats it as unavailable rather than dropping the session).
    let future = Data(#"{"codec":"lyra","sampleRate":16000,"channels":1,"framesPerPacket":320,"bitrate":6000,"extra":1}"#.utf8)
    let decoded = try JSONDecoder().decode(AudioConfig.self, from: future)
    #expect(decoded.codec == "lyra" && decoded.unavailable == nil)
    // The request's reserved mute flag is optional both ways.
    #expect(try JSONDecoder().decode(AudioRequest.self, from: Data(#"{"enabled":true,"muteMacOutput":true}"#.utf8)).muteMacOutput == true)
}

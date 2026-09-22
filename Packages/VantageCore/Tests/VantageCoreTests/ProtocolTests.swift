import Foundation
import Testing
@testable import VantageCore

@Test func protocolVersionIsPositive() {
    #expect(VantageProtocol.version >= 1)
}

@Test func binaryRoundTrip() throws {
    var writer = BinaryWriter()
    writer.write(UInt8(7))
    writer.write(true)
    writer.write(UInt16(65_000))
    writer.write(UInt32(4_000_000_000))
    writer.write(UInt64.max - 1)
    writer.write(Int32(-42))
    writer.write(Float(1.5))
    writer.write(Double.pi)
    writer.write(Data([1, 2, 3]))
    writer.write("héllo")
    var reader = BinaryReader(writer.data)
    #expect(try reader.readUInt8() == 7)
    #expect(try reader.readBool() == true)
    #expect(try reader.readUInt16() == 65_000)
    #expect(try reader.readUInt32() == 4_000_000_000)
    #expect(try reader.readUInt64() == UInt64.max - 1)
    #expect(try reader.readInt32() == -42)
    #expect(try reader.readFloat() == 1.5)
    #expect(try reader.readDouble() == Double.pi)
    #expect(try reader.readData() == Data([1, 2, 3]))
    #expect(try reader.readString() == "héllo")
    #expect(reader.isAtEnd)
}

@Test func frameHeaderRoundTrip() throws {
    let header = Frame.Header(kind: .videoFrame, flags: 3, length: 1234)
    let decoded = try Frame.Header.decode(header.encoded())
    #expect(decoded == header)
    #expect(header.encoded().count == Frame.headerLength)
}

@Test func frameRejectsBadMagic() {
    var bad = Frame.Header(kind: .ping, length: 0).encoded()
    bad[0] = 0
    #expect(throws: FrameError.badMagic(0)) { try Frame.Header.decode(bad) }
}

@Test func controlMessageRoundTrip() throws {
    let hello = Hello(clientName: "iPad", deviceModel: "iPad16,3", appVersion: "1.0", clientPublicKey: Data(repeating: 9, count: 32), supportedCodecs: [.hevc, .h264], maxDecodeWidth: 4096, maxDecodeHeight: 2304, viewport: Viewport(widthPoints: 1210, heightPoints: 834, scale: 2))
    let frame = try Message.hello(hello).encodedFrame()
    let header = try Frame.Header.decode(frame.prefix(Frame.headerLength))
    let decoded = try Message.decode(kind: header.kind, payload: frame.dropFirst(Frame.headerLength))
    guard case .hello(let back) = decoded else { Issue.record("wrong kind"); return }
    #expect(back.clientName == "iPad")
    #expect(back.clientPublicKey == hello.clientPublicKey)
    #expect(back.viewport == hello.viewport)
    #expect(back.supportedCodecs == [.hevc, .h264])
}

@Test func displaySelectionCodable() throws {
    let select = SelectDisplay(selection: .fitViewport(Viewport(widthPoints: 1210, heightPoints: 834, scale: 2)), targetFPS: 60, quality: .auto)
    let payload = try Message.selectDisplay(select).encodedPayload()
    guard case .selectDisplay(let back) = try Message.decode(kind: .selectDisplay, payload: payload) else { Issue.record("wrong kind"); return }
    #expect(back.selection == select.selection)
}

@Test func binaryMessagesRoundTrip() throws {
    let frame = VideoFrame(sequence: 42, captureNanos: 1_000_000, isKeyframe: true, width: 2420, height: 1668, data: Data([0, 0, 0, 2, 0x65, 0x88]))
    guard case .videoFrame(let f) = try Message.decode(kind: .videoFrame, payload: try Message.videoFrame(frame).encodedPayload()) else { Issue.record("wrong kind"); return }
    #expect(f == frame)

    let pointer = PointerEvent(action: .down, button: .right, x: 10.5, y: 20.25, clickCount: 2, modifiers: [.command, .shift])
    guard case .pointerEvent(let p) = try Message.decode(kind: .pointerEvent, payload: try Message.pointerEvent(pointer).encodedPayload()) else { Issue.record("wrong kind"); return }
    #expect(p == pointer)

    let scroll = ScrollEvent(phase: .ended, isContinuous: true, deltaX: -3, deltaY: 12.5, x: 1, y: 2, velocityX: 0, velocityY: -800)
    guard case .scrollEvent(let s) = try Message.decode(kind: .scrollEvent, payload: try Message.scrollEvent(scroll).encodedPayload()) else { Issue.record("wrong kind"); return }
    #expect(s == scroll)

    let key = KeyEvent(keyCode: 0x24, isDown: true, modifiers: [.command], isRepeat: false)
    guard case .keyEvent(let k) = try Message.decode(kind: .keyEvent, payload: try Message.keyEvent(key).encodedPayload()) else { Issue.record("wrong kind"); return }
    #expect(k == key)

    let cursor = CursorPosition(x: 5, y: 6, isVisible: false)
    guard case .cursorPosition(let c) = try Message.decode(kind: .cursorPosition, payload: try Message.cursorPosition(cursor).encodedPayload()) else { Issue.record("wrong kind"); return }
    #expect(c == cursor)
}

@Test func authTranscriptVerifies() throws {
    let client = DeviceIdentity()
    let host = DeviceIdentity()
    let nonce = AuthTranscript.randomNonce()
    let signature = try client.sign(AuthTranscript.bytes(nonce: nonce, hostPublicKey: host.publicKeyData, clientPublicKey: client.publicKeyData))
    #expect(AuthTranscript.verify(signature: signature, nonce: nonce, hostPublicKey: host.publicKeyData, clientPublicKey: client.publicKeyData))
    #expect(!AuthTranscript.verify(signature: signature, nonce: AuthTranscript.randomNonce(), hostPublicKey: host.publicKeyData, clientPublicKey: client.publicKeyData))
    #expect(client.fingerprint.count == 16)
    #expect(AuthTranscript.randomPairingCode().count == 6)
}

@Test func tailscaleRanges() {
    #expect(VantageNetwork.isTailscaleAddress(.ipv4(.init("100.64.0.4")!)))
    #expect(VantageNetwork.isTailscaleAddress(.ipv4(.init("100.64.0.2")!)))
    #expect(!VantageNetwork.isTailscaleAddress(.ipv4(.init("100.128.0.1")!)))
    #expect(!VantageNetwork.isTailscaleAddress(.ipv4(.init("192.168.1.1")!)))
    #expect(VantageNetwork.isTailscaleAddress(.ipv6(.init("fd7a:115c:a1e0::2")!)))
    #expect(VantageNetwork.isTailscaleAddress(.name("drews-macbook-pro-1.tail1234.ts.net", nil)))
}

@Test func hidKeyMapCoversModifiersAndLetters() {
    #expect(HIDKeyMap.virtualKey(forHIDUsage: 0xE3) == 0x37) // Left GUI -> Command
    #expect(HIDKeyMap.virtualKey(forHIDUsage: 0xE1) == 0x38) // Left Shift
    #expect(HIDKeyMap.virtualKey(forHIDUsage: 0x04) == 0x00) // A
    #expect(HIDKeyMap.virtualKey(forHIDUsage: 0x28) == 0x24) // Return
    #expect(HIDKeyMap.virtualKey(forHIDUsage: 0x4F) == 0x7C) // Right arrow
    #expect(HIDKeyMap.virtualKey(forHIDUsage: 0x46) == nil)  // PrintScreen has no kVK
    #expect(HIDKeyMap.hidToVirtualKey.count >= 118)
}

@Test func geometryAspectFitCentersAndFits() {
    let rect = Geometry.aspectFit(CGSize(width: 2420, height: 1668), in: CGSize(width: 1000, height: 1000))
    #expect(abs(rect.width - 1000) < 0.5)
    #expect(rect.height < 1000)
    #expect(abs(rect.minY - (1000 - rect.height) / 2) < 0.5)
}

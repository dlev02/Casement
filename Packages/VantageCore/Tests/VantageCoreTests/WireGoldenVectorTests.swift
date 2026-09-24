import Foundation
import Testing
@testable import VantageCore

/// Wire vectors shared with the Windows host's C# library (`WindowsHost/tests/Vantage.Protocol.Tests/GoldenVectorTests.cs`
/// defines the same messages under the same names). Each side writes its frames to
/// `WindowsHost/tests/golden/<side>/<name>.frame` when `VANTAGE_WRITE_GOLDEN=1`, and always decodes
/// the other side's: JSON must mean the same key for key and value for value, binary must match
/// byte for byte. A change to a message that breaks the other side fails here first.
@Suite struct WireGoldenVectorTests {
    static let id = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
    static let key32 = Data((1...32).map { UInt8($0) })
    static let signature64 = Data((0..<64).map { UInt8(255 - $0) })
    static let token = Data((0..<32).map { UInt8(($0 * 7) & 0xFF) })
    static let display = DisplayInfo(id: 1, name: "DELL U2723QE", pixelWidth: 3840, pixelHeight: 2160, pointWidth: 2560, pointHeight: 1440,
                                     scale: 1.5, originX: -3840, originY: 0, isMain: true, isBuiltIn: false, isVirtual: false, refreshRate: 59.94)

    /// Keep in step with the C# list.
    static let vectors: [(String, Message)] = [
        ("hello", .hello(Hello(clientName: "iPad", deviceModel: "iPad16,6", appVersion: "1.0", clientPublicKey: key32,
                               supportedCodecs: [.hevc, .h264], maxDecodeWidth: 4096, maxDecodeHeight: 2304,
                               viewport: Viewport(widthPoints: 1210, heightPoints: 834, scale: 2),
                               features: ClientFeatures(dictation: true, macAudio: true, fileTransfer: true)))),
        ("helloFilesOnly", .hello(Hello(clientName: "iPad", deviceModel: "iPad16,6", appVersion: "1.0", clientPublicKey: key32,
                                        supportedCodecs: [], maxDecodeWidth: 0, maxDecodeHeight: 0, viewport: nil, isReadinessProbe: false,
                                        features: ClientFeatures(fileTransfer: true, filesOnly: true)))),
        ("challenge", .challenge(Challenge(hostName: "DREW-PC", hostVersion: "1.0", hostPublicKey: key32, nonce: token, isPaired: false,
                                           peerTailnetName: "drew@example.com", hostPlatform: .windows))),
        ("authenticate", .authenticate(Authenticate(signature: signature64, pairingCode: "024680"))),
        ("authResultOk", .authResult(AuthResult(status: .ok, sessionToken: token, displays: [display],
                                                capabilities: HostCapabilities(codecs: [.h264], canManageVirtualDisplay: false, clipboard: true, maxFPS: 60,
                                                                               fileTransfer: true, filesOnlySessions: true, platform: .windows)))),
        ("authResultPairing", .authResult(AuthResult(status: .pairingRequired, message: "Enter the pairing code shown on the PC"))),
        ("authResultProbe", .authResult(AuthResult(status: .ok, readiness: HostReadiness(screenRecordingGranted: true, accessibilityGranted: true)))),
        ("displayList", .displayList(DisplayList(displays: [display]))),
        ("selectDisplayFit", .selectDisplay(SelectDisplay(selection: .fitViewport(Viewport(widthPoints: 1210, heightPoints: 834, scale: 2)),
                                                          targetFPS: 60, quality: .auto, preferredCodec: .hevc, useVirtualDisplay: false))),
        ("selectDisplayId", .selectDisplay(SelectDisplay(selection: .display(3), targetFPS: 30, quality: .text))),
        ("streamConfig", .streamConfig(StreamConfig(display: display, codec: .h264, fps: 60, bitrateKbps: 39_813))),
        ("viewportChanged", .viewportChanged(ViewportChanged(viewport: Viewport(widthPoints: 1366, heightPoints: 1024, scale: 2)))),
        ("qualityFeedback", .qualityFeedback(QualityFeedback(rttMillis: 12.5, decodeMillis: 3.25, framesReceived: 15, framesDropped: 1,
                                                             queueDepth: 0, bytesReceived: 9_007_199_254_740_993, windowSeconds: 0.25))),
        ("requestKeyframe", .requestKeyframe),
        ("clipboard", .clipboard(ClipboardPayload(text: "Line one\nLíne two ✓", imagePNG: Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE]),
                                                  rtf: Data("{\\rtf1 hi}".utf8)))),
        ("hostCommand", .hostCommand(HostCommandMessage(command: .sleepDisplay))),
        ("ping", .ping(Ping(sentAtNanos: 18_446_744_073_709_551_615))),
        ("pong", .pong(Pong(echoNanos: 9_007_199_254_740_993))),
        ("disconnect", .disconnect(DisconnectMessage(reason: "The PC ended the session."))),
        ("attachMedia", .attachMedia(AttachMedia(sessionToken: token))),
        ("textInput", .textInput(TextInput(text: "héllo\n\t😀"))),
        ("videoConfig", .videoConfig(VideoConfig(codec: .h264, width: 1600, height: 1000,
                                                 parameterSets: [Data([0x67, 0x64, 0x00, 0x28, 0xAC]), Data([0x68, 0xEE, 0x3C, 0xB0])],
                                                 nalLengthSize: 4, fps: 60))),
        ("hostStatus", .hostStatus(HostStatus(isScreenLocked: true, isSecureInputActive: false, inputPath: .native, message: "The PC is locked",
                                              isDisplayAsleep: false, isScreenUnavailable: false))),
        ("fileOffer", .fileOffer(FileOffer(id: id, name: "Quarterly Report.pdf", byteCount: 70_000_000_000,
                                           modified: Date(timeIntervalSinceReferenceDate: 780_000_000.5), uti: "com.adobe.pdf"))),
        ("fileAccept", .fileAccept(FileAccept(id: id, resumeOffset: 1_048_576))),
        ("fileAcceptRejected", .fileAccept(FileAccept(id: id, resumeOffset: 0, rejected: "There isn't enough free space for it."))),
        ("fileComplete", .fileComplete(FileComplete(id: id, sha256: key32))),
        ("fileResultOk", .fileResult(FileResult(id: id, ok: true, savedName: "Quarterly Report 2.pdf"))),
        ("fileResultError", .fileResult(FileResult(id: id, ok: false, error: "The file arrived damaged. Try sending it again."))),
        ("fileCancel", .fileCancel(FileCancel(id: id))),
        ("videoFrame", .videoFrame(VideoFrame(sequence: 42, captureNanos: 123_456_789_012, isKeyframe: true, width: 1600, height: 1000,
                                              data: Data([0, 0, 0, 5, 0x65, 0x88, 0x84, 0x00, 0x21])))),
        ("pointerEvent", .pointerEvent(PointerEvent(action: .down, button: .right, x: 400.5, y: 250.25, clickCount: 2, modifiers: [.shift, .command]))),
        ("scrollEvent", .scrollEvent(ScrollEvent(phase: .ended, momentum: .none, isContinuous: true, deltaX: -1.5, deltaY: 12.75, x: 100, y: 200,
                                                 velocityX: -30, velocityY: 640.5, modifiers: [.control]))),
        ("keyEvent", .keyEvent(KeyEvent(keyCode: 0x7E, isDown: true, modifiers: [.control, .function], isRepeat: true))),
        ("fileChunkToClient", .fileChunkToClient(FileChunk(id: id, offset: 262_144, data: Data([1, 2, 3, 4, 5])))),
        ("fileChunkToHost", .fileChunkToHost(FileChunk(id: id, offset: 0x0102_0304_0506_0708, data: Data([0xFF])))),
    ]

    static var golden: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // Packages/VantageCore
            .deletingLastPathComponent().deletingLastPathComponent() // repo root
            .appending(path: "WindowsHost/tests/golden", directoryHint: .isDirectory)
    }

    @Test(arguments: vectors.map(\.0))
    func swiftVectorsAreCommittedAndStable(name: String) throws {
        let message = try #require(Self.vectors.first { $0.0 == name }?.1)
        let frame = try message.encodedFrame()
        let url = Self.golden.appending(path: "swift/\(name).frame")
        if ProcessInfo.processInfo.environment["VANTAGE_WRITE_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try frame.write(to: url)
        }
        // JSON key order isn't promised by JSONEncoder, so compare what the committed bytes mean.
        let committed = try Data(contentsOf: url)
        try Self.expectSameMessage(committed, as: message)
    }

    @Test(arguments: vectors.map(\.0))
    func csharpVectorsDecodeToTheSameMessage(name: String) throws {
        let message = try #require(Self.vectors.first { $0.0 == name }?.1)
        let frame = try Data(contentsOf: Self.golden.appending(path: "csharp/\(name).frame"))
        try Self.expectSameMessage(frame, as: message)
    }

    /// The frame's header is right, and its payload decodes (with the real decoder) to a message
    /// whose encoding means the same as the expected one; for JSON, the raw bytes do too (so a
    /// stray or misspelled key the decoder would skip still fails).
    static func expectSameMessage(_ frame: Data, as expected: Message) throws {
        let header = try Frame.Header.decode(frame.prefix(Frame.headerLength))
        #expect(header.kind == expected.kind)
        #expect(Int(header.length) == frame.count - Frame.headerLength)
        let payload = Data(frame.dropFirst(Frame.headerLength))
        let decoded = try Message.decode(kind: header.kind, payload: payload)
        let ours = try expected.encodedPayload()
        if expected.kind.isBinary || payload.isEmpty {
            #expect(payload == ours)
            #expect(try decoded.encodedPayload() == ours)
        } else {
            #expect(try canonical(payload) == canonical(ours))
            #expect(try canonical(decoded.encodedPayload()) == canonical(ours))
        }
    }

    /// Sorted keys, numbers by value: two encodings of the same JSON compare equal.
    static func canonical(_ json: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
}

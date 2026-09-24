import CoreMedia
import CryptoKit
import Foundation
import ImageIO
import Network
import Synchronization
import Testing
import UniformTypeIdentifiers
import VantageCore
import VideoToolbox
@testable import VantageClientLogic

/// The Windows host (C#, `WindowsHost/`) against the real client code. Opt in with a running host:
///
/// ```
/// dotnet WindowsHost/src/Vantage.SyntheticHost/bin/Debug/net10.0/Vantage.SyntheticHost.dll --port 47862 \
///   --pairing-code 246810 --pairing-code-rearm 3 --display-asleep --clipboard-text "from the PC" \
///   --input-log /tmp/interop-input.jsonl --state-dir "$(mktemp -d)"
/// VANTAGE_INTEROP_HOST=127.0.0.1:47862 VANTAGE_INTEROP_INPUT_LOG=/tmp/interop-input.jsonl \
///   VANTAGE_INTEROP_CLIPBOARD_TEXT="from the PC" xcrun swift test --filter WindowsHostInteropTests
/// ```
///
/// Optional: `VANTAGE_INTEROP_FILES_HOST` (a second host started with `--send-file-on-connect
/// <VANTAGE_INTEROP_SEND_FILE>`) for the host → client resume, `VANTAGE_INTEROP_FILE_BYTES` (size of
/// the client → host file, default 64 MiB), `VANTAGE_INTEROP_PNG` (where the decoded frame goes),
/// `VANTAGE_TEST_PAIRING_CODE` (default 246810), `VANTAGE_INTEROP_REARM` (seconds the host waits
/// before showing its fixed code again, default 3). The same suite runs against the real Windows
/// host over Tailscale; the input-log and clipboard checks then need their env vars left unset.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VANTAGE_INTEROP_HOST"] != nil), .serialized, .timeLimit(.minutes(10)))
@MainActor
struct WindowsHostInteropTests {
    static let env = ProcessInfo.processInfo.environment
    static let address = env["VANTAGE_INTEROP_HOST"] ?? "127.0.0.1:47862"
    static var host: String { String(address.split(separator: ":")[0]) }
    static var port: UInt16 { UInt16(address.split(separator: ":")[1])! }
    static let code = env["VANTAGE_TEST_PAIRING_CODE"] ?? "246810"
    static let rearm = Double(env["VANTAGE_INTEROP_REARM"] ?? "3") ?? 3
    static let viewport = Viewport(widthPoints: 1210, heightPoints: 834, scale: 2)

    // MARK: Handshake and pairing

    @Test func pairingThroughTheRealClientThenRemembered() async throws {
        try await Self.waitForCode()
        let identity = DeviceIdentity()
        let session = ClientSession(identity: identity, files: FileTransferController(receiveDirectory: Self.scratch("pairing")))
        defer { session.disconnect() }
        let device = SavedDevice(name: "Interop PC", host: Self.host, port: Self.port)

        session.connect(to: device, viewport: Self.viewport)
        try await Self.eventually { session.state == .pairingRequired }
        #expect(session.pairingError == nil)
        #expect(session.hostPlatform == .windows)

        session.connect(to: device, viewport: Self.viewport, pairingCode: "000000")
        try await Self.eventually { session.state == .pairingRequired && session.pairingError != nil }

        session.connect(to: device, viewport: Self.viewport, pairingCode: Self.code)
        try await Self.eventually { session.state == .connected }
        #expect(session.capabilities?.platform == .windows)
        #expect(session.capabilities?.codecs == [.h264])
        #expect(session.capabilities?.fileTransfer == true)
        #expect(session.capabilities?.audio == nil, "no Mac audio on Windows")
        #expect(session.dictationEngines == nil, "no host dictation on Windows")
        #expect(!session.displays.isEmpty)

        session.disconnect()
        session.connect(to: device, viewport: Self.viewport) // no code: the key is trusted now
        try await Self.eventually { session.state == .connected }
    }

    @Test func fiveWrongCodesBurnTheCodeAndEachCostsASecond() async throws {
        try await Self.waitForCode()
        let stranger = DeviceIdentity()
        for _ in 0..<5 {
            let started = ContinuousClock.now
            let (_, result) = try await Self.handshake(stranger, code: "999999")
            #expect(result?.status == .badPairingCode)
            #expect(ContinuousClock.now - started >= .milliseconds(950), "each miss costs a second")
        }
        let (_, burned) = try await Self.handshake(stranger, code: Self.code)
        #expect(burned?.status == .badPairingCode, "the right code no longer works")
        #expect(burned?.message?.contains("expired") == true)
    }

    @Test func probesAndVersionMismatches() async throws {
        let identity = try await Self.pairedIdentity()
        let probe = try await Self.open()
        try await probe.send(.hello(Hello(clientName: "Interop", deviceModel: "test", appVersion: "1.0", clientPublicKey: identity.publicKeyData,
                                          supportedCodecs: [], maxDecodeWidth: 0, maxDecodeHeight: 0, viewport: nil, isReadinessProbe: true)))
        guard case .challenge(let challenge)? = try await probe.receive() else { Issue.record("no challenge"); return }
        #expect(challenge.hostPlatform == .windows)
        try await probe.send(.authenticate(Authenticate(signature: try Self.sign(identity, challenge))))
        guard case .authResult(let result)? = try await probe.receive() else { Issue.record("no result"); return }
        #expect(result.status == .ok)
        #expect(result.readiness?.screenRecordingGranted == true && result.readiness?.accessibilityGranted == true)
        #expect(result.displays == nil)
        #expect(try await probe.receive() == nil, "the host hangs up after a probe")

        let old = try await Self.open()
        try await old.send(.hello(Hello(protocolVersion: 1, clientName: "Old", deviceModel: "test", appVersion: "0.9",
                                        clientPublicKey: identity.publicKeyData, supportedCodecs: [.h264], maxDecodeWidth: 4096,
                                        maxDecodeHeight: 2304, viewport: nil)))
        guard case .authResult(let mismatch)? = try await old.receive() else { Issue.record("no result"); return }
        #expect(mismatch.status == .versionMismatch)
        #expect(mismatch.message == "Protocol 2 required")
    }

    // MARK: Streaming

    @Test func streamDecodesWithVideoToolboxAndKeyframesComeOnRequest() async throws {
        let identity = try await Self.pairedIdentity()
        let session = ClientSession(identity: identity, files: FileTransferController(receiveDirectory: Self.scratch("stream")))
        defer { session.disconnect() }
        let received = Mutex<[(ContinuousClock.Instant, Message)]>([])
        session.onVideo = { message in received.withLock { $0.append((.now, message)) } }
        let clipboard = Mutex<ClipboardPayload?>(nil)
        session.onClipboard = { payload in clipboard.withLock { $0 = payload } }
        session.connect(to: SavedDevice(name: "Interop PC", host: Self.host, port: Self.port), viewport: Self.viewport)
        try await Self.eventually { session.state == .connected }
        try await Self.eventually { received.withLock { $0.count } >= 45 }

        let messages = received.withLock { $0.map(\.1) }
        #expect(session.activeConfig?.codec == .h264, "the stream config came first")
        guard case .videoConfig(let config)? = messages.first else { Issue.record("the first video message isn't a videoConfig"); return }
        #expect(config.nalLengthSize == 4 && config.parameterSets.count == 2)
        guard case .videoFrame(let first) = messages[1] else { Issue.record("no frame after the config"); return }
        #expect(first.isKeyframe && first.sequence == 0)

        // Decode an IDR and the P-frames after it with VideoToolbox, the way the app does, and keep a picture.
        let frames = messages.compactMap { if case .videoFrame(let frame) = $0 { frame } else { nil } }
        let decoder = try FrameDecoder(config: config)
        let images = try frames.prefix(30).map { try decoder.decode($0) }
        #expect(images.count == 30)
        #expect(images[0].width == config.width && images[0].height == config.height)
        let png = URL(fileURLWithPath: Self.env["VANTAGE_INTEROP_PNG"] ?? NSTemporaryDirectory() + "vantage-windows-interop.png")
        try Self.writePNG(images[29], to: png)
        print("decoded frame written to \(png.path)")

        // A keyframe request is answered by the very next frame, well inside 100 ms of arriving.
        for _ in 0..<3 {
            let asked = ContinuousClock.now
            received.withLock { $0.removeAll() }
            session.send(.requestKeyframe)
            try await Self.eventually {
                received.withLock { $0.contains { if case .videoFrame(let frame) = $0.1 { frame.isKeyframe } else { false } } }
            }
            let (at, _) = try #require(received.withLock { list in list.first { if case .videoFrame(let f) = $0.1 { f.isKeyframe } else { false } } })
            #expect(at - asked < .milliseconds(100), "IDR after \(at - asked)")
        }

        if let text = Self.env["VANTAGE_INTEROP_CLIPBOARD_TEXT"] {
            try await Self.eventually { clipboard.withLock { $0 } != nil }
            #expect(clipboard.withLock { $0?.text } == text)
        }
    }

    @Test func pongEchoesTheExactNanosAndInputReachesTheHost() async throws {
        let identity = try await Self.pairedIdentity()
        let (channel, result) = try await Self.handshake(identity)
        #expect(result?.status == .ok)
        try await channel.send(.selectDisplay(SelectDisplay(selection: .fitViewport(Self.viewport), targetFPS: 60, quality: .auto, preferredCodec: .hevc)))
        let nanos: UInt64 = (1 << 63) + 9_007_199_254_740_993
        try await channel.send(.ping(Ping(sentAtNanos: nanos)))
        let pong = try await Self.next(channel) { if case .pong(let pong) = $0 { pong } else { nil } }
        #expect(pong.echoNanos == nanos)

        let marker = "interop-\(UUID().uuidString.prefix(6))"
        try await channel.send(.pointerEvent(PointerEvent(action: .down, button: .left, x: 400, y: 250)))
        try await channel.send(.pointerEvent(PointerEvent(action: .up, button: .left, x: 400, y: 250)))
        try await channel.send(.keyEvent(KeyEvent(keyCode: 0x31, isDown: true, modifiers: [.command])))
        try await channel.send(.keyEvent(KeyEvent(keyCode: 0x31, isDown: false, modifiers: [.command])))
        try await channel.send(.textInput(TextInput(text: marker)))
        try await channel.send(.clipboard(ClipboardPayload(text: marker + "-clip")))
        try await channel.send(.ping(Ping(sentAtNanos: 1)))
        _ = try await Self.next(channel) { if case .pong(let pong) = $0, pong.echoNanos == 1 { pong } else { nil } }

        guard let path = Self.env["VANTAGE_INTEROP_INPUT_LOG"] else { return }
        try await Self.eventually { ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").contains(marker + "-clip") }
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n")
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let tail = Array(lines.suffix(8))
        let chord = try #require(tail.first { $0["type"] as? String == "key" && $0["down"] as? Bool == true })
        #expect(chord["windows"] as? [String] == ["key E0 5B down", "key 39 down"], "⌘Space arrives as Win+Space")
        let click = try #require(tail.first { $0["type"] as? String == "pointer" && $0["action"] as? String == "down" })
        #expect((click["windows"] as? [String])?.last == "Left down 800,500", "points map to pixels")
        #expect(tail.contains { $0["type"] as? String == "text" && $0["text"] as? String == marker })
        #expect(tail.contains { $0["type"] as? String == "clipboard" && $0["text"] as? String == marker + "-clip" })
        await channel.close()
    }

    @Test func sleepingDisplayIsReportedAndWakeBringsThePictureBack() async throws {
        let identity = try await Self.pairedIdentity()
        let session = ClientSession(identity: identity, files: FileTransferController(receiveDirectory: Self.scratch("sleep")))
        defer { session.disconnect() }
        let keyframes = Mutex(0)
        session.onVideo = { message in if case .videoFrame(let frame) = message, frame.isKeyframe { keyframes.withLock { $0 += 1 } } }
        session.connect(to: SavedDevice(name: "Interop PC", host: Self.host, port: Self.port), viewport: Self.viewport)
        try await Self.eventually { session.state == .connected && keyframes.withLock { $0 } > 0 }
        #expect(session.hostStatus?.isDisplayAsleep == false)

        session.send(.hostCommand(HostCommandMessage(command: .sleepDisplay)))
        try await Self.eventually { session.isDisplayAsleep }
        #expect(!session.isScreenUnavailable)
        let before = keyframes.withLock { $0 }
        session.wakeDisplay()
        try await Self.eventually { session.hostStatus?.isDisplayAsleep == false && keyframes.withLock { $0 } > before }
    }

    // MARK: File channel

    @Test func attachTokensWorkOnceAndOnlyFromTheSameAddress() async throws {
        guard Self.host == "127.0.0.1" else { return } // needs the host on this Mac, reachable as both 127.0.0.1 and ::1
        let identity = try await Self.pairedIdentity()
        let (primary, result) = try await Self.handshake(identity)
        let token = try #require(result?.sessionToken)
        #expect(try await Self.attach(token, host: "::1") == nil, "issued to 127.0.0.1, presented from ::1")
        #expect(try await Self.attach(token, host: "127.0.0.1") == nil, "and the miss used it up")
        await primary.close()

        let (again, second) = try await Self.handshake(identity)
        let fresh = try #require(second?.sessionToken)
        let channel = try #require(try await Self.attach(fresh, host: "127.0.0.1"))
        #expect(try await Self.attach(fresh, host: "127.0.0.1") == nil, "a token works once")
        await channel.close()
        await again.close()
    }

    @Test func aFileToTheHostResumesAfterTheChannelIsCut() async throws {
        let identity = try await Self.pairedIdentity()
        let bytes = Int(Self.env["VANTAGE_INTEROP_FILE_BYTES"] ?? "") ?? 64 << 20
        let folder = Self.scratch("upload")
        let source = folder.appending(path: "Interop \(UUID().uuidString.prefix(6)).bin")
        try Self.writeRandom(source, bytes: bytes)
        let id = UUID()

        // First try: cut the channel a third of the way in.
        let (primary, result) = try await Self.handshake(identity, filesOnly: true)
        let token = try #require(result?.sessionToken)
        let channel = try #require(try await Self.attach(token, host: Self.host))
        let engine = FileTransferEngine(channel: channel, role: .client, configuration: .init(receiveDirectory: folder))
        let run = Task { await engine.run() }
        let cut = Task {
            for await event in engine.events {
                if case .progress(_, let done) = event, done > UInt64(bytes / 3) { await channel.close(); return done }
            }
            return 0
        }
        let first = await engine.send(fileAt: source, id: id)
        #expect(!first.isSuccess, "cut off: \(first)")
        let cutAt = await cut.value
        await run.value
        await primary.close()

        // Second try, new connection, same id: the host resumes from what it kept.
        let (primary2, result2) = try await Self.handshake(identity, filesOnly: true)
        let token2 = try #require(result2?.sessionToken)
        let channel2 = try #require(try await Self.attach(token2, host: Self.host))
        let engine2 = FileTransferEngine(channel: channel2, role: .client, configuration: .init(receiveDirectory: folder))
        let run2 = Task { await engine2.run() }
        let resumedAt = Task {
            for await event in engine2.events { if case .progress(_, let done) = event { return done } }
            return 0
        }
        let started = ContinuousClock.now
        let second = await engine2.send(fileAt: source, id: id)
        #expect(second.isSuccess, "\(second)")
        let offset = await resumedAt.value
        #expect(offset > 0 && offset <= cutAt, "resumed at \(offset) (cut at \(cutAt))")
        print("sent \(bytes) bytes to the host, resumed at \(offset), second leg took \(ContinuousClock.now - started)")
        await engine2.close()
        await run2.value
        await primary2.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VANTAGE_INTEROP_FILES_HOST"] != nil
                   && ProcessInfo.processInfo.environment["VANTAGE_INTEROP_SEND_FILE"] != nil))
    func aFileFromTheHostResumesAfterTheChannelIsCut() async throws {
        let filesHost = try #require(Self.env["VANTAGE_INTEROP_FILES_HOST"])
        let sendFile = URL(fileURLWithPath: try #require(Self.env["VANTAGE_INTEROP_SEND_FILE"]))
        let host = String(filesHost.split(separator: ":")[0]), port = UInt16(filesHost.split(separator: ":")[1])!
        let identity = try await Self.pairedIdentity(host: host, port: port)
        let folder = Self.scratch("download")
        let size = try #require(try sendFile.resourceValues(forKeys: [.fileSizeKey]).fileSize)

        let (primary, result) = try await Self.handshake(identity, filesOnly: true, host: host, port: port)
        let token = try #require(result?.sessionToken)
        let channel = try #require(try await Self.attach(token, host: host, port: port))
        let engine = FileTransferEngine(channel: channel, role: .client, configuration: .init(receiveDirectory: folder))
        let run = Task { await engine.run() }
        var cutAt: UInt64 = 0
        for await event in engine.events {
            if case .progress(_, let done) = event, done > UInt64(size / 3) {
                cutAt = done
                await channel.close()
                break
            }
        }
        await run.value
        await primary.close()
        #expect(cutAt > 0)

        let (primary2, result2) = try await Self.handshake(identity, filesOnly: true, host: host, port: port)
        let token2 = try #require(result2?.sessionToken)
        let channel2 = try #require(try await Self.attach(token2, host: host, port: port))
        let engine2 = FileTransferEngine(channel: channel2, role: .client, configuration: .init(receiveDirectory: folder))
        let run2 = Task { await engine2.run() }
        var firstProgress: UInt64?
        var saved: URL?
        for await event in engine2.events {
            switch event {
            case .progress(_, let done) where firstProgress == nil: firstProgress = done
            case .finished(_, .received(let url)): saved = url
            case .finished(_, let outcome): Issue.record("\(outcome)")
            default: break
            }
            if saved != nil { break }
        }
        #expect((firstProgress ?? 0) > 0, "the host re-offered it under the same id and it resumed at \(firstProgress ?? 0)")
        let savedURL = try #require(saved)
        #expect(try Self.sha256(savedURL) == Self.sha256(sendFile), "the resumed file is whole")
        print("received \(size) bytes from the host, resumed at \(firstProgress ?? 0)")
        await engine2.close()
        await run2.value
        await primary2.close()
    }

    // MARK: Helpers

    static func scratch(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "vantage-interop/\(name)-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func eventually(timeout: Duration = .seconds(20), _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while try !condition() {
            guard ContinuousClock.now < deadline else { throw InteropFailure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func open(host: String = host, port: UInt16 = port, bulk: Bool = false) async throws -> MessageChannel {
        let parameters = bulk ? VantageNetwork.bulkParameters() : VantageNetwork.tcpParameters()
        let channel = MessageChannel(connection: NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters),
                                     maxBufferedMessages: 64)
        try await channel.start()
        return channel
    }

    static func sign(_ identity: DeviceIdentity, _ challenge: Challenge) throws -> Data {
        try identity.sign(AuthTranscript.bytes(nonce: challenge.nonce, hostPublicKey: challenge.hostPublicKey, clientPublicKey: identity.publicKeyData))
    }

    /// Hello → challenge → authenticate (with the code if unpaired) → the result, on a raw channel.
    static func handshake(_ identity: DeviceIdentity, code: String? = nil, filesOnly: Bool = false,
                          host: String = host, port: UInt16 = port) async throws -> (MessageChannel, AuthResult?) {
        let channel = try await open(host: host, port: port)
        try await channel.send(.hello(Hello(clientName: "Interop", deviceModel: "test", appVersion: "1.0", clientPublicKey: identity.publicKeyData,
                                            supportedCodecs: filesOnly ? [] : [.hevc, .h264], maxDecodeWidth: filesOnly ? 0 : 4096,
                                            maxDecodeHeight: filesOnly ? 0 : 2304, viewport: filesOnly ? nil : viewport,
                                            features: ClientFeatures(fileTransfer: true, filesOnly: filesOnly ? true : nil))))
        guard case .challenge(let challenge)? = try await channel.receive() else { return (channel, nil) }
        try await channel.send(.authenticate(Authenticate(signature: try sign(identity, challenge), pairingCode: challenge.isPaired ? nil : (code ?? Self.code))))
        guard case .authResult(let result)? = try await channel.receive() else { return (channel, nil) }
        return (channel, result)
    }

    /// A file channel for `token`, or nil when the host hangs up on it (a refused attach is closed
    /// at once; an accepted one stays open, and its messages are left for the engine).
    static func attach(_ token: Data, host: String, port: UInt16 = port) async throws -> MessageChannel? {
        let channel = try await open(host: host, port: port, bulk: true)
        try await channel.send(.attachMedia(AttachMedia(sessionToken: token)))
        try await Task.sleep(for: .milliseconds(400))
        return await channel.isClosed ? nil : channel
    }

    static func next<T>(_ channel: MessageChannel, _ match: (Message) -> T?) async throws -> T {
        while let message = try await channel.receive() {
            if let value = match(message) { return value }
        }
        throw InteropFailure.closed
    }

    /// The host shows its fixed code again a few seconds after a pairing uses it or misses burn it.
    static func waitForCode() async throws {
        try await Task.sleep(for: .seconds(rearm + 0.5))
    }

    /// An identity the host trusts, kept in the temp folder per host so later runs skip pairing.
    static func pairedIdentity(host: String = host, port: UInt16 = port) async throws -> DeviceIdentity {
        let file = FileManager.default.temporaryDirectory.appending(path: "vantage-interop-identity-\(host)-\(port).key")
        let identity = (try? Data(contentsOf: file)).flatMap { try? DeviceIdentity(rawRepresentation: $0) } ?? DeviceIdentity()
        try identity.rawRepresentation.write(to: file)
        for _ in 0..<5 {
            let (channel, result) = try await handshake(identity, host: host, port: port)
            await channel.close()
            if result?.status == .ok { return identity }
            try await waitForCode() // the code was just used or burned; it comes back
        }
        throw InteropFailure.couldNotPair
    }

    static func writeRandom(_ url: URL, bytes: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var remaining = bytes
        while remaining > 0 {
            let count = min(remaining, 8 << 20)
            var chunk = Data(count: count)
            chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
            try handle.write(contentsOf: chunk)
            remaining -= count
        }
    }

    static func sha256(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 << 20), !data.isEmpty { hasher.update(data: data) }
        return Data(hasher.finalize())
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw InteropFailure.png }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw InteropFailure.png }
    }
}

enum InteropFailure: Error { case timedOut, closed, couldNotPair, png, decode(OSStatus) }

private final class DecodedOutput: Sendable {
    let value = Mutex<(OSStatus, CGImage?)>((noErr, nil))
}

/// Decodes `videoFrame`s the way `VideoStreamController` builds its samples: a format description
/// from the `videoConfig` parameter sets, 4-byte AVCC lengths, one sample per frame.
final class FrameDecoder {
    private let format: CMVideoFormatDescription
    private let session: VTDecompressionSession

    init(config: VideoConfig) throws {
        var format: CMVideoFormatDescription?
        let sets = config.parameterSets
        let status = sets[0].withUnsafeBytes { sps in
            sets[1].withUnsafeBytes { pps in
                let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                                                                           parameterSetSizes: sizes, nalUnitHeaderLength: Int32(config.nalLengthSize),
                                                                           formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw InteropFailure.decode(status) }
        self.format = format
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                   imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session)
        guard created == noErr, let session else { throw InteropFailure.decode(created) }
        self.session = session
    }

    deinit { VTDecompressionSessionInvalidate(session) }

    func decode(_ frame: VideoFrame) throws -> CGImage {
        var block: CMBlockBuffer?
        let bytes = [UInt8](frame.data)
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw InteropFailure.decode(status) }
        status = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        guard status == noErr else { throw InteropFailure.decode(status) }
        var sample: CMSampleBuffer?
        var size = bytes.count
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                           sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw InteropFailure.decode(status) }
        let output = DecodedOutput()
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { result, _, buffer, _, _ in
            var image: CGImage?
            if let buffer { VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) }
            output.value.withLock { $0 = (result, image) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        let (decodeStatus, image) = output.value.withLock { $0 }
        guard status == noErr, decodeStatus == noErr, let image else { throw InteropFailure.decode(status != noErr ? status : decodeStatus) }
        return image
    }
}

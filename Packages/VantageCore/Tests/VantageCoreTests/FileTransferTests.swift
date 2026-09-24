import CryptoKit
import Foundation
import Network
import Testing
@testable import VantageCore

// MARK: Messages

@Test func fileControlMessagesRoundTrip() throws {
    let id = UUID()
    let modified = Date(timeIntervalSince1970: 1_790_000_000)
    let messages: [(Message, MessageKind, UInt8)] = [
        (.fileOffer(FileOffer(id: id, name: "Report.pdf", byteCount: 3 << 20, modified: modified, uti: "com.adobe.pdf")), .fileOffer, 80),
        (.fileAccept(FileAccept(id: id, resumeOffset: 0)), .fileAccept, 81),
        (.fileAccept(.rejected(id, reason: "Too big")), .fileAccept, 81),
        (.fileComplete(FileComplete(id: id, sha256: Data(SHA256.hash(data: Data("x".utf8))))), .fileComplete, 82),
        (.fileResult(FileResult(id: id, ok: true, savedName: "Report 2.pdf")), .fileResult, 83),
        (.fileResult(FileResult(id: id, ok: false, error: "Damaged")), .fileResult, 83),
        (.fileCancel(FileCancel(id: id)), .fileCancel, 84),
    ]
    for (message, kind, raw) in messages {
        let frame = try message.encodedFrame()
        let header = try Frame.Header.decode(frame.prefix(Frame.headerLength))
        #expect(header.kind == kind)
        #expect(kind.rawValue == raw)
        #expect(!kind.isBinary)
        let back = try Message.decode(kind: header.kind, payload: frame.dropFirst(Frame.headerLength))
        switch (message, back) {
        case (.fileOffer(let a), .fileOffer(let b)): #expect(a == b)
        case (.fileAccept(let a), .fileAccept(let b)): #expect(a == b)
        case (.fileComplete(let a), .fileComplete(let b)): #expect(a == b)
        case (.fileResult(let a), .fileResult(let b)): #expect(a == b)
        case (.fileCancel(let a), .fileCancel(let b)): #expect(a == b)
        default: Issue.record("\(kind) decoded as \(back.kind)")
        }
    }
    // Accepts leave `rejected` out entirely, so the wire stays small and readable.
    let accept = String(decoding: try Message.fileAccept(FileAccept(id: id)).encodedPayload(), as: UTF8.self)
    #expect(!accept.contains("rejected"))
    #expect(accept.contains(#""resumeOffset":0"#))
}

@Test func fileChunkLayoutIsFixedLittleEndian() throws {
    let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
    let bytes = Data((0..<300).map { UInt8($0 & 0xFF) })
    let chunk = FileChunk(id: id, offset: 0x0102_0304_0506_0708, data: bytes)
    for (message, kind, raw) in [(Message.fileChunkToClient(chunk), MessageKind.fileChunkToClient, UInt8(103)),
                                 (.fileChunkToHost(chunk), .fileChunkToHost, 124)] {
        let payload = try message.encodedPayload()
        #expect(kind.rawValue == raw)
        #expect(kind.isBinary)
        #expect(message.kind == kind)
        #expect(payload.count == FileChunk.headerLength + bytes.count)
        #expect(Array(payload.prefix(16)) == [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        #expect(Array(payload[16..<24]) == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        #expect(payload.suffix(bytes.count) == bytes)
        let back = try Message.decode(kind: kind, payload: payload)
        switch back {
        case .fileChunkToClient(let b), .fileChunkToHost(let b): #expect(b == chunk)
        default: Issue.record("wrong kind")
        }
    }
    #expect(throws: BinaryDecodingError.self) { try Message.decode(kind: .fileChunkToHost, payload: Data(count: 20)) }
    #expect(FileChunk.standardSize + FileChunk.headerLength < Int(Frame.maxPayloadLength))
}

@Test func capabilitiesAndFeaturesStayOptional() throws {
    // An older host's capabilities and an older client's features decode with the new field nil.
    let old = #"{"codecs":["hevc"],"canManageVirtualDisplay":false,"clipboard":true,"maxFPS":60}"#
    let caps = try JSONDecoder().decode(HostCapabilities.self, from: Data(old.utf8))
    #expect(caps.fileTransfer == nil)
    let features = try JSONDecoder().decode(ClientFeatures.self, from: Data(#"{"dictation":true}"#.utf8))
    #expect(features.fileTransfer == nil)
    let now = try JSONDecoder().decode(ClientFeatures.self, from: JSONEncoder().encode(ClientFeatures(fileTransfer: true)))
    #expect(now.fileTransfer == true)
}

// MARK: Names

@Test(arguments: [
    ("Report.pdf", "Report.pdf"),
    ("../../.ssh/authorized_keys", "authorized_keys"),
    ("..\\..\\Windows\\evil.exe", "evil.exe"),
    ("/etc/passwd", "passwd"),
    ("dir/", "dir"),
    (".hidden", "hidden"),
    ("...", FileNames.fallback),
    ("", FileNames.fallback),
    ("   ", FileNames.fallback),
    ("a:b.txt", "a-b.txt"),
    ("tab\there\n.txt", "tabhere.txt"),
    ("invoice\u{202E}fdp.app", "invoicefdp.app"),
    ("zero\u{200B}width.txt", "zerowidth.txt"),
    ("Cafe\u{0301}.txt", "Caf\u{00E9}.txt"),
    ("trailing dot. ", "trailing dot"),
    ("Résumé 🎉.key", "Résumé 🎉.key"),
])
func sanitizesUntrustedNames(input: String, expected: String) {
    #expect(FileNames.sanitize(input) == expected)
}

@Test func longNamesKeepTheirExtension() {
    let long = String(repeating: "é", count: 300) + ".pdf"
    let name = FileNames.sanitize(long)
    #expect(name.utf8.count <= FileNames.maxLength)
    #expect(name.hasSuffix(".pdf"))
    #expect(name.hasPrefix("éé"))
    let noExtension = FileNames.sanitize(String(repeating: "x", count: 400))
    #expect(noExtension.utf8.count == FileNames.maxLength)
}

@Test func uniqueNamesFollowFinder() throws {
    #expect(FileNames.candidate("Report.pdf", number: 1) == "Report.pdf")
    #expect(FileNames.candidate("Report.pdf", number: 2) == "Report 2.pdf")
    #expect(FileNames.candidate("Makefile", number: 3) == "Makefile 3")
    #expect(FileNames.candidate("archive.tar.gz", number: 2) == "archive.tar 2.gz")
    let directory = FileManager.default.temporaryDirectory.appending(path: "names-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(FileNames.uniqueURL(for: "Report.pdf", in: directory).lastPathComponent == "Report.pdf")
    try Data().write(to: directory.appending(path: "Report.pdf"))
    try Data().write(to: directory.appending(path: "Report 2.pdf"))
    #expect(FileNames.uniqueURL(for: "Report.pdf", in: directory).lastPathComponent == "Report 3.pdf")
}

// MARK: Attach tokens

private final class Owner: Sendable {}

@Test func attachTokensAreSingleUsePeerBoundAndExpire() {
    let registry = AttachTokenRegistry<Owner>(lifetime: .seconds(60))
    let a = Owner(), b = Owner()
    let tokenA = registry.issue(for: a, peer: "100.64.0.5")
    let tokenB = registry.issue(for: b, peer: "100.64.0.6")
    #expect(tokenA.count == 32)
    #expect(tokenA != tokenB)

    #expect(registry.claim(Data(count: 32), peer: "100.64.0.5") == nil)
    #expect(registry.claim(tokenA.prefix(31), peer: "100.64.0.5") == nil)
    #expect(registry.claim(tokenA, peer: "100.64.0.5") === a)
    #expect(registry.claim(tokenA, peer: "100.64.0.5") == nil, "single use")

    // The right token from the wrong address is refused, and burns the token.
    #expect(registry.claim(tokenB, peer: "100.64.0.99") == nil)
    #expect(registry.claim(tokenB, peer: "100.64.0.6") == nil)

    // A new token replaces the owner's old one; revoke drops it.
    let old = registry.issue(for: a, peer: "100.64.0.5")
    let new = registry.issue(for: a, peer: "100.64.0.5")
    #expect(registry.count == 1)
    #expect(registry.claim(old, peer: "100.64.0.5") == nil)
    registry.revoke(owner: a)
    #expect(registry.claim(new, peer: "100.64.0.5") == nil)

    // Expiry.
    let start = ContinuousClock.now
    let late = registry.issue(for: b, peer: "p", now: start)
    #expect(registry.claim(late, peer: "p", now: start + .seconds(61)) == nil)
    #expect(registry.count == 0)

    #expect(AttachTokenRegistry<Owner>.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
    #expect(!AttachTokenRegistry<Owner>.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
    #expect(!AttachTokenRegistry<Owner>.constantTimeEquals(Data([1, 2]), Data([1, 2, 3])))
}

// MARK: Engine over loopback

/// A connected pair of channels on loopback.
private func channelPair(serverBuffer: Int? = 16) async throws -> (client: MessageChannel, server: MessageChannel, listener: NWListener) {
    let listener = try NWListener(using: VantageNetwork.tcpParameters(), on: .any)
    let accepted = AsyncStream<MessageChannel> { continuation in
        listener.newConnectionHandler = { connection in
            continuation.yield(MessageChannel(connection: connection, label: "test.files.server", maxBufferedMessages: serverBuffer))
            continuation.finish()
        }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        listener.stateUpdateHandler = { state in
            if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume() }
            else if case .failed(let error) = state { listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
        }
        listener.start(queue: .global())
    }
    let client = MessageChannel(connection: NWConnection(host: .ipv4(.loopback), port: listener.port!, using: VantageNetwork.bulkParameters()),
                                label: "test.files.client", maxBufferedMessages: 16)
    try await client.start()
    var iterator = accepted.makeAsyncIterator()
    let server = try #require(await iterator.next())
    try await server.start()
    return (client, server, listener)
}

private func temporaryDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "vantage-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func randomFile(bytes: Int, in directory: URL, name: String) throws -> URL {
    var generator = SystemRandomNumberGenerator()
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { raw in
        for index in stride(from: 0, to: bytes - 7, by: 8) {
            raw.storeBytes(of: generator.next() as UInt64, toByteOffset: index, as: UInt64.self)
        }
    }
    let url = directory.appending(path: name)
    try data.write(to: url)
    return url
}

@Suite(.timeLimit(.minutes(1)))
struct FileTransferEngineTests {
    @Test func sendsBothWaysWithMatchingBytes() async throws {
        let (clientChannel, serverChannel, listener) = try await channelPair()
        defer { listener.cancel() }
        let clientDir = try temporaryDirectory("client"), hostDir = try temporaryDirectory("host")
        defer { try? FileManager.default.removeItem(at: clientDir); try? FileManager.default.removeItem(at: hostDir) }
        let savedHook = SavedList()
        let client = FileTransferEngine(channel: clientChannel, role: .client, configuration: .init(receiveDirectory: clientDir))
        let host = FileTransferEngine(channel: serverChannel, role: .host,
                                      configuration: .init(receiveDirectory: hostDir, afterSave: { url, _ in savedHook.append(url) }))
        let runs = [Task { await client.run() }, Task { await host.run() }]

        let source = try randomFile(bytes: 3 << 20 | 12_345, in: clientDir, name: "Upload.bin")
        // A file already there: the new one becomes "Upload 2.bin".
        try Data("old".utf8).write(to: hostDir.appending(path: "Upload.bin"))
        let started = ContinuousClock.now
        let up = await client.send(fileAt: source)
        let elapsed = ContinuousClock.now - started
        #expect(up == .sent(savedName: "Upload 2.bin"))
        let arrived = hostDir.appending(path: "Upload 2.bin")
        #expect(try Data(contentsOf: arrived) == Data(contentsOf: source))
        #expect(savedHook.urls.map(\.lastPathComponent) == ["Upload 2.bin"])
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("loopback upload: \(String(format: "%.1f", Double(3 << 20 | 12_345) / seconds / 1_048_576)) MiB/s")

        // And straight back, under a new name, plus an empty file.
        let down = await host.send(fileAt: arrived, name: "Returned.bin")
        guard case .sent("Returned.bin") = down else { Issue.record("\(down)"); return }
        #expect(try Data(contentsOf: clientDir.appending(path: "Returned.bin")) == Data(contentsOf: source))
        let empty = hostDir.appending(path: "Empty.txt")
        try Data().write(to: empty)
        #expect(await host.send(fileAt: empty) == .sent(savedName: "Empty.txt"))
        #expect(try Data(contentsOf: clientDir.appending(path: "Empty.txt")).isEmpty)

        // No partial files left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: hostDir.path).filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)
        await client.close()
        for run in runs { await run.value }
    }

    @Test func eventsDescribeEachTransfer() async throws {
        let (clientChannel, serverChannel, listener) = try await channelPair()
        defer { listener.cancel() }
        let clientDir = try temporaryDirectory("client"), hostDir = try temporaryDirectory("host")
        defer { try? FileManager.default.removeItem(at: clientDir); try? FileManager.default.removeItem(at: hostDir) }
        let client = FileTransferEngine(channel: clientChannel, role: .client, configuration: .init(receiveDirectory: clientDir, chunkSize: 64 << 10, progressInterval: .zero))
        let host = FileTransferEngine(channel: serverChannel, role: .host, configuration: .init(receiveDirectory: hostDir, progressInterval: .zero))
        let runs = [Task { await client.run() }, Task { await host.run() }]
        let collected = Task { () -> [FileTransferEvent] in
            var all: [FileTransferEvent] = []
            for await event in host.events { all.append(event) }
            return all
        }
        let source = try randomFile(bytes: 1 << 20, in: clientDir, name: "Plain.bin")
        let id = UUID()
        // The sender claims a path outside the folder; the receiver keeps only the last part.
        let outcome = await client.send(fileAt: source, name: "../../Sneaky.bin", id: id)
        #expect(outcome == .sent(savedName: "Sneaky.bin"))
        await client.close()
        for run in runs { await run.value }
        let events = await collected.value
        #expect(events.first == .started(FileTransferItem(id: id, name: "Sneaky.bin", byteCount: 1 << 20, direction: .receiving)))
        let progress = events.compactMap { if case .progress(_, let bytes) = $0 { bytes } else { nil } }
        #expect(progress.count >= 2)
        #expect(progress == progress.sorted())
        #expect(progress.last == 1 << 20)
        #expect(events.last == .finished(id: id, .received(hostDir.appending(path: "Sneaky.bin"))))
    }

    @Test func oversizedOfferIsRejected() async throws {
        let (clientChannel, serverChannel, listener) = try await channelPair()
        defer { listener.cancel() }
        let clientDir = try temporaryDirectory("client"), hostDir = try temporaryDirectory("host")
        defer { try? FileManager.default.removeItem(at: clientDir); try? FileManager.default.removeItem(at: hostDir) }
        let client = FileTransferEngine(channel: clientChannel, role: .client, configuration: .init(receiveDirectory: clientDir))
        let host = FileTransferEngine(channel: serverChannel, role: .host, configuration: .init(receiveDirectory: hostDir, maxIncomingBytes: 1 << 20))
        let runs = [Task { await client.run() }, Task { await host.run() }]
        let big = try randomFile(bytes: 2 << 20, in: clientDir, name: "Big.bin")
        let outcome = await client.send(fileAt: big)
        guard case .failed(let reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.contains("too large"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: hostDir.path).isEmpty)
        // The channel is still good for the next file.
        let small = try randomFile(bytes: 1_000, in: clientDir, name: "Small.bin")
        #expect(await client.send(fileAt: small) == .sent(savedName: "Small.bin"))
        await client.close()
        for run in runs { await run.value }
    }

    /// A sender with the wrong checksum gets `fileResult.ok == false`, and nothing is saved.
    @Test func badChecksumIsRefused() async throws {
        let (clientChannel, serverChannel, listener) = try await channelPair()
        defer { listener.cancel() }
        let hostDir = try temporaryDirectory("host")
        defer { try? FileManager.default.removeItem(at: hostDir) }
        let host = FileTransferEngine(channel: serverChannel, role: .host, configuration: .init(receiveDirectory: hostDir))
        let run = Task { await host.run() }
        let id = UUID()
        let bytes = Data(repeating: 7, count: 300_000)
        try await clientChannel.send(.fileOffer(FileOffer(id: id, name: "Tampered.bin", byteCount: UInt64(bytes.count))))
        guard case .fileAccept(let accept)? = try await clientChannel.receive() else { Issue.record("no accept"); return }
        #expect(accept.id == id && accept.rejected == nil && accept.resumeOffset == 0)
        try await clientChannel.send(.fileChunkToHost(FileChunk(id: id, offset: 0, data: bytes.prefix(200_000))))
        try await clientChannel.send(.fileChunkToHost(FileChunk(id: id, offset: 200_000, data: bytes.suffix(100_000))))
        try await clientChannel.send(.fileComplete(FileComplete(id: id, sha256: Data(SHA256.hash(data: Data("not it".utf8))))))
        guard case .fileResult(let result)? = try await clientChannel.receive() else { Issue.record("no result"); return }
        #expect(result.id == id && !result.ok)
        #expect(result.error?.contains("damaged") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: hostDir.path).isEmpty)

        // A chunk at the wrong offset fails the transfer too.
        let second = UUID()
        try await clientChannel.send(.fileOffer(FileOffer(id: second, name: "Gap.bin", byteCount: 10)))
        guard case .fileAccept? = try await clientChannel.receive() else { Issue.record("no accept"); return }
        try await clientChannel.send(.fileChunkToHost(FileChunk(id: second, offset: 4, data: Data(count: 6))))
        guard case .fileResult(let gap)? = try await clientChannel.receive() else { Issue.record("no result"); return }
        #expect(gap.id == second && !gap.ok)

        // A chunk going the wrong way is a protocol violation: the host drops the channel.
        try await clientChannel.send(.fileChunkToClient(FileChunk(id: second, offset: 0, data: Data(count: 1))))
        await run.value
        #expect(try await clientChannel.receive() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: hostDir.path).isEmpty)
    }

    @Test func receiverCancelStopsTheSender() async throws {
        let (clientChannel, serverChannel, listener) = try await channelPair()
        defer { listener.cancel() }
        let clientDir = try temporaryDirectory("client")
        defer { try? FileManager.default.removeItem(at: clientDir) }
        let client = FileTransferEngine(channel: clientChannel, role: .client, configuration: .init(receiveDirectory: clientDir))
        let run = Task { await client.run() }
        let source = try randomFile(bytes: 8 << 20, in: clientDir, name: "Long.bin")
        let sending = Task { await client.send(fileAt: source) }
        // Play the Mac: accept, take one chunk, then cancel.
        guard case .fileOffer(let offer)? = try await serverChannel.receive() else { Issue.record("no offer"); return }
        try await serverChannel.send(.fileAccept(FileAccept(id: offer.id)))
        guard case .fileChunkToHost(let first)? = try await serverChannel.receive() else { Issue.record("no chunk"); return }
        #expect(first.offset == 0 && first.data.count == FileChunk.standardSize)
        try await serverChannel.send(.fileCancel(FileCancel(id: offer.id)))
        #expect(await sending.value == .cancelled(byPeer: true))
        await client.close()
        await run.value
    }

    @Test func senderCancelReachesTheReceiver() async throws {
        let (clientChannel, serverChannel, listener) = try await channelPair()
        defer { listener.cancel() }
        let clientDir = try temporaryDirectory("client"), hostDir = try temporaryDirectory("host")
        defer { try? FileManager.default.removeItem(at: clientDir); try? FileManager.default.removeItem(at: hostDir) }
        // Paced so the cancel always lands mid-file (loopback would finish 8 MiB in ~30 ms).
        var paced = FileTransferConfiguration(receiveDirectory: clientDir, progressInterval: .zero)
        paced.chunkDelay = .milliseconds(10)
        let client = FileTransferEngine(channel: clientChannel, role: .client, configuration: paced)
        let host = FileTransferEngine(channel: serverChannel, role: .host, configuration: .init(receiveDirectory: hostDir))
        let runs = [Task { await client.run() }, Task { await host.run() }]
        let hostEvents = Task { () -> [FileTransferEvent] in
            var all: [FileTransferEvent] = []
            for await event in host.events { all.append(event) }
            return all
        }
        let source = try randomFile(bytes: 8 << 20, in: clientDir, name: "Huge.bin")
        let id = UUID()
        let sending = Task { await client.send(fileAt: source, id: id) }
        var sawProgress = false
        for await event in client.events {
            if case .progress = event { sawProgress = true; break }
        }
        #expect(sawProgress)
        await client.cancel(id)
        #expect(await sending.value == .cancelled(byPeer: false))
        // A queued send cancelled before its turn never starts.
        let queued = UUID()
        await client.cancel(queued)
        #expect(await client.send(fileAt: source, id: queued) == .cancelled(byPeer: false))
        try await Task.sleep(for: .milliseconds(300))
        await client.close()
        for run in runs { await run.value }
        let events = await hostEvents.value
        #expect(events.contains(.finished(id: id, .cancelled(byPeer: true))))
        #expect(try FileManager.default.contentsOfDirectory(atPath: hostDir.path).isEmpty, "the partial file is deleted")
    }

    @Test func queuedSendsGoInOrderAndFailWhenTheChannelDrops() async throws {
        let (clientChannel, serverChannel, listener) = try await channelPair()
        defer { listener.cancel() }
        let clientDir = try temporaryDirectory("client"), hostDir = try temporaryDirectory("host")
        defer { try? FileManager.default.removeItem(at: clientDir); try? FileManager.default.removeItem(at: hostDir) }
        let client = FileTransferEngine(channel: clientChannel, role: .client, configuration: .init(receiveDirectory: clientDir))
        let host = FileTransferEngine(channel: serverChannel, role: .host, configuration: .init(receiveDirectory: hostDir))
        let runs = [Task { await client.run() }, Task { await host.run() }]
        let files = try (1...3).map { try randomFile(bytes: 400_000, in: clientDir, name: "File \($0).bin") }
        let outcomes = await withTaskGroup(of: (Int, FileTransferOutcome).self) { group in
            for (index, file) in files.enumerated() {
                group.addTask { (index, await client.send(fileAt: file)) }
                try? await Task.sleep(for: .milliseconds(5)) // queue in this order
            }
            var results: [Int: FileTransferOutcome] = [:]
            for await (index, outcome) in group { results[index] = outcome }
            return results
        }
        #expect(outcomes[0] == .sent(savedName: "File 1.bin"))
        #expect(outcomes[1] == .sent(savedName: "File 2.bin"))
        #expect(outcomes[2] == .sent(savedName: "File 3.bin"))

        await serverChannel.close()
        for run in runs { await run.value }
        guard case .failed = await client.send(fileAt: files[0]) else { Issue.record("should fail once closed"); return }
    }

    // MARK: Resume

    /// Upload (iPad → Mac) and download (Mac → iPad): the connection drops mid-file, the partial
    /// stays, and the same id on a new connection carries on from it and ends byte-identical.
    @Test(arguments: [FileTransferRole.client, .host])
    func interruptedFileResumesOnANewConnection(sender: FileTransferRole) async throws {
        let senderDir = try temporaryDirectory("sender"), receiverDir = try temporaryDirectory("receiver")
        defer { try? FileManager.default.removeItem(at: senderDir); try? FileManager.default.removeItem(at: receiverDir) }
        let receiver: FileTransferRole = sender == .client ? .host : .client
        let size = 6 << 20 | 4_321
        let source = try randomFile(bytes: size, in: senderDir, name: "Photos.zip")
        let id = UUID()

        // First connection: paced, and dropped once a couple of MiB have arrived.
        do {
            let (a, b, listener) = try await channelPair()
            defer { listener.cancel() }
            var paced = FileTransferConfiguration(receiveDirectory: senderDir, progressInterval: .zero)
            paced.chunkDelay = .milliseconds(15)
            let sending = FileTransferEngine(channel: a, role: sender, configuration: paced)
            let receiving = FileTransferEngine(channel: b, role: receiver, configuration: .init(receiveDirectory: receiverDir, progressInterval: .zero))
            let runs = [Task { await sending.run() }, Task { await receiving.run() }]
            let outcome = Task { await sending.send(fileAt: source, id: id) }
            for await event in receiving.events {
                if case .progress(_, let bytes) = event, bytes >= 2 << 20 { break }
            }
            await b.close() // the receiver's side of the connection goes away
            guard case .failed = await outcome.value else { Issue.record("the first attempt should fail"); return }
            for run in runs { await run.value }
        }
        let partial = receiverDir.appending(path: FileTransferEngine.partialPrefix + id.uuidString + FileTransferEngine.partialSuffix)
        let kept = try #require(try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? UInt64)
        #expect(kept >= 2 << 20 && kept < UInt64(size), "the partial file stays for a resume")

        // Second connection, same id: picks up at the partial's size.
        let (a, b, listener) = try await channelPair()
        defer { listener.cancel() }
        let sending = FileTransferEngine(channel: a, role: sender, configuration: .init(receiveDirectory: senderDir))
        let receiving = FileTransferEngine(channel: b, role: receiver, configuration: .init(receiveDirectory: receiverDir, progressInterval: .zero))
        let runs = [Task { await sending.run() }, Task { await receiving.run() }]
        let received = Task { () -> [FileTransferEvent] in
            var all: [FileTransferEvent] = []
            for await event in receiving.events { all.append(event) }
            return all
        }
        #expect(await sending.send(fileAt: source, id: id) == .sent(savedName: "Photos.zip"))
        #expect(try Data(contentsOf: receiverDir.appending(path: "Photos.zip")) == Data(contentsOf: source))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        await sending.close()
        for run in runs { await run.value }
        let events = await received.value
        #expect(events.first == .started(FileTransferItem(id: id, name: "Photos.zip", byteCount: UInt64(size), direction: .receiving)))
        #expect(events.dropFirst().first == .progress(id: id, bytes: kept), "reports where it resumed")
    }

    /// A partial that no longer matches the sender's file fails the final checksum and is
    /// deleted, never renamed into place; the next attempt starts from zero and succeeds.
    @Test func resumedFileThatDoesntMatchIsRefusedThenSentWhole() async throws {
        let (clientChannel, serverChannel, listener) = try await channelPair()
        defer { listener.cancel() }
        let clientDir = try temporaryDirectory("client"), hostDir = try temporaryDirectory("host")
        defer { try? FileManager.default.removeItem(at: clientDir); try? FileManager.default.removeItem(at: hostDir) }
        let source = try randomFile(bytes: 1 << 20, in: clientDir, name: "Edited.mov")
        let id = UUID()
        // A partial whose bytes differ from the file's first half.
        let partial = hostDir.appending(path: FileTransferEngine.partialPrefix + id.uuidString + FileTransferEngine.partialSuffix)
        try Data(repeating: 0x5A, count: 512 << 10).write(to: partial)
        let client = FileTransferEngine(channel: clientChannel, role: .client, configuration: .init(receiveDirectory: clientDir))
        let host = FileTransferEngine(channel: serverChannel, role: .host, configuration: .init(receiveDirectory: hostDir))
        let runs = [Task { await client.run() }, Task { await host.run() }]
        guard case .failed(let reason) = await client.send(fileAt: source, id: id) else { Issue.record("should fail its checksum"); return }
        #expect(reason.contains("damaged"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: hostDir.path).isEmpty, "nothing renamed into place, partial gone")
        #expect(await client.send(fileAt: source, id: id) == .sent(savedName: "Edited.mov"))
        #expect(try Data(contentsOf: hostDir.appending(path: "Edited.mov")) == Data(contentsOf: source))
        await client.close()
        for run in runs { await run.value }
    }

    /// The sender reconnects before this side notices the old connection died: the new channel
    /// takes the half-written partial over from the old one, and the old one's later shutdown
    /// neither deletes it nor reports it.
    @Test func newChannelTakesOverAPartialFromAStaleOne() async throws {
        let hostDir = try temporaryDirectory("host")
        defer { try? FileManager.default.removeItem(at: hostDir) }
        let bytes = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let id = UUID()
        let chunk = 256 << 10

        let (oldClient, oldServer, oldListener) = try await channelPair()
        defer { oldListener.cancel() }
        let oldHost = FileTransferEngine(channel: oldServer, role: .host, configuration: .init(receiveDirectory: hostDir, progressInterval: .zero))
        let oldRun = Task { await oldHost.run() }
        let oldEvents = Task { () -> [FileTransferEvent] in
            var all: [FileTransferEvent] = []
            for await event in oldHost.events { all.append(event) }
            return all
        }
        try await oldClient.send(.fileOffer(FileOffer(id: id, name: "Scan.pdf", byteCount: UInt64(bytes.count))))
        guard case .fileAccept(let first)? = try await oldClient.receive() else { Issue.record("no accept"); return }
        #expect(first.resumeOffset == 0)
        for offset in stride(from: 0, to: 2 * chunk, by: chunk) {
            try await oldClient.send(.fileChunkToHost(FileChunk(id: id, offset: UInt64(offset), data: bytes[offset..<offset + chunk])))
        }

        let (newClient, newServer, newListener) = try await channelPair()
        defer { newListener.cancel() }
        let newHost = FileTransferEngine(channel: newServer, role: .host, configuration: .init(receiveDirectory: hostDir))
        let newRun = Task { await newHost.run() }
        // Give the old engine a moment to write both chunks.
        try await Task.sleep(for: .milliseconds(200))
        try await newClient.send(.fileOffer(FileOffer(id: id, name: "Scan.pdf", byteCount: UInt64(bytes.count))))
        guard case .fileAccept(let second)? = try await newClient.receive() else { Issue.record("no accept"); return }
        #expect(second.resumeOffset == UInt64(2 * chunk))
        for offset in stride(from: 2 * chunk, to: bytes.count, by: chunk) {
            try await newClient.send(.fileChunkToHost(FileChunk(id: id, offset: UInt64(offset), data: bytes[offset..<offset + chunk])))
        }
        try await newClient.send(.fileComplete(FileComplete(id: id, sha256: Data(SHA256.hash(data: bytes)))))
        guard case .fileResult(let result)? = try await newClient.receive() else { Issue.record("no result"); return }
        #expect(result.ok && result.savedName == "Scan.pdf")
        #expect(try Data(contentsOf: hostDir.appending(path: "Scan.pdf")) == bytes)

        await oldHost.close()
        await oldRun.value
        let events = await oldEvents.value
        #expect(!events.contains { if case .finished = $0 { true } else { false } }, "the old channel no longer owns it")
        await newHost.close()
        await newRun.value
    }

    /// Partials older than `partialLifetime` go when an engine starts; fresh ones stay.
    @Test func stalePartialsAreDeletedAndFreshOnesKept() async throws {
        let (clientChannel, serverChannel, listener) = try await channelPair()
        defer { listener.cancel() }
        let hostDir = try temporaryDirectory("host")
        defer { try? FileManager.default.removeItem(at: hostDir) }
        let stale = hostDir.appending(path: FileTransferEngine.partialPrefix + UUID().uuidString + FileTransferEngine.partialSuffix)
        let fresh = hostDir.appending(path: FileTransferEngine.partialPrefix + UUID().uuidString + FileTransferEngine.partialSuffix)
        try Data(count: 10).write(to: stale)
        try Data(count: 10).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-25 * 3_600)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-23 * 3_600)], ofItemAtPath: fresh.path)
        let host = FileTransferEngine(channel: serverChannel, role: .host, configuration: .init(receiveDirectory: hostDir))
        let run = Task { await host.run() }
        await clientChannel.close()
        await run.value
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    /// Idle until a file is in flight, idle again after.
    @Test func busyWhileAFileMoves() async throws {
        let (clientChannel, serverChannel, listener) = try await channelPair()
        defer { listener.cancel() }
        let clientDir = try temporaryDirectory("client"), hostDir = try temporaryDirectory("host")
        defer { try? FileManager.default.removeItem(at: clientDir); try? FileManager.default.removeItem(at: hostDir) }
        var paced = FileTransferConfiguration(receiveDirectory: clientDir, progressInterval: .zero)
        paced.chunkDelay = .milliseconds(20)
        let client = FileTransferEngine(channel: clientChannel, role: .client, configuration: paced)
        let host = FileTransferEngine(channel: serverChannel, role: .host, configuration: .init(receiveDirectory: hostDir, progressInterval: .zero))
        let runs = [Task { await client.run() }, Task { await host.run() }]
        var busy = (await client.isBusy, await host.isBusy)
        #expect(!busy.0 && !busy.1)
        let source = try randomFile(bytes: 2 << 20, in: clientDir, name: "Busy.bin")
        let sending = Task { await client.send(fileAt: source) }
        for await event in host.events { if case .progress(_, let bytes) = event, bytes > 0 { break } }
        busy = (await client.isBusy, await host.isBusy)
        #expect(busy.0 && busy.1)
        #expect(await sending.value == .sent(savedName: "Busy.bin"))
        busy = (await client.isBusy, await host.isBusy)
        #expect(!busy.0 && !busy.1)
        await client.close()
        for run in runs { await run.value }
    }
}

private final class SavedList: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URL] = []
    func append(_ url: URL) { lock.withLock { list.append(url) } }
    var urls: [URL] { lock.withLock { list } }
}

import CryptoKit
import Darwin
import Foundation
import Network
import Testing
import VantageCore
@testable import VantageClientLogic

// MARK: A loopback host that speaks the file channel

/// What the mock host's primary connection does after `selectDisplay`.
private enum PrimaryBehaviour: Sendable {
    /// Read until the client goes away.
    case stay
    /// Drop the connection once, after the file channel has attached (the client reconnects).
    case dropOnceAfterAttach
}

/// A session owner for the token registry.
private final class MockSession: Sendable {
    let number: Int
    init(number: Int) { self.number = number }
}

/// Stands in for Vantage Host: authenticates, hands out a file channel token (unless it plays an
/// older host), binds the second connection with `AttachTokenRegistry`, and runs a host-role
/// `FileTransferEngine` on it, saving into `directory`. Its file channels never close with their
/// session, like a current Vantage Host; `keepsFiles` says so to the client (and takes files-only
/// sessions), which is what makes the client rely on it.
private final class MockFileHost: @unchecked Sendable {
    let listener: NWListener
    let directory: URL
    let offersFiles: Bool
    let keepsFiles: Bool
    /// Answer files-only sessions with "pairing required", as a Mac that doesn't know this iPad.
    let refusesFilesOnlyUnpaired: Bool
    let maxIncomingBytes: UInt64
    let behaviour: PrimaryBehaviour
    private let registry = AttachTokenRegistry<MockSession>()
    private let lock = NSLock()
    private var engines: [FileTransferEngine] = []
    private var connectionsSeen = 0
    private var attachesRefused = 0
    private var droppedOnce = false
    private var events: [FileTransferEvent] = []
    private var primaries: [MessageChannel] = []
    private var hellos: [Hello] = []
    private var screenMessages: [MessageKind] = []
    private var primariesClosed = 0
    /// Replaces the engine on the next file channel: the test plays the host by hand.
    var rawFileChannel: (@Sendable (MessageChannel) async throws -> Void)?

    var port: UInt16 { listener.port!.rawValue }
    var connectionCount: Int { lock.withLock { connectionsSeen } }
    var refusedAttaches: Int { lock.withLock { attachesRefused } }
    var latestEngine: FileTransferEngine? { lock.withLock { engines.last } }
    var engineCount: Int { lock.withLock { engines.count } }
    var hostEvents: [FileTransferEvent] { lock.withLock { events } }
    var filesOnlyHelloCount: Int { lock.withLock { hellos.filter { $0.features?.filesOnly == true }.count } }
    var screenHelloCount: Int { lock.withLock { hellos.filter { $0.features?.filesOnly != true }.count } }
    /// Kinds a files-only session sent on its primary other than ping (should be none).
    var filesOnlyStrayMessages: [MessageKind] { lock.withLock { screenMessages } }
    var closedPrimaryCount: Int { lock.withLock { primariesClosed } }
    /// Starts of the transfer with this id, as the Mac saw them.
    func starts(of id: UUID) -> Int {
        hostEvents.filter { if case .started(let item) = $0 { item.id == id } else { false } }.count
    }

    init(offersFiles: Bool = true, keepsFiles: Bool = false, refusesFilesOnlyUnpaired: Bool = false,
         maxIncomingBytes: UInt64 = 64 << 30, behaviour: PrimaryBehaviour = .stay) async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "mock-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.offersFiles = offersFiles
        self.keepsFiles = keepsFiles
        self.refusesFilesOnlyUnpaired = refusesFilesOnlyUnpaired
        self.maxIncomingBytes = maxIncomingBytes
        self.behaviour = behaviour
        listener = try NWListener(using: VantageNetwork.tcpParameters(), on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(MessageChannel(connection: connection, label: "mock.host", maxBufferedMessages: 64)) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume() }
                else if case .failed(let error) = state { listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            listener.start(queue: .global())
        }
    }

    func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Cuts every live connection, primary and file channel, as if the network went away.
    func dropEverything() async {
        let (channels, running) = lock.withLock { (primaries, engines) }
        for channel in channels { await channel.close() }
        for engine in running { await engine.close() }
    }

    private func accept(_ channel: MessageChannel) async {
        lock.withLock { connectionsSeen += 1 }
        do {
            try await channel.start()
            guard let first = try await channel.receive() else { return }
            let peer = Self.host(channel.remoteEndpoint)
            switch first {
            case .hello(let hello):
                try await primary(channel, hello: hello, peer: peer)
            case .attachMedia(let attach):
                guard registry.claim(attach.sessionToken, peer: peer) != nil else {
                    lock.withLock { attachesRefused += 1 }
                    await channel.close()
                    return
                }
                if let raw = rawFileChannel {
                    rawFileChannel = nil
                    try await raw(channel)
                    return
                }
                let engine = FileTransferEngine(channel: channel, role: .host,
                                                configuration: .init(receiveDirectory: directory, maxIncomingBytes: maxIncomingBytes))
                lock.withLock { engines.append(engine) }
                Task { for await event in engine.events { self.lock.withLock { self.events.append(event) } } }
                await engine.run()
            default:
                await channel.close()
            }
        } catch {
            await channel.close()
        }
    }

    private func primary(_ channel: MessageChannel, hello: Hello, peer: String) async throws {
        lock.withLock { primaries.append(channel); hellos.append(hello) }
        defer { lock.withLock { primariesClosed += 1 } }
        let identity = DeviceIdentity()
        let nonce = AuthTranscript.randomNonce()
        let filesOnly = hello.features?.filesOnly == true && keepsFiles
        try await channel.send(.challenge(Challenge(hostName: "Mock Mac", hostVersion: "1.0", hostPublicKey: identity.publicKeyData,
                                                    nonce: nonce, isPaired: !(filesOnly && refusesFilesOnlyUnpaired))))
        guard case .authenticate? = try await channel.receive() else { throw ChannelError.closed }
        if filesOnly && refusesFilesOnlyUnpaired {
            try await channel.send(.authResult(AuthResult(status: .pairingRequired)))
            await channel.close()
            return
        }
        let wantsFiles = hello.features?.fileTransfer == true && offersFiles
        let session = MockSession(number: connectionCount)
        let token = wantsFiles ? registry.issue(for: session, peer: peer) : nil
        let capabilities = HostCapabilities(codecs: [.hevc], canManageVirtualDisplay: false, clipboard: true, maxFPS: 60,
                                            fileTransfer: wantsFiles ? true : nil,
                                            filesOnlySessions: wantsFiles && keepsFiles ? true : nil)
        try await channel.send(.authResult(AuthResult(status: .ok, sessionToken: token, capabilities: capabilities)))
        let engineCountAtStart = engineCount
        while let message = try await channel.receive() {
            if case .disconnect = message { break }
            if filesOnly, message.kind != .ping { lock.withLock { screenMessages.append(message.kind) } }
            if behaviour == .dropOnceAfterAttach, engineCount > engineCountAtStart, !lock.withLock({ droppedOnce }) {
                lock.withLock { droppedOnce = true }
                break
            }
        }
        registry.revoke(owner: session)
        await channel.close()
    }

    private static func host(_ endpoint: NWEndpoint?) -> String {
        guard case .hostPort(let host, _)? = endpoint else { return "?" }
        switch host {
        case .ipv4(let a): return a.debugDescription
        case .ipv6(let a): return a.debugDescription
        case .name(let n, _): return n
        @unknown default: return "?"
        }
    }
}

private enum Failure: Error { case timedOut(String) }

@MainActor
private func waitUntil(_ what: String, seconds: Double = 15, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw Failure.timedOut(what) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private func scratchDirectory(_ label: String) throws -> URL {
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

private func sha256(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }

private let viewport = Viewport(widthPoints: 800, heightPoints: 600, scale: 2)

// MARK: Tests

@Suite(.timeLimit(.minutes(1)), .serialized)
struct FileTransferSessionTests {
    /// A 3 MiB file from the iPad to the Mac's folder and back to the iPad's Received folder.
    @Test @MainActor func roundTripsThreeMebibytesBothWays() async throws {
        let host = try await MockFileHost()
        defer { host.stop() }
        let clientDir = try scratchDirectory("client"), sourceDir = try scratchDirectory("source")
        defer { try? FileManager.default.removeItem(at: clientDir); try? FileManager.default.removeItem(at: sourceDir) }
        let files = FileTransferController(receiveDirectory: clientDir)
        var received: [FileTransferController.Transfer] = []
        files.onReceived = { received.append($0) }
        let session = ClientSession(identity: DeviceIdentity(), files: files)
        defer { session.disconnect() }
        session.connect(to: SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port), viewport: viewport)
        try await waitUntil("file channel") { files.isConnected }
        #expect(session.hostOffersFiles)
        #expect(host.connectionCount == 2, "the primary connection and the file channel")

        let source = try randomFile(bytes: 3 << 20, in: sourceDir, name: "Report.pdf")
        let started = ContinuousClock.now
        files.send([source], securityScoped: false)
        #expect(files.transfers.count == 1)
        #expect(files.hasActiveTransfers)
        try await waitUntil("upload") { files.transfers.first?.state == .done }
        let elapsed = ContinuousClock.now - started
        let upload = try #require(files.transfers.first)
        #expect(upload.direction == .sending && upload.savedName == "Report.pdf" && upload.fraction == 1)
        let onMac = host.directory.appending(path: "Report.pdf")
        #expect(try sha256(onMac) == sha256(source))
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("loopback session upload: 3 MiB in \(Int(seconds * 1000)) ms (\(String(format: "%.0f", 3 / seconds)) MiB/s)")

        // The Mac sends it back.
        let engine = try #require(host.latestEngine)
        let back = await engine.send(fileAt: onMac, name: "Report.pdf")
        #expect(back == .sent(savedName: "Report.pdf"))
        try await waitUntil("download") { received.count == 1 }
        let download = try #require(files.transfers.last)
        #expect(download.direction == .receiving && download.state == .done)
        let saved = try #require(download.savedURL)
        #expect(saved == clientDir.appending(path: "Report.pdf"))
        #expect(try sha256(saved) == sha256(source))
        #expect(!files.hasActiveTransfers)
    }

    @Test @MainActor func refusedOfferShowsTheReason() async throws {
        let host = try await MockFileHost(maxIncomingBytes: 1 << 20)
        defer { host.stop() }
        let sourceDir = try scratchDirectory("source")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        let session = ClientSession(identity: DeviceIdentity(), files: files)
        defer { session.disconnect() }
        session.connect(to: SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port), viewport: viewport)
        try await waitUntil("file channel") { files.isConnected }
        files.send([try randomFile(bytes: 2 << 20, in: sourceDir, name: "Big.bin"),
                    try randomFile(bytes: 1_000, in: sourceDir, name: "Small.bin")], securityScoped: false)
        try await waitUntil("both settled") { !files.hasActiveTransfers }
        guard case .failed(let reason) = files.transfers[0].state else { Issue.record("\(files.transfers[0].state)"); return }
        #expect(reason.contains("too large"))
        #expect(files.transfers[1].state == .done, "the queue moves on")
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.directory.path) == ["Small.bin"])
    }

    @Test @MainActor func cancelMidTransferReachesTheMac() async throws {
        let host = try await MockFileHost()
        defer { host.stop() }
        let sourceDir = try scratchDirectory("source")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        files.chunkDelayForTesting = .milliseconds(20) // about a second for 12 chunks, so the cancel lands mid-file
        let session = ClientSession(identity: DeviceIdentity(), files: files)
        defer { session.disconnect() }
        session.connect(to: SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port), viewport: viewport)
        try await waitUntil("file channel") { files.isConnected }
        files.send([try randomFile(bytes: 3 << 20, in: sourceDir, name: "Huge.bin")], securityScoped: false)
        try await waitUntil("progress") { (files.transfers.first?.bytesDone ?? 0) > 0 }
        let id = try #require(files.transfers.first?.id)
        files.cancel(id)
        try await waitUntil("cancelled") { files.transfers.first?.state == .cancelled }
        try await waitUntil("the Mac sees it") { host.hostEvents.contains(.finished(id: id, .cancelled(byPeer: true))) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: host.directory.path).isEmpty, "no partial file left")
        #expect(files.isConnected, "the channel carries on")
    }

    /// The Mac claims a checksum that doesn't match: the iPad answers `fileResult.ok == false`
    /// and keeps nothing.
    @Test @MainActor func badChecksumFromTheMacIsRefused() async throws {
        let host = try await MockFileHost()
        defer { host.stop() }
        let clientDir = try scratchDirectory("client")
        defer { try? FileManager.default.removeItem(at: clientDir) }
        let answer = AsyncStream<FileResult>.makeStream()
        host.rawFileChannel = { channel in
            let id = UUID()
            let bytes = Data(repeating: 0xA5, count: 700_000)
            try await channel.send(.fileOffer(FileOffer(id: id, name: "Damaged.bin", byteCount: UInt64(bytes.count))))
            guard case .fileAccept(let accept)? = try await channel.receive(), accept.rejected == nil else { return }
            try await channel.send(.fileChunkToClient(FileChunk(id: id, offset: 0, data: bytes.prefix(FileChunk.standardSize))))
            try await channel.send(.fileChunkToClient(FileChunk(id: id, offset: UInt64(FileChunk.standardSize), data: bytes.dropFirst(FileChunk.standardSize))))
            try await channel.send(.fileComplete(FileComplete(id: id, sha256: Data(repeating: 0, count: 32))))
            if case .fileResult(let result)? = try await channel.receive() { answer.continuation.yield(result) }
            answer.continuation.finish()
            while try await channel.receive() != nil {}
        }
        let files = FileTransferController(receiveDirectory: clientDir)
        let session = ClientSession(identity: DeviceIdentity(), files: files)
        defer { session.disconnect() }
        session.connect(to: SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port), viewport: viewport)
        var iterator = answer.stream.makeAsyncIterator()
        let result = try #require(await iterator.next())
        #expect(!result.ok)
        #expect(result.error?.contains("damaged") == true)
        try await waitUntil("row failed") { if case .failed = files.transfers.first?.state { true } else { false } }
        #expect(try FileManager.default.contentsOfDirectory(atPath: clientDir.path).isEmpty)
    }

    /// The Mac drops the session mid-queue; the client reconnects both connections, and the
    /// queued file goes through on the new file channel.
    @Test @MainActor func fileChannelComesBackWithTheSession() async throws {
        let host = try await MockFileHost(behaviour: .dropOnceAfterAttach)
        defer { host.stop() }
        let sourceDir = try scratchDirectory("source")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        let session = ClientSession(identity: DeviceIdentity(), files: files)
        defer { session.disconnect() }
        session.connect(to: SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port), viewport: viewport)
        try await waitUntil("first file channel") { files.isConnected && host.engineCount == 1 }
        // The next thing the client sends on the primary (its feedback, or here a ping) makes
        // the mock drop it.
        session.ping()
        try await waitUntil("dropped", seconds: 5) { !files.isConnected || session.state != .connected }
        files.send([try randomFile(bytes: 500_000, in: sourceDir, name: "Later.bin")], securityScoped: false)
        try await waitUntil("second file channel", seconds: 20) { files.isConnected && host.engineCount == 2 }
        try await waitUntil("sent after reconnect") { files.transfers.first?.state == .done }
        #expect(FileManager.default.fileExists(atPath: host.directory.appending(path: "Later.bin").path))
    }

    /// The network drops mid-upload: the row pauses where it stopped, the session reconnects,
    /// and the same file carries on from the Mac's partial instead of starting over.
    @Test @MainActor func interruptedUploadResumesWhereItStopped() async throws {
        let host = try await MockFileHost()
        defer { host.stop() }
        let sourceDir = try scratchDirectory("source")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        files.chunkDelayForTesting = .milliseconds(25)
        let session = ClientSession(identity: DeviceIdentity(), files: files)
        defer { session.disconnect() }
        session.connect(to: SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port), viewport: viewport)
        try await waitUntil("file channel") { files.isConnected }
        let source = try randomFile(bytes: 4 << 20, in: sourceDir, name: "Library.zip")
        files.send([source], securityScoped: false)
        try await waitUntil("a third of it") { (files.transfers.first?.bytesDone ?? 0) >= 1_500_000 }
        files.chunkDelayForTesting = .zero

        await host.dropEverything()
        try await waitUntil("paused") { files.transfers.first?.interruptedAt != nil }
        let paused = try #require(files.transfers.first)
        #expect(paused.state == .waiting && paused.bytesDone > 0, "keeps its place")

        try await waitUntil("finished after reconnecting", seconds: 20) { files.transfers.first?.state == .done }
        #expect(try sha256(host.directory.appending(path: "Library.zip")) == sha256(source))
        let id = paused.id
        let starts = host.hostEvents.enumerated().filter { if case .started(let item) = $0.element { item.id == id } else { false } }
        #expect(starts.count == 2, "offered once, then again under the same id")
        let resumedAt = starts.last.flatMap { start in host.hostEvents.dropFirst(start.offset + 1).first }
        guard case .progress(id, let bytes)? = resumedAt else { Issue.record("no resume point: \(String(describing: resumedAt))"); return }
        #expect(bytes >= 1_000_000 && bytes < 4 << 20, "picked up at \(bytes)")
    }

    // MARK: Files without the screen

    /// Disconnect mid-upload on a Mac that keeps files: the screen goes, the file carries on to
    /// the end on the same channel (never restarted), and the channel closes once idle.
    @Test @MainActor func transferKeepsGoingAfterTheSessionEnds() async throws {
        let host = try await MockFileHost(keepsFiles: true)
        defer { host.stop() }
        let sourceDir = try scratchDirectory("source")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        files.chunkDelayForTesting = .milliseconds(30)
        let session = ClientSession(identity: DeviceIdentity(), files: files)
        session.fileLink.idleTimeout = .milliseconds(600)
        session.connect(to: SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port), viewport: viewport)
        try await waitUntil("file channel") { files.isConnected }
        #expect(session.fileLink.macKeepsFiles == true)
        let source = try randomFile(bytes: 3 << 20, in: sourceDir, name: "Holiday.mov")
        files.send([source], securityScoped: false)
        try await waitUntil("under way") { (files.transfers.first?.bytesDone ?? 0) > 0 }

        session.disconnect()
        try await waitUntil("the Mac saw the screen go") { host.closedPrimaryCount == 1 }
        #expect(files.isConnected, "the file channel stays")
        #expect(files.transfers.first?.state == .active)
        try await waitUntil("finished without the screen") { files.transfers.first?.state == .done }
        #expect(try sha256(host.directory.appending(path: "Holiday.mov")) == sha256(source))
        let id = try #require(files.transfers.first?.id)
        #expect(host.starts(of: id) == 1, "carried on, not restarted")
        try await waitUntil("closed once idle", seconds: 5) { !files.isConnected }
        let engine = try #require(host.latestEngine)
        try await waitUntil("the Mac's side closed too", seconds: 5) { await engine.hasClosed }
        #expect(host.engineCount == 1 && host.filesOnlyHelloCount == 0)
    }

    /// Send Files from the device list: no screen session at all. The iPad opens a files-only
    /// session that never asks for the screen, sends everything queued, and closes once idle.
    @Test @MainActor func sendsFilesWithoutOpeningTheScreen() async throws {
        let host = try await MockFileHost(keepsFiles: true)
        defer { host.stop() }
        let sourceDir = try scratchDirectory("source")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        let link = FileLink(files: files, identity: DeviceIdentity(), clientName: "Test iPad", clientModel: "iPad")
        link.idleTimeout = .milliseconds(600)
        link.update(SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port))
        let sources = try (1...3).map { try randomFile(bytes: 300_000 * $0, in: sourceDir, name: "Scan \($0).pdf") }
        files.send(sources, securityScoped: false)
        try await waitUntil("all three sent") { files.transfers.count == 3 && files.transfers.allSatisfy { $0.state == .done } }
        for source in sources {
            #expect(try sha256(host.directory.appending(path: source.lastPathComponent)) == sha256(source))
        }
        #expect(host.filesOnlyHelloCount == 1 && host.screenHelloCount == 0)
        #expect(host.filesOnlyStrayMessages.isEmpty, "a files-only session never asks for the screen")
        #expect(link.macKeepsFiles == true)
        try await waitUntil("closed once idle", seconds: 5) { !files.isConnected && link.phase == .idle }
        try await waitUntil("its session closed too", seconds: 5) { host.closedPrimaryCount == 1 }
    }

    /// The file channel alone drops while the screen stays up: it comes back through a
    /// files-only session and the file resumes.
    @Test @MainActor func droppedFileChannelComesBackWithoutTheScreen() async throws {
        let host = try await MockFileHost(keepsFiles: true)
        defer { host.stop() }
        let sourceDir = try scratchDirectory("source")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        files.chunkDelayForTesting = .milliseconds(25)
        let session = ClientSession(identity: DeviceIdentity(), files: files)
        defer { session.disconnect() }
        session.connect(to: SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port), viewport: viewport)
        try await waitUntil("file channel") { files.isConnected }
        let source = try randomFile(bytes: 3 << 20, in: sourceDir, name: "Drawings.zip")
        files.send([source], securityScoped: false)
        try await waitUntil("under way") { (files.transfers.first?.bytesDone ?? 0) >= 600_000 }
        files.chunkDelayForTesting = .zero
        await host.latestEngine?.close()
        try await waitUntil("finished", seconds: 20) { files.transfers.first?.state == .done }
        #expect(session.state == .connected, "the screen never dropped")
        #expect(host.filesOnlyHelloCount == 1, "the channel came back through a files-only session")
        #expect(try sha256(host.directory.appending(path: "Drawings.zip")) == sha256(source))
        let id = try #require(files.transfers.first?.id)
        #expect(host.starts(of: id) == 2)
    }

    /// A Mac from before files-only sessions: nothing is sent without a screen, and the files say
    /// why; the connection it answered is closed at once.
    @Test @MainActor func olderMacExplainsItNeedsTheScreenForFiles() async throws {
        let host = try await MockFileHost(keepsFiles: false)
        defer { host.stop() }
        let sourceDir = try scratchDirectory("source")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        let link = FileLink(files: files, identity: DeviceIdentity(), clientName: "Test iPad", clientModel: "iPad")
        link.update(SavedDevice(name: "Old Mac", host: "127.0.0.1", port: host.port))
        files.send([try randomFile(bytes: 1_000, in: sourceDir, name: "Note.txt")], securityScoped: false)
        try await waitUntil("failed") { if case .failed = files.transfers.first?.state { true } else { false } }
        guard case .failed(let reason) = files.transfers.first?.state else { return }
        #expect(reason.contains("Update Vantage Host on Old Mac"))
        #expect(host.engineCount == 0)
        try await waitUntil("hung up") { host.closedPrimaryCount == 1 }
        #expect(link.macKeepsFiles == false)
        // The next file fails straight away, without another connection.
        files.send([try randomFile(bytes: 1_000, in: sourceDir, name: "Note 2.txt")], securityScoped: false)
        #expect(files.transfers.last?.state == .failed(reason))
        #expect(host.connectionCount == 1)
    }

    /// Disconnect from an older Mac still takes the file channel down with the screen (and the
    /// session screen asks first, see `RemoteSessionScreen.disconnect`).
    @Test @MainActor func olderMacsFileChannelEndsWithTheSession() async throws {
        let host = try await MockFileHost(keepsFiles: false)
        defer { host.stop() }
        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        let session = ClientSession(identity: DeviceIdentity(), files: files)
        session.connect(to: SavedDevice(name: "Old Mac", host: "127.0.0.1", port: host.port), viewport: viewport)
        try await waitUntil("file channel") { files.isConnected }
        #expect(session.fileLink.macKeepsFiles == false)
        session.disconnect()
        try await waitUntil("closed with the session") { !files.isConnected }
        let engine = try #require(host.latestEngine)
        try await waitUntil("the Mac's side closed", seconds: 5) { await engine.hasClosed }
    }

    /// A Mac that doesn't know this iPad yet: files-only sessions can't pair, so the files say how.
    @Test @MainActor func filesOnlyNeedsAPairedMac() async throws {
        let host = try await MockFileHost(keepsFiles: true, refusesFilesOnlyUnpaired: true)
        defer { host.stop() }
        let sourceDir = try scratchDirectory("source")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        let link = FileLink(files: files, identity: DeviceIdentity(), clientName: "Test iPad", clientModel: "iPad")
        link.update(SavedDevice(name: "New Mac", host: "127.0.0.1", port: host.port))
        files.send([try randomFile(bytes: 1_000, in: sourceDir, name: "Hello.txt")], securityScoped: false)
        try await waitUntil("failed") { if case .failed = files.transfers.first?.state { true } else { false } }
        guard case .failed(let reason) = files.transfers.first?.state else { return }
        #expect(reason.contains("pair"))
        #expect(link.phase == .unavailable(reason))
    }

    /// A long queue ("a photo library"): 1,500 files go one after another without memory growing
    /// with the queue, one that vanished before its turn fails on its own, and the run sums up
    /// right the whole way.
    @Test(.timeLimit(.minutes(3))) @MainActor func longQueueKeepsMovingWithFlatMemory() async throws {
        let host = try await MockFileHost(keepsFiles: true)
        defer { host.stop() }
        let sourceDir = try scratchDirectory("library")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let count = 1_500
        let block = Data(repeating: 0x6B, count: 24_000)
        var sources: [URL] = []
        for number in 1...count {
            let url = sourceDir.appending(path: String(format: "IMG_%04d.heic", number))
            try block.write(to: url)
            sources.append(url)
        }
        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        let link = FileLink(files: files, identity: DeviceIdentity(), clientName: "Test iPad", clientModel: "iPad")
        link.update(SavedDevice(name: "Mock Mac", host: "127.0.0.1", port: host.port))
        files.send(sources, securityScoped: false)
        try FileManager.default.removeItem(at: sources[700]) // gone before its turn
        #expect(files.summary.count == count && files.summary.bytes == UInt64(count * block.count))

        try await waitUntil("a tenth through", seconds: 60) { files.summary.finished >= count / 10 }
        let early = currentFootprint()
        try await waitUntil("all settled", seconds: 150) { !files.summary.isActive }
        let late = currentFootprint()
        let summary = files.summary
        #expect(summary.finished == count && summary.failed == 1)
        guard case .failed(let reason) = files.transfers[700].state else { Issue.record("\(files.transfers[700].state)"); return }
        #expect(reason.contains("couldn't read"))
        let saved = try FileManager.default.contentsOfDirectory(atPath: host.directory.path).filter { $0.hasPrefix("IMG_") }
        #expect(saved.count == count - 1, "the rest went through")
        print("long queue: \(count) files, footprint \(early >> 20) MiB at 10%, \(late >> 20) MiB at the end")
        #expect(late < early + 24 << 20, "memory stays flat along the queue (\(early >> 20) → \(late >> 20) MiB)")
    }

    @Test @MainActor func olderHostNeverSeesAFileChannel() async throws {
        let host = try await MockFileHost(offersFiles: false)
        defer { host.stop() }
        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        let session = ClientSession(identity: DeviceIdentity(), files: files)
        defer { session.disconnect() }
        session.connect(to: SavedDevice(name: "Old Mac", host: "127.0.0.1", port: host.port), viewport: viewport)
        try await waitUntil("connected") { session.state == .connected }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!session.hostOffersFiles)
        #expect(!files.isConnected)
        #expect(host.connectionCount == 1)
    }

    /// A second connection with a made-up token (or a replayed one) is closed without joining.
    @Test func forgedAndReplayedTokensAreRefused() async throws {
        let host = try await MockFileHost()
        defer { host.stop() }
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: host.port)!, using: VantageNetwork.bulkParameters())
        let channel = MessageChannel(connection: connection)
        try await channel.start()
        try await channel.send(.attachMedia(AttachMedia(sessionToken: Data(repeating: 7, count: 32))))
        #expect(try await channel.receive() == nil)
        #expect(host.refusedAttaches == 1)
        #expect(host.engineCount == 0)
    }
}

@MainActor struct SharedFileInboxTests {
    /// "Open in Vantage": the file is copied out (the original stays with its app) and waits for
    /// a session; one queued for a Mac that can't take files fails with the reason.
    @Test func openedFilesAreCopiedAndQueued() throws {
        let sourceDir = try scratchDirectory("shared")
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let original = try randomFile(bytes: 10_000, in: sourceDir, name: "From Mail.pdf")
        let inbox = SharedFileInbox()
        inbox.accept(original)
        #expect(FileManager.default.fileExists(atPath: original.path), "the other app's file stays put")
        let copies = inbox.take()
        #expect(inbox.pending.isEmpty)
        let copy = try #require(copies.first)
        #expect(copy.lastPathComponent == "From Mail.pdf" && copy.path.contains("/Outbox/"))
        #expect(try Data(contentsOf: copy) == Data(contentsOf: original))

        let files = FileTransferController(receiveDirectory: try scratchDirectory("client"))
        files.sendOutboxCopy(copy)
        #expect(files.transfers.first?.state == .waiting)
        files.failWaiting("Update Vantage Host.")
        #expect(files.transfers.first?.state == .failed("Update Vantage Host."))
        #expect(!FileManager.default.fileExists(atPath: copy.path), "the outbox copy is cleaned up")
    }
}

/// This process's physical footprint (what Xcode's memory gauge shows).
private func currentFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

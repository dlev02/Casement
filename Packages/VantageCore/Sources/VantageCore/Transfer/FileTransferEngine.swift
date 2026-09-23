import CryptoKit
import Foundation
import Synchronization
import UniformTypeIdentifiers
import os

/// Which end of the session this engine runs on; decides the chunk kind it sends and accepts.
public enum FileTransferRole: Sendable {
    case host, client

    func chunkMessage(_ chunk: FileChunk) -> Message {
        self == .host ? .fileChunkToClient(chunk) : .fileChunkToHost(chunk)
    }
}

/// One file moving in either direction, as the UI shows it.
public struct FileTransferItem: Sendable, Equatable, Identifiable {
    public enum Direction: Sendable, Equatable { case sending, receiving }
    public var id: UUID
    public var name: String
    public var byteCount: UInt64
    public var direction: Direction

    public init(id: UUID, name: String, byteCount: UInt64, direction: Direction) {
        self.id = id
        self.name = name
        self.byteCount = byteCount
        self.direction = direction
    }
}

/// How a transfer ended.
public enum FileTransferOutcome: Sendable, Equatable {
    /// Sent, and the other side saved it under this name.
    case sent(savedName: String?)
    /// Received and saved here.
    case received(URL)
    /// A user-facing reason.
    case failed(String)
    case cancelled(byPeer: Bool)

    public var isSuccess: Bool {
        switch self {
        case .sent, .received: true
        case .failed, .cancelled: false
        }
    }
}

public enum FileTransferEvent: Sendable, Equatable {
    /// A file started moving: an offer we sent (once it's our turn) or one we accepted.
    case started(FileTransferItem)
    /// Bytes done so far, at most every `progressInterval`, and once at the end.
    case progress(id: UUID, bytes: UInt64)
    case finished(id: UUID, FileTransferOutcome)
}

public struct FileTransferConfiguration: Sendable {
    /// Where received files are saved (created if missing).
    public var receiveDirectory: URL
    public var chunkSize: Int
    /// Chunks handed to the network stack but not yet taken by it.
    public var window: Int
    /// Offers above this are refused.
    public var maxIncomingBytes: UInt64
    /// Free space that must remain after a received file.
    public var freeSpaceMargin: UInt64
    public var progressInterval: Duration
    /// Runs on each received file after it is in place (the host sets the quarantine flag here).
    public var afterSave: (@Sendable (URL, FileOffer) -> Void)?
    /// A pause before each chunk sent. Zero outside tests: it only exists so UI tests can catch
    /// a transfer in the middle.
    public var chunkDelay: Duration = .zero

    public init(receiveDirectory: URL, chunkSize: Int = FileChunk.standardSize, window: Int = 4,
                maxIncomingBytes: UInt64 = 64 << 30, freeSpaceMargin: UInt64 = 256 << 20,
                progressInterval: Duration = .milliseconds(100), afterSave: (@Sendable (URL, FileOffer) -> Void)? = nil) {
        self.receiveDirectory = receiveDirectory
        self.chunkSize = chunkSize
        self.window = window
        self.maxIncomingBytes = maxIncomingBytes
        self.freeSpaceMargin = freeSpaceMargin
        self.progressInterval = progressInterval
        self.afterSave = afterSave
    }
}

/// Runs file transfers over a session's file channel, both ways at once: one outgoing file at a
/// time (`send` calls queue in order) and whatever the peer offers, saved to
/// `receiveDirectory` through a hidden `.vantage-<id>.partial` file that is renamed only after
/// its SHA-256 checks out.
///
/// Sending keeps `window` chunks in flight with `MessageChannel.send(_:completion:)`, so the
/// socket paces the file to the link instead of it piling up in memory. Receiving leans on the
/// channel's `maxBufferedMessages` for the same reason in the other direction.
public actor FileTransferEngine {
    public nonisolated let events: AsyncStream<FileTransferEvent>
    private let eventSink: AsyncStream<FileTransferEvent>.Continuation
    private let channel: MessageChannel
    private let role: FileTransferRole
    private let config: FileTransferConfiguration
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "files")
    private var isClosed = false

    // Outgoing: one at a time, FIFO.
    private var outgoingBusy = false
    private var turnWaiters: [CheckedContinuation<Void, Never>] = []
    private var outgoing: Outgoing?
    private var cancelledBeforeStart: Set<UUID> = []

    // Incoming, by id.
    private var incoming: [UUID: Incoming] = [:]

    public static let partialPrefix = ".vantage-"
    public static let partialSuffix = ".partial"

    public init(channel: MessageChannel, role: FileTransferRole, configuration: FileTransferConfiguration) {
        self.channel = channel
        self.role = role
        self.config = configuration
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Reads the channel until it closes, then fails whatever was in flight. Any message that
    /// doesn't belong on a file channel ends it.
    public func run() async {
        removeStalePartials()
        do {
            while let message = try await channel.receive() {
                try await handle(message)
            }
        } catch {
            if !isClosed { log.error("file channel ended: \(error.localizedDescription, privacy: .public)") }
        }
        await shutDown(reason: "The connection was lost.")
    }

    /// The channel has closed; nothing more will move on this engine.
    public var hasClosed: Bool { isClosed }

    /// Ends the channel and every transfer on it.
    public func close() async {
        await shutDown(reason: "The connection was closed.")
    }

    // MARK: Sending

    /// Sends one file and returns once the peer has answered (or it failed). Calls queue behind
    /// each other. `name` overrides the file's own name.
    public func send(fileAt url: URL, name: String? = nil, id: UUID = UUID()) async -> FileTransferOutcome {
        await takeTurn()
        defer { passTurn() }
        if cancelledBeforeStart.remove(id) != nil { return finish(outgoing: id, .cancelled(byPeer: false)) }
        guard !isClosed else { return finish(outgoing: id, .failed("The connection was lost.")) }

        let handle: FileHandle
        let offer: FileOffer
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .contentTypeKey, .isDirectoryKey])
            if values.isDirectory == true { return finish(outgoing: id, .failed("Folders can't be sent. Compress it first.")) }
            handle = try FileHandle(forReadingFrom: url)
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            offer = FileOffer(id: id, name: name ?? url.lastPathComponent, byteCount: size,
                              modified: values.contentModificationDate, uti: values.contentType?.identifier)
        } catch {
            log.error("can't read file to send: \(error.localizedDescription, privacy: .public)")
            return finish(outgoing: id, .failed("Vantage couldn't read that file."))
        }
        defer { try? handle.close() }

        let state = Outgoing(id: id)
        outgoing = state
        defer { if outgoing === state { outgoing = nil } }
        eventSink.yield(.started(FileTransferItem(id: id, name: offer.name, byteCount: offer.byteCount, direction: .sending)))

        do {
            try await channel.send(.fileOffer(offer))
        } catch {
            return finish(outgoing: id, .failed("The connection was lost."))
        }
        switch await state.nextReply() {
        case .accept(let accept):
            if let reason = accept.rejected { return finish(outgoing: id, .failed(reason)) }
            if accept.resumeOffset > offer.byteCount { return finish(outgoing: id, .failed("The other device asked for a part of the file that doesn't exist.")) }
            return await stream(handle: handle, offer: offer, from: accept.resumeOffset, state: state)
        case .result(let result):
            return finish(outgoing: id, result.ok ? .failed("The other device answered out of turn.") : .failed(result.error ?? "The other device couldn't save the file."))
        case .cancelled(let byPeer):
            return finish(outgoing: id, .cancelled(byPeer: byPeer))
        case .closed:
            return finish(outgoing: id, .failed("The connection was lost."))
        }
    }

    /// Stops a transfer in either direction (or a queued send before it starts).
    public func cancel(_ id: UUID) {
        if let outgoing, outgoing.id == id {
            guard !outgoing.cancelled else { return }
            outgoing.cancelled = true
            outgoing.window?.abort(CancellationError())
            channel.sendDetached(.fileCancel(FileCancel(id: id)))
            outgoing.deliver(.cancelled(byPeer: false))
        } else if let state = incoming.removeValue(forKey: id) {
            state.discard()
            channel.sendDetached(.fileCancel(FileCancel(id: id)))
            eventSink.yield(.finished(id: id, .cancelled(byPeer: false)))
        } else {
            cancelledBeforeStart.insert(id)
        }
    }

    private func stream(handle: FileHandle, offer: FileOffer, from start: UInt64, state: Outgoing) async -> FileTransferOutcome {
        let id = offer.id
        var hasher = SHA256()
        var offset: UInt64 = 0
        let window = SendWindow(size: config.window)
        state.window = window
        var lastProgress = ContinuousClock.now
        do {
            // A resumed transfer still hashes the whole file.
            while offset < start {
                let piece = try handle.read(upToCount: Int(min(UInt64(config.chunkSize), start - offset))) ?? Data()
                guard !piece.isEmpty else { throw TransferFailure.fileChanged }
                hasher.update(data: piece)
                offset += UInt64(piece.count)
            }
            while offset < offer.byteCount {
                if let early = state.takeTerminalReply() { return finish(outgoing: id, early) }
                let wanted = Int(min(UInt64(config.chunkSize), offer.byteCount - offset))
                let piece = try handle.read(upToCount: wanted) ?? Data()
                guard piece.count == wanted else { throw TransferFailure.fileChanged }
                hasher.update(data: piece)
                if config.chunkDelay > .zero { try await Task.sleep(for: config.chunkDelay) }
                try await window.acquire()
                if let early = state.takeTerminalReply() { return finish(outgoing: id, early) }
                channel.send(role.chunkMessage(FileChunk(id: id, offset: offset, data: piece))) { error in
                    window.release(error)
                }
                offset += UInt64(piece.count)
                if ContinuousClock.now - lastProgress >= config.progressInterval {
                    lastProgress = .now
                    eventSink.yield(.progress(id: id, bytes: offset))
                }
            }
            try await window.drain()
            if let early = state.takeTerminalReply() { return finish(outgoing: id, early) }
            eventSink.yield(.progress(id: id, bytes: offset))
            try await channel.send(.fileComplete(FileComplete(id: id, sha256: Data(hasher.finalize()))))
        } catch TransferFailure.fileChanged {
            channel.sendDetached(.fileCancel(FileCancel(id: id)))
            return finish(outgoing: id, .failed("The file changed while it was being sent."))
        } catch {
            if let early = state.takeTerminalReply() { return finish(outgoing: id, early) }
            if state.cancelled { return finish(outgoing: id, .cancelled(byPeer: false)) }
            log.error("send failed: \(error.localizedDescription, privacy: .public)")
            return finish(outgoing: id, .failed(error is CocoaError ? "Vantage couldn't read that file." : "The connection was lost."))
        }
        switch await state.nextReply() {
        case .result(let result):
            if result.ok { logRate("sent", bytes: offer.byteCount - start, since: state.started) }
            return finish(outgoing: id, result.ok ? .sent(savedName: result.savedName) : .failed(result.error ?? "The other device couldn't save the file."))
        case .cancelled(let byPeer):
            return finish(outgoing: id, .cancelled(byPeer: byPeer))
        case .accept:
            return finish(outgoing: id, .failed("The other device answered out of turn."))
        case .closed:
            return finish(outgoing: id, .failed("The connection was lost before the other device confirmed the file."))
        }
    }

    private func finish(outgoing id: UUID, _ outcome: FileTransferOutcome) -> FileTransferOutcome {
        eventSink.yield(.finished(id: id, outcome))
        return outcome
    }

    private func takeTurn() async {
        if !outgoingBusy {
            outgoingBusy = true
            return
        }
        await withCheckedContinuation { turnWaiters.append($0) }
    }

    private func passTurn() {
        if turnWaiters.isEmpty {
            outgoingBusy = false
        } else {
            turnWaiters.removeFirst().resume() // stays busy: the turn passes straight on
        }
    }

    // MARK: Receiving

    private func handle(_ message: Message) async throws {
        switch message {
        case .fileOffer(let offer):
            try await receiveOffer(offer)
        case .fileChunkToHost(let chunk) where role == .host,
             .fileChunkToClient(let chunk) where role == .client:
            receiveChunk(chunk)
        case .fileComplete(let complete):
            try await receiveComplete(complete)
        case .fileAccept(let accept):
            if let outgoing, outgoing.id == accept.id { outgoing.deliver(.accept(accept)) }
        case .fileResult(let result):
            if let outgoing, outgoing.id == result.id { outgoing.deliver(.result(result)) }
        case .fileCancel(let cancel):
            if let outgoing, outgoing.id == cancel.id {
                outgoing.cancelledByPeer = true
                outgoing.window?.abort(CancellationError())
                outgoing.deliver(.cancelled(byPeer: true))
            } else if let state = incoming.removeValue(forKey: cancel.id) {
                state.discard()
                eventSink.yield(.finished(id: cancel.id, .cancelled(byPeer: true)))
            }
        default:
            // Nothing else belongs on a file channel (including chunks going the wrong way).
            log.error("unexpected \(String(describing: message.kind), privacy: .public) on the file channel")
            throw TransferFailure.protocolViolation
        }
    }

    private func receiveOffer(_ offer: FileOffer) async throws {
        guard !isClosed, incoming[offer.id] == nil, outgoing?.id != offer.id else {
            try await channel.send(.fileAccept(.rejected(offer.id, reason: "That file is already being transferred.")))
            return
        }
        let name = FileNames.sanitize(offer.name)
        if let reason = rejection(for: offer) {
            log.info("refusing incoming file (\(offer.byteCount, privacy: .public) bytes): \(reason, privacy: .public)")
            try await channel.send(.fileAccept(.rejected(offer.id, reason: reason)))
            return
        }
        let directory = config.receiveDirectory
        let partial = directory.appending(path: Self.partialPrefix + offer.id.uuidString + Self.partialSuffix, directoryHint: .notDirectory)
        let handle: FileHandle
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: partial.path(percentEncoded: false), contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: partial)
        } catch {
            log.error("can't create partial file: \(error.localizedDescription, privacy: .public)")
            try await channel.send(.fileAccept(.rejected(offer.id, reason: "The file couldn't be saved on this device.")))
            return
        }
        incoming[offer.id] = Incoming(offer: offer, name: name, partial: partial, handle: handle)
        eventSink.yield(.started(FileTransferItem(id: offer.id, name: name, byteCount: offer.byteCount, direction: .receiving)))
        try await channel.send(.fileAccept(FileAccept(id: offer.id, resumeOffset: 0)))
        if offer.byteCount == 0 { eventSink.yield(.progress(id: offer.id, bytes: 0)) }
    }

    private func rejection(for offer: FileOffer) -> String? {
        if offer.byteCount > config.maxIncomingBytes {
            return "The file is too large (\(ByteCountFormatter.string(fromByteCount: Int64(clamping: offer.byteCount), countStyle: .file)))."
        }
        // Measure on the folder, or the nearest one above it that exists yet.
        var probe = config.receiveDirectory
        while !FileManager.default.fileExists(atPath: probe.path(percentEncoded: false)), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage, free >= 0,
           UInt64(free) < offer.byteCount &+ config.freeSpaceMargin {
            return "There isn't enough free space for it."
        }
        return nil
    }

    private func receiveChunk(_ chunk: FileChunk) {
        guard let state = incoming[chunk.id] else { return } // late chunks after a cancel
        guard chunk.offset == state.received, state.received + UInt64(chunk.data.count) <= state.offer.byteCount else {
            failIncoming(state, "The file arrived damaged.")
            return
        }
        do {
            try state.handle.write(contentsOf: chunk.data)
        } catch {
            log.error("write failed: \(error.localizedDescription, privacy: .public)")
            failIncoming(state, "The file couldn't be saved. The disk may be full.")
            return
        }
        state.hasher.update(data: chunk.data)
        state.received += UInt64(chunk.data.count)
        if ContinuousClock.now - state.lastProgress >= config.progressInterval {
            state.lastProgress = .now
            eventSink.yield(.progress(id: chunk.id, bytes: state.received))
        }
    }

    private func receiveComplete(_ complete: FileComplete) async throws {
        guard let state = incoming.removeValue(forKey: complete.id) else { return }
        try? state.handle.close()
        let digest = Data(state.hasher.finalize())
        guard state.received == state.offer.byteCount,
              constantTimeEquals(digest, complete.sha256) else {
            state.discard()
            log.error("incoming file failed its checksum (\(state.received, privacy: .public)/\(state.offer.byteCount, privacy: .public) bytes)")
            try await channel.send(.fileResult(FileResult(id: complete.id, ok: false, error: "The file arrived damaged. Try sending it again.")))
            eventSink.yield(.finished(id: complete.id, .failed("The file arrived damaged.")))
            return
        }
        eventSink.yield(.progress(id: complete.id, bytes: state.received))
        do {
            let saved = try place(state)
            config.afterSave?(saved, state.offer)
            logRate("received", bytes: state.received, since: state.started)
            // It's saved here whether or not the answer reaches the sender.
            eventSink.yield(.finished(id: complete.id, .received(saved)))
            try await channel.send(.fileResult(FileResult(id: complete.id, ok: true, savedName: saved.lastPathComponent)))
        } catch let error as ChannelError {
            throw error
        } catch {
            state.discard()
            log.error("couldn't move received file into place: \(error.localizedDescription, privacy: .public)")
            try await channel.send(.fileResult(FileResult(id: complete.id, ok: false, error: "The file couldn't be saved on the other device.")))
            eventSink.yield(.finished(id: complete.id, .failed("The file couldn't be saved.")))
        }
    }

    /// Renames the partial file to the first free Finder-style name, retrying if another writer
    /// takes that name in between.
    private func place(_ state: Incoming) throws -> URL {
        let manager = FileManager.default
        if let modified = state.offer.modified {
            try? manager.setAttributes([.modificationDate: modified], ofItemAtPath: state.partial.path(percentEncoded: false))
        }
        var lastError: (any Error)?
        for _ in 0..<8 {
            let target = FileNames.uniqueURL(for: state.name, in: config.receiveDirectory)
            do {
                try manager.moveItem(at: state.partial, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                lastError = CocoaError(.fileWriteFileExists)
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    private func logRate(_ verb: String, bytes: UInt64, since start: ContinuousClock.Instant) {
        let elapsed = ContinuousClock.now - start
        let seconds = max(0.000_001, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        log.info("\(verb, privacy: .public) \(bytes, privacy: .public) bytes in \(Int(seconds * 1000), privacy: .public) ms (\(String(format: "%.1f", Double(bytes) / seconds / 1_048_576), privacy: .public) MiB/s)")
    }

    private func failIncoming(_ state: Incoming, _ reason: String) {
        incoming[state.offer.id] = nil
        state.discard()
        channel.sendDetached(.fileResult(FileResult(id: state.offer.id, ok: false, error: reason)))
        eventSink.yield(.finished(id: state.offer.id, .failed(reason)))
    }

    /// Partial files left by a crash or a lost connection more than an hour ago. Resume isn't
    /// built yet, so nothing will ever complete them.
    private func removeStalePartials() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: config.receiveDirectory.path(percentEncoded: false)) else { return }
        for name in names where name.hasPrefix(Self.partialPrefix) && name.hasSuffix(Self.partialSuffix) {
            let url = config.receiveDirectory.appending(path: name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < Date.now.addingTimeInterval(-3_600) { try? manager.removeItem(at: url) }
        }
    }

    private func shutDown(reason: String) async {
        guard !isClosed else { return }
        isClosed = true
        await channel.close()
        if let outgoing {
            outgoing.window?.abort(ChannelError.closed)
            outgoing.deliver(.closed)
        }
        for (id, state) in incoming {
            state.discard()
            eventSink.yield(.finished(id: id, .failed(reason)))
        }
        incoming.removeAll()
        // Queued sends find the engine closed when their turn comes.
        let waiters = turnWaiters
        turnWaiters.removeAll()
        outgoingBusy = !waiters.isEmpty
        for waiter in waiters { waiter.resume() }
        eventSink.finish()
    }
}

private enum TransferFailure: Error {
    case fileChanged
    case protocolViolation
}

/// What the receiver said about the file being sent.
private enum PeerReply: Sendable {
    case accept(FileAccept)
    case result(FileResult)
    case cancelled(byPeer: Bool)
    case closed
}

/// The file being sent. Only touched on the engine's actor.
private final class Outgoing: @unchecked Sendable {
    let id: UUID
    let started = ContinuousClock.now
    var cancelled = false
    var cancelledByPeer = false
    var window: SendWindow?
    private var replies: [PeerReply] = []
    private var waiter: CheckedContinuation<PeerReply, Never>?

    init(id: UUID) { self.id = id }

    func deliver(_ reply: PeerReply) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: reply)
        } else {
            replies.append(reply)
        }
    }

    func nextReply() async -> PeerReply {
        if !replies.isEmpty { return replies.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// A reply that ends the transfer early (a cancel, a failure result, the channel closing),
    /// turned into its outcome.
    func takeTerminalReply() -> FileTransferOutcome? {
        guard let index = replies.firstIndex(where: { if case .accept = $0 { false } else { true } }) else {
            if cancelled { return .cancelled(byPeer: false) }
            return nil
        }
        switch replies.remove(at: index) {
        case .result(let result): return .failed(result.error ?? "The other device couldn't save the file.")
        case .cancelled(let byPeer): return .cancelled(byPeer: byPeer)
        case .closed: return .failed("The connection was lost.")
        case .accept: return nil
        }
    }
}

/// A file being received. Only touched on the engine's actor.
private final class Incoming: @unchecked Sendable {
    let offer: FileOffer
    let name: String
    let partial: URL
    let handle: FileHandle
    var hasher = SHA256()
    var received: UInt64 = 0
    var lastProgress = ContinuousClock.now
    let started = ContinuousClock.now

    init(offer: FileOffer, name: String, partial: URL, handle: FileHandle) {
        self.offer = offer
        self.name = name
        self.partial = partial
        self.handle = handle
    }

    func discard() {
        try? handle.close()
        try? FileManager.default.removeItem(at: partial)
    }
}

/// Up to `size` sends in flight: `acquire` before handing a chunk to the connection, `release`
/// from its completion. The first send error (or an `abort`) fails every later call.
final class SendWindow: Sendable {
    private struct State {
        var available: Int
        var inFlight = 0
        var waiters: [CheckedContinuation<Void, any Error>] = []
        var drainers: [CheckedContinuation<Void, any Error>] = []
        var error: (any Error)?
    }

    private let state: Mutex<State>

    init(size: Int) {
        state = Mutex(State(available: max(1, size)))
    }

    func acquire() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let result: Result<Void, any Error>? = state.withLock { state in
                if let error = state.error { return .failure(error) }
                if state.available > 0 {
                    state.available -= 1
                    state.inFlight += 1
                    return .success(())
                }
                state.waiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func release(_ error: (any Error)?) {
        let (wake, drained, failure): ([CheckedContinuation<Void, any Error>], [CheckedContinuation<Void, any Error>], (any Error)?) = state.withLock { state in
            state.inFlight -= 1
            if let error, state.error == nil { state.error = error }
            if let failure = state.error {
                let all = state.waiters
                state.waiters.removeAll()
                let drainers = state.inFlight == 0 ? state.drainers : []
                if state.inFlight == 0 { state.drainers.removeAll() }
                return (all, drainers, failure)
            }
            if !state.waiters.isEmpty {
                state.inFlight += 1
                return ([state.waiters.removeFirst()], [], nil)
            }
            state.available += 1
            if state.inFlight == 0 {
                let drainers = state.drainers
                state.drainers.removeAll()
                return ([], drainers, nil)
            }
            return ([], [], nil)
        }
        for continuation in wake {
            if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
        }
        for continuation in drained {
            if let failure { continuation.resume(throwing: failure) } else { continuation.resume() }
        }
    }

    /// Waits until every send has been taken by the stack.
    func drain() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let result: Result<Void, any Error>? = state.withLock { state in
                if let error = state.error { return .failure(error) }
                if state.inFlight == 0 { return .success(()) }
                state.drainers.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func abort(_ error: any Error) {
        let pending: [CheckedContinuation<Void, any Error>] = state.withLock { state in
            if state.error == nil { state.error = error }
            let pending = state.waiters + state.drainers
            state.waiters.removeAll()
            state.drainers.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume(throwing: error) }
    }
}

import Foundation
import Network
import Synchronization
import os

public enum ChannelError: Error, Sendable {
    case notReady
    case closed
    case connectionFailed(String)
    case cancelled
}

/// A framed, bidirectional message stream over one `NWConnection`.
///
/// Sends are serialized by the actor; inbound messages are read with `receive()`, which returns
/// `nil` on clean close and throws on failure.
///
/// After `encrypt(with:)` (or `send(_:thenEncryptWith:)`) every frame travels as a sealed record
/// (`SessionCrypto`). A sealed record that arrives before this side has its keys waits for them;
/// a plain frame that arrives after is a downgrade and ends the channel.
public actor MessageChannel {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "channel")
    private var isStarted = false
    private(set) public var isClosed = false

    // Inbound queue: messages wait here until `receive()` takes them; at most one waiter.
    private var pending: [Message] = []
    private var waiter: CheckedContinuation<Message?, any Error>?
    private var terminalError: (any Error)?
    /// When set, the receive loop stops reading once this many messages wait unread, so a slow
    /// consumer (a file being written to disk) pushes back through TCP instead of buffering.
    private let maxBufferedMessages: Int?
    private var drainWaiter: CheckedContinuation<Void, Never>?
    /// Seals outgoing frames once the connection is encrypted. Locked, not actor state, because
    /// the hot path sends from any isolation: sealing and handing the record to the connection
    /// happen under one lock, so the record counter follows the order on the wire.
    private nonisolated let sealer = Mutex<RecordSealer?>(nil)
    private var opener: RecordOpener?
    /// The receive loop, holding a sealed record that came before the keys.
    private var keyWaiter: CheckedContinuation<Void, Never>?

    /// Whether frames in both directions are sealed records now.
    public var isEncrypted: Bool { opener != nil }

    public nonisolated var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }
    public nonisolated var endpoint: NWEndpoint { connection.endpoint }

    public init(connection: NWConnection, label: String = "vantage.channel", maxBufferedMessages: Int? = nil) {
        self.connection = connection
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
        self.maxBufferedMessages = maxBufferedMessages
    }

    /// Opens the connection and starts the receive loop. Resolves once the connection is ready.
    public func start() async throws {
        guard !isStarted else { return }
        isStarted = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            let box = ResumeOnce(cont)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    box.resume(.success(()))
                    Task { await self?.receiveLoop() }
                case .failed(let error):
                    box.resume(.failure(ChannelError.connectionFailed(error.localizedDescription)))
                    Task { await self?.finish(error: error) }
                case .cancelled:
                    box.resume(.failure(ChannelError.cancelled))
                    Task { await self?.finish(error: nil) }
                case .waiting(let error):
                    // Waiting means no viable path yet; surface as failure quickly so callers can retry.
                    box.resume(.failure(ChannelError.connectionFailed(error.localizedDescription)))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Returns the next message from the peer, or `nil` once the channel has closed cleanly.
    /// Single consumer: callers must not overlap `receive()` calls.
    public func receive() async throws -> Message? {
        if !pending.isEmpty {
            let message = pending.removeFirst()
            if let drainWaiter, pending.count < (maxBufferedMessages ?? .max) {
                self.drainWaiter = nil
                drainWaiter.resume()
            }
            return message
        }
        if let terminalError { throw terminalError }
        if isClosed { return nil }
        precondition(waiter == nil, "MessageChannel.receive() called concurrently")
        return try await withCheckedThrowingContinuation { cont in
            waiter = cont
        }
    }

    private func deliver(_ message: Message) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            pending.append(message)
        }
    }

    /// Sends a message and waits until the network stack has accepted it.
    public func send(_ message: Message) async throws {
        guard !isClosed else { throw ChannelError.closed }
        let frame = try message.encodedFrame()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            transmit(frame) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    /// Seals everything from now on with `keys`, both ways. The client calls this once the
    /// host's challenge checks out, before it sends `authenticate`; the client side of a file
    /// channel right after `attachMedia`, and the host side once it has looked up the token.
    public func encrypt(with keys: SessionKeys) {
        installOpener(keys)
        sealer.withLock { $0 = RecordSealer(key: keys.sendKey) }
    }

    /// Sends `message` as it is, then seals everything after it: the host's `challenge`, which
    /// carries its key share. The receive side switches first, since the peer's next frame is
    /// already sealed.
    public func send(_ message: Message, thenEncryptWith keys: SessionKeys) async throws {
        installOpener(keys)
        try await send(message)
        sealer.withLock { $0 = RecordSealer(key: keys.sendKey) }
    }

    private func installOpener(_ keys: SessionKeys) {
        precondition(opener == nil, "MessageChannel is already encrypted")
        opener = RecordOpener(key: keys.receiveKey)
        if let keyWaiter {
            self.keyWaiter = nil
            keyWaiter.resume()
        }
    }

    /// Tests only: a frame that skips the sealer, as something splicing into the stream would send.
    func sendUnsealedForTesting(_ message: Message) async throws {
        let frame = try message.encodedFrame()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Hands one encoded frame to the connection, sealed when the channel is encrypted.
    private nonisolated func transmit(_ frame: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        sealer.withLock { sealer in
            var content = frame
            if sealer != nil {
                do { content = try sealer!.seal(frame) } catch { completion(error); return }
            }
            connection.send(content: content, completion: .contentProcessed { error in
                completion(error.map { ChannelError.connectionFailed($0.localizedDescription) })
            })
        }
    }

    /// Hands a message to the connection now, in call order, and reports when the network stack
    /// has taken it (`.contentProcessed`) or failed. Lets a bulk sender keep a few messages in
    /// flight while still pacing to the link.
    public nonisolated func send(_ message: Message, completion: @escaping @Sendable ((any Error)?) -> Void) {
        let frame: Data
        do { frame = try message.encodedFrame() } catch { completion(error); return }
        transmit(frame, completion: completion)
    }

    /// Fire-and-forget send for hot-path messages (video, cursor, input). Safe to call from any
    /// isolation; a send failure is surfaced by the receive loop ending, so it is ignored here.
    public nonisolated func sendDetached(_ message: Message) {
        guard let frame = try? message.encodedFrame() else { return }
        transmit(frame) { _ in }
    }

    public func close() {
        finish(error: nil)
    }

    private func finish(error: (any Error)?) {
        guard !isClosed else { return }
        isClosed = true
        terminalError = error
        if let waiter {
            self.waiter = nil
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) }
        }
        if let drainWaiter {
            self.drainWaiter = nil
            drainWaiter.resume()
        }
        if let keyWaiter {
            self.keyWaiter = nil
            keyWaiter.resume()
        }
        connection.cancel()
    }

    private func receiveLoop() async {
        do {
            while !isClosed {
                let headerData = try await receiveExactly(Frame.headerLength)
                let message: Message
                if headerData.first == SessionCrypto.recordMagic {
                    let sealed = try await receiveExactly(try RecordOpener.sealedLength(ofHeader: headerData))
                    // The peer switched first (the host's challenge, a file channel's attach):
                    // hold the record until this side has the keys, or the channel closes.
                    if opener == nil { await withCheckedContinuation { keyWaiter = $0 } }
                    guard !isClosed else { break }
                    guard var opener else { throw RecordError.malformed }
                    let frame = try opener.open(header: headerData, sealed: sealed)
                    self.opener = opener
                    message = try Self.decodeFrame(frame)
                } else {
                    guard opener == nil else { throw RecordError.plaintextAfterEncryption }
                    let header = try Frame.Header.decode(headerData)
                    let payload = header.length == 0 ? Data() : try await receiveExactly(Int(header.length))
                    message = try Message.decode(kind: header.kind, payload: payload)
                }
                deliver(message)
                if let maxBufferedMessages, pending.count >= maxBufferedMessages, !isClosed {
                    await withCheckedContinuation { drainWaiter = $0 }
                }
            }
        } catch {
            if !isClosed {
                log.debug("receive loop ended: \(error.localizedDescription)")
            }
            finish(error: (error as? ChannelError) == .closed ? nil : error)
        }
    }

    /// One whole frame opened from a record: its header must account for every byte.
    private static func decodeFrame(_ frame: Data) throws -> Message {
        let header = try Frame.Header.decode(frame.prefix(Frame.headerLength))
        guard Int(header.length) == frame.count - Frame.headerLength else { throw RecordError.malformed }
        return try Message.decode(kind: header.kind, payload: Data(frame.dropFirst(Frame.headerLength)))
    }

    /// Reads `length` bytes by taking whatever has arrived and appending. Never ask
    /// `NWConnection` for a large `minimumIncompleteLength`: on a Mac with a content filter
    /// (Little Snitch here, macOS 27), non-loopback connections run through Network.framework's
    /// `ne_filter` protocol, which silently dropped chunks of the stream whenever a receive
    /// waited for 16 KB or more — a 4K keyframe arrived with holes and the next header read as
    /// `badMagic`. A 1-byte minimum is clean there.
    private func receiveExactly(_ length: Int) async throws -> Data {
        let first = try await receiveAvailable(upTo: length)
        if first.count == length { return first }
        var buffer = Data(capacity: length)
        buffer.append(first)
        while buffer.count < length {
            buffer.append(try await receiveAvailable(upTo: length - buffer.count))
        }
        return buffer
    }

    private func receiveAvailable(upTo maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { content, _, _, error in
                if let error {
                    cont.resume(throwing: ChannelError.connectionFailed(error.localizedDescription))
                } else if let content, !content.isEmpty {
                    cont.resume(returning: content)
                } else {
                    cont.resume(throwing: ChannelError.closed)
                }
            }
        }
    }
}

extension ChannelError: Equatable {
    public static func == (lhs: ChannelError, rhs: ChannelError) -> Bool {
        switch (lhs, rhs) {
        case (.notReady, .notReady), (.closed, .closed), (.cancelled, .cancelled): true
        case (.connectionFailed(let a), .connectionFailed(let b)): a == b
        default: false
        }
    }
}

/// Guards a continuation so racing state callbacks resume it at most once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, any Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}

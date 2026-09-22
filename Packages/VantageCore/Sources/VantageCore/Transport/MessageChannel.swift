import Foundation
import Network
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

    public nonisolated var remoteEndpoint: NWEndpoint? { connection.currentPath?.remoteEndpoint }
    public nonisolated var endpoint: NWEndpoint { connection.endpoint }

    public init(connection: NWConnection, label: String = "vantage.channel") {
        self.connection = connection
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
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
        if !pending.isEmpty { return pending.removeFirst() }
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
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: ChannelError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Fire-and-forget send for hot-path messages (video, cursor, input). Safe to call from any
    /// isolation; a send failure is surfaced by the receive loop ending, so it is ignored here.
    public nonisolated func sendDetached(_ message: Message) {
        guard let frame = try? message.encodedFrame() else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
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
        connection.cancel()
    }

    private func receiveLoop() async {
        do {
            while !isClosed {
                let headerData = try await receiveExactly(Frame.headerLength)
                let header = try Frame.Header.decode(headerData)
                let payload = header.length == 0 ? Data() : try await receiveExactly(Int(header.length))
                let message = try Message.decode(kind: header.kind, payload: payload)
                deliver(message)
            }
        } catch {
            if !isClosed {
                log.debug("receive loop ended: \(error.localizedDescription)")
            }
            finish(error: (error as? ChannelError) == .closed ? nil : error)
        }
    }

    private func receiveExactly(_ length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { content, _, isComplete, error in
                if let error {
                    cont.resume(throwing: ChannelError.connectionFailed(error.localizedDescription))
                } else if let content, content.count == length {
                    cont.resume(returning: content)
                } else if isComplete {
                    cont.resume(throwing: ChannelError.closed)
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

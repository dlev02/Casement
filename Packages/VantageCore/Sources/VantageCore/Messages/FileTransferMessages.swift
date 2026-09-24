import Foundation

// MARK: - File transfer
//
// Files travel on a second TCP connection (the "file channel"), so a 256 KiB chunk never sits in
// front of video or input on the main stream. The client opens it right after authenticating,
// with `attachMedia{sessionToken}` as its first message; the token is the one the host returned
// in `AuthResult.sessionToken`. Every kind here is gated: the client asks with
// `Hello.features.fileTransfer`, the host answers with a token and `HostCapabilities.fileTransfer`,
// and these kinds only ever appear on the file channel, so older peers never see them.
//
// One file, either direction: sender `fileOffer` → receiver `fileAccept` (or a rejection) → sender
// `fileChunk`s in order → sender `fileComplete{sha256}` → receiver `fileResult`. Either side may
// send `fileCancel` at any point. A sender re-offers an interrupted file with the same `id`; a
// receiver that kept the partial answers `resumeOffset` with how much it has, and the sender
// streams from there (the SHA-256 still covers the whole file). Peers that predate resume answer
// 0 and start over, which the protocol always allowed.

/// Sender → receiver: a file is ready to send.
public struct FileOffer: Codable, Sendable, Equatable {
    public var id: UUID
    /// The sender's name for the file. Untrusted: the receiver sanitises it before use.
    public var name: String
    public var byteCount: UInt64
    public var modified: Date?
    /// Uniform type identifier, when the sender knows it.
    public var uti: String?

    public init(id: UUID = UUID(), name: String, byteCount: UInt64, modified: Date? = nil, uti: String? = nil) {
        self.id = id
        self.name = name
        self.byteCount = byteCount
        self.modified = modified
        self.uti = uti
    }
}

/// Receiver → sender: go ahead from `resumeOffset`, or not at all when `rejected` is set.
public struct FileAccept: Codable, Sendable, Equatable {
    public var id: UUID
    /// Where the sender should start: 0 for a fresh file, or the size of the partial file the
    /// receiver kept from an earlier, interrupted attempt with the same `id`.
    public var resumeOffset: UInt64
    /// A user-facing reason the receiver won't take the file; nil means accepted.
    public var rejected: String?

    public init(id: UUID, resumeOffset: UInt64 = 0, rejected: String? = nil) {
        self.id = id
        self.resumeOffset = resumeOffset
        self.rejected = rejected
    }

    public static func rejected(_ id: UUID, reason: String) -> FileAccept {
        FileAccept(id: id, rejected: reason)
    }
}

/// Sender → receiver: every byte has been sent; this is the SHA-256 of the whole file.
public struct FileComplete: Codable, Sendable, Equatable {
    public var id: UUID
    public var sha256: Data

    public init(id: UUID, sha256: Data) {
        self.id = id
        self.sha256 = sha256
    }
}

/// Receiver → sender: how it ended.
public struct FileResult: Codable, Sendable, Equatable {
    public var id: UUID
    public var ok: Bool
    /// The name the file was saved under (after sanitising and de-duplicating).
    public var savedName: String?
    /// A user-facing reason when `ok` is false.
    public var error: String?

    public init(id: UUID, ok: Bool, savedName: String? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.savedName = savedName
        self.error = error
    }
}

/// Either side: stop this transfer. The receiver deletes what it has (including a partial file
/// kept for a resume); no result follows.
public struct FileCancel: Codable, Sendable, Equatable {
    public var id: UUID
    public init(id: UUID) { self.id = id }
}

/// Sender → receiver: one piece of the file, at an explicit offset.
///
/// Wire layout (little-endian): `id 16 B | offset u64 | bytes`. Sent as `fileChunkToClient` (103)
/// by the host and `fileChunkToHost` (124) by the client.
public struct FileChunk: Sendable, Equatable {
    public var id: UUID
    public var offset: UInt64
    public var data: Data

    /// Bytes before the file data.
    public static let headerLength = 24
    /// What senders put in one chunk (256 KiB, far below `Frame.maxPayloadLength`).
    public static let standardSize = 256 * 1024

    public init(id: UUID, offset: UInt64, data: Data) {
        self.id = id
        self.offset = offset
        self.data = data
    }

    func encode() -> Data {
        var writer = BinaryWriter(capacity: Self.headerLength + data.count)
        var uuid = id.uuid
        withUnsafeBytes(of: &uuid) { writer.writeRaw(Data($0)) }
        writer.write(offset)
        writer.writeRaw(data)
        return writer.data
    }

    static func decode(_ payload: Data) throws -> FileChunk {
        var reader = BinaryReader(payload)
        let idBytes = try reader.readRaw(16)
        let uuid = idBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        let offset = try reader.readUInt64()
        return FileChunk(id: UUID(uuid: uuid), offset: offset, data: reader.readRemaining())
    }
}

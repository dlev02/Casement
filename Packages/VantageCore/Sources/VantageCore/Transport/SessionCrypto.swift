import CryptoKit
import Foundation

/// End-to-end encryption for connections that don't run inside Tailscale's WireGuard tunnel (the
/// local network, a cable).
///
/// Each side makes a fresh X25519 key share per connection (`Hello.clientKeyShare`,
/// `Challenge.hostKeyShare`), and both Ed25519 signatures of the handshake cover both shares
/// (`AuthTranscript.hostBytes(… clientKeyShare:hostKeyShare:)`, `clientBytes(… shares)`), so a
/// device in the middle can't swap in a share of its own without breaking a signature. The shared
/// secret goes through HKDF-SHA256, salted with a hash of the whole handshake, into one
/// ChaCha20-Poly1305 key per direction and a secret for the session's file channel. From the
/// challenge on, every frame travels as a sealed record (`RecordSealer`): fresh keys per
/// connection give forward secrecy, and a counter nonce per direction rejects a replayed,
/// reordered or dropped record.
///
/// ```
/// record: | 'E' | 0 | 0 0 | sealed length (u32 LE) | ChaCha20-Poly1305(frame) ‖ tag (16) |
/// nonce:  4 zero bytes ‖ record counter (u64 LE), from 0 in each direction
/// aad:    the record's 8-byte header
/// ```
public enum SessionCrypto {
    /// An X25519 public key share is this long.
    public static let shareLength = 32
    /// First byte of a sealed record (a plain frame starts with `Frame.magic`, "V").
    public static let recordMagic: UInt8 = 0x45 // "E"
    public static let tagLength = 16
    /// A sealed record holds at most one whole frame plus its tag.
    public static let maxSealedLength = UInt32(Frame.headerLength) + Frame.maxPayloadLength + UInt32(tagLength)

    static let transcriptDomain = Data("casement-session-v1".utf8)

    /// The salt both sides feed HKDF: everything the handshake agreed, in a fixed order.
    static func transcriptHash(clientNonce: Data, hostNonce: Data, hostPublicKey: Data, clientPublicKey: Data,
                               clientKeyShare: Data, hostKeyShare: Data) -> Data {
        var hash = SHA256()
        for part in [transcriptDomain, clientNonce, hostNonce, hostPublicKey, clientPublicKey, clientKeyShare, hostKeyShare] {
            hash.update(data: part)
        }
        return Data(hash.finalize())
    }
}

/// One side's ephemeral X25519 key for one connection. Never stored, never reused.
public struct SessionKeyShare: Sendable {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    /// The 32-byte public share sent to the other side.
    public var publicShare: Data { privateKey.publicKey.rawRepresentation }

    /// The session's keys, from the other side's share and everything the handshake agreed.
    /// Throws for a share that isn't a valid X25519 key (including the all-zero result of a
    /// low-order point, which CryptoKit refuses).
    public func sessionKeys(peerShare: Data, role: SessionKeys.Role, clientNonce: Data, hostNonce: Data, hostPublicKey: Data,
                            clientPublicKey: Data) throws -> SessionKeys {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerShare)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let (clientShare, hostShare) = role == .client ? (publicShare, peerShare) : (peerShare, publicShare)
        let salt = SessionCrypto.transcriptHash(clientNonce: clientNonce, hostNonce: hostNonce, hostPublicKey: hostPublicKey,
                                                clientPublicKey: clientPublicKey, clientKeyShare: clientShare, hostKeyShare: hostShare)
        func derive(_ label: String) -> SymmetricKey {
            shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(label.utf8), outputByteCount: 32)
        }
        return SessionKeys(role: role, clientToHost: derive("casement c2h"), hostToClient: derive("casement h2c"),
                           fileSecret: derive("casement file"))
    }
}

/// The keys one connection seals and opens records with, from the point of view of `role`.
public struct SessionKeys: Sendable {
    public enum Role: Sendable { case client, host }

    public let role: Role
    let clientToHost: SymmetricKey
    let hostToClient: SymmetricKey
    /// Feeds the keys of this session's file channel (`fileChannelKeys(token:)`).
    let fileSecret: SymmetricKey

    init(role: Role, clientToHost: SymmetricKey, hostToClient: SymmetricKey, fileSecret: SymmetricKey) {
        self.role = role
        self.clientToHost = clientToHost
        self.hostToClient = hostToClient
        self.fileSecret = fileSecret
    }

    var sendKey: SymmetricKey { role == .client ? clientToHost : hostToClient }
    var receiveKey: SymmetricKey { role == .client ? hostToClient : clientToHost }

    /// Keys for the file channel that joins this session with `token` (`attachMedia`). The token
    /// only ever travelled inside this session's sealed `authResult`, and the keys also need this
    /// session's secret, so only the device that signed in can open the channel's records.
    public func fileChannelKeys(token: Data) -> SessionKeys {
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: fileSecret, salt: token, info: Data(label.utf8), outputByteCount: 32)
        }
        return SessionKeys(role: role, clientToHost: derive("casement file c2h"), hostToClient: derive("casement file h2c"),
                           fileSecret: derive("casement file next"))
    }
}

public enum RecordError: Error, Sendable, Equatable {
    /// The record didn't open: tampered with, out of order, replayed, or sealed with other keys.
    case authenticationFailed
    case malformed
    /// A plain frame arrived after the connection switched to sealed records (a downgrade).
    case plaintextAfterEncryption
    /// This direction has sealed 2^64 records, which a connection never reaches.
    case exhausted
}

/// Seals frames into records for one direction of one connection.
struct RecordSealer: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    static func header(sealedLength: Int) -> Data {
        var writer = BinaryWriter(capacity: Frame.headerLength)
        writer.write(SessionCrypto.recordMagic)
        writer.write(UInt8(0))
        writer.write(UInt16(0))
        writer.write(UInt32(sealedLength))
        return writer.data
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.littleEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes) // 12 bytes, always valid
    }

    /// A whole record (header, ciphertext, tag) for one encoded frame.
    mutating func seal(_ frame: Data) throws -> Data {
        guard counter < .max else { throw RecordError.exhausted }
        let header = Self.header(sealedLength: frame.count + SessionCrypto.tagLength)
        let box = try ChaChaPoly.seal(frame, using: key, nonce: Self.nonce(counter), authenticating: header)
        counter += 1
        var record = Data(capacity: header.count + frame.count + SessionCrypto.tagLength)
        record.append(header)
        record.append(box.ciphertext)
        record.append(box.tag)
        return record
    }
}

/// Opens records for the other direction, in order.
struct RecordOpener: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    /// The sealed length a record header announces, after checking it is one.
    static func sealedLength(ofHeader header: Data) throws -> Int {
        var reader = BinaryReader(header)
        guard try reader.readUInt8() == SessionCrypto.recordMagic, try reader.readUInt8() == 0, try reader.readUInt16() == 0 else {
            throw RecordError.malformed
        }
        let length = try reader.readUInt32()
        guard length >= UInt32(SessionCrypto.tagLength + Frame.headerLength), length <= SessionCrypto.maxSealedLength else {
            throw RecordError.malformed
        }
        return Int(length)
    }

    /// The frame inside a record, given the record's header and its sealed bytes.
    mutating func open(header: Data, sealed: Data) throws -> Data {
        guard sealed.count >= SessionCrypto.tagLength else { throw RecordError.malformed }
        let split = sealed.index(sealed.endIndex, offsetBy: -SessionCrypto.tagLength)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: RecordSealer.nonce(counter), ciphertext: sealed[..<split], tag: sealed[split...])
            let frame = try ChaChaPoly.open(box, using: key, authenticating: header)
            counter += 1
            return frame
        } catch {
            throw RecordError.authenticationFailed
        }
    }
}

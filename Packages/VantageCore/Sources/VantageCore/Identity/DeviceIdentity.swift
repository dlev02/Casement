import CryptoKit
import Foundation

/// Long-lived Ed25519 identity for a device (client or host).
public struct DeviceIdentity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public init() {
        self.privateKey = Curve25519.Signing.PrivateKey()
    }

    public init(rawRepresentation: Data) throws {
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public var publicKeyData: Data { privateKey.publicKey.rawRepresentation }
    public var rawRepresentation: Data { privateKey.rawRepresentation }

    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }

    /// Short human-readable fingerprint (first 8 bytes of SHA-256 of the public key, hex).
    public var fingerprint: String {
        Self.fingerprint(of: publicKeyData)
    }

    public static func fingerprint(of publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// What a connection is for. Bound into the client's signature, so a signature a client made for
/// an availability check can't be replayed to open a screen session.
public enum AuthPurpose: UInt8, Sendable, CaseIterable {
    case screen = 0
    case probe = 1
    case files = 2

    /// The purpose a hello declares (the host side computes it from the same hello).
    public init(hello: Hello) {
        if hello.isReadinessProbe == true { self = .probe }
        else if hello.features?.filesOnly == true { self = .files }
        else { self = .screen }
    }
}

/// Builds and verifies the handshake transcripts both sides sign and verify.
///
/// Two generations. A client that sends `Hello.clientNonce` expects the host to sign
/// `hostBytes` (its proof of identity) and itself signs `clientBytes`, which binds both nonces,
/// both keys and the connection's purpose: a signature made for one host, or one kind of
/// connection, is useless anywhere else. A client without a nonce signs the older `bytes`, which
/// hosts still accept until every client has updated.
public enum AuthTranscript {
    /// The older client transcript: `"vantage-auth-v1" ‖ nonce ‖ hostPublicKey ‖ clientPublicKey`.
    public static let domain = Data("vantage-auth-v1".utf8)
    /// `"vantage-auth-v2" ‖ clientNonce ‖ hostNonce ‖ hostPublicKey ‖ clientPublicKey ‖ purpose`.
    public static let clientDomain = Data("vantage-auth-v2".utf8)
    /// `"vantage-host-auth-v1" ‖ clientNonce ‖ hostNonce ‖ hostPublicKey ‖ clientPublicKey`.
    public static let hostDomain = Data("vantage-host-auth-v1".utf8)
    /// An encrypted connection's client transcript: `clientBytes`' fields under this domain, then
    /// both key shares (`SessionCrypto`).
    public static let encryptedClientDomain = Data("vantage-auth-v3".utf8)
    /// An encrypted connection's host transcript: `hostBytes`' fields under this domain, then both
    /// key shares.
    public static let encryptedHostDomain = Data("vantage-host-auth-v2".utf8)
    /// Every nonce is this long, so the plain concatenations above can't be shifted.
    public static let nonceLength = 32

    public static func bytes(nonce: Data, hostPublicKey: Data, clientPublicKey: Data) -> Data {
        var data = Data()
        data.append(domain)
        data.append(nonce)
        data.append(hostPublicKey)
        data.append(clientPublicKey)
        return data
    }

    public static func verify(signature: Data, nonce: Data, hostPublicKey: Data, clientPublicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: clientPublicKey) else { return false }
        return key.isValidSignature(signature, for: bytes(nonce: nonce, hostPublicKey: hostPublicKey, clientPublicKey: clientPublicKey))
    }

    /// What the client signs: 15 + 32 + 32 + 32 + 32 + 1 = 144 bytes, or with both key shares
    /// (an encrypted connection) under `encryptedClientDomain`, 208 bytes.
    public static func clientBytes(clientNonce: Data, hostNonce: Data, hostPublicKey: Data, clientPublicKey: Data, purpose: AuthPurpose,
                                   keyShares: KeyShares? = nil) -> Data {
        var data = Data()
        data.append(keyShares == nil ? clientDomain : encryptedClientDomain)
        data.append(clientNonce)
        data.append(hostNonce)
        data.append(hostPublicKey)
        data.append(clientPublicKey)
        data.append(purpose.rawValue)
        if let keyShares {
            data.append(keyShares.client)
            data.append(keyShares.host)
        }
        return data
    }

    /// Checks the client's signature over `clientBytes`. False for a nonce of the wrong length.
    public static func verifyClient(signature: Data, clientNonce: Data, hostNonce: Data, hostPublicKey: Data, clientPublicKey: Data,
                                    purpose: AuthPurpose, keyShares: KeyShares? = nil) -> Bool {
        guard clientNonce.count == nonceLength, hostNonce.count == nonceLength,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: clientPublicKey) else { return false }
        return key.isValidSignature(signature, for: clientBytes(clientNonce: clientNonce, hostNonce: hostNonce, hostPublicKey: hostPublicKey,
                                                                clientPublicKey: clientPublicKey, purpose: purpose, keyShares: keyShares))
    }

    /// What the host signs: 20 + 32 + 32 + 32 + 32 = 148 bytes, or with both key shares under
    /// `encryptedHostDomain`, 212 bytes.
    public static func hostBytes(clientNonce: Data, hostNonce: Data, hostPublicKey: Data, clientPublicKey: Data, keyShares: KeyShares? = nil) -> Data {
        var data = Data()
        data.append(keyShares == nil ? hostDomain : encryptedHostDomain)
        data.append(clientNonce)
        data.append(hostNonce)
        data.append(hostPublicKey)
        data.append(clientPublicKey)
        if let keyShares {
            data.append(keyShares.client)
            data.append(keyShares.host)
        }
        return data
    }

    /// Checks the host's signature over `hostBytes` with the key the challenge names.
    public static func verifyHost(signature: Data, clientNonce: Data, hostNonce: Data, hostPublicKey: Data, clientPublicKey: Data,
                                  keyShares: KeyShares? = nil) -> Bool {
        guard clientNonce.count == nonceLength, hostNonce.count == nonceLength,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: hostPublicKey) else { return false }
        return key.isValidSignature(signature, for: hostBytes(clientNonce: clientNonce, hostNonce: hostNonce, hostPublicKey: hostPublicKey,
                                                              clientPublicKey: clientPublicKey, keyShares: keyShares))
    }

    /// Both sides' X25519 shares on an encrypted connection, each `SessionCrypto.shareLength` bytes.
    public struct KeyShares: Sendable, Equatable {
        public var client: Data
        public var host: Data
        public init(client: Data, host: Data) {
            self.client = client
            self.host = host
        }
    }

    public static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// Six-digit pairing code, zero-padded.
    public static func randomPairingCode() -> String {
        String(format: "%06d", Int.random(in: 0 ..< 1_000_000))
    }
}

/// The client's check of a host before it signs anything: the challenge must carry the host's
/// signature over this connection's nonce, and the key must be the one remembered for the device
/// from its first connection (the pairing). Without this a device that looked like a saved host
/// could collect the client's signature, or its pairing code, and use either on the real one.
public enum HostIdentityCheck {
    public enum Failure: Error, Equatable, Sendable {
        /// The challenge has no `hostSignature`: the host predates host authentication.
        case unsigned
        /// The signature doesn't verify under the key the challenge names.
        case badSignature
        /// The key isn't the one remembered for this device.
        case changed
        /// This connection must be encrypted (it isn't inside Tailscale) and the host didn't
        /// answer the device's key share: it predates local connections.
        case unencrypted
    }

    /// Returns the host's public key, verified, for the caller to remember when `expected` was nil.
    /// `clientKeyShare` is the share the hello offered: when the challenge answers it, the host's
    /// signature must cover both shares.
    public static func verify(_ challenge: Challenge, clientNonce: Data, clientPublicKey: Data, expected: Data?,
                              clientKeyShare: Data? = nil) throws(Failure) -> Data {
        guard let signature = challenge.hostSignature else { throw .unsigned }
        let shares = clientKeyShare.flatMap { client in challenge.hostKeyShare.map { AuthTranscript.KeyShares(client: client, host: $0) } }
        guard AuthTranscript.verifyHost(signature: signature, clientNonce: clientNonce, hostNonce: challenge.nonce,
                                        hostPublicKey: challenge.hostPublicKey, clientPublicKey: clientPublicKey,
                                        keyShares: shares) else { throw .badSignature }
        if let expected, expected != challenge.hostPublicKey { throw .changed }
        return challenge.hostPublicKey
    }
}

/// The device's side of one handshake: the nonce (and, off the tailnet, the key share) its hello
/// carries, the check of the host's challenge, what it signs, and the keys that seal the rest.
/// The screen, availability check, files-only and input-only connections all use it.
public struct ClientHandshake: Sendable {
    public let clientNonce = AuthTranscript.randomNonce()
    private let keyShare: SessionKeyShare?
    /// The connection runs outside Tailscale, so it must end up encrypted.
    public let requiresEncryption: Bool
    private let clientPublicKey: Data

    /// `offersEncryption`: send a key share (any route that isn't on the tailnet; a host that
    /// predates it ignores the share). `requiresEncryption`: refuse a host that doesn't answer it
    /// (a route known to be the local network, where nothing else protects the stream).
    public init(clientPublicKey: Data, offersEncryption: Bool, requiresEncryption: Bool) {
        self.clientPublicKey = clientPublicKey
        self.keyShare = offersEncryption || requiresEncryption ? SessionKeyShare() : nil
        self.requiresEncryption = requiresEncryption
    }

    /// The hello's share, nil when this connection doesn't offer one.
    public var clientKeyShare: Data? { keyShare?.publicShare }

    /// Fills in the hello's nonce and key share.
    public func prepare(_ hello: Hello) -> Hello {
        var hello = hello
        hello.clientNonce = clientNonce
        hello.clientKeyShare = clientKeyShare
        return hello
    }

    /// Checks the challenge (`HostIdentityCheck`) and that it's encrypted when it has to be.
    public func verify(_ challenge: Challenge, expected: Data?) throws(HostIdentityCheck.Failure) -> Data {
        let key = try HostIdentityCheck.verify(challenge, clientNonce: clientNonce, clientPublicKey: clientPublicKey, expected: expected,
                                               clientKeyShare: clientKeyShare)
        if requiresEncryption, keyShares(challenge) == nil { throw .unencrypted }
        return key
    }

    /// What the device signs for `purpose`, after `verify`.
    public func transcript(for challenge: Challenge, purpose: AuthPurpose) -> Data {
        AuthTranscript.clientBytes(clientNonce: clientNonce, hostNonce: challenge.nonce, hostPublicKey: challenge.hostPublicKey,
                                   clientPublicKey: clientPublicKey, purpose: purpose, keyShares: keyShares(challenge))
    }

    /// The keys for everything after the challenge, or nil when the host answered in the clear
    /// (inside Tailscale, or a host that predates local connections).
    public func sessionKeys(for challenge: Challenge) throws -> SessionKeys? {
        guard let keyShare, let shares = keyShares(challenge) else { return nil }
        return try keyShare.sessionKeys(peerShare: shares.host, role: .client, clientNonce: clientNonce, hostNonce: challenge.nonce,
                                        hostPublicKey: challenge.hostPublicKey, clientPublicKey: clientPublicKey)
    }

    private func keyShares(_ challenge: Challenge) -> AuthTranscript.KeyShares? {
        guard let client = clientKeyShare, let host = challenge.hostKeyShare, host.count == SessionCrypto.shareLength else { return nil }
        return AuthTranscript.KeyShares(client: client, host: host)
    }
}

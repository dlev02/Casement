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

/// Builds and verifies the challenge transcript both sides sign/verify.
public enum AuthTranscript {
    public static let domain = Data("vantage-auth-v1".utf8)

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

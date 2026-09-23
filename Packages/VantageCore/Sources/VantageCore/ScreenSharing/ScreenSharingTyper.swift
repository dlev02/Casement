import CommonCrypto
import CryptoKit
import Foundation
import Network

/// Types text through macOS's own Screen Sharing server (screensharingd, RFB on port 5900).
///
/// Third-party apps can't post keystrokes into secure fields or the lock screen (Secure Event
/// Input), but screensharingd is part of the OS and can — that's how Screens types a Mac password.
/// This client does the bare minimum: RFB 3.889 handshake, Apple Remote Desktop authentication
/// (security type 30, Diffie-Hellman → MD5 → AES-128-ECB credentials), ClientInit, KeyEvents,
/// then disconnects. It never requests framebuffer updates. It needs Screen Sharing (or Remote
/// Management) turned on for the Mac account whose username and password it's given.
public enum ScreenSharingTyper {
    public static let defaultPort: UInt16 = 5900

    public enum TypeError: Error, Sendable, Equatable {
        case unreachable(String)
        case notScreenSharing
        case unsupportedAuthentication([UInt8])
        case authenticationFailed(String)
        case protocolError(String)
        case timedOut
    }

    /// Connects, authenticates, types `text` (plus Return if asked), and disconnects.
    public static func type(_ text: String, pressReturn: Bool, host: String, port: UInt16 = defaultPort,
                            username: String, password: String, timeout: Duration = .seconds(12)) async throws {
        let events = keyEvents(for: text, pressReturn: pressReturn)
        let session = RFBConnection(host: host, port: port)
        defer { session.close() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await session.open()
                try await session.handshakeAndAuthenticate(username: username, password: password)
                for chunk in events.chunked(into: 16) {
                    try await session.send(Data(chunk.flatMap(\.bytes)))
                    try await Task.sleep(for: .milliseconds(15))
                }
                // Let the server consume the last events before the socket closes.
                try await Task.sleep(for: .milliseconds(150))
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                session.close() // fails any read still waiting on the socket
                throw TypeError.timedOut
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Checks the credentials without typing anything.
    public static func verify(host: String, port: UInt16 = defaultPort, username: String, password: String) async throws {
        try await type("", pressReturn: false, host: host, port: port, username: username, password: password)
    }

    // MARK: Key events

    struct KeyEvent: Equatable {
        var keysym: UInt32
        var down: Bool
        var bytes: [UInt8] {
            [4, down ? 1 : 0, 0, 0,
             UInt8(keysym >> 24), UInt8((keysym >> 16) & 0xFF), UInt8((keysym >> 8) & 0xFF), UInt8(keysym & 0xFF)]
        }
    }

    static let shiftKeysym: UInt32 = 0xFFE1
    static let returnKeysym: UInt32 = 0xFF0D
    static let tabKeysym: UInt32 = 0xFF09
    /// Characters that need Shift on a US keyboard. screensharingd maps a keysym to a key code and
    /// types it with whatever modifiers are held, so Shift has to be pressed explicitly.
    static let shiftedCharacters = Set(#"ABCDEFGHIJKLMNOPQRSTUVWXYZ~!@#$%^&*()_+{}|:"<>?"#.unicodeScalars.map(\.value))

    static func keysym(for scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
        case 0x0A, 0x0D: returnKeysym
        case 0x09: tabKeysym
        case 0x20...0x7E, 0xA0...0xFF: scalar.value          // Latin-1 keysyms equal their code points
        default: 0x0100_0000 | scalar.value                   // X11 Unicode keysym
        }
    }

    static func keyEvents(for text: String, pressReturn: Bool) -> [KeyEvent] {
        var events: [KeyEvent] = []
        for scalar in text.unicodeScalars {
            let sym = keysym(for: scalar)
            let shifted = shiftedCharacters.contains(scalar.value)
            if shifted { events.append(KeyEvent(keysym: shiftKeysym, down: true)) }
            events.append(KeyEvent(keysym: sym, down: true))
            events.append(KeyEvent(keysym: sym, down: false))
            if shifted { events.append(KeyEvent(keysym: shiftKeysym, down: false)) }
        }
        if pressReturn {
            events.append(KeyEvent(keysym: returnKeysym, down: true))
            events.append(KeyEvent(keysym: returnKeysym, down: false))
        }
        return events
    }

    // MARK: ARD authentication (security type 30)

    /// Builds the client's reply to the server's Diffie-Hellman parameters: the AES-encrypted
    /// credentials block followed by the client's public key.
    static func ardResponse(generator: [UInt8], prime: [UInt8], serverPublicKey: [UInt8],
                            username: String, password: String,
                            privateKey: [UInt8]? = nil, padding: [UInt8]? = nil) throws -> [UInt8] {
        // A 256-bit private exponent is the usual choice for finite-field DH (well past the
        // strength of the MD5/AES-128 that follows) and keeps a 4096-bit exchange fast on an iPad.
        let secret = privateKey ?? randomBytes(32)
        guard let clientPublic = ModularExponent.power(base: generator, exponent: secret, modulus: prime),
              let shared = ModularExponent.power(base: serverPublicKey, exponent: secret, modulus: prime)
        else { throw TypeError.protocolError("invalid Diffie-Hellman parameters") }
        let key = Array(Insecure.MD5.hash(data: shared))
        let credentials = credentialsBlock(username: username, password: password, padding: padding ?? randomBytes(128))
        guard let encrypted = aes128ECB(credentials, key: key) else { throw TypeError.protocolError("encryption failed") }
        return encrypted + clientPublic
    }

    /// 64 bytes of NUL-terminated UTF-8 username, then 64 of password; unused bytes are random.
    static func credentialsBlock(username: String, password: String, padding: [UInt8]) -> [UInt8] {
        var block = Array(padding.prefix(128))
        block += [UInt8](repeating: 0, count: 128 - block.count)
        for (offset, value) in [(0, username), (64, password)] {
            let utf8 = Array(value.utf8.prefix(63))
            block.replaceSubrange(offset..<(offset + utf8.count), with: utf8)
            block[offset + utf8.count] = 0
        }
        return block
    }

    static func aes128ECB(_ input: [UInt8], key: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, input, input.count, &output, output.count, &written)
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(written))
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return bytes
    }
}

/// A byte-exact RFB reader/writer over one NWConnection.
private final class RFBConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "vantage.screensharing")

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 5900,
                                  using: NWParameters(tls: nil, tcp: tcp))
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() { continuation.resume(throwing: ScreenSharingTyper.TypeError.unreachable(error.localizedDescription)) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: ScreenSharingTyper.TypeError.unreachable("cancelled")) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func close() { connection.cancel() }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: ScreenSharingTyper.TypeError.unreachable(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    func receive(_ count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: ScreenSharingTyper.TypeError.unreachable(error.localizedDescription))
                } else if let data, data.count == count {
                    continuation.resume(returning: Array(data))
                } else {
                    continuation.resume(throwing: ScreenSharingTyper.TypeError.protocolError(isComplete ? "connection closed" : "short read"))
                }
            }
        }
    }

    func receiveU16() async throws -> Int { let b = try await receive(2); return Int(b[0]) << 8 | Int(b[1]) }
    func receiveU32() async throws -> Int {
        let b = try await receive(4)
        return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    func handshakeAndAuthenticate(username: String, password: String) async throws {
        let greeting = try await receive(12)
        guard greeting.starts(with: Array("RFB ".utf8)) else { throw ScreenSharingTyper.TypeError.notScreenSharing }
        try await send(Data("RFB 003.889\n".utf8))

        let typeCount = Int(try await receive(1)[0])
        guard typeCount > 0 else {
            let reason = String(decoding: try await receive(try await receiveU32()), as: UTF8.self)
            throw ScreenSharingTyper.TypeError.protocolError(reason)
        }
        let types = try await receive(typeCount)
        guard types.contains(30) else { throw ScreenSharingTyper.TypeError.unsupportedAuthentication(types) }
        try await send(Data([30]))

        let generator = try await receive(2)
        let keyLength = try await receiveU16()
        guard (16...1024).contains(keyLength) else { throw ScreenSharingTyper.TypeError.protocolError("key length \(keyLength)") }
        let prime = try await receive(keyLength)
        let serverKey = try await receive(keyLength)
        let response = try ScreenSharingTyper.ardResponse(generator: generator, prime: prime, serverPublicKey: serverKey,
                                                          username: username, password: password)
        try await send(Data(response))

        let result = try await receiveU32()
        // Apple's 3.889 server sends no reason string after a failure (unlike RFB 3.8), so don't wait for one.
        guard result == 0 else {
            throw ScreenSharingTyper.TypeError.authenticationFailed("Screen Sharing rejected the username or password.")
        }

        try await send(Data([1])) // ClientInit, shared: don't disconnect other viewers
        _ = try await receive(20)  // ServerInit: width, height, pixel format
        _ = try await receive(try await receiveU32()) // desktop name
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

import Foundation

/// Which devices a host trusts and the pairing code it shows: the Keychain-backed trust store on
/// a Mac, an in-memory one in tests. `SessionAdmission` is the only thing that consults it.
public protocol PairingAuthority: AnyObject, Sendable {
    func isTrusted(_ publicKey: Data) -> Bool
    /// Checks a code the device typed; an accepted code is used up.
    func consumePairingCode(_ code: String) -> PairingCheck
    /// Records a device that just paired.
    func trust(_ publicKey: Data, name: String, model: String?)
}

public enum PairingCheck: Sendable, Equatable {
    case accepted
    case incorrect
    /// No code is on show, or it ran out (ten minutes, or five wrong guesses).
    case unavailable
}

/// The six-digit code a computer shows while pairing: made on demand, good for ten minutes and
/// one pairing, burned after five wrong guesses. A fixed code (DEBUG `--pairing-code`) never
/// expires but is still used up by a pairing or burned by guesses. Pure; the caller keeps it
/// under its lock and passes the clock.
public struct PairingCodes: Sendable {
    /// A code is burned after this many wrong guesses, so a peer gets 5 tries in a million.
    public static let maxAttempts = 5
    /// A code shown on the computer stops working after ten minutes.
    public static let lifetime: Duration = .seconds(10 * 60)

    private let fixedCode: String?
    private var active: String?
    private var issuedAt: ContinuousClock.Instant?
    private var failedAttempts = 0

    public init(fixedCode: String? = nil) {
        self.fixedCode = fixedCode
    }

    /// The code on show, if any.
    public var current: String? { active }

    /// Shows a fresh code, replacing any old one.
    @discardableResult
    public mutating func issue(now: ContinuousClock.Instant) -> String {
        let code = fixedCode ?? AuthTranscript.randomPairingCode()
        active = code
        issuedAt = now
        failedAttempts = 0
        return code
    }

    /// Checks a code the device typed. Returns whether the code on show was cleared by this
    /// check (used, expired, or burned), so the caller can tell its UI.
    public mutating func check(_ code: String, now: ContinuousClock.Instant) -> (result: PairingCheck, cleared: Bool) {
        guard let active else { return (.unavailable, false) }
        if fixedCode == nil, let issuedAt, now - issuedAt > Self.lifetime {
            clear()
            return (.unavailable, true)
        }
        guard Self.constantTimeEquals(active, code) else {
            failedAttempts += 1
            if failedAttempts >= Self.maxAttempts {
                clear()
                return (.incorrect, true)
            }
            return (.incorrect, false)
        }
        clear()
        return (.accepted, true)
    }

    /// Withdraws the code on show (Done, or its ten minutes ran out). True when there was one.
    @discardableResult
    public mutating func cancel() -> Bool {
        guard active != nil else { return false }
        clear()
        return true
    }

    private mutating func clear() {
        active = nil
        issuedAt = nil
        failedAttempts = 0
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The host side of the handshake: a `hello` becomes a challenge (`begin`), and the device's
/// answer becomes a verdict (`Pending.finish`): the kind of session it may open, or the result
/// that turns it away. Version check, the nonce and transcript the device's build signs
/// (`vantage-auth-v2` with the connection's purpose, or `vantage-auth-v1` from a build without a
/// nonce), signature checks, the pairing code (accepted, wrong, run out; a miss costs the peer a
/// second), the availability check, files-only sessions, the Screen Recording grant, and the
/// capabilities to advertise. Transcripts and messages are byte-for-byte what they were.
///
/// Used by `HostSession` on the Mac and by the client tests' mock hosts, so there is one copy of
/// the host's rules in Swift.
public enum SessionAdmission {
    /// What a device may open.
    public enum Kind: Sendable, Equatable {
        /// A short connection to see whether the computer is reachable and ready; nothing else starts.
        case availabilityCheck
        /// Files without a screen.
        case filesOnly
        case screen
    }

    public enum Begin: Sendable {
        /// Send this result and end the connection.
        case refused(AuthResult)
        /// Send the challenge and wait for `authenticate`.
        case challenged(Challenge, Pending)
    }

    public enum Outcome: Sendable {
        /// The device is admitted to a session of this kind; `newlyPaired` when it used the code.
        case admitted(Kind, newlyPaired: Bool)
        /// Send this result (after `delay`, which slows down guessing) and end the connection.
        case refused(AuthResult, delay: Duration)
    }

    /// What this host can do, for the result an admitted device receives.
    public struct HostAbilities: Sendable {
        public var platform: HostPlatform?
        public var screenRecordingGranted: Bool
        public var accessibilityGranted: Bool
        public var canManageVirtualDisplay: Bool
        /// Engines the host can run, best first; advertised only to a device that knows them.
        public var dictationEngines: [DictationEngineID]

        public init(platform: HostPlatform?, screenRecordingGranted: Bool, accessibilityGranted: Bool, canManageVirtualDisplay: Bool,
                    dictationEngines: [DictationEngineID]) {
            self.platform = platform
            self.screenRecordingGranted = screenRecordingGranted
            self.accessibilityGranted = accessibilityGranted
            self.canManageVirtualDisplay = canManageVirtualDisplay
            self.dictationEngines = dictationEngines
        }
    }

    /// A challenge sent, waiting for the device's answer.
    public struct Pending: Sendable {
        public let hello: Hello
        public let kind: Kind
        public let isPaired: Bool
        let hostPublicKey: Data
        let hostNonce: Data
        /// The device's nonce when it sent a valid one (it then signs the v2 transcript).
        let clientNonce: Data?

        /// Checks the signature and, for an unpaired device, the pairing code.
        public func finish(_ auth: Authenticate, pairing: any PairingAuthority) -> Outcome {
            let signatureValid = if let clientNonce {
                AuthTranscript.verifyClient(signature: auth.signature, clientNonce: clientNonce, hostNonce: hostNonce, hostPublicKey: hostPublicKey,
                                            clientPublicKey: hello.clientPublicKey, purpose: AuthPurpose(hello: hello))
            } else {
                AuthTranscript.verify(signature: auth.signature, nonce: hostNonce, hostPublicKey: hostPublicKey, clientPublicKey: hello.clientPublicKey)
            }
            guard signatureValid else { return .refused(AuthResult(status: .badSignature), delay: .zero) }
            var newlyPaired = false
            if !isPaired {
                guard let code = auth.pairingCode else {
                    return .refused(AuthResult(status: .pairingRequired, message: "Enter the pairing code shown on the Mac"), delay: .zero)
                }
                switch pairing.consumePairingCode(code) {
                case .accepted:
                    pairing.trust(hello.clientPublicKey, name: hello.clientName, model: hello.deviceModel)
                    newlyPaired = true
                case .incorrect:
                    // Slow down guessing; the code is also burned after a few misses.
                    return .refused(AuthResult(status: .badPairingCode, message: "Incorrect pairing code. Try the code shown on the Mac."), delay: .seconds(1))
                case .unavailable:
                    return .refused(AuthResult(status: .badPairingCode,
                                               message: "That pairing code has expired. On the Mac, choose Show Pairing Code and enter the new one."), delay: .seconds(1))
                }
            }
            if kind == .filesOnly, hello.features?.fileTransfer != true {
                return .refused(AuthResult(status: .denied, message: "Nothing to do on this connection."), delay: .zero)
            }
            return .admitted(kind, newlyPaired: newlyPaired)
        }
    }

    /// Answers a `hello`: a refusal for the wrong protocol version, else the challenge (signed
    /// over the device's nonce when it sent one) and what to remember until the device answers.
    /// `peerTailnetName` is looked up only for a screen session (it costs a subprocess).
    public static func begin(hello: Hello, identity: DeviceIdentity, hostName: String, hostVersion: String = "1.0", platform: HostPlatform?,
                             isPaired: Bool, peerTailnetName: () -> String? = { nil }, nonce: Data = AuthTranscript.randomNonce()) throws -> Begin {
        guard hello.protocolVersion == VantageProtocol.version else {
            return .refused(AuthResult(status: .versionMismatch, message: "Protocol \(VantageProtocol.version) required"))
        }
        let kind: Kind = switch AuthPurpose(hello: hello) {
        case .probe: .availabilityCheck
        case .files: .filesOnly
        case .screen: .screen
        }
        // A client that sent a nonce wants proof this challenge comes from the holder of the host
        // key, and signs the transcript that binds both nonces and the connection's purpose. One
        // that didn't (an older Casement) signs the older transcript; the host still takes that.
        let clientNonce = hello.clientNonce.flatMap { $0.count == AuthTranscript.nonceLength ? $0 : nil }
        let hostSignature = try clientNonce.map { clientNonce in
            try identity.sign(AuthTranscript.hostBytes(clientNonce: clientNonce, hostNonce: nonce, hostPublicKey: identity.publicKeyData,
                                                       clientPublicKey: hello.clientPublicKey))
        }
        let challenge = Challenge(hostName: hostName, hostVersion: hostVersion, hostPublicKey: identity.publicKeyData, nonce: nonce, isPaired: isPaired,
                                  peerTailnetName: kind == .screen ? peerTailnetName() : nil, hostPlatform: platform, hostSignature: hostSignature)
        return .challenged(challenge, Pending(hello: hello, kind: kind, isPaired: isPaired, hostPublicKey: identity.publicKeyData,
                                              hostNonce: nonce, clientNonce: clientNonce))
    }

    /// The result an admitted availability check receives before the connection ends.
    public static func availabilityResult(host: HostAbilities) -> AuthResult {
        AuthResult(status: .ok, readiness: HostReadiness(screenRecordingGranted: host.screenRecordingGranted,
                                                         accessibilityGranted: host.accessibilityGranted))
    }

    /// Why a screen session can't open on this host right now, or nil.
    public static func screenRefusal(host: HostAbilities) -> AuthResult? {
        guard host.screenRecordingGranted else {
            return AuthResult(status: .denied,
                              message: "On the Mac, grant Screen Recording to Casement Host in System Settings → Privacy & Security, then reopen Casement Host and retry.")
        }
        return nil
    }

    /// What an admitted device is told the host can do. Dictation kinds are new, so they're
    /// advertised only to a device that said it knows them; a file channel only to one that can open it.
    public static func capabilities(for kind: Kind, hello: Hello, host: HostAbilities) -> HostCapabilities {
        switch kind {
        case .availabilityCheck:
            return HostCapabilities(codecs: [], canManageVirtualDisplay: false, clipboard: false, maxFPS: 0, platform: host.platform)
        case .filesOnly:
            return HostCapabilities(codecs: [], canManageVirtualDisplay: false, clipboard: false, maxFPS: 0,
                                    fileTransfer: true, filesOnlySessions: true, platform: host.platform)
        case .screen:
            let takesFiles = hello.features?.fileTransfer == true
            // Audio rides on the Screen Recording grant, so a session that got this far can always offer it.
            return HostCapabilities(codecs: [.hevc, .h264], canManageVirtualDisplay: host.canManageVirtualDisplay, clipboard: true, maxFPS: 60,
                                    dictationEngines: hello.features?.dictation == true ? host.dictationEngines : nil,
                                    audio: true, fileTransfer: takesFiles ? true : nil, filesOnlySessions: takesFiles ? true : nil,
                                    platform: host.platform, curtain: true)
        }
    }
}

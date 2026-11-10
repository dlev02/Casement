import Foundation
import Testing
@testable import VantageCore

/// The host's rules for letting a device in, on the module every Swift host side shares.
struct SessionAdmissionTests {
    /// Paired devices in memory, with the real pairing-code rules under a lock.
    private final class Trust: PairingAuthority, @unchecked Sendable {
        private let lock = NSLock()
        private var trusted: Set<String> = []
        private var codes = PairingCodes()
        var now = ContinuousClock.now

        @discardableResult func show() -> String { lock.withLock { codes.issue(now: now) } }
        var current: String? { lock.withLock { codes.current } }
        func isTrusted(_ publicKey: Data) -> Bool { lock.withLock { trusted.contains(DeviceIdentity.fingerprint(of: publicKey)) } }
        func consumePairingCode(_ code: String) -> PairingCheck { lock.withLock { codes.check(code, now: now).result } }
        func trust(_ publicKey: Data, name: String, model: String?) { lock.withLock { _ = trusted.insert(DeviceIdentity.fingerprint(of: publicKey)) } }
    }

    private let host = DeviceIdentity()
    private let device = DeviceIdentity()

    private func hello(probe: Bool = false, filesOnly: Bool = false, nonce: Data? = AuthTranscript.randomNonce()) -> Hello {
        Hello(clientName: "iPad", deviceModel: "iPad16,6", appVersion: "1.0", clientPublicKey: device.publicKeyData, supportedCodecs: [.hevc],
              maxDecodeWidth: 4096, maxDecodeHeight: 4096, viewport: nil, isReadinessProbe: probe ? true : nil,
              features: filesOnly ? ClientFeatures(fileTransfer: true, filesOnly: true) : nil, clientNonce: nonce)
    }

    /// What the device does with a challenge: checks the host's proof, signs for `purpose`.
    private func answer(_ challenge: Challenge, hello: Hello, purpose: AuthPurpose = .screen, code: String? = nil) throws -> Authenticate {
        let signature: Data
        if let nonce = hello.clientNonce {
            _ = try HostIdentityCheck.verify(challenge, clientNonce: nonce, clientPublicKey: device.publicKeyData, expected: host.publicKeyData)
            signature = try device.sign(AuthTranscript.clientBytes(clientNonce: nonce, hostNonce: challenge.nonce, hostPublicKey: challenge.hostPublicKey,
                                                                   clientPublicKey: device.publicKeyData, purpose: purpose))
        } else {
            signature = try device.sign(AuthTranscript.bytes(nonce: challenge.nonce, hostPublicKey: challenge.hostPublicKey, clientPublicKey: device.publicKeyData))
        }
        return Authenticate(signature: signature, pairingCode: code)
    }

    private func challenged(_ hello: Hello, trust: Trust) throws -> (Challenge, SessionAdmission.Pending) {
        guard case .challenged(let challenge, let pending) = try SessionAdmission.begin(hello: hello, identity: host, hostName: "Studio",
                                                                                         platform: .macOS, isPaired: trust.isTrusted(hello.clientPublicKey)) else {
            throw Failure.refusedEarly
        }
        return (challenge, pending)
    }

    private enum Failure: Error { case refusedEarly }

    @Test func pairingRequiredThenTheCodePairsThenTheDeviceIsRemembered() throws {
        let trust = Trust()
        let hello = hello()
        var (challenge, pending) = try challenged(hello, trust: trust)
        #expect(challenge.isPaired == false && challenge.hostSignature != nil && challenge.peerTailnetName == nil)
        guard case .refused(let result, let delay) = pending.finish(try answer(challenge, hello: hello), pairing: trust) else { Issue.record("admitted without a code"); return }
        #expect(result.status == .pairingRequired && delay == .zero)

        let code = trust.show()
        guard case .admitted(.screen, let newlyPaired) = pending.finish(try answer(challenge, hello: hello, code: code), pairing: trust) else { Issue.record("the code didn't pair"); return }
        #expect(newlyPaired && trust.isTrusted(device.publicKeyData) && trust.current == nil) // used up

        (challenge, pending) = try challenged(hello, trust: trust)
        #expect(challenge.isPaired)
        guard case .admitted(.screen, false) = pending.finish(try answer(challenge, hello: hello), pairing: trust) else { Issue.record("not remembered"); return }
    }

    @Test func fiveMissesBurnTheCodeAndEachMissCostsASecond() throws {
        let trust = Trust()
        let hello = hello()
        let (challenge, pending) = try challenged(hello, trust: trust)
        let code = trust.show()
        for _ in 0..<5 {
            guard case .refused(let result, let delay) = pending.finish(try answer(challenge, hello: hello, code: "000000"), pairing: trust) else { Issue.record("a wrong code paired"); return }
            #expect(result.status == .badPairingCode && result.message?.hasPrefix("Incorrect pairing code") == true && delay == .seconds(1))
        }
        #expect(trust.current == nil) // burned
        guard case .refused(let result, let delay) = pending.finish(try answer(challenge, hello: hello, code: code), pairing: trust) else { Issue.record("a burned code paired"); return }
        #expect(result.status == .badPairingCode && result.message?.hasPrefix("That pairing code has expired") == true && delay == .seconds(1))
        // A code also runs out after ten minutes; a fixed DEBUG code doesn't.
        trust.show()
        trust.now += .seconds(601)
        #expect(trust.consumePairingCode(trust.current ?? "") == .unavailable)
        var fixed = PairingCodes(fixedCode: "246810")
        fixed.issue(now: trust.now)
        #expect(fixed.check("246810", now: trust.now + .seconds(3600)).result == .accepted)
    }

    @Test func aSignatureMadeForAnAvailabilityCheckCannotOpenAScreenSession() throws {
        let trust = Trust()
        trust.trust(device.publicKeyData, name: "iPad", model: nil)
        let probe = hello(probe: true)
        var (challenge, pending) = try challenged(probe, trust: trust)
        #expect(pending.kind == .availabilityCheck)
        guard case .admitted(.availabilityCheck, false) = pending.finish(try answer(challenge, hello: probe, purpose: .probe), pairing: trust) else { Issue.record("the probe was refused"); return }
        // The same signature presented on a screen session (its hello says screen) is refused.
        let screen = hello(nonce: probe.clientNonce)
        (challenge, pending) = try SessionAdmission.begin(hello: screen, identity: host, hostName: "Studio", platform: .macOS, isPaired: true,
                                                          nonce: challenge.nonce).challenged!
        guard case .refused(let result, _) = pending.finish(try answer(challenge, hello: screen, purpose: .probe), pairing: trust) else { Issue.record("a probe's signature opened a screen"); return }
        #expect(result.status == .badSignature)
    }

    @Test func olderClientsFilesOnlySessionsAndWrongVersionsAreJudgedTheSameWay() throws {
        let trust = Trust()
        trust.trust(device.publicKeyData, name: "iPad", model: nil)
        // A build without a nonce signs the older transcript and gets an unsigned challenge.
        let old = hello(nonce: nil)
        let (challenge, pending) = try challenged(old, trust: trust)
        #expect(challenge.hostSignature == nil)
        guard case .admitted(.screen, false) = pending.finish(try answer(challenge, hello: old), pairing: trust) else { Issue.record("the older client was refused"); return }
        // Files-only needs the file channel; without it there's nothing to do.
        let files = hello(filesOnly: true)
        let (filesChallenge, filesPending) = try challenged(files, trust: trust)
        guard case .admitted(.filesOnly, false) = filesPending.finish(try answer(filesChallenge, hello: files, purpose: .files), pairing: trust) else { Issue.record("files-only refused"); return }
        var noFiles = files
        noFiles.features = ClientFeatures(filesOnly: true)
        let (noFilesChallenge, noFilesPending) = try challenged(noFiles, trust: trust)
        guard case .refused(let result, _) = noFilesPending.finish(try answer(noFilesChallenge, hello: noFiles, purpose: .files), pairing: trust) else { Issue.record("admitted with nothing to do"); return }
        #expect(result.status == .denied)
        // The wrong protocol version is turned away before any challenge.
        var wrong = hello()
        wrong.protocolVersion = VantageProtocol.version + 1
        guard case .refused(let mismatch) = try SessionAdmission.begin(hello: wrong, identity: host, hostName: "Studio", platform: .macOS, isPaired: true) else { Issue.record("challenged a wrong version"); return }
        #expect(mismatch.status == .versionMismatch)
        // Capabilities: a device that can open a file channel hears about files; one that can't doesn't.
        let abilities = SessionAdmission.HostAbilities(platform: .macOS, screenRecordingGranted: true, accessibilityGranted: true, canManageVirtualDisplay: false, dictationEngines: [.apple])
        let plain = SessionAdmission.capabilities(for: .screen, hello: hello(), host: abilities)
        #expect(plain.fileTransfer == nil && plain.dictationEngines == nil && plain.curtain == true && plain.audio == true)
        var rich = hello()
        rich.features = ClientFeatures(dictation: true, fileTransfer: true)
        let full = SessionAdmission.capabilities(for: .screen, hello: rich, host: abilities)
        #expect(full.fileTransfer == true && full.filesOnlySessions == true && full.dictationEngines == [.apple])
        #expect(SessionAdmission.screenRefusal(host: abilities) == nil)
        var ungranted = abilities
        ungranted.screenRecordingGranted = false
        #expect(SessionAdmission.screenRefusal(host: ungranted)?.status == .denied)
    }
}

private extension SessionAdmission.Begin {
    var challenged: (Challenge, SessionAdmission.Pending)? {
        if case .challenged(let challenge, let pending) = self { (challenge, pending) } else { nil }
    }
}

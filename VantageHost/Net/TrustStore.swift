import Foundation
import VantageCore

/// Stores trusted client device public keys and manages one-time pairing codes.
/// Trusted keys persist in UserDefaults (fingerprint → name); the host identity lives in Keychain.
nonisolated final class TrustStore: @unchecked Sendable {
    struct TrustedClient: Codable, Sendable, Identifiable {
        var fingerprint: String
        var name: String
        var addedAt: Date
        /// The device's hardware model when it paired ("iPad16,6"); nil for older pairings.
        var model: String?
        var id: String { fingerprint }
        /// What it is, for an icon: from the model, else guessed from the name.
        var symbol: String { DeviceSymbol.for(model: model, name: name) }
    }

    private let defaults = HostOptions.shared.syntheticCapture
        ? UserDefaults(suiteName: "com.benjaminlevinson.vantage.synthetic")! : .standard
    private let key = "vantage.trustedClients"
    private let lock = NSLock()
    private var activePairingCode: String?
    private var pairingIssuedAt: Date?
    private var failedPairingAttempts = 0

    /// A code is burned after this many wrong guesses, so a peer gets 5 tries in a million.
    static let maxPairingAttempts = 5
    /// A code shown on the Mac stops working after ten minutes.
    static let pairingLifetime: TimeInterval = 10 * 60

    enum PairingCheck: Sendable { case accepted, incorrect, unavailable }

    var onChange: (@Sendable () -> Void)?
    /// Called when a code stops being valid (used, expired, or burned by wrong guesses).
    var onPairingCodeCleared: (@Sendable () -> Void)?

    func isTrusted(_ publicKey: Data) -> Bool {
        let fingerprint = DeviceIdentity.fingerprint(of: publicKey)
        return trustedClients().contains { $0.fingerprint == fingerprint }
    }

    func trust(_ publicKey: Data, name: String, model: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        var clients = trustedClientsLocked()
        let fingerprint = DeviceIdentity.fingerprint(of: publicKey)
        guard !clients.contains(where: { $0.fingerprint == fingerprint }) else { return }
        clients.append(TrustedClient(fingerprint: fingerprint, name: name, addedAt: Date(), model: model))
        save(clients)
        onChange?()
    }

    /// What iOS and visionOS call every device, now that apps can't read the name its owner gave it.
    static func isGenericName(_ name: String) -> Bool {
        ["iPad", "iPhone", "iPod touch", "Apple Vision Pro"].contains(name)
    }

    func name(ofFingerprint fingerprint: String) -> String? {
        trustedClients().first { $0.fingerprint == fingerprint }?.name
    }

    /// Renames a paired device; a blank name keeps the old one.
    func rename(fingerprint: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var clients = trustedClientsLocked()
        guard let index = clients.firstIndex(where: { $0.fingerprint == fingerprint }), clients[index].name != name else { return }
        clients[index].name = name
        save(clients)
        onChange?()
    }

    /// Swaps a generic "iPad" for the device's tailnet name; a name someone chose stays.
    func adoptTailnetName(_ name: String, fingerprint: String) {
        guard let current = self.name(ofFingerprint: fingerprint), Self.isGenericName(current) else { return }
        rename(fingerprint: fingerprint, to: name)
    }

    func revoke(fingerprint: String) {
        lock.lock(); defer { lock.unlock() }
        var clients = trustedClientsLocked()
        clients.removeAll { $0.fingerprint == fingerprint }
        save(clients)
        onChange?()
    }

    func trustedClients() -> [TrustedClient] {
        lock.lock(); defer { lock.unlock() }
        return trustedClientsLocked()
    }

    // MARK: Pairing

    /// Generates a fresh six-digit pairing code the user reads off the Mac.
    @discardableResult
    func newPairingCode() -> String {
        lock.lock(); defer { lock.unlock() }
        let code = HostOptions.shared.fixedPairingCode ?? AuthTranscript.randomPairingCode()
        activePairingCode = code
        pairingIssuedAt = Date()
        failedPairingAttempts = 0
        return code
    }

    func consumePairingCode(_ code: String) -> PairingCheck {
        lock.lock(); defer { lock.unlock() }
        guard let active = activePairingCode else { return .unavailable }
        if HostOptions.shared.fixedPairingCode == nil, let issued = pairingIssuedAt,
           Date().timeIntervalSince(issued) > Self.pairingLifetime {
            clearPairingCodeLocked()
            return .unavailable
        }
        guard Self.constantTimeEquals(active, code) else {
            failedPairingAttempts += 1
            if failedPairingAttempts >= Self.maxPairingAttempts { clearPairingCodeLocked() }
            return .incorrect
        }
        clearPairingCodeLocked()
        return .accepted
    }

    /// Withdraws the code shown on the Mac (Done, or its ten minutes ran out).
    func cancelPairingCode() {
        lock.lock(); defer { lock.unlock() }
        guard activePairingCode != nil else { return }
        clearPairingCodeLocked()
    }

    private func clearPairingCodeLocked() {
        activePairingCode = nil
        pairingIssuedAt = nil
        failedPairingAttempts = 0
        onPairingCodeCleared?()
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    var currentPairingCode: String? {
        lock.lock(); defer { lock.unlock() }
        return activePairingCode
    }

    private func trustedClientsLocked() -> [TrustedClient] {
        guard let data = defaults.data(forKey: key),
              let clients = try? JSONDecoder().decode([TrustedClient].self, from: data) else { return [] }
        return clients
    }

    private func save(_ clients: [TrustedClient]) {
        defaults.set(try? JSONEncoder().encode(clients), forKey: key)
    }
}

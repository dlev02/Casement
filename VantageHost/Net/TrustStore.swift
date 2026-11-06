import Foundation
import VantageCore
import os

/// Stores trusted client device public keys and manages one-time pairing codes.
/// Trusted keys decide who gets the screen and input, so they live in the Keychain beside the host
/// identity: any program this user runs can rewrite UserDefaults without a Screen Recording or
/// Accessibility grant, and could have paired itself that way. Synthetic hosts keep their
/// throwaway list in a defaults suite of their own.
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

    private let defaults = HostOptions.shared.syntheticCapture || HostOptions.shared.allowsSelfCurtain
        ? UserDefaults(suiteName: "com.benjaminlevinson.vantage.synthetic")! : .standard
    private let key = "vantage.trustedClients"
    private let keychain = HostOptions.shared.syntheticCapture || HostOptions.shared.allowsSelfCurtain
        ? nil : KeychainStore(service: "com.benjaminlevinson.vantage.host")
    private let keychainAccount = "trusted-clients"
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "trust")
    private let lock = NSLock()
    /// The list as last read or written; nil until the first read succeeds.
    private var loadedClients: [TrustedClient]?
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
        guard var clients = loadClientsLocked() else { return }
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
        guard var clients = loadClientsLocked() else { return }
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
        guard var clients = loadClientsLocked() else { return }
        clients.removeAll { $0.fingerprint == fingerprint }
        save(clients)
        onChange?()
    }

    func trustedClients() -> [TrustedClient] {
        lock.lock(); defer { lock.unlock() }
        return loadClientsLocked() ?? []
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

    /// Nil when the Keychain can't be read right now: nobody is trusted, and nothing is saved over
    /// the list until it can be.
    private func loadClientsLocked() -> [TrustedClient]? {
        if let loadedClients { return loadedClients }
        guard let keychain else {
            let clients = decode(defaults.data(forKey: key))
            loadedClients = clients
            return clients
        }
        do {
            if let stored = try keychain.data(for: keychainAccount) {
                let clients = decode(stored)
                loadedClients = clients
                return clients
            }
        } catch {
            log.error("couldn't read the paired devices from the Keychain: \(String(describing: error), privacy: .public)")
            return nil
        }
        // First launch of a host that keeps them in the Keychain: bring over the older list. The
        // Keychain then always holds a list, even an empty one, so defaults are never read again.
        let clients = decode(defaults.data(forKey: key))
        loadedClients = clients
        if save(clients) { defaults.removeObject(forKey: key) }
        return clients
    }

    private func decode(_ data: Data?) -> [TrustedClient] {
        data.flatMap { try? JSONDecoder().decode([TrustedClient].self, from: $0) } ?? []
    }

    @discardableResult
    private func save(_ clients: [TrustedClient]) -> Bool {
        loadedClients = clients
        guard let data = try? JSONEncoder().encode(clients) else { return false }
        guard let keychain else {
            defaults.set(data, forKey: key)
            return true
        }
        do {
            try keychain.set(data, for: keychainAccount)
            return true
        } catch {
            log.error("couldn't save the paired devices to the Keychain: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

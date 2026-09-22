import Foundation
import VantageCore

/// Stores trusted client device public keys and manages one-time pairing codes.
/// Trusted keys persist in UserDefaults (fingerprint → name); the host identity lives in Keychain.
nonisolated final class TrustStore: @unchecked Sendable {
    struct TrustedClient: Codable, Sendable, Identifiable {
        var fingerprint: String
        var name: String
        var addedAt: Date
        var id: String { fingerprint }
    }

    private let defaults = UserDefaults.standard
    private let key = "vantage.trustedClients"
    private let lock = NSLock()
    private var activePairingCode: String?

    var onChange: (@Sendable () -> Void)?

    func isTrusted(_ publicKey: Data) -> Bool {
        let fingerprint = DeviceIdentity.fingerprint(of: publicKey)
        return trustedClients().contains { $0.fingerprint == fingerprint }
    }

    func trust(_ publicKey: Data, name: String) {
        lock.lock(); defer { lock.unlock() }
        var clients = trustedClientsLocked()
        let fingerprint = DeviceIdentity.fingerprint(of: publicKey)
        guard !clients.contains(where: { $0.fingerprint == fingerprint }) else { return }
        clients.append(TrustedClient(fingerprint: fingerprint, name: name, addedAt: Date()))
        save(clients)
        onChange?()
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
        return code
    }

    func consumePairingCode(_ code: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let active = activePairingCode, active == code else { return false }
        activePairingCode = nil
        return true
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

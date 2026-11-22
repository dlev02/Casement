import Foundation
import VantageCore
import os

/// The Mac account password Casement can type for you, and the account name that goes with it,
/// one pair per computer.
///
/// They live in the Keychain, never in the saved-device list. Each is kept under every name the
/// computer goes by (`accounts`): its host key once a connection has verified it, its address,
/// and the saved entry's id, which is all earlier builds used. The id alone didn't survive iCloud:
/// the same Mac added on two devices gets two ids, so a password synced from one was never found on
/// the other. Reading takes the first that has a value; writing and removing touch them all, so
/// earlier builds on other devices keep finding them too. With iCloud sync on they ride iCloud
/// Keychain to your other devices; otherwise they never leave this one except as keystrokes on an
/// already-authenticated session.
enum DeviceSecrets {
    static let keychainService = "com.benjaminlevinson.vantage.client.secrets"
    private static let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "secrets")

    enum Kind: String, CaseIterable {
        case password, username
    }

    /// Nothing could be written, so the secret isn't saved anywhere.
    struct SaveError: LocalizedError {
        let status: OSStatus?
        var errorDescription: String? {
            let code = status.map { " (error \($0))" } ?? ""
            return "The Keychain didn't save it\(code). Unlock this device and try again."
        }
    }

    static func password(for device: SavedDevice) -> String? { read(.password, for: device) }
    static func username(for device: SavedDevice) -> String? { read(.username, for: device) }
    static func hasPassword(for device: SavedDevice) -> Bool { password(for: device) != nil }

    /// Saves a password, or removes it (and the account name, useless without it) when `password`
    /// is nil or empty.
    static func setPassword(_ password: String?, for device: SavedDevice) throws {
        guard let password, !password.isEmpty else {
            remove(.password, for: device)
            remove(.username, for: device)
            return
        }
        try write(password, .password, for: device)
    }

    /// The Mac account name Screen Sharing signs in with, which is how Casement types into password
    /// fields and the lock screen that block ordinary keystrokes. Empty removes it.
    static func setUsername(_ username: String?, for device: SavedDevice) throws {
        let trimmed = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            remove(.username, for: device)
            return
        }
        try write(trimmed, .username, for: device)
    }

    /// Forgets both (the computer was removed). `sharedNames` false keeps the names other devices
    /// share (host key, address) and forgets only this entry's id: right when secrets sync through
    /// iCloud Keychain but the list doesn't, so another device still keeping the computer doesn't
    /// lose its password.
    static func removeAll(for device: SavedDevice, sharedNames: Bool = true) {
        for kind in Kind.allCases {
            let accounts = accounts(kind, for: device)
            for account in sharedNames ? accounts : Array(accounts.suffix(1)) {
                CloudSync.removeSecret(account, service: keychainService)
            }
        }
    }

    // MARK: Accounts

    /// The Keychain accounts a secret is kept under, most stable first: the host's identity, its
    /// address, then the saved entry's id.
    static func accounts(_ kind: Kind, for device: SavedDevice) -> [String] {
        var accounts: [String] = []
        if let key = device.hostPublicKey { accounts.append("\(kind.rawValue).key.\(DeviceIdentity.fingerprint(of: key))") }
        accounts.append(addressAccount(kind, host: device.host, port: device.port))
        accounts.append("\(kind.rawValue).\(device.id.uuidString)")
        return accounts
    }

    /// Every account the computers' secrets may be under, for moving them between the local and
    /// synced Keychains.
    static func allAccounts(for devices: [SavedDevice]) -> [String] {
        devices.flatMap { device in Kind.allCases.flatMap { accounts($0, for: device) } }
    }

    /// The same computer typed as "Studio.example.ts.net." and "studio.example.ts.net" is one address.
    static func addressAccount(_ kind: Kind, host: String, port: UInt16) -> String {
        "\(kind.rawValue).address.\(DeviceMerge.normalizedHost(host)):\(port)"
    }

    // MARK: Keeping the names in step

    /// Copies each secret into any account of `device` that doesn't hold it yet: one saved by an
    /// earlier build under the id alone, or under the address before the host key was known, or
    /// moved from an entry this one replaced (`also`). Cheap when nothing is missing.
    static func fillIn(_ device: SavedDevice, from also: SavedDevice? = nil) {
        for kind in Kind.allCases {
            let targets = accounts(kind, for: device)
            let sources = targets + (also.map { accounts(kind, for: $0) } ?? [])
            guard let value = sources.lazy.compactMap({ CloudSync.secret($0, service: keychainService) }).first else { continue }
            for account in targets where CloudSync.secret(account, service: keychainService) != value {
                do { try CloudSync.storeSecret(value, account: account, service: keychainService) } catch {
                    log.error("couldn't copy \(kind.rawValue, privacy: .public) to another account: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// `fillIn` for each computer whose names haven't been put in step on this device yet (once per
    /// computer, address and key, so a launch after the first reads nothing).
    static func fillInOnce(_ devices: [SavedDevice], defaults: UserDefaults = .standard) {
        let key = "vantage.secretsFilledIn"
        var done = Set(defaults.stringArray(forKey: key) ?? [])
        let before = done.count
        for device in devices {
            let mark = accounts(.password, for: device).joined(separator: "|")
            guard !done.contains(mark) else { continue }
            fillIn(device)
            done.insert(mark)
        }
        if done.count != before { defaults.set(Array(done), forKey: key) }
    }

    /// The computer moved to a new address or key: forgets the names it no longer goes by, after
    /// copying the secrets to the new ones.
    static func moved(from old: SavedDevice, to new: SavedDevice) {
        fillIn(new, from: old)
        for kind in Kind.allCases {
            let current = Set(accounts(kind, for: new))
            for account in accounts(kind, for: old) where !current.contains(account) {
                CloudSync.removeSecret(account, service: keychainService)
            }
        }
    }

    // MARK: Reading and writing

    private static func read(_ kind: Kind, for device: SavedDevice) -> String? {
        accounts(kind, for: device).lazy.compactMap { CloudSync.secret($0, service: keychainService) }.first
    }

    /// Writes every account. Saved as long as one took it (reading finds it there); throws only
    /// when none did.
    private static func write(_ value: String, _ kind: Kind, for device: SavedDevice) throws {
        var saved = false
        var lastStatus: OSStatus?
        for account in accounts(kind, for: device) {
            do {
                try CloudSync.storeSecret(value, account: account, service: keychainService)
                saved = true
            } catch {
                if case KeychainError.unexpectedStatus(let status) = error { lastStatus = status }
                log.error("couldn't save \(kind.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        guard saved else { throw SaveError(status: lastStatus) }
    }

    private static func remove(_ kind: Kind, for device: SavedDevice) {
        for account in accounts(kind, for: device) { CloudSync.removeSecret(account, service: keychainService) }
    }
}

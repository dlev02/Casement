import Foundation
import Security

public enum KeychainError: Error, Sendable {
    case unexpectedStatus(OSStatus)
}

/// Minimal generic-password Keychain wrapper shared by host and client.
public struct KeychainStore: Sendable {
    public let service: String
    /// Synchronizable items ride iCloud Keychain to the user's other devices. They can't be
    /// "this device only", so they get the plain after-first-unlock protection class instead.
    public let synchronizable: Bool
    /// Secrets only used while someone is actively using the app (passwords, API keys) are
    /// readable only while the device is unlocked, not merely after the first unlock since boot.
    public let unlockedOnly: Bool

    public init(service: String = "com.benjaminlevinson.vantage", synchronizable: Bool = false, unlockedOnly: Bool = false) {
        self.service = service
        self.synchronizable = synchronizable
        self.unlockedOnly = unlockedOnly
    }

    private var accessibility: CFString {
        switch (synchronizable, unlockedOnly) {
        case (true, true): kSecAttrAccessibleWhenUnlocked
        case (true, false): kSecAttrAccessibleAfterFirstUnlock
        case (false, true): kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case (false, false): kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: synchronizable,
        ]
    }

    public func data(for account: String) throws -> Data? {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    public func set(_ value: Data, for account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: accessibility,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            let addStatus = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func remove(_ account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func string(for account: String) throws -> String? {
        guard let data = try data(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String, for account: String) throws {
        try set(Data(value.utf8), for: account)
    }

    /// Loads the device identity from the Keychain, creating and storing one if absent.
    public func loadOrCreateIdentity(account: String = "device-identity") throws -> DeviceIdentity {
        if let raw = try data(for: account), let identity = try? DeviceIdentity(rawRepresentation: raw) {
            return identity
        }
        let identity = DeviceIdentity()
        try set(identity.rawRepresentation, for: account)
        return identity
    }
}

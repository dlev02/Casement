import Foundation
import Observation
import VantageCore
import os

/// Keeps saved Macs, their passwords, and the Tailscale key the same on every device signed into
/// the same iCloud account, so setup happens once.
///
/// Secrets travel through iCloud Keychain (`kSecAttrSynchronizable`), which needs no entitlement.
/// The device list travels through iCloud key-value storage, which needs the
/// `com.apple.developer.ubiquity-kvstore-identifier` entitlement — a personal team can't sign for
/// it, so `deviceListAvailability` reports when that half is switched off and the settings screen
/// explains. Turning sync on migrates what's already saved; turning it off copies everything back
/// to the local Keychain and leaves the cloud copy alone.
@MainActor
@Observable
final class CloudSync {
    static let shared = CloudSync()

    private static let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "sync")
    private static let enabledKey = "vantage.iCloudSync"
    private static let devicesKey = "devices"
    private static let tombstonesKey = "deletedDevices"

    private(set) var isEnabled: Bool
    /// Set by `DeviceStore` so a merge from another device has somewhere to land.
    var onRemoteDevices: (([SavedDevice], [UUID: Date]) -> Void)?
    private var observer: NSObjectProtocol?

    enum DeviceListAvailability: Equatable {
        case available
        case noiCloudAccount
        case notEntitled

        var explanation: String? {
            switch self {
            case .available: nil
            case .noiCloudAccount: "Sign in to iCloud in Settings to sync your device list."
            case .notEntitled: "Passwords and your Tailscale key sync through iCloud Keychain now. The device list itself waits on an App Store build — this copy of Vantage isn't signed for iCloud storage."
            }
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if isEnabled { startObserving() }
    }

    // MARK: Secrets

    /// The Keychain store secrets should use right now.
    static func secretsStore(service: String) -> KeychainStore {
        KeychainStore(service: service, synchronizable: shared.isEnabled, unlockedOnly: true)
    }

    /// Reads from the store sync currently points at, falling back to the other so a key saved
    /// before sync was flipped is never invisible.
    static func secret(_ account: String, service: String) -> String? {
        let preferred = KeychainStore(service: service, synchronizable: shared.isEnabled)
        let fallback = KeychainStore(service: service, synchronizable: !shared.isEnabled)
        if let value = try? preferred.string(for: account), !value.isEmpty { return value }
        if let value = try? fallback.string(for: account), !value.isEmpty { return value }
        return nil
    }

    /// Removes an account from both stores.
    static func removeSecret(_ account: String, service: String) {
        try? KeychainStore(service: service, synchronizable: true).remove(account)
        try? KeychainStore(service: service, synchronizable: false).remove(account)
    }

    // MARK: Switching

    func setEnabled(_ enabled: Bool, devices: [SavedDevice]) {
        guard enabled != isEnabled else { return }
        migrateSecrets(toSynchronizable: enabled, deviceIDs: devices.map(\.id))
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startObserving()
            push(devices: devices, tombstones: [:])
            pullNow()
        } else {
            stopObserving()
        }
    }

    private func migrateSecrets(toSynchronizable: Bool, deviceIDs: [UUID]) {
        let accounts = TailscaleAccount.keychainAccounts.map { ($0, TailscaleAccount.keychainService) }
            + deviceIDs.flatMap { [(DeviceSecrets.account(for: $0), DeviceSecrets.keychainService),
                                   (DeviceSecrets.usernameAccount(for: $0), DeviceSecrets.keychainService)] }
        for (account, service) in accounts {
            let from = KeychainStore(service: service, synchronizable: !toSynchronizable)
            let to = KeychainStore(service: service, synchronizable: toSynchronizable, unlockedOnly: true)
            guard let value = try? from.string(for: account), !value.isEmpty else { continue }
            do {
                try to.set(value, for: account)
                try from.remove(account)
            } catch {
                Self.log.error("could not move \(account, privacy: .public) between keychains: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Device list

    private var store: NSUbiquitousKeyValueStore { .default }

    var deviceListAvailability: DeviceListAvailability {
        if FileManager.default.ubiquityIdentityToken == nil { return .noiCloudAccount }
        return Self.hasKeyValueStoreEntitlement ? .available : .notEntitled
    }

    /// Whether this build carries the iCloud key-value entitlement. Read from the signed
    /// provisioning profile rather than probing the store, which only logs when it's missing.
    private static let hasKeyValueStoreEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) else {
            #if targetEnvironment(simulator)
            return Bundle.main.object(forInfoDictionaryKey: "VantageSimulatorAssumesICloud") != nil
            #else
            return false
            #endif
        }
        return text.contains("com.apple.developer.ubiquity-kvstore-identifier")
    }()

    func push(devices: [SavedDevice], tombstones: [UUID: Date]) {
        guard isEnabled, deviceListAvailability == .available else { return }
        if let data = try? JSONEncoder().encode(devices) { store.set(data, forKey: Self.devicesKey) }
        let stamps = tombstones.reduce(into: [String: Double]()) { $0[$1.key.uuidString] = $1.value.timeIntervalSince1970 }
        store.set(stamps, forKey: Self.tombstonesKey)
        store.synchronize()
    }

    func pullNow() {
        guard isEnabled, deviceListAvailability == .available else { return }
        store.synchronize()
        deliverRemote()
    }

    private func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.deliverRemote() }
        }
        store.synchronize()
    }

    private func stopObserving() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func deliverRemote() {
        guard let data = store.data(forKey: Self.devicesKey),
              let devices = try? JSONDecoder().decode([SavedDevice].self, from: data) else { return }
        let raw = store.dictionary(forKey: Self.tombstonesKey) as? [String: Double] ?? [:]
        let tombstones = raw.reduce(into: [UUID: Date]()) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = Date(timeIntervalSince1970: entry.value) }
        }
        onRemoteDevices?(devices, tombstones)
    }
}

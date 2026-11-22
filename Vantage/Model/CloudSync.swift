import Foundation
import Observation
import VantageCore
import os

/// Keeps saved Macs, their passwords, and the Tailscale key the same on every device signed into
/// the same iCloud account, so setup happens once.
///
/// Secrets travel through iCloud Keychain (`kSecAttrSynchronizable`), which needs no entitlement.
/// The device list travels through iCloud key-value storage, which needs the
/// `com.apple.developer.ubiquity-kvstore-identifier` entitlement (`Vantage.entitlements`). A copy
/// signed without it (built on a team that hasn't enabled iCloud for its bundle ID) can't use the
/// store, so `deviceListAvailability` reports when that half is switched off and the settings
/// screen explains. Turning sync on migrates what's already saved; turning it off copies everything back
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
            #if os(macOS)
            case .noiCloudAccount: "Sign in to iCloud in System Settings to sync your computers."
            #else
            case .noiCloudAccount: "Sign in to iCloud in Settings to sync your computers."
            #endif
            case .notEntitled: "Passwords and your Tailscale key sync through iCloud Keychain. This copy of Casement isn't signed for iCloud storage, so your list of computers stays on this device."
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

    /// Saves to the store sync points at. When that's iCloud Keychain and it refuses (a Mac copy
    /// not signed for the data protection Keychain answers errSecMissingEntitlement), the secret
    /// is kept in this device's Keychain instead, so saving never fails just because sync can't
    /// carry it.
    static func storeSecret(_ value: String, account: String, service: String) throws {
        do {
            try secretsStore(service: service).set(value, for: account)
        } catch where shared.isEnabled {
            log.error("iCloud Keychain refused a secret, keeping it on this device: \(String(describing: error), privacy: .public)")
            try KeychainStore(service: service, synchronizable: false, unlockedOnly: true).set(value, for: account)
        }
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

    /// Turning sync on pulls what iCloud already has first (merged through `onRemoteDevices`);
    /// the caller then pushes the merged list. Pushing first replaced the list in iCloud with
    /// this device's, which on a new iPhone is empty.
    func setEnabled(_ enabled: Bool, devices: [SavedDevice]) {
        guard enabled != isEnabled else { return }
        migrateSecrets(toSynchronizable: enabled, devices: devices)
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            startObserving()
            pullNow()
        } else {
            stopObserving()
        }
    }

    /// Sync starts on by itself, once, on a device whose copy of Casement is signed for iCloud,
    /// signed into an iCloud account, and allowed to keep synced Keychain items, unless the
    /// person has already chosen either way. Setting things up once is the point, and a new
    /// device can't offer to bring the list over if it waits for a switch nobody knows about. A
    /// device without iCloud asks again next launch, so signing in later still turns it on.
    var shouldTurnOnByDefault: Bool {
        !isEnabled && UserDefaults.standard.object(forKey: Self.enabledKey) == nil
            && deviceListAvailability == .available && Self.keychainSyncWorks
    }

    /// iCloud Keychain takes an item here. Always on an iPhone or iPad; a Mac copy needs the data
    /// protection Keychain, which only a build signed with its App ID's profile gets. Tried once
    /// per launch with a throwaway item.
    static let keychainSyncWorks: Bool = {
        #if os(macOS)
        let probe = KeychainStore(service: DeviceSecrets.keychainService, synchronizable: true, unlockedOnly: true)
        do {
            try probe.set("probe", for: "sync-probe")
            try? probe.remove("sync-probe")
            return true
        } catch {
            log.error("iCloud Keychain unavailable to this copy: \(String(describing: error), privacy: .public)")
            return false
        }
        #else
        return true
        #endif
    }()

    private func migrateSecrets(toSynchronizable: Bool, devices: [SavedDevice]) {
        let accounts = TailscaleAccount.keychainAccounts.map { ($0, TailscaleAccount.keychainService) }
            + DeviceSecrets.allAccounts(for: devices).map { ($0, DeviceSecrets.keychainService) }
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

    /// Why sync isn't carrying everything on this device, if it isn't.
    var explanation: String? {
        if let list = deviceListAvailability.explanation { return list }
        guard !Self.keychainSyncWorks else { return nil }
        return "This copy of Casement can't use iCloud Keychain, so passwords and your Tailscale key stay on this Mac. Your list of computers still syncs."
    }

    // MARK: Device list

    private var store: NSUbiquitousKeyValueStore { .default }

    var deviceListAvailability: DeviceListAvailability {
        if FileManager.default.ubiquityIdentityToken == nil { return .noiCloudAccount }
        return Self.hasKeyValueStoreEntitlement ? .available : .notEntitled
    }

    /// Whether this build carries the iCloud key-value entitlement. Read from the signed
    /// provisioning profile rather than probing the store, which only logs when it's missing.
    /// iOS embeds it as `embedded.mobileprovision` in the bundle; a Mac app as
    /// `Contents/embedded.provisionprofile`.
    private static let hasKeyValueStoreEntitlement: Bool = {
        #if os(macOS)
        let profile: URL? = Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        #else
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        #endif
        guard let url = profile,
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

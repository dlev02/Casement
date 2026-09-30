import AppIntents
import Foundation
import Observation
import SwiftUI
import VantageCore
import WidgetKit

/// Persists saved devices and user preferences for the client.
@MainActor
@Observable
final class DeviceStore {
    #if os(visionOS) || os(macOS)
    /// visionOS and Mac sessions live in their own windows and share the list's store.
    static let shared = DeviceStore()
    #endif

    private let defaultsKey = "vantage.savedDevices"
    private let defaults = UserDefaults.standard

    var devices: [SavedDevice] = []
    var sort: DeviceSort = .lastConnected {
        didSet { defaults.set(sort.rawValue, forKey: "vantage.sort") }
    }
    var isGridLayout: Bool {
        didSet { defaults.set(isGridLayout, forKey: "vantage.grid") }
    }
    var searchText: String = ""
    /// Macs removed here, so a copy syncing back from iCloud doesn't resurrect them.
    private var tombstones: [UUID: Date] = [:]
    private let tombstonesKey = "vantage.deletedDevices"
    let cloud = CloudSync.shared

    init() {
        isGridLayout = defaults.bool(forKey: "vantage.grid")
        if let raw = defaults.string(forKey: "vantage.sort"), let sort = DeviceSort(rawValue: raw) {
            self.sort = sort
        }
        load()
        applyLaunchOptions()
        publishCatalog()
        cloud.onRemoteDevices = { [weak self] devices, tombstones in self?.merge(remote: devices, tombstones: tombstones) }
        cloud.pullNow()
    }

    // MARK: iCloud

    func setCloudSync(_ enabled: Bool) {
        cloud.setEnabled(enabled, devices: devices)
    }

    /// Folds in the list from another device: newer copy of each Mac wins, removals win over
    /// anything older than the removal, and Macs only known here are kept.
    private func merge(remote: [SavedDevice], tombstones remoteTombstones: [UUID: Date]) {
        var changed = false
        for (id, date) in remoteTombstones where (tombstones[id] ?? .distantPast) < date {
            tombstones[id] = date
            if let index = devices.firstIndex(where: { $0.id == id }),
               (devices[index].updatedAt ?? .distantPast) < date {
                devices.remove(at: index)
                DeviceSecrets.setPassword(nil, forID: id)
                changed = true
            }
        }
        for device in remote {
            if let deleted = tombstones[device.id], (device.updatedAt ?? .distantPast) < deleted { continue }
            if let index = devices.firstIndex(where: { $0.id == device.id }) {
                if (devices[index].updatedAt ?? .distantPast) < (device.updatedAt ?? .distantPast) {
                    devices[index] = device
                    changed = true
                }
            } else if !devices.contains(where: { $0.host == device.host && $0.port == device.port }) {
                devices.append(device)
                changed = true
            }
        }
        // A Mac added, renamed, or removed on another device has to reach Siri, Spotlight, and
        // the widgets too, not just local storage.
        if changed {
            persist()
            publishCatalog()
        }
    }

    private func applyLaunchOptions() {
        if let host = ClientOptions.seedHost ?? ClientOptions.autoConnectHost, !devices.contains(where: { $0.host == host }) {
            devices.append(SavedDevice(name: "My Mac", host: host))
            save()
        }
        if ClientOptions.seedSampleDevices, devices.count < 3 {
            devices.append(contentsOf: [
                SavedDevice(name: "My Mac", host: "studio-mac.example.ts.net", lastConnected: Date().addingTimeInterval(-300), connectionCount: 42),
                SavedDevice(name: "Office Mac", host: "office-mac.example.ts.net", os: "macOS", lastConnected: Date().addingTimeInterval(-86_400 * 3), connectionCount: 7),
                SavedDevice(name: "MacBook Air", host: "macbook-air.example.ts.net", lastConnected: nil, connectionCount: 0),
                SavedDevice(name: "Drew's PC", host: "drew-pc.example.ts.net", os: "Windows", lastConnected: Date().addingTimeInterval(-3_600), connectionCount: 3),
            ])
        }
    }

    var sortedDevices: [SavedDevice] {
        let filtered = searchText.isEmpty ? devices : devices.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) || $0.host.localizedCaseInsensitiveContains(searchText)
        }
        switch sort {
        case .name: return filtered.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        case .lastConnected: return filtered.sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
        case .connectionCount: return filtered.sorted { $0.connectionCount > $1.connectionCount }
        }
    }

    /// Returns the device as stored — adding a Mac that's already saved updates the existing entry
    /// rather than duplicating it, so the caller gets back the id that secrets belong under.
    @discardableResult
    func add(_ device: SavedDevice) -> SavedDevice {
        if let index = devices.firstIndex(where: { $0.host == device.host && $0.port == device.port }) {
            devices[index].name = device.name
            devices[index].updatedAt = Date()
            save()
            return devices[index]
        }
        var device = device
        device.updatedAt = Date()
        tombstones[device.id] = nil
        devices.append(device)
        save()
        return device
    }

    func remove(_ device: SavedDevice) {
        devices.removeAll { $0.id == device.id }
        tombstones[device.id] = Date()
        DeviceSecrets.setPassword(nil, for: device)
        save()
    }

    func markConnected(_ device: SavedDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].lastConnected = Date()
        devices[index].connectionCount += 1
        devices[index].updatedAt = Date()
        save()
    }

    func update(_ device: SavedDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index] = device
        devices[index].updatedAt = Date()
        save()
    }

    /// Gives one Mac its own session controls (nil goes back to the default). Stamped like any
    /// other edit, so the layout follows the Mac to other devices through iCloud.
    func setControlStrip(_ layout: ControlStripLayout?, for id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }), devices[index].controlStrip != layout else { return }
        devices[index].controlStrip = layout
        devices[index].updatedAt = Date()
        save()
    }

    /// Remembers whether this Mac's sound plays here. Stamped like any other edit, so it follows
    /// the Mac to other devices through iCloud.
    func setPlayMacAudio(_ on: Bool, for id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }), (devices[index].playMacAudio ?? false) != on else { return }
        devices[index].playMacAudio = on
        devices[index].updatedAt = Date()
        save()
    }

    /// Records what a device's host said it runs (its session, or the list's availability
    /// check), so a PC is shown and controlled as a PC before the next connection. Stamped like
    /// any other edit so other devices learn it too; nothing happens while it's unchanged.
    func recordPlatform(_ platform: HostPlatform, for id: UUID) {
        let os = platform.savedOS
        guard let index = devices.firstIndex(where: { $0.id == id }),
              devices[index].platform != platform, devices[index].os != os else { return }
        devices[index].os = os
        devices[index].updatedAt = Date()
        save()
    }

    /// `recordPlatform` for every device an availability check heard from.
    func recordPlatforms(_ platforms: [UUID: HostPlatform]) {
        for (id, platform) in platforms { recordPlatform(platform, for: id) }
    }

    private func load() {
        if let raw = defaults.dictionary(forKey: tombstonesKey) as? [String: Double] {
            tombstones = raw.reduce(into: [:]) { result, entry in
                if let id = UUID(uuidString: entry.key) { result[id] = Date(timeIntervalSince1970: entry.value) }
            }
        }
        guard let data = defaults.data(forKey: defaultsKey),
              var decoded = try? JSONDecoder().decode([SavedDevice].self, from: data) else {
            _ = ControlStripLayout.upgradeSavedLayouts(defaults: defaults, perMac: [])
            return
        }
        // A strip saved as an older standard layout picks up controls added since.
        let layouts = ControlStripLayout.upgradeSavedLayouts(defaults: defaults, perMac: decoded.map(\.controlStrip))
        for index in decoded.indices where decoded[index].controlStrip != layouts[index] {
            decoded[index].controlStrip = layouts[index]
        }
        devices = decoded
    }

    /// Saves locally, hands the list to iCloud when sync is on, and refreshes what Siri and the
    /// widgets know about.
    private func save() {
        #if DEBUG
        if ClientOptions.readOnlyDevices { return }
        #endif
        persist()
        cloud.push(devices: devices, tombstones: tombstones)
        publishCatalog()
    }

    /// Siri phrases, Spotlight, widgets, and the Control Center control read a small catalog
    /// rather than the full device list.
    private func publishCatalog() {
        let previous = Set(DeviceCatalog.load().map(\.id))
        let macs = catalogMacs
        DeviceCatalog.save(macs)
        WidgetCenter.shared.reloadTimelines(ofKind: DeviceCatalog.widgetKind)
        #if !os(visionOS) // no Control Center controls on visionOS
        ControlCenter.shared.reloadControls(ofKind: DeviceCatalog.controlKind)
        #endif
        VantageShortcuts.updateAppShortcutParameters()
        let removed = Array(previous.subtracting(macs.map(\.id)))
        Task { await MacSpotlight.sync(macs, removed: removed) }
    }

    private var catalogMacs: [DeviceCatalog.Mac] {
        devices.map { DeviceCatalog.Mac(id: $0.id, name: $0.name, host: $0.host, lastConnected: $0.lastConnected) }
    }

    /// Re-applies the Spotlight policy after the app lock is switched on or off: locked means no
    /// Macs in Spotlight at all.
    func refreshSpotlight() {
        let macs = catalogMacs
        Task { await MacSpotlight.sync(macs, removed: [], replacingAll: true) }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(devices), forKey: defaultsKey)
        let stamps = tombstones.reduce(into: [String: Double]()) { $0[$1.key.uuidString] = $1.value.timeIntervalSince1970 }
        defaults.set(stamps, forKey: tombstonesKey)
    }
}

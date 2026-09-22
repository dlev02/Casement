import Foundation
import Observation
import SwiftUI
import VantageCore

/// Persists saved devices and user preferences for the client.
@MainActor
@Observable
final class DeviceStore {
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

    init() {
        isGridLayout = defaults.bool(forKey: "vantage.grid")
        if let raw = defaults.string(forKey: "vantage.sort"), let sort = DeviceSort(rawValue: raw) {
            self.sort = sort
        }
        load()
        applyLaunchOptions()
    }

    private func applyLaunchOptions() {
        if let host = ClientOptions.seedHost ?? ClientOptions.autoConnectHost, !devices.contains(where: { $0.host == host }) {
            devices.append(SavedDevice(name: "Drew's MacBook Pro", host: host))
            save()
        }
        if ClientOptions.seedSampleDevices, devices.count < 3 {
            devices.append(contentsOf: [
                SavedDevice(name: "Drew's MacBook Pro", host: "drews-macbook-pro-1.tail1234.ts.net", lastConnected: Date().addingTimeInterval(-300), connectionCount: 42),
                SavedDevice(name: "Drew-PC", host: "drew-pc.tail1234.ts.net", os: "windows", lastConnected: Date().addingTimeInterval(-86_400 * 3), connectionCount: 7),
                SavedDevice(name: "Julie's MacBook Air", host: "julies-macbook-air.tail1234.ts.net", lastConnected: nil, connectionCount: 0),
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

    func add(_ device: SavedDevice) {
        if let index = devices.firstIndex(where: { $0.host == device.host && $0.port == device.port }) {
            devices[index].name = device.name
        } else {
            devices.append(device)
        }
        save()
    }

    func remove(_ device: SavedDevice) {
        devices.removeAll { $0.id == device.id }
        save()
    }

    func markConnected(_ device: SavedDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].lastConnected = Date()
        devices[index].connectionCount += 1
        save()
    }

    func update(_ device: SavedDevice) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index] = device
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedDevice].self, from: data) else { return }
        devices = decoded
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(devices), forKey: defaultsKey)
    }
}

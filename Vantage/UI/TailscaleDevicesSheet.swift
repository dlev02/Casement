import SwiftUI
import VantageCore

/// Lists the tailnet's devices from the Tailscale API so a Mac can be added with one tap.
/// Macs are probed for a running Vantage Host; other platforms are shown but can't be added.
struct TailscaleDevicesSheet: View {
    @Environment(DeviceStore.self) private var store
    @Environment(TailscaleAccount.self) private var account
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [TailscaleDevice] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var probes: [String: HostAvailability] = [:]
    @State private var justAdded: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if !account.isSignedIn && ClientOptions.tailscaleFixture == nil {
                    TailscaleAccountScreen { _ in Task { await load() } }
                } else {
                    deviceList
                }
            }
            .navigationTitle("Add from Tailscale")
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if account.isSignedIn || ClientOptions.tailscaleFixture != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .disabled(isLoading)
                    }
                }
            }
            .task { if account.isSignedIn || ClientOptions.tailscaleFixture != nil { await load() } }
        }
    }

    @ViewBuilder private var deviceList: some View {
        if isLoading && devices.isEmpty {
            ProgressView("Loading your tailnet…")
        } else if let errorMessage, devices.isEmpty {
            ContentUnavailableView {
                Label("Couldn't Load Devices", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again") { Task { await load() } }.buttonStyle(.glassProminent)
                Button("Sign Out") { account.signOut() }
            }
        } else {
            List {
                if macs.isEmpty {
                    Section {
                        Text("No Macs on this tailnet yet.").foregroundStyle(.secondary)
                    } header: {
                        Text("Macs")
                    }
                } else {
                    Section {
                        ForEach(macs) { device in macRow(device) }
                    } header: {
                        Text("Macs")
                    } footer: {
                        Text("To control a Mac, install Vantage Host on it, grant Screen Recording and Accessibility, and pair once with the code it shows.")
                    }
                }
                if !unsupported.isEmpty {
                    Section {
                        ForEach(unsupported) { device in unsupportedRow(device) }
                    } header: {
                        Text("Not Supported Yet")
                    } footer: {
                        Text("Vantage Host runs on macOS only. Windows and Linux hosting may come later; iPhones, iPads, and Android devices can't be controlled.")
                    }
                }
            }
            .overlay(alignment: .top) {
                if isLoading { ProgressView().padding(8).glassEffect().padding(.top, 8) }
            }
        }
    }

    private func macRow(_ device: TailscaleDevice) -> some View {
        let existing = isAlreadySaved(device)
        return HStack(spacing: 14) {
            DeviceIconTile(os: "macOS", size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName).font(.body.weight(.semibold)).lineLimit(1)
                Text(device.magicDNSName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                probeLabel(for: device)
            }
            Spacer(minLength: 12)
            if existing || justAdded.contains(device.id) {
                Label("Added", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Add") { add(device) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func unsupportedRow(_ device: TailscaleDevice) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10.5, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay { Image(systemName: device.platform.symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName).font(.body.weight(.semibold)).lineLimit(1)
                Text(device.magicDNSName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(unsupportedReason(device.platform)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func probeLabel(for device: TailscaleDevice) -> some View {
        let status = probes[device.id] ?? .checking
        HStack(spacing: 6) {
            if status == .checking {
                ProgressView().controlSize(.mini)
                Text(device.isRecentlySeen ? "Checking for Vantage Host…" : "Last seen \(lastSeenText(device))")
            } else {
                Circle().fill(status == .ready || status == .online || status == .pairingRequired ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(probeText(status, device: device))
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func probeText(_ status: HostAvailability, device: TailscaleDevice) -> String {
        switch status {
        case .ready: "Vantage Host is ready"
        case .online: "Vantage Host is running"
        case .pairingRequired: "Vantage Host is running · pair to connect"
        case .needsPermission: "Vantage Host needs Mac permissions"
        case .incompatible: "Vantage Host needs an update"
        case .unavailable: device.isRecentlySeen ? "Vantage Host isn't running on this Mac" : "Last seen \(lastSeenText(device))"
        case .checking: "Checking…"
        }
    }

    private func unsupportedReason(_ platform: TailscaleDevice.Platform) -> String {
        switch platform {
        case .windows: "Windows hosting isn't available yet"
        case .linux: "Linux hosting isn't available yet"
        case .iOS, .android: "Can't be controlled remotely"
        case .mac: ""
        case .other: "Not supported"
        }
    }

    private func lastSeenText(_ device: TailscaleDevice) -> String {
        guard let date = device.lastSeenDate else { return "a while ago" }
        return date.formatted(.relative(presentation: .named))
    }

    private var localAddresses: Set<String> { Set(VantageNetwork.localTailscaleAddresses()) }

    private var macs: [TailscaleDevice] {
        devices.filter { $0.platform.isSupported && $0.addresses.allSatisfy { !localAddresses.contains($0) } }
    }

    private var unsupported: [TailscaleDevice] {
        devices.filter { !$0.platform.isSupported && $0.addresses.allSatisfy { !localAddresses.contains($0) } }
    }

    private func isAlreadySaved(_ device: TailscaleDevice) -> Bool {
        store.devices.contains { saved in
            saved.host.caseInsensitiveCompare(device.magicDNSName) == .orderedSame || device.addresses.contains(saved.host)
        }
    }

    private func add(_ device: TailscaleDevice) {
        let host = device.tailnetIPv4 ?? device.magicDNSName
        store.add(SavedDevice(name: device.displayName, host: host))
        withAnimation(.snappy) { _ = justAdded.insert(device.id) }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            devices = try await account.devices()
            await probeMacs()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Probes each Mac for a running Vantage Host using the normal readiness check.
    private func probeMacs() async {
        let identity = (try? KeychainStore(service: "com.benjaminlevinson.vantage.client").loadOrCreateIdentity()) ?? DeviceIdentity()
        let targets = macs
        for device in targets { probes[device.id] = .checking }
        await withTaskGroup(of: (String, HostAvailability).self) { group in
            for device in targets {
                guard let host = device.tailnetIPv4 ?? Optional(device.magicDNSName) else { continue }
                let probe = SavedDevice(name: device.displayName, host: host)
                group.addTask { (device.id, await HostAvailabilityProbe.check(probe, identity: identity, timeout: .seconds(4))) }
            }
            for await (id, status) in group { probes[id] = status }
        }
    }
}

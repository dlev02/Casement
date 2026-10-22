import SwiftUI
import VantageCore

/// Lists the tailnet's devices from the Tailscale API so a Mac or PC can be added with one tap.
/// Macs and PCs are probed for a running Vantage Host; other platforms are shown but can't be added.
struct TailscaleDevicesSheet: View {
    @Environment(DeviceStore.self) private var store
    @Environment(TailscaleAccount.self) private var account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                        if isLoading {
                            ProgressView().accessibilityLabel("Refreshing")
                        } else {
                            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        }
                    }
                }
            }
            .task { if account.isSignedIn || ClientOptions.tailscaleFixture != nil { await load() } }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 440, idealHeight: 560)
        #endif
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
                if !addedJustNow.isEmpty {
                    Section {
                        ForEach(addedJustNow) { device in nextStepRow(device) }
                    } header: {
                        Text("Next Step")
                    }
                }
                if macs.isEmpty {
                    Section {
                        Text("No Macs or PCs on this tailnet yet.").foregroundStyle(.secondary)
                    } header: {
                        Text("Macs and PCs")
                    }
                } else {
                    Section {
                        ForEach(macs) { device in macRow(device) }
                    } header: {
                        Text("Macs and PCs")
                    } footer: {
                        Text("To control a Mac or PC, install Casement Host on it and pair once with the code it shows. On a Mac, also grant Screen Recording and Accessibility.")
                    }
                }
                if !unsupported.isEmpty {
                    Section {
                        ForEach(unsupported) { device in unsupportedRow(device) }
                    } header: {
                        Text("Not Supported")
                    } footer: {
                        Text("Casement Host runs on Macs and Windows PCs. Linux computers, iPhones, iPads, and Android devices can't be controlled.")
                    }
                }
            }
            .refreshable { await load() }
        }
    }

    private func macRow(_ device: TailscaleDevice) -> some View {
        let existing = isAlreadySaved(device)
        return HStack(spacing: 14) {
            DeviceIconTile(os: device.os, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName).font(.body.weight(.semibold)).lineLimit(lineLimit)
                Text(device.magicDNSName).font(.subheadline).foregroundStyle(.secondary).lineLimit(lineLimit)
                probeLabel(for: device)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            if existing || justAdded.contains(device.id) {
                Label("Added", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Add") { add(device) }
                    #if os(macOS)
                    .buttonStyle(.bordered) // a glass button in every row of a sheet is a lot of glass
                    #else
                    .buttonStyle(.glassProminent)
                    #endif
                    .controlSize(.small)
                    .accessibilityLabel("Add \(device.displayName)")
            }
        }
        .padding(.vertical, 4)
    }

    /// Computers added in this sheet, in the order they're listed.
    private var addedJustNow: [TailscaleDevice] { macs.filter { justAdded.contains($0.id) } }

    /// What to do on a computer just added: pairing happens there, in Casement Host, and nothing
    /// in this app says so until the first connection asks for a code.
    private func nextStepRow(_ device: TailscaleDevice) -> some View {
        let host = HostNoun(device.platform == .windows ? .windows : .macOS)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pair with \(device.displayName)").font(.body.weight(.semibold))
                Text("On \(device.displayName), \(host.pairingInstruction) Then connect from here and type in the code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tailscale.nextStep")
    }

    private func unsupportedRow(_ device: TailscaleDevice) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10.5, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay { Image(systemName: device.platform.symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName).font(.body.weight(.semibold)).lineLimit(lineLimit)
                Text(device.magicDNSName).font(.subheadline).foregroundStyle(.secondary).lineLimit(lineLimit)
                Text(unsupportedReason(device.platform)).font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .foregroundStyle(.secondary)
    }

    /// Names and addresses stay on one line, except at accessibility sizes, where they wrap.
    private var lineLimit: Int? { dynamicTypeSize.isAccessibilitySize ? nil : 1 }

    @ViewBuilder private func probeLabel(for device: TailscaleDevice) -> some View {
        let status = probes[device.id] ?? .checking
        HStack(spacing: 6) {
            if status == .checking {
                ProgressView().controlSize(.mini)
                Text(device.isRecentlySeen ? "Checking for Casement Host…" : "Last seen \(lastSeenText(device))")
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
        case .ready: "Casement Host is ready"
        case .online: "Casement Host is running"
        case .pairingRequired: "Casement Host is running · pair to connect"
        case .needsPermission: device.platform == .windows ? "Casement Host needs permissions" : "Casement Host needs Mac permissions"
        case .incompatible: "Casement Host needs an update"
        case .unavailable: device.isRecentlySeen ? "Casement Host isn't reachable" : "Last seen \(lastSeenText(device))"
        case .checking: "Checking…"
        }
    }

    private func unsupportedReason(_ platform: TailscaleDevice.Platform) -> String {
        switch platform {
        case .linux: "Linux hosting isn't available"
        case .iOS, .android: "Can't be controlled remotely"
        case .mac, .windows: ""
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
        store.add(SavedDevice(name: device.displayName, host: host,
                              os: device.platform == .windows ? HostPlatform.windows.savedOS : HostPlatform.macOS.savedOS))
        withAnimation(.snappy) { _ = justAdded.insert(device.id) }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            devices = try await account.devices()
            #if DEBUG
            // `-VantageTailscaleJustAdded 1` (with the fixture): a Mac and a PC as if just added,
            // to screenshot the pairing step without tapping (AXe taps don't reach this app).
            if ProcessInfo.processInfo.arguments.contains("-VantageTailscaleJustAdded") { justAdded = ["1", "3"] }
            #endif
            await probeMacs()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Probes each Mac and PC for a running Vantage Host using the normal readiness check.
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

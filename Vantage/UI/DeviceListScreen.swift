import SwiftUI
import VantageCore

/// Home screen: a searchable, sortable list/grid of saved devices with Tailscale status.
struct DeviceListScreen: View {
    @Environment(DeviceStore.self) private var store
    @Environment(TailscaleReachability.self) private var reachability
    @State private var showAddDevice = false
    @State private var editingDevice: SavedDevice?
    @Binding var selectedDevice: SavedDevice?
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability = HostAvailabilityStore()
    @AppStorage("vantage.availabilityChecks") private var availabilityChecks = true

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Group {
                if store.devices.isEmpty {
                    emptyState
                } else if store.sortedDevices.isEmpty {
                    ContentUnavailableView.search(text: store.searchText)
                } else if store.isGridLayout {
                    gridView
                } else {
                    listView
                }
            }
            .navigationTitle("Vantage")
            .searchable(text: $store.searchText, prompt: "Search devices")
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .top) { tailscaleBanner }
            .sheet(isPresented: $showAddDevice) {
                AddDeviceSheet()
            }
            .sheet(item: $editingDevice) { device in
                AddDeviceSheet(existing: device)
            }
            .task {
                if let host = ClientOptions.autoConnectHost, selectedDevice == nil {
                    selectedDevice = store.devices.first { $0.host == host }
                }
            }
            .task(id: availabilityKey) {
                guard scenePhase == .active, selectedDevice == nil, availabilityChecks else { return }
                await availability.monitor(store.devices)
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(store.sortedDevices) { device in
                Button { selectedDevice = device } label: {
                    DeviceRow(device: device, availability: availability.statuses[device.id] ?? .checking)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) { store.remove(device) } label: { Label("Delete", systemImage: "trash") }
                    Button { editingDevice = device } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                }
            }
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                ForEach(store.sortedDevices) { device in
                    Button { selectedDevice = device } label: {
                        DeviceCard(device: device, availability: availability.statuses[device.id] ?? .checking)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { editingDevice = device } label: { Label("Edit", systemImage: "pencil") }
                        Button(role: .destructive) { store.remove(device) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .padding()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Devices", systemImage: "display")
        } description: {
            Text("Add your Mac to start a remote session over Tailscale.")
        } actions: {
            Button("Add Device") { showAddDevice = true }.buttonStyle(.glassProminent)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink { SettingsScreen() } label: { Label("Settings", systemImage: "gearshape") }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: sortBinding) {
                    ForEach(DeviceSort.allCases) { sort in
                        Label(sort.label, systemImage: sort.symbol).tag(sort)
                    }
                }
                Divider()
                Button { store.isGridLayout.toggle() } label: {
                    Label(store.isGridLayout ? "List" : "Grid", systemImage: store.isGridLayout ? "list.bullet" : "square.grid.2x2")
                }
            } label: {
                Label("Sort and Layout", systemImage: "arrow.up.arrow.down")
            }
            Button { showAddDevice = true } label: { Label("Add Device", systemImage: "plus") }
        }
    }

    private var sortBinding: Binding<DeviceSort> {
        Binding(get: { store.sort }, set: { store.sort = $0 })
    }

    private var availabilityKey: String {
        guard scenePhase == .active, selectedDevice == nil, availabilityChecks else { return "paused" }
        return store.devices.map { "\($0.id):\($0.host):\($0.port)" }.joined(separator: "|")
    }

    @ViewBuilder
    private var tailscaleBanner: some View {
        if !reachability.isActive {
            HStack(spacing: 8) {
                Image(systemName: "network.slash")
                Text("Tailscale isn’t connected")
                Spacer()
                Button("Open") { TailscaleReachability.openTailscaleApp() }
                    .buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(12)
            .glassEffect(in: .rect(cornerRadius: 16))
            .padding(.horizontal)
        }
    }
}

struct DeviceRow: View {
    let device: SavedDevice
    var availability: HostAvailability = .checking
    var body: some View {
        HStack(spacing: 14) {
            DeviceIconTile(os: device.os, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(device.host)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                AvailabilityLabel(status: availability)
            }
            Spacer(minLength: 12)
            if let last = device.lastConnected {
                Text(lastConnectedText(last))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct DeviceCard: View {
    let device: SavedDevice
    var availability: HostAvailability = .checking
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                DeviceIconTile(os: device.os, size: 48)
                Spacer()
                if let last = device.lastConnected {
                    Text(lastConnectedText(last))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(device.host).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                AvailabilityLabel(status: availability)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }
}

/// The rounded, tinted tile used for device icons in the list and grid.
struct DeviceIconTile: View {
    let os: String
    var size: CGFloat = 44
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Color.accentColor.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: osSymbol(os))
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)
    }
}

private struct AvailabilityLabel: View {
    let status: HostAvailability
    var body: some View {
        HStack(spacing: 6) {
            if status == .checking {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(status.tint).frame(width: 7, height: 7)
            }
            Text(status.label)
                .font(.footnote)
                .foregroundStyle(status.isWarning ? status.tint : .secondary)
        }
        .padding(.top, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Host status: \(status.label)")
    }
}

private func lastConnectedText(_ date: Date) -> String {
    if Date().timeIntervalSince(date) < 60 { return "Just now" }
    return date.formatted(.relative(presentation: .named))
}

private extension HostAvailability {
    var tint: Color {
        switch self {
        case .ready, .online: .green
        case .pairingRequired, .needsPermission, .incompatible: .orange
        case .checking, .unavailable: .secondary
        }
    }
    var isWarning: Bool {
        switch self {
        case .pairingRequired, .needsPermission, .incompatible: true
        default: false
        }
    }
}

func osSymbol(_ os: String) -> String {
    switch os.lowercased() {
    case let value where value.contains("mac"): "macbook"
    case let value where value.contains("windows"): "pc"
    case let value where value.contains("ios"): "ipad"
    default: "display"
    }
}

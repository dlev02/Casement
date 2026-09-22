import SwiftUI
import VantageCore

/// Home screen: a searchable, sortable list/grid of saved devices with Tailscale status.
struct DeviceListScreen: View {
    @Environment(DeviceStore.self) private var store
    @Environment(TailscaleReachability.self) private var reachability
    @State private var showAddDevice = false
    @State private var editingDevice: SavedDevice?
    @State private var selectedDevice: SavedDevice?

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
            .fullScreenCover(item: $selectedDevice) { device in
                RemoteSessionScreen(device: device)
            }
            .task {
                if let host = ClientOptions.autoConnectHost, selectedDevice == nil {
                    selectedDevice = store.devices.first { $0.host == host }
                }
            }
        }
    }

    private var listView: some View {
        List {
            ForEach(store.sortedDevices) { device in
                Button { selectedDevice = device } label: {
                    DeviceRow(device: device)
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
                        DeviceCard(device: device)
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
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: osSymbol(device.os))
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline)
                Text(device.host).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let last = device.lastConnected {
                Text(last, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct DeviceCard: View {
    let device: SavedDevice
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: osSymbol(device.os)).font(.largeTitle).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline).lineLimit(1)
                Text(device.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .glassEffect(in: .rect(cornerRadius: 20))
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

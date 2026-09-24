import SwiftUI
import VantageCore

/// Home screen: a searchable, sortable list/grid of saved devices with Tailscale status.
struct DeviceListScreen: View {
    @Environment(DeviceStore.self) private var store
    @Environment(TailscaleReachability.self) private var reachability
    @State private var showAddDevice = false
    @State private var showTailscaleDevices = false
    @State private var editingDevice: SavedDevice?
    @State private var deviceToDelete: SavedDevice?
    @State private var deviceToLogIn: SavedDevice?
    @State private var logInStatus: LogInStatus?
    @Binding var selectedDevice: SavedDevice?
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability = HostAvailabilityStore()
    @AppStorage("vantage.availabilityChecks") private var availabilityChecks = true
    /// Files keep moving with a Mac after its session closes; its row shows them.
    private let transfers = FileTransferCenter.shared
    @State private var transfersDevice: SavedDevice?

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
            .sheet(isPresented: $showTailscaleDevices) {
                TailscaleDevicesSheet()
            }
            .sheet(item: $editingDevice) { device in
                AddDeviceSheet(existing: device)
            }
            .sheet(item: $transfersDevice) { device in
                NavigationStack {
                    TransfersView(files: transfers.link(for: device).files, macName: device.name)
                }
            }
            .confirmationDialog(
                deviceToDelete.map { "Remove “\($0.name)”?" } ?? "",
                isPresented: Binding(get: { deviceToDelete != nil }, set: { if !$0 { deviceToDelete = nil } }),
                titleVisibility: .visible,
                presenting: deviceToDelete
            ) { device in
                Button("Remove Device", role: .destructive) { store.remove(device) }
                Button("Cancel", role: .cancel) {}
            } message: { device in
                Text("\(device.host) will be removed from this device list. The Mac itself is not affected, and you can add it again later.")
            }
            .confirmationDialog(
                deviceToLogIn.map { "Log in to “\($0.name)”?" } ?? "",
                isPresented: Binding(get: { deviceToLogIn != nil }, set: { if !$0 { deviceToLogIn = nil } }),
                titleVisibility: .visible,
                presenting: deviceToLogIn
            ) { device in
                Button("Type Password") { logIn(to: device) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Vantage signs in to the Mac's Screen Sharing and types your saved password and Return. Use this when the Mac is at its login or lock screen, for example after a restart.")
            }
            .overlay(alignment: .bottom) {
                if let logInStatus {
                    LogInStatusBadge(status: logInStatus)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: logInStatus)
            .task {
                if selectedDevice == nil, let host = ClientOptions.takeAutoConnectHost() {
                    selectedDevice = store.devices.first { $0.host == host }
                }
                if ClientOptions.openTailscaleDevices { showTailscaleDevices = true }
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
                DeviceListItem(device: device, availability: availability.statuses[device.id] ?? .checking,
                               files: transfers.files(for: device.id),
                               onOpen: { selectedDevice = device }, onShowTransfers: { transfersDevice = device })
                .swipeActions {
                    Button(role: .destructive) { deviceToDelete = device } label: { Label("Delete", systemImage: "trash") }
                    Button { editingDevice = device } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                    if ScreenSharingPassword.canLogIn(device) {
                        Button { deviceToLogIn = device } label: { Label("Log In", systemImage: "key") }.tint(.orange)
                    }
                }
                .contextMenu { deviceMenu(for: device) }
            }
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                ForEach(store.sortedDevices) { device in
                    DeviceCard(device: device, availability: availability.statuses[device.id] ?? .checking,
                               files: transfers.files(for: device.id),
                               onOpen: { selectedDevice = device }, onShowTransfers: { transfersDevice = device })
                    #if os(visionOS)
                    .contentShape(.hoverEffect, .rect(cornerRadius: 20))
                    .hoverEffect()
                    #endif
                    .contextMenu { deviceMenu(for: device) }
                }
            }
            .padding()
            #if os(visionOS)
            .padding(.horizontal, 8) // line the cards up with the window's toolbar and list insets
            #endif
        }
    }

    @ViewBuilder
    private func deviceMenu(for device: SavedDevice) -> some View {
        if transfers.files(for: device.id)?.hasTransfers == true {
            Button { transfersDevice = device } label: { Label("Transfers…", systemImage: "arrow.up.arrow.down") }
        }
        Button { editingDevice = device } label: { Label("Edit", systemImage: "pencil") }
        if ScreenSharingPassword.canLogIn(device) {
            Button { deviceToLogIn = device } label: { Label("Log In with Screen Sharing", systemImage: "key") }
        }
        Button(role: .destructive) { deviceToDelete = device } label: { Label("Delete", systemImage: "trash") }
    }

    private func logIn(to device: SavedDevice) {
        logInStatus = .typing(device.name)
        Task {
            do {
                try await ScreenSharingPassword.logIn(to: device)
                logInStatus = .sent(device.name)
                try? await Task.sleep(for: .seconds(3))
            } catch {
                logInStatus = .failed(ScreenSharingPassword.message(for: error))
                try? await Task.sleep(for: .seconds(6))
            }
            logInStatus = nil
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Devices", systemImage: "display")
        } description: {
            Text("Add your Mac to start a remote session over Tailscale.")
        } actions: {
            Button("Add from Tailscale") { showTailscaleDevices = true }.buttonStyle(.glassProminent)
            Button("Add Manually") { showAddDevice = true }.buttonStyle(.glass)
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
            Menu {
                Button { showTailscaleDevices = true } label: { Label("Add from Tailscale…", systemImage: "network") }
                Button { showAddDevice = true } label: { Label("Add Manually…", systemImage: "keyboard") }
            } label: {
                Label("Add Device", systemImage: "plus")
            }
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
            .platformGlass(in: .rect(cornerRadius: 16))
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

/// A Mac in the list: its row opens the session, and while files move with it a line under the
/// name shows them (its own button, so it isn't swallowed by the row's).
private struct DeviceListItem: View {
    let device: SavedDevice
    let availability: HostAvailability
    let files: FileTransferController?
    let onOpen: () -> Void
    let onShowTransfers: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                DeviceRow(device: device, availability: availability)
            }
            .buttonStyle(.plain)
            if let files, files.hasActiveTransfers {
                DeviceTransferBadge(files: files, macName: device.name, onOpen: onShowTransfers)
                    .padding(.leading, 58) // under the name, past the 44 pt icon and its spacing
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: files?.hasActiveTransfers == true)
    }
}

/// A Mac in the grid: the card opens the session; while files move with it a line at the
/// bottom shows them.
struct DeviceCard: View {
    let device: SavedDevice
    var availability: HostAvailability = .checking
    var files: FileTransferController?
    var onOpen: () -> Void = {}
    var onShowTransfers: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onOpen) {
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
                .contentShape(.rect)
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.plain)
            if let files, files.hasActiveTransfers {
                DeviceTransferBadge(files: files, macName: device.name, onOpen: onShowTransfers)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .platformGlass(in: .rect(cornerRadius: 20))
        .animation(.easeOut(duration: 0.2), value: files?.hasActiveTransfers == true)
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

/// Progress of "Log In with Screen Sharing" from the device list.
enum LogInStatus: Equatable {
    case typing(String), sent(String), failed(String)
}

private struct LogInStatusBadge: View {
    let status: LogInStatus

    var body: some View {
        HStack(spacing: 10) {
            switch status {
            case .typing(let name):
                ProgressView().controlSize(.small)
                Text("Logging in to \(name)…")
            case .sent(let name):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Password sent to \(name). Connect once it finishes logging in.")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
            }
        }
        .font(.callout)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .platformGlass(in: .rect(cornerRadius: 22))
        .frame(maxWidth: 560)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI
import UniformTypeIdentifiers
import VantageCore

/// Home screen: a searchable, sortable list/grid of saved devices with Tailscale status.
struct DeviceListScreen: View {
    @Environment(DeviceStore.self) private var store
    @State private var actions = DeviceActions()
    @Binding var selectedDevice: SavedDevice?
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability = HostAvailabilityStore()
    @AppStorage("vantage.availabilityChecks") private var availabilityChecks = true
    /// Files keep moving with a Mac after its session closes; its row shows them.
    private let transfers = FileTransferCenter.shared

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Group {
                if store.devices.isEmpty {
                    DeviceListEmptyState(actions: actions)
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
            .safeAreaInset(edge: .top) { TailscaleBanner() }
            .deviceActionPresentations(actions)
            .task {
                if selectedDevice == nil, let host = ClientOptions.takeAutoConnectHost() {
                    selectedDevice = store.devices.first { $0.host == host }
                }
                #if DEBUG
                // `-VantageSendTestFile` without a session: as if picked with Send Files… on the first Mac.
                if ClientOptions.autoConnectHost == nil, let bytes = ClientOptions.takeSendTestFileBytes(),
                   let device = store.devices.first {
                    transfers.link(for: device).files.queueTestFile(bytes: bytes)
                }
                #endif
                if ClientOptions.openTailscaleDevices { actions.showTailscaleDevices = true }
            }
            .task(id: availabilityKey) {
                guard scenePhase == .active, selectedDevice == nil, availabilityChecks else { return }
                await availability.monitor(store.devices)
            }
            .onChange(of: availability.platforms) { _, platforms in store.recordPlatforms(platforms) }
        }
    }

    private var listView: some View {
        List {
            ForEach(store.sortedDevices) { device in
                DeviceListItem(device: device, availability: availability.statuses[device.id] ?? .checking,
                               files: transfers.files(for: device.id),
                               onOpen: { selectedDevice = device }, onShowTransfers: { actions.transfersDevice = device },
                               onSendFiles: { actions.sendFiles(to: device) }, dropFiles: { transfers.link(for: device).files })
                .swipeActions {
                    Button(role: .destructive) { actions.deviceToDelete = device } label: { Label("Delete", systemImage: "trash") }
                    Button { actions.editingDevice = device } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                    if ScreenSharingPassword.canLogIn(device) {
                        Button { actions.deviceToLogIn = device } label: { Label("Log In", systemImage: "key") }.tint(.orange)
                    }
                }
                .contextMenu { DeviceMenu(device: device, actions: actions) }
            }
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                ForEach(store.sortedDevices) { device in
                    DeviceCard(device: device, availability: availability.statuses[device.id] ?? .checking,
                               files: transfers.files(for: device.id),
                               onOpen: { selectedDevice = device }, onShowTransfers: { actions.transfersDevice = device },
                               onSendFiles: { actions.sendFiles(to: device) }, dropFiles: { transfers.link(for: device).files })
                    #if os(visionOS)
                    .contentShape(.hoverEffect, .rect(cornerRadius: 20))
                    .hoverEffect()
                    #endif
                    .contextMenu { DeviceMenu(device: device, actions: actions) }
                }
            }
            .padding()
            #if os(visionOS)
            .padding(.horizontal, 8) // line the cards up with the window's toolbar and list insets
            #endif
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .listLeading) {
            NavigationLink { SettingsScreen() } label: { Label("Settings", systemImage: "gearshape") }
        }
        ToolbarItemGroup(placement: .listTrailing) {
            Menu {
                DeviceSortPicker()
                Divider()
                Button { store.isGridLayout.toggle() } label: {
                    Label(store.isGridLayout ? "List" : "Grid", systemImage: store.isGridLayout ? "list.bullet" : "square.grid.2x2")
                }
            } label: {
                Label("Sort and Layout", systemImage: "arrow.up.arrow.down")
            }
            AddDeviceMenu(actions: actions)
        }
    }

    private var availabilityKey: String {
        guard scenePhase == .active, selectedDevice == nil, availabilityChecks else { return "paused" }
        return store.devices.map { "\($0.id):\($0.host):\($0.port)" }.joined(separator: "|")
    }
}

/// Everything the device list asks for besides opening a session: adding, editing, and removing
/// Macs, sending them files, and logging in through Screen Sharing. The list (and on the Mac, the
/// sidebar and the menu bar) sets these; `deviceActionPresentations` presents them.
@MainActor
@Observable
final class DeviceActions {
    #if os(macOS)
    /// The Mac has one device list window; the menu bar reaches it from any window, a session's too.
    static let shared = DeviceActions()
    #endif

    var showAddDevice = false
    var showTailscaleDevices = false
    var editingDevice: SavedDevice?
    var deviceToDelete: SavedDevice?
    var deviceToLogIn: SavedDevice?
    var logInStatus: LogInStatus?
    var transfersDevice: SavedDevice?
    /// Send Files… picks files for this Mac without opening its screen.
    var sendFilesDevice: SavedDevice?
    var showSendFiles = false

    /// Files for this Mac, straight from the Files picker: they go over a files-only session, and
    /// the Mac's row shows them moving.
    func sendFiles(to device: SavedDevice) {
        sendFilesDevice = device
        showSendFiles = true
    }

    func logIn(to device: SavedDevice) {
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
}

extension View {
    /// The sheets, file picker, and confirmations behind `DeviceActions`.
    func deviceActionPresentations(_ actions: DeviceActions) -> some View {
        modifier(DeviceActionPresentations(actions: actions))
    }
}

private struct DeviceActionPresentations: ViewModifier {
    @Bindable var actions: DeviceActions
    @Environment(DeviceStore.self) private var store
    private let transfers = FileTransferCenter.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $actions.showAddDevice) {
                AddDeviceSheet().appLockCurtain()
            }
            .sheet(isPresented: $actions.showTailscaleDevices) {
                TailscaleDevicesSheet().appLockCurtain()
            }
            .sheet(item: $actions.editingDevice) { device in
                AddDeviceSheet(existing: device).appLockCurtain()
            }
            .sheet(item: $actions.transfersDevice) { device in
                NavigationStack {
                    TransfersView(files: transfers.link(for: device).files, macName: device.name, host: device.hostNoun)
                }
                #if os(macOS)
                .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 480)
                #endif
                .appLockCurtain()
            }
            .fileImporter(isPresented: $actions.showSendFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result, !urls.isEmpty, let device = actions.sendFilesDevice else { return }
                transfers.link(for: device).files.send(urls, securityScoped: true)
            }
            .confirmationDialog(
                actions.deviceToDelete.map { "Remove “\($0.name)”?" } ?? "",
                isPresented: Binding(get: { actions.deviceToDelete != nil }, set: { if !$0 { actions.deviceToDelete = nil } }),
                titleVisibility: .visible,
                presenting: actions.deviceToDelete
            ) { device in
                Button("Remove Device", role: .destructive) { store.remove(device) }
                Button("Cancel", role: .cancel) {}
            } message: { device in
                Text("\(device.host) will be removed from this device list. \(device.hostNoun.theCapitalized) itself is not affected, and you can add it again later.")
            }
            .confirmationDialog(
                actions.deviceToLogIn.map { "Log in to “\($0.name)”?" } ?? "",
                isPresented: Binding(get: { actions.deviceToLogIn != nil }, set: { if !$0 { actions.deviceToLogIn = nil } }),
                titleVisibility: .visible,
                presenting: actions.deviceToLogIn
            ) { device in
                Button("Type Password") { actions.logIn(to: device) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Vantage signs in to the Mac's Screen Sharing and types your saved password and Return. Use this when the Mac is at its login or lock screen, for example after a restart.")
            }
            .overlay(alignment: .bottom) {
                if let logInStatus = actions.logInStatus {
                    LogInStatusBadge(status: logInStatus)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.3), value: actions.logInStatus)
    }
}

/// A Mac's context menu, in the list and grid, and in the Mac's sidebar.
struct DeviceMenu: View {
    let device: SavedDevice
    let actions: DeviceActions
    private let transfers = FileTransferCenter.shared

    var body: some View {
        Section {
            Button { actions.sendFiles(to: device) } label: { Label("Send Files…", systemImage: StripItem.sendFile.symbol) }
            if transfers.files(for: device.id)?.hasTransfers == true {
                Button { actions.transfersDevice = device } label: { Label("Transfers…", systemImage: "arrow.up.arrow.down") }
            }
        }
        Button { actions.editingDevice = device } label: { Label(Self.editTitle, systemImage: "pencil") }
        if ScreenSharingPassword.canLogIn(device) {
            Button { actions.deviceToLogIn = device } label: { Label("Log In with Screen Sharing", systemImage: "key") }
        }
        Button(role: .destructive) { actions.deviceToDelete = device } label: { Label("Delete", systemImage: "trash") }
    }

    #if os(macOS)
    static let editTitle = "Edit…" // it opens a sheet
    #else
    static let editTitle = "Edit"
    #endif
}

/// Add from Tailscale, or by name or address.
struct AddDeviceMenu: View {
    let actions: DeviceActions

    var body: some View {
        Menu {
            Button { actions.showTailscaleDevices = true } label: { Label("Add from Tailscale…", systemImage: "network") }
            Button { actions.showAddDevice = true } label: { Label("Add Manually…", systemImage: "keyboard") }
        } label: {
            Label("Add Device", systemImage: "plus")
        }
    }
}

/// How the device list is ordered.
struct DeviceSortPicker: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        Picker("Sort", selection: Binding(get: { store.sort }, set: { store.sort = $0 })) {
            ForEach(DeviceSort.allCases) { sort in
                Label(sort.label, systemImage: sort.symbol).tag(sort)
            }
        }
    }
}

/// No Macs saved yet: how to add the first one.
struct DeviceListEmptyState: View {
    let actions: DeviceActions

    var body: some View {
        ContentUnavailableView {
            Label("No Devices", systemImage: "display")
        } description: {
            Text("Add your Mac or PC to start a remote session over Tailscale.")
        } actions: {
            Button("Add from Tailscale") { actions.showTailscaleDevices = true }.buttonStyle(.glassProminent)
            Button("Add Manually") { actions.showAddDevice = true }.buttonStyle(.glass)
        }
    }
}

/// Shown above the list while Tailscale is off on this device, with a way to open it.
struct TailscaleBanner: View {
    @Environment(TailscaleReachability.self) private var reachability

    var body: some View {
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
    let onSendFiles: () -> Void
    /// Files dropped on the row go to this Mac's queue.
    let dropFiles: () -> FileTransferController
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                DeviceRow(device: device, availability: availability)
            }
            .buttonStyle(.plain)
            .accessibilityAction(named: "Send Files") { onSendFiles() }
            if let files, files.hasActiveTransfers {
                DeviceTransferBadge(files: files, macName: device.name, onOpen: onShowTransfers)
                    .padding(.leading, 58) // under the name, past the 44 pt icon and its spacing
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: files?.hasActiveTransfers == true)
        .overlay(alignment: .trailing) {
            if isDropTargeted { DropTargetHint(macName: device.name).transition(.opacity) }
        }
        .animation(.easeOut(duration: isDropTargeted ? 0.2 : 0.15), value: isDropTargeted)
        .onDrop(of: [.item], delegate: FileDropDelegate(isEnabled: true, isTargeted: $isDropTargeted, files: dropFiles))
    }
}

/// "Drop to send to ⟨Mac⟩" at the end of a row or the foot of a card while files hover over it.
struct DropTargetHint: View {
    let macName: String

    var body: some View {
        Label("Drop to send", systemImage: StripItem.sendFile.symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor, in: .capsule)
            .accessibilityLabel("Drop to send to \(macName)")
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
    var onSendFiles: () -> Void = {}
    var dropFiles: (() -> FileTransferController)?
    @State private var isDropTargeted = false
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
            .accessibilityAction(named: "Send Files") { onSendFiles() }
            if let files, files.hasActiveTransfers {
                DeviceTransferBadge(files: files, macName: device.name, onOpen: onShowTransfers)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .platformGlass(in: .rect(cornerRadius: 20))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .overlay(alignment: .bottomTrailing) { DropTargetHint(macName: device.name).padding(12) }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: files?.hasActiveTransfers == true)
        .animation(.easeOut(duration: isDropTargeted ? 0.2 : 0.15), value: isDropTargeted)
        .onDrop(of: [.item], delegate: FileDropDelegate(isEnabled: dropFiles != nil, isTargeted: $isDropTargeted,
                                                        files: { dropFiles?() ?? FileTransferController() }))
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

struct AvailabilityLabel: View {
    let status: HostAvailability
    /// Increased on a selected Mac sidebar row, where an orange word on the accent fill is hard to read.
    @Environment(\.backgroundProminence) private var prominence
    var body: some View {
        HStack(spacing: 6) {
            if status == .checking {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(status.tint).frame(width: 7, height: 7)
            }
            Text(status.label)
                .font(.footnote)
                .foregroundStyle(status.isWarning && prominence != .increased ? status.tint : .secondary)
        }
        .padding(.top, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Host status: \(status.label)")
    }
}

func lastConnectedText(_ date: Date) -> String {
    if Date().timeIntervalSince(date) < 60 { return "Just now" }
    return date.formatted(.relative(presentation: .named))
}

extension HostAvailability {
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

struct LogInStatusBadge: View {
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

private extension ToolbarItemPlacement {
    #if os(macOS) // the Mac has no top bar
    static var listLeading: Self { .navigation }
    static var listTrailing: Self { .primaryAction }
    #else
    static var listLeading: Self { .topBarLeading }
    static var listTrailing: Self { .topBarTrailing }
    #endif
}

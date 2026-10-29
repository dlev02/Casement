import SwiftUI
import VantageCore

/// Which Settings tab is up, so the menu can open Settings on one (Paired Devices → Devices).
@MainActor
@Observable
final class HostSettingsNavigation {
    static let shared = HostSettingsNavigation()
    var tab = HostOptions.shared.openSettingsTab ?? "general"
}

struct HostSettingsView: View {
    @Bindable var controller: HostController
    @AppStorage(RestartGuard.defaultsKey) private var confirmRestart = true
    @Bindable private var navigation = HostSettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            devicesTab
                .tabItem { Label("Devices", systemImage: "ipad.and.iphone") }
                .tag("devices")
            FilesSettingsTab()
                .tabItem { Label("Files", systemImage: "arrow.down.doc") }
                .tag("files")
            readinessTab
                .tabItem { Label("Reboot", systemImage: "power.circle") }
                .tag("reboot")
            DictationSettingsTab(parakeet: ParakeetModel.shared)
                .tabItem { Label("Dictation", systemImage: "waveform") }
                .tag("dictation")
        }
        .frame(width: 500, height: 500)
    }

    // Every tab follows System Settings: a row says what it is (and at most one short line under
    // it says what it does); anything longer goes in the section's footer; values and buttons sit
    // on the trailing edge, and a button names what it will do in the current state.

    private var readinessTab: some View {
        Form {
            Section {
                Toggle(isOn: $confirmRestart) {
                    Text("Ask before restarting, shutting down, or logging out")
                    Text("Including restarts from Software Update")
                }
                if controller.canRestartSafely {
                    LabeledContent("Restart without stopping at FileVault") {
                        Button("Restart Safely…") { controller.restartSafely() }
                    }
                }
            } header: {
                Text("While a device is connected")
            } footer: {
                Footer(controller.canRestartSafely
                       ? "Casement Host asks first and can cancel the restart. Restart Safely unlocks FileVault by itself for one restart, so the Mac comes back at the login window; it's also offered when you restart while connected."
                       : "Casement Host asks first and can cancel the restart.")
            }
            Section {
                Toggle("Start Casement Host at login", isOn: Binding(
                    get: { controller.loginItem.isEnabled },
                    set: { controller.loginItem.setEnabled($0) }))
                if controller.loginItem.requiresApproval {
                    LabeledContent("Waiting for your approval") {
                        Button("Open Login Items…") { controller.loginItem.openLoginItemsSettings() }
                    }
                }
            } header: {
                Text("After a restart")
            } footer: {
                Footer("Once you log in, Casement Host opens and your devices reconnect by themselves.")
            }
            Section {
                if let report = controller.readiness {
                    LabeledContent("FileVault") {
                        Text(report.fileVaultOn.map { $0 ? "On" : "Off" } ?? "Unknown").foregroundStyle(.secondary)
                    }
                    LabeledContent("Remote Login (SSH)") { serviceState(report.remoteLoginEnabled) }
                    LabeledContent {
                        serviceState(report.screenSharingEnabled)
                    } label: {
                        Text("Screen Sharing")
                        Text("Types your password at the lock screen")
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            } header: {
                HStack {
                    Text("Before login")
                    Spacer()
                    Button("Check Again") { controller.refreshReadiness() }
                        .controlSize(.small)
                }
            } footer: {
                Footer(beforeLoginFooter)
            }
        }
        .formStyle(.grouped)
    }

    private var beforeLoginFooter: String {
        let lockScreen = "macOS blocks apps from typing into the lock screen and password fields, so the key button on your iPad types your saved password through this Mac's own Screen Sharing instead."
        guard controller.readiness?.fileVaultOn == true else { return lockScreen }
        return "With FileVault on, an unexpected restart waits at the FileVault screen, where Tailscale isn't running. To recover from afar, keep Remote Login on and a Tailscale subnet router at home, then SSH to this Mac's home address to unlock it. " + lockScreen
    }

    /// On, or Off with a button to Sharing settings.
    @ViewBuilder private func serviceState(_ on: Bool) -> some View {
        if on {
            Label("On", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            HStack(spacing: 10) {
                Text("Off").foregroundStyle(.secondary)
                Button("Turn On…") { Self.openSharingSettings() }
            }
        }
    }

    private static func openSharingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private var generalTab: some View {
        Form {
            Section("This Mac") {
                LabeledContent("Name on your tailnet") {
                    Text(controller.tailscaleSelfName.isEmpty ? "—" : controller.tailscaleSelfName)
                        .textSelection(.enabled)
                }
                LabeledContent("Tailscale admin console") {
                    Button("Open") { controller.openTailscaleAdmin() }
                }
                LabeledContent {
                    Text(controller.fingerprint)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                } label: {
                    Text("Identity")
                    Text("Paired devices check this key")
                }
            }
            Section {
                LabeledContent {
                    permissionState(controller.hasScreenPermission) { controller.requestScreenPermission() }
                } label: {
                    Text("Screen Recording")
                    Text("To show this Mac's screen")
                }
                LabeledContent {
                    permissionState(controller.hasInputPermission) { controller.requestInputPermission() }
                } label: {
                    Text("Accessibility")
                    Text("To click and type on this Mac")
                }
            } header: {
                Text("Permissions")
            } footer: {
                if controller.permissionStillMissingAfterAsking {
                    Footer(HostPermission.staleEntryHelp)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Live while the tab is up, so Allowed appears as soon as macOS grants it.
            while !Task.isCancelled {
                controller.refreshPermissions()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    @State private var removing: TrustStore.TrustedClient?
    @State private var renaming: TrustStore.TrustedClient?
    @State private var newName = ""

    private var devicesTab: some View {
        Form {
            Section {
                if controller.trustedClients.isEmpty {
                    ContentUnavailableView("No Paired Devices", systemImage: "ipad.and.iphone",
                                           description: Text("Choose Pair a Device in the menu bar and enter the code in Casement."))
                } else {
                    let connected = Set(controller.connectedDevices.map(\.fingerprint))
                    ForEach(controller.trustedClients.sorted { $0.addedAt > $1.addedAt }) { client in
                        LabeledContent {
                            HStack(spacing: 12) {
                                if connected.contains(client.id) { ConnectedBadge() }
                                Button("Rename…") { newName = client.name; renaming = client }
                                Button("Remove…") { removing = client }
                            }
                        } label: {
                            Label {
                                Text(client.name)
                                Text("Paired \(client.addedAt, format: .relative(presentation: .named))")
                            } icon: {
                                // One width for every glyph, so the names line up.
                                Image(systemName: client.symbol)
                                    .frame(width: 22)
                            }
                        }
                        .help("Key \(client.fingerprint)")
                    }
                }
            } header: {
                Text("Paired devices")
            } footer: {
                Footer("A removed device is disconnected and needs a new pairing code to connect again.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove \(removing?.name ?? "this device")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { client in
            Button("Remove", role: .destructive) { controller.revoke(client.fingerprint) }
        } message: { _ in
            Text("It's disconnected now and needs a new pairing code to connect again.")
        }
        .alert("Rename \(renaming?.name ?? "Device")", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { client in
            TextField("Name", text: $newName)
            Button("Rename") { controller.rename(client.fingerprint, to: newName) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Allowed, or a button that asks for it.
    @ViewBuilder private func permissionState(_ granted: Bool, request: @escaping () -> Void) -> some View {
        if granted {
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            Button("Allow…", action: request)
        }
    }
}

/// A section footer in Settings: caption, secondary, wrapping.
struct Footer: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

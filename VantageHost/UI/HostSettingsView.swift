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

    private var readinessTab: some View {
        Form {
            Section("While connected") {
                Toggle("Ask before restarting, shutting down, or logging out", isOn: $confirmRestart)
                Text("If a device is connected when macOS starts a restart (including one from Software Update), Porthole Host asks first and can cancel it.")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.canRestartSafely {
                    Button("Restart Safely…") { controller.restartSafely() }
                    Text("Restart Safely unlocks FileVault by itself for one restart, so the Mac comes back at the login window instead of stopping at the FileVault screen. It's also offered when you restart while connected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("After a reboot") {
                Toggle("Start Porthole Host at login", isOn: Binding(
                    get: { controller.loginItem.isEnabled },
                    set: { controller.loginItem.setEnabled($0) }))
                if controller.loginItem.requiresApproval {
                    Button("Approve in Login Items…") { controller.loginItem.openLoginItemsSettings() }
                }
                Text("Once you log in, Porthole Host relaunches and your iPad reconnects automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Before login") {
                if let report = controller.readiness {
                    LabeledContent("FileVault") { statusText(report.fileVaultOn.map { $0 ? "On" : "Off" } ?? "Unknown") }
                    LabeledContent("Remote Login (SSH)") { statusBadge(report.remoteLoginEnabled) }
                    LabeledContent("Screen Sharing") { statusBadge(report.screenSharingEnabled) }
                    if report.fileVaultOn == true {
                        Text("With FileVault on, an unexpected restart waits at the FileVault screen, where Tailscale isn't running. To recover from afar, keep Remote Login on and a Tailscale subnet router at home, then SSH to this Mac's home address to unlock it. For restarts you start yourself, use Restart Safely.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Re-check") { controller.refreshReadiness() }
            }
            Section("Locked screen") {
                Text("macOS blocks typing from apps into the lock screen and password fields (Secure Input). When that happens, the iPad's key button types your saved password through this Mac's own Screen Sharing instead, so keep Screen Sharing on (System Settings → General → Sharing) and allow your account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func statusText(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private var generalTab: some View {
        Form {
            Section("This Mac") {
                LabeledContent("Identity", value: controller.fingerprint)
                LabeledContent("Tailscale", value: controller.tailscaleSelfName.isEmpty ? "—" : controller.tailscaleSelfName)
                Button("Open Tailscale Admin Console") { controller.openTailscaleAdmin() }
            }
            Section("Permissions") {
                LabeledContent("Screen Recording") {
                    statusBadge(controller.hasScreenPermission)
                }
                LabeledContent("Accessibility (input)") {
                    statusBadge(controller.hasInputPermission)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var devicesTab: some View {
        Form {
            Section("Paired devices") {
                if controller.trustedClients.isEmpty {
                    ContentUnavailableView("No paired devices", systemImage: "ipad", description: Text("Show a pairing code and enter it on your iPad."))
                } else {
                    ForEach(controller.trustedClients) { client in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(client.name)
                                Text(client.fingerprint).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                controller.revoke(client.fingerprint)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Revoke \(client.name)'s access; it will need a new pairing code")
                            .accessibilityLabel("Revoke \(client.name)")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func statusBadge(_ granted: Bool) -> some View {
        Label(granted ? "Granted" : "Needed", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(granted ? .green : .orange)
            .labelStyle(.titleAndIcon)
    }
}

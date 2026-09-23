import SwiftUI
import VantageCore

struct HostSettingsView: View {
    @Bindable var controller: HostController

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            devicesTab
                .tabItem { Label("Devices", systemImage: "ipad.and.iphone") }
            readinessTab
                .tabItem { Label("Reboot", systemImage: "power.circle") }
        }
        .frame(width: 500, height: 420)
    }

    private var readinessTab: some View {
        Form {
            Section("After a reboot") {
                Toggle("Start Vantage Host at login", isOn: Binding(
                    get: { controller.loginItem.isEnabled },
                    set: { controller.loginItem.setEnabled($0) }))
                if controller.loginItem.requiresApproval {
                    Button("Approve in Login Items…") { controller.loginItem.openLoginItemsSettings() }
                }
                Text("Once you log in, Vantage Host relaunches and your iPad reconnects automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Before login") {
                if let report = controller.readiness {
                    LabeledContent("FileVault") { statusText(report.fileVaultOn.map { $0 ? "On" : "Off" } ?? "Unknown") }
                    LabeledContent("Remote Login (SSH)") { statusBadge(report.remoteLoginEnabled) }
                    LabeledContent("Screen Sharing") { statusBadge(report.screenSharingEnabled) }
                    if report.fileVaultOn == true {
                        Text("With FileVault on, a cold boot waits at the pre-boot unlock screen. Tailscale is not running there, so Vantage cannot reach the Mac until someone unlocks it (macOS 26+ can unlock over SSH from the local network only). A restart that keeps the disk unlocked, or a Mac left logged in, reconnects on its own.")
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

import LocalAuthentication
import SwiftUI
import VantageCore

struct SettingsScreen: View {
    @Environment(TailscaleReachability.self) private var reachability
    @AppStorage("vantage.requireBiometrics") private var requireBiometrics = false
    @AppStorage("vantage.trackpadSensitivity") private var trackpadSensitivity = 1.5

    var body: some View {
        Form {
            Section("Network") {
                LabeledContent("Tailscale") {
                    Label(reachability.isActive ? "Connected" : "Not connected",
                          systemImage: reachability.isActive ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(reachability.isActive ? .green : .red)
                        .labelStyle(.titleAndIcon)
                }
                Button("Open Tailscale") { TailscaleReachability.openTailscaleApp() }
                Link("Tailscale Admin Console", destination: URL(string: "https://login.tailscale.com/admin/machines")!)
            }
            Section("Security") {
                Toggle("Require Face ID / Touch ID", isOn: $requireBiometrics)
                Text("Locks Vantage when you leave and return, protecting saved connections.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Input") {
                VStack(alignment: .leading) {
                    Text("Trackpad sensitivity")
                    Slider(value: $trackpadSensitivity, in: 0.5...3.0, step: 0.1)
                }
            }
            Section("About") {
                LabeledContent("Version", value: "1.0")
                LabeledContent("Protocol", value: String(VantageProtocol.version))
            }
        }
        .navigationTitle("Settings")
    }
}

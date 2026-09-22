import SwiftUI

struct SettingsScreen: View {
    var body: some View {
        List {
            Section {
                NavigationLink { AppearanceSettings() } label: { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                NavigationLink { ControlSettings() } label: { Label("Controls", systemImage: "keyboard") }
            }
            Section {
                NavigationLink { ConnectionSettings() } label: { Label("Connection", systemImage: "network") }
                NavigationLink { SecuritySettings() } label: { Label("Privacy & Security", systemImage: "lock.shield") }
            }
            Section {
                LabeledContent("Version", value: version)
                Text("Your Mac, wherever you are.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "1.0") (\(info["CFBundleVersion"] as? String ?? "—"))"
    }
}

private struct AppearanceSettings: View {
    @AppStorage("vantage.appearance") private var appearance = AppAppearance.automatic
    var body: some View {
        Form {
            Section {
                Picker("Color scheme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { choice in Text(choice.label).tag(choice) }
                }
                .pickerStyle(.inline)
            } footer: {
                Text("Automatic follows your iPad or iPhone. Appearance changes Vantage's controls and screens, not the remote Mac desktop.")
            }
        }
        .navigationTitle("Appearance")
    }
}

private struct ControlSettings: View {
    @AppStorage("vantage.trackpadSensitivity") private var sensitivity = 1.5
    @AppStorage("vantage.toolbarDock") private var dock = ToolbarDock.bottomLeft
    @AppStorage("vantage.toolbarCollapsed") private var collapsed = false
    var body: some View {
        Form {
            Section("Session toolbar") {
                Picker("Position", selection: $dock) {
                    ForEach(ToolbarDock.allCases) { position in Text(position.label).tag(position) }
                }
                Toggle("Collapsed", isOn: $collapsed)
                Text("Drag the toolbar or compact keyboard control to any corner. Tap the chevron to expand or collapse. Your position is remembered.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Trackpad") {
                LabeledContent("Sensitivity", value: sensitivity.formatted(.number.precision(.fractionLength(1))))
                Slider(value: $sensitivity, in: 0.5...3, step: 0.1)
                    .accessibilityLabel("Trackpad sensitivity")
            }
            Section("Keyboard") {
                LabeledContent("Hardware keyboard", value: "Keystrokes")
                LabeledContent("On-screen keyboard", value: "Unicode text")
                Text("Hardware keys follow the Mac's keyboard layout. On-screen text supports accented characters and emoji; Return and Delete send keystrokes. Neither mode can bypass a locked Mac or a secure input restriction.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Controls")
    }
}

private struct ConnectionSettings: View {
    @Environment(TailscaleReachability.self) private var reachability
    var body: some View {
        Form {
            Section("This device") {
                LabeledContent("Tailscale") {
                    Label(reachability.isActive ? "Detected" : "Not detected", systemImage: "network")
                        .foregroundStyle(reachability.isActive ? Color.green : Color.secondary)
                }
                Button("Open Tailscale") { TailscaleReachability.openTailscaleApp() }
                Link("Manage Tailscale devices", destination: URL(string: "https://login.tailscale.com/admin/machines")!)
            }
            Section("Availability") {
                Text("Vantage checks saved hosts while the device list is open. Available means Vantage Host answered; Unavailable can mean the Mac is asleep, the host is closed, or the network cannot reach it.")
                Text("No desktop previews are captured for these checks.").foregroundStyle(.secondary)
            }
            Section("Returning to a session") {
                Text("Switch back to Vantage to reconnect to your open session immediately. Closing a session returns you to the device list. An unreachable Mac is retried for several minutes; Close remains available.")
            }
        }
        .navigationTitle("Connection")
    }
}

private struct SecuritySettings: View {
    @AppStorage("vantage.requireBiometrics") private var requireBiometrics = false
    var body: some View {
        Form {
            Section {
                Toggle("Require Face ID / Touch ID", isOn: $requireBiometrics)
            } footer: {
                Text("Unlock Vantage with biometrics or your device passcode after leaving the app. An open session resumes after you unlock.")
            }
        }
        .navigationTitle("Privacy & Security")
    }
}

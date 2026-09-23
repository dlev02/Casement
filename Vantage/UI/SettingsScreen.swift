import SwiftUI
import VantageCore

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
                NavigationLink { AboutScreen() } label: {
                    HStack {
                        Label("About Vantage", systemImage: "info.circle")
                        Spacer()
                        Text(AppInfo.versionString).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }
}

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—" }
    static var versionString: String { "\(version) (\(build))" }
    static let websiteURL = URL(string: "https://drewlevinson.me")!
    static let githubURL = URL(string: "https://github.com/dlev02")!
}

private struct AppearanceSettings: View {
    @AppStorage("vantage.appearance") private var appearance = AppAppearance.automatic
    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { choice in Text(choice.label).tag(choice) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Automatic follows the system setting. This changes Vantage's own screens and controls, not the Mac you're viewing.")
            }
        }
        .navigationTitle("Appearance")
    }
}

struct ControlSettings: View {
    @AppStorage("vantage.touchMode") private var touchMode = InputController.TouchMode.trackpad
    @AppStorage("vantage.trackpadSensitivity") private var sensitivity = 1.5
    @AppStorage("vantage.softwareKeyboardMode") private var keyboardMode = SoftwareKeyboardMode.unicode
    @AppStorage("vantage.toolbarDock") private var dock = ToolbarDock.bottomLeft
    @AppStorage("vantage.toolbarCollapsed") private var collapsed = false
    @AppStorage("vantage.pencilSqueeze") private var pencilSqueeze = PencilAction.collapseControls
    @AppStorage("vantage.pencilDoubleTap") private var pencilDoubleTap = PencilAction.rightClick
    @AppStorage("vantage.dictationEngine") private var dictationEngine = DictationEnginePreference.mac
    @AppStorage(DictationEnginePreference.macOffersParakeetKey) private var macOffersParakeet = false

    var body: some View {
        Form {
            #if os(visionOS)
            Section {
                LabeledContent("Click", value: "Look and pinch")
                LabeledContent("Drag", value: "Pinch and move")
                LabeledContent("Right-Click", value: "Pinch and hold")
            } header: {
                Text("Pointer")
            } footer: {
                Text("The Mac's pointer goes where you were looking when you pinch.")
            }
            #else
            Section {
                Picker("Touch", selection: $touchMode) {
                    ForEach(InputController.TouchMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Trackpad Sensitivity")
                        Spacer()
                        Text(sensitivity.formatted(.number.precision(.fractionLength(1))) + "×")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $sensitivity, in: 0.5...3, step: 0.1)
                        .accessibilityLabel("Trackpad sensitivity")
                }
            } header: {
                Text("Pointer")
            } footer: {
                Text("Trackpad moves the Mac's pointer like a laptop trackpad and taps to click. Direct Touch clicks exactly where you tap.")
            }

            Section {
                Picker("On-Screen Keyboard", selection: $keyboardMode) {
                    ForEach(SoftwareKeyboardMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Unicode Text sends exactly what you type, including accents, emoji, and dictation. Keystrokes sends real key presses using the Mac's US layout, which some apps, games, terminals, and virtual machines require. Holding ⌘, ⌥, or ⌃ in the session controls always sends keystrokes, so ⌘C works from either mode. Hardware keyboards always send keystrokes.")
            }

            Section {
                Picker("Position", selection: $dock) {
                    ForEach(ToolbarDock.allCases) { position in
                        Label(position.label, systemImage: position.symbol).tag(position)
                    }
                }
                Toggle("Start Collapsed", isOn: $collapsed)
            } header: {
                Text("Session Controls")
            } footer: {
                Text("You can also drag the controls to any corner during a session.")
            }

            Section {
                Picker("Squeeze", selection: $pencilSqueeze) {
                    ForEach(PencilAction.allCases) { action in
                        Label(action.label, systemImage: action.symbol).tag(action)
                    }
                }
                Picker("Double-Tap", selection: $pencilDoubleTap) {
                    ForEach(PencilAction.allCases) { action in
                        Label(action.label, systemImage: action.symbol).tag(action)
                    }
                }
            } header: {
                Text("Apple Pencil")
            } footer: {
                Text("The Pencil always clicks exactly where it touches, and Pencil Pro moves the Mac's pointer while hovering. Squeeze needs Pencil Pro; double-tap works on Pencil (2nd generation) and later. Collapse Controls also brings hidden controls back.")
            }
            #endif
        }
        .navigationTitle("Controls")
    }
}

private struct ConnectionSettings: View {
    @Environment(TailscaleReachability.self) private var reachability
    @Environment(TailscaleAccount.self) private var account
    @AppStorage("vantage.availabilityChecks") private var availabilityChecks = true

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    TailscaleAccountScreen()
                } label: {
                    HStack {
                        Text("Tailscale Account")
                        Spacer()
                        Text(account.isSignedIn ? "Signed In" : "Not Signed In").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Sign in with a read-only key to add Macs straight from your tailnet's device list.")
            }
            Section {
                HStack {
                    Text("Tailscale")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(reachability.isActive ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(reachability.isActive ? "Connected" : "Not Connected")
                    }
                    .foregroundStyle(.secondary)
                }
                if let address = reachability.address {
                    HStack {
                        Text("This Device")
                        Spacer()
                        Text(address).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Button("Open Tailscale") { TailscaleReachability.openTailscaleApp() }
                Link("Manage Tailscale Devices", destination: URL(string: "https://login.tailscale.com/admin/machines")!)
            } header: {
                Text("Network")
            } footer: {
                Text("Vantage only connects to Macs on your tailnet. Traffic never leaves Tailscale's encrypted tunnel.")
            }

            Section {
                Toggle("Check Availability", isOn: $availabilityChecks)
            } header: {
                Text("Device List")
            } footer: {
                Text("Shows whether each saved Mac is reachable and ready while the list is open. Nothing from the Mac's screen is captured for this.")
            }
        }
        .navigationTitle("Connection")
    }
}

struct SecuritySettings: View {
    @AppStorage("vantage.requireBiometrics") private var requireBiometrics = false
    @Environment(DeviceStore.self) private var store

    var body: some View {
        let cloud = store.cloud
        Form {
            Section {
                Toggle("Require Face ID / Touch ID", isOn: $requireBiometrics)
            } footer: {
                Text("Unlock Vantage with biometrics or your device passcode after leaving the app. An open session resumes after you unlock.")
            }

            Section {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { cloud.isEnabled },
                    set: { store.setCloudSync($0) }
                ))
                if cloud.isEnabled, let explanation = cloud.deviceListAvailability.explanation {
                    Label(explanation, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Keeps your saved Macs, their passwords, and your Tailscale key the same on every iPhone, iPad, and Vision Pro signed into your iCloud account, so you set Vantage up once. Secrets travel through iCloud Keychain, end-to-end encrypted; Apple can't read them and neither can anyone else.")
            }
        }
        .navigationTitle("Privacy & Security")
    }
}

struct AboutScreen: View {

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    AppIconTile()
                        .padding(.bottom, 6)
                    Text("Vantage")
                        .font(.title.weight(.bold))
                    Text("Your Mac, wherever you are.")
                        .foregroundStyle(.secondary)
                    Text("Version \(AppInfo.versionString)")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                LinkRow(title: "Website", symbol: "globe", destination: AppInfo.websiteURL)
                LinkRow(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", destination: AppInfo.githubURL)
            } header: {
                Text("Designed and built by Drew Levinson")
            }

            Section {
                Text("Vantage streams your Mac with ScreenCaptureKit and hardware video encoding, and connects only across your own Tailscale network. There is no account and no relay server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("How It Works")
            }
        }
        .navigationTitle("About")
    }
}

private struct AppIconTile: View {
    var body: some View {
        Group {
            if let icon = Bundle.main.primaryIconName, let image = UIImage(named: icon) {
                Image(uiImage: image).resizable()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.18, green: 0.45, blue: 1.0), Color(red: 0.05, green: 0.2, blue: 0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "macbook.and.ipad")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .accessibilityHidden(true)
    }
}

private struct LinkRow: View {
    let title: String
    let symbol: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack {
                Label(title, systemImage: symbol)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private extension Bundle {
    /// Name of the primary app icon set, if the bundle declares one.
    var primaryIconName: String? {
        guard let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String] else { return nil }
        return files.last
    }
}

#if canImport(UIKit)
import UIKit
#endif

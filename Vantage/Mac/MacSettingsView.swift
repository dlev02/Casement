#if os(macOS)
import SwiftUI

/// Vantage › Settings… (⌘,): the same settings as the iPad's, as tabs. Settings is a scene of
/// its own, so it gets the store, the lock, and Tailscale state from `macWindowRoot` rather than
/// from the device list (`ConnectionSettings` reads Tailscale from the environment).
struct MacSettingsView: View {
    @AppStorage("vantage.mac.settingsTab") private var tab = Tab.general

    enum Tab: String {
        case general, controls, connection, security
    }

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab("General", systemImage: "gearshape", value: Tab.general) {
                page { MacGeneralSettings() }
            }
            SwiftUI.Tab("Controls", systemImage: "keyboard", value: Tab.controls) {
                page { ControlSettings() }
            }
            SwiftUI.Tab("Connection", systemImage: "network", value: Tab.connection) {
                page { ConnectionSettings() }
            }
            SwiftUI.Tab("Privacy & Security", systemImage: "hand.raised", value: Tab.security) {
                page { SecuritySettings() }
            }
        }
        .frame(width: 560)
        .macWindowRoot()
        .accessibilityIdentifier("settings")
    }

    /// Each tab can drill in (Customize Controls, the Tailscale account), so each has a stack.
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        SettingsPage(content: content())
    }
}

/// One tab, sized to what it shows, like the Settings windows of Apple's own apps: a short tab
/// makes a short window rather than a tall one that's mostly empty, and a long one stops at
/// `maxHeight` and scrolls.
private struct SettingsPage<Content: View>: View {
    let content: Content
    @State private var contentHeight: CGFloat?

    private static var minHeight: CGFloat { 160 }
    private static var maxHeight: CGFloat { 620 }

    var body: some View {
        NavigationStack {
            content
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    // The toolbar's inset is outside this frame already; keep a margin under the
                    // last footer like System Settings.
                    geometry.contentSize.height + 20
                } action: { _, height in
                    contentHeight = height
                }
        }
        .formStyle(.grouped)
        .frame(height: contentHeight.map { min(max($0, Self.minHeight), Self.maxHeight) } ?? 420)
    }
}

/// How Vantage looks.
private struct MacGeneralSettings: View {
    @AppStorage("vantage.appearance") private var appearance = AppAppearance.automatic

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { choice in Text(choice.label).tag(choice) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Automatic follows the system setting. This changes Casement's own windows and controls, not the Mac you're viewing.")
            }
        }
        .navigationTitle("General")
    }
}
#endif

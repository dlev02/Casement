import SwiftUI
import VantageCore

/// The menu-bar popover: shows status, permissions, pairing, and controls.
struct HostMenuView: View {
    @Bindable var controller: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            statusSection
            if !controller.hasScreenPermission || !controller.hasInputPermission {
                Divider()
                permissionsSection
            }
            Divider()
            HostFilesSection(controller: controller)
            Divider()
            pairingSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .task {
            while !Task.isCancelled {
                controller.refreshPermissions()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("VantageLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Vantage Host").font(.headline)
                Text(controller.tailscaleSelfName.isEmpty ? "This Mac" : controller.tailscaleSelfName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow(icon: statusIcon, tint: statusTint, title: statusTitle)
            statusRow(icon: controller.tailscaleRunning ? "checkmark.circle.fill" : "xmark.circle.fill",
                      tint: controller.tailscaleRunning ? .green : .red,
                      title: controller.tailscaleRunning ? "Tailscale connected" : "Tailscale not running")
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permissions needed").font(.subheadline.weight(.semibold))
            if !controller.hasScreenPermission {
                Button {
                    controller.requestScreenPermission()
                } label: {
                    Label("Grant Screen Recording", systemImage: "rectangle.dashed.badge.record")
                }
            }
            if !controller.hasInputPermission {
                Button {
                    controller.requestInputPermission()
                } label: {
                    Label("Grant Accessibility (input)", systemImage: "hand.tap")
                }
            }
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pairing").font(.subheadline.weight(.semibold))
            if let code = controller.pairingCode {
                HStack {
                    Text(code)
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .tracking(4)
                    Spacer()
                    Text("Enter on iPad").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                controller.generatePairingCode()
            } label: {
                Label("Show pairing code", systemImage: "key.horizontal")
            }
            if !controller.trustedClients.isEmpty {
                Text("^[\(controller.trustedClients.count) paired device](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            Spacer()
            if controller.canRestartSafely {
                Button("Restart Safely…") { controller.restartSafely() }
                    .help("Restart without stopping at the FileVault screen")
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    private func statusRow(icon: String, tint: Color, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
                .accessibilityHidden(true) // the title says it
            Text(title).font(.callout)
            Spacer()
        }
    }

    private var statusIcon: String {
        switch controller.status {
        case .connected: "person.fill.checkmark"
        case .listening: "antenna.radiowaves.left.and.right"
        case .error: "exclamationmark.triangle.fill"
        case .idle: "pause.circle"
        }
    }

    private var statusTint: Color {
        switch controller.status {
        case .connected: .green
        case .listening: .blue
        case .error: .red
        case .idle: .secondary
        }
    }

    private var statusTitle: String {
        switch controller.status {
        // A plain String, so no markdown inflection: spell out the plural.
        case .connected(let count): count == 1 ? "1 client connected" : "\(count) clients connected"
        case .listening: "Ready for connections"
        case .error(let message): message
        case .idle: "Not listening"
        }
    }
}

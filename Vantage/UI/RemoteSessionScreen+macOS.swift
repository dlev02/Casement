#if os(macOS)
import AppKit
import SwiftUI
import VantageCore

// MARK: - Mac client

extension RemoteSessionLayout {
    /// Pointer and keys go to the Mac.
    private var sendsInput: Bool {
        model.isConnected && !model.isViewOnly && !AppLock.shared.isLocked
    }

    @ViewBuilder var macSessionSurface: some View {
        #if DEBUG
        RemoteSessionNSRepresentable(input: model.input, video: model.video, sendsInput: sendsInput,
                                     capturesShortcuts: model.capturesShortcuts, swapsCommandAndControl: swapsKeys,
                                     pasteModifier: host.isWindows ? .control : .command,
                                     stickyModifiers: model.stickyModifiers, screenLabel: screenLabel,
                                     onPaste: { model.pasteThroughClipboard() }, keyProbe: MacSessionOptions.keyProbe ? macKeyProbe : nil)
        #else
        RemoteSessionNSRepresentable(input: model.input, video: model.video, sendsInput: sendsInput,
                                     capturesShortcuts: model.capturesShortcuts, swapsCommandAndControl: swapsKeys,
                                     pasteModifier: host.isWindows ? .control : .command,
                                     stickyModifiers: model.stickyModifiers, screenLabel: screenLabel,
                                     onPaste: { model.pasteThroughClipboard() })
        #endif
    }

    /// A PC follows its own "⌘ acts as Ctrl" (on unless turned off); a Mac, Settings' "Swap ⌘ and ⌃".
    private var swapsKeys: Bool {
        host.isWindows ? model.keyRemap.swapsCommandAndControl : macSwapsCommandAndControl
    }

    var windowSubtitle: String {
        switch session.state {
        case .connected:
            var parts: [String] = []
            if let display = session.activeConfig?.display {
                parts.append("\(Int(display.pointWidth)) × \(Int(display.pointHeight))")
            }
            if model.isViewOnly { parts.append("View Only") }
            return parts.joined(separator: " · ")
        case .connecting, .authenticating: return "Connecting…"
        case .reconnecting, .suspended: return "Reconnecting…"
        case .pairingRequired: return "Pairing"
        case .failed: return "Not connected"
        default: return ""
        }
    }

    @ToolbarContentBuilder var macToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.isViewOnly) {
                Label("View Only", systemImage: "eye")
            }
            .help("Watch \(host.the) without sending the pointer or keys")
            .accessibilityIdentifier("session.mac.viewOnly")
            Toggle(isOn: $model.capturesShortcuts) {
                Label("Send Keyboard Shortcuts", systemImage: "command")
            }
            .help(model.capturesShortcuts ? "⌘Q, ⌘W and other shortcuts go to \(host.the). ⌃⌥⌘ shortcuts stay with Casement."
                                          : "⌘Q, ⌘W, ⌘H, ⌘M and ⌘, act on Casement")
            .accessibilityIdentifier("session.mac.captureShortcuts")
            Menu {
                ForEach(HostShortcut.sessionMenu(for: model.hostPlatform)) { shortcut in
                    Button { model.sendShortcut(shortcut) } label: {
                        Label(shortcut.label, systemImage: shortcut.symbol)
                    }
                }
                Divider()
                Button { model.sendHostCommand(.sleepDisplay) } label: { Label("Sleep Display", systemImage: "moon") }
                Button { model.sendHostCommand(.lockScreen) } label: { Label("Lock \(host.name)", systemImage: "lock") }
            } label: {
                Label(host.name, systemImage: host.symbol)
            }
            .help("\(host.name) shortcuts")
            .disabled(!model.isConnected)
            Button { model.isPickingFiles = true } label: {
                Label("Send File", systemImage: StripItem.sendFile.symbol)
            }
            .help("Send files to \(device.name)'s Downloads folder")
            .disabled(!model.canSendFiles)
        }
        // The way out stands apart from the controls.
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { model.disconnect() } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .help("Disconnect from \(device.name)")
            .accessibilityIdentifier("session.toolbar.disconnect")
        }
    }

    #if DEBUG
    /// `-VantageKeyProbe 1`: the keys sent lately, as `session.keyProbe`'s label.
    @ViewBuilder var keyProbeElement: some View {
        if MacSessionOptions.keyProbe {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("session.keyProbe")
                // A label, not a value: macOS doesn't report a plain element's value to UI tests.
                .accessibilityLabel(macKeyProbe.value)
                .allowsHitTesting(false)
        }
    }
    #endif
}

/// The session's Mac is the one Vantage runs on: say so, since the picture shows itself and the
/// pointer comes straight back.
struct ThisMacBanner: View {
    let isViewOnly: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're viewing this Mac from itself").font(.callout.weight(.semibold))
                Text(isViewOnly ? "View Only is on, so the pointer and keys stay here."
                                : "The pointer and keys go to this same Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .platformGlass(in: .capsule)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session.thisMacBanner")
    }
}
#endif

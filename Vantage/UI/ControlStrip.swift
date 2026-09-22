import SwiftUI
import VantageCore

/// Floating command strip shown during a session. Provides modifier toggles and common keys,
/// mirroring the toolbar taxonomy of dedicated remote-desktop clients.
struct ControlStrip: View {
    @Binding var stickyModifiers: KeyModifiers
    @Binding var touchMode: InputController.TouchMode
    let onKey: (UInt16, KeyModifiers) -> Void
    let onShowKeyboard: () -> Void
    let onSendClipboard: () -> Void
    let onDisconnect: () -> Void
    let onToggleControls: () -> Void

    // macOS virtual key codes for common keys.
    private let esc: UInt16 = 0x35
    private let tab: UInt16 = 0x30
    private let arrowsLeft: UInt16 = 0x7B
    private let arrowsRight: UInt16 = 0x7C
    private let arrowsUp: UInt16 = 0x7E
    private let arrowsDown: UInt16 = 0x7D

    var body: some View {
        HStack(spacing: 8) {
            modifierButton("control", .control)
            modifierButton("option", .option)
            modifierButton("command", .command)
            modifierButton("shift", .shift)
            Divider().frame(height: 24)
            keyButton("escape", esc)
            keyButton("arrow.right.to.line", tab)
            arrowCluster
            Divider().frame(height: 24)
            Button(action: onShowKeyboard) { Image(systemName: "keyboard") }
                .buttonStyle(.glass)
            Menu {
                Picker("Touch Mode", selection: $touchMode) {
                    ForEach(InputController.TouchMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                Button(action: onSendClipboard) {
                    Label("Send Clipboard to Mac", systemImage: "doc.on.clipboard")
                }
                Divider()
                Button(role: .destructive, action: onDisconnect) {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(in: .capsule)
    }

    private var arrowCluster: some View {
        HStack(spacing: 2) {
            keyButton("chevron.left", arrowsLeft)
            VStack(spacing: 2) {
                keyButton("chevron.up", arrowsUp)
                keyButton("chevron.down", arrowsDown)
            }
            keyButton("chevron.right", arrowsRight)
        }
    }

    private func modifierButton(_ symbol: String, _ modifier: KeyModifiers) -> some View {
        Button {
            if stickyModifiers.contains(modifier) { stickyModifiers.remove(modifier) }
            else { stickyModifiers.insert(modifier) }
        } label: {
            Image(systemName: symbolName(for: modifier))
                .foregroundStyle(stickyModifiers.contains(modifier) ? Color.accentColor : .primary)
        }
        .buttonStyle(.glass)
    }

    private func symbolName(for modifier: KeyModifiers) -> String {
        switch modifier {
        case .command: "command"
        case .option: "option"
        case .control: "control"
        case .shift: "shift"
        default: "questionmark"
        }
    }

    private func keyButton(_ symbol: String, _ keyCode: UInt16) -> some View {
        Button {
            onKey(keyCode, stickyModifiers)
            stickyModifiers = []
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.glass)
    }
}

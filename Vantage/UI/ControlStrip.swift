import SwiftUI
import VantageCore

/// Fits the session controls into one row on iPad, or two rows in a narrow window.
struct ControlStrip: View {
    @State private var showOptions = false
    @Binding var isCollapsed: Bool
    @Binding var dock: ToolbarDock
    @Binding var stickyModifiers: KeyModifiers
    @Binding var touchMode: InputController.TouchMode
    let onKey: (UInt16, KeyModifiers) -> Void
    let onShowKeyboard: () -> Void
    let onSendClipboard: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        Group {
            if isCollapsed {
                HStack(spacing: 4) {
                    keyboardButton
                    collapseButton
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        modifiers
                        Divider().frame(height: 24)
                        keys
                        Divider().frame(height: 24)
                        actions
                    }
                    VStack(spacing: 4) {
                        HStack(spacing: 4) { modifiers; actions }
                        HStack(spacing: 4) { keys }
                    }
                    VStack(spacing: 4) {
                        HStack(spacing: 4) { modifiers }
                        HStack(spacing: 0) { keys }
                        HStack(spacing: 4) { actions }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(8)
        .glassEffect(in: .rect(cornerRadius: 28))
        .accessibilityElement(children: .contain)
        .accessibilityValue(dock.label)
        .accessibilityAction(named: isCollapsed ? "Expand controls" : "Collapse controls") { isCollapsed.toggle() }
        .accessibilityAction(named: "Move to top left") { dock = .topLeft }
        .accessibilityAction(named: "Move to top right") { dock = .topRight }
        .accessibilityAction(named: "Move to bottom left") { dock = .bottomLeft }
        .accessibilityAction(named: "Move to bottom right") { dock = .bottomRight }
        .contextMenu {
            ForEach(ToolbarDock.allCases) { position in
                Button("Move to \(position.label.lowercased())") { dock = position }
            }
            Button(isCollapsed ? "Expand controls" : "Collapse controls") { isCollapsed.toggle() }
        }
        .confirmationDialog("Session Options", isPresented: $showOptions, titleVisibility: .visible) {
            Button("Direct Touch") { touchMode = .direct }
            Button("Trackpad") { touchMode = .trackpad }
            Button("Send Clipboard to Mac", action: onSendClipboard)
            ForEach(ToolbarDock.allCases) { position in
                Button("Move to \(position.label.lowercased())") { dock = position }
            }
            Button("Collapse controls") { isCollapsed = true }
            Button("Disconnect", role: .destructive, action: onDisconnect)
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var modifiers: some View {
        modifierButton("Control", "control", .control)
        modifierButton("Option", "option", .option)
        modifierButton("Command", "command", .command)
        modifierButton("Shift", "shift", .shift)
    }

    @ViewBuilder private var keys: some View {
        keyButton("Escape", "escape", 0x35)
        keyButton("Tab", "arrow.right.to.line", 0x30)
        keyButton("Left Arrow", "chevron.left", 0x7B)
        keyButton("Up Arrow", "chevron.up", 0x7E)
        keyButton("Down Arrow", "chevron.down", 0x7D)
        keyButton("Right Arrow", "chevron.right", 0x7C)
    }

    @ViewBuilder private var actions: some View {
        keyboardButton
        Button { showOptions = true } label: {
            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Session Options")
        collapseButton
    }

    private var keyboardButton: some View {
        Button(action: onShowKeyboard) {
            Image(systemName: "keyboard").frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Toggle Keyboard")
    }

    private var collapseButton: some View {
        Button { isCollapsed.toggle() } label: {
            Image(systemName: isCollapsed
                ? (dock.isLeading ? "chevron.compact.right" : "chevron.compact.left")
                : (dock.isLeading ? "chevron.compact.left" : "chevron.compact.right"))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(isCollapsed ? "Expand controls" : "Collapse controls")
        .accessibilityIdentifier("session.toolbar.collapse")
        .accessibilityHint("Drag the controls to move them to another corner.")
    }

    private func modifierButton(_ title: String, _ symbol: String, _ modifier: KeyModifiers) -> some View {
        Button {
            if stickyModifiers.contains(modifier) { stickyModifiers.remove(modifier) }
            else { stickyModifiers.insert(modifier) }
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(stickyModifiers.contains(modifier) ? Color.accentColor : .primary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
                .background(stickyModifiers.contains(modifier) ? Color.accentColor.opacity(0.18) : .clear, in: .circle)
        }
        .accessibilityLabel(title)
        .accessibilityValue(stickyModifiers.contains(modifier) ? "On" : "Off")
    }

    private func keyButton(_ title: String, _ symbol: String, _ keyCode: UInt16) -> some View {
        Button {
            onKey(keyCode, stickyModifiers)
            stickyModifiers = []
        } label: {
            Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }
}

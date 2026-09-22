import SwiftUI
import VantageCore

/// Floating session controls: modifier keys, navigation keys, keyboard, and a session menu.
/// Collapses to a compact pill. Both states share one glass identity so the surface morphs
/// between them instead of cutting.
struct ControlStrip: View {
    @Binding var isCollapsed: Bool
    @Binding var dock: ToolbarDock
    @Binding var stickyModifiers: KeyModifiers
    @Binding var touchMode: InputController.TouchMode
    let onKey: (UInt16, KeyModifiers) -> Void
    let onShowKeyboard: () -> Void
    let onSendClipboard: () -> Void
    let onDisconnect: () -> Void

    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            if isCollapsed {
                compact
                    .transition(.blurReplace)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectID("controls", in: glassNamespace)
            } else {
                expanded
                    .transition(.blurReplace)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
                    .glassEffectID("controls", in: glassNamespace)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(dock.label)
        .accessibilityAction(named: isCollapsed ? "Expand controls" : "Collapse controls") { toggleCollapsed() }
        .accessibilityAction(named: "Move to top left") { move(to: .topLeft) }
        .accessibilityAction(named: "Move to top right") { move(to: .topRight) }
        .accessibilityAction(named: "Move to bottom left") { move(to: .bottomLeft) }
        .accessibilityAction(named: "Move to bottom right") { move(to: .bottomRight) }
        .contextMenu {
            Section("Move Controls") {
                ForEach(ToolbarDock.allCases) { position in
                    Button { move(to: position) } label: { Label(position.label, systemImage: position.symbol) }
                }
            }
        }
    }

    // MARK: States

    private var compact: some View {
        HStack(spacing: 0) {
            keyboardButton
            collapseButton
        }
        .padding(4)
    }

    private var expanded: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                modifiers
                separator
                keys
                separator
                actions
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) { modifiers; separator; actions }
                HStack(spacing: 0) { keys }
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) { modifiers }
                HStack(spacing: 0) { keys }
                HStack(spacing: 0) { actions }
            }
        }
        .padding(4)
    }

    private var separator: some View {
        Capsule()
            .fill(.primary.opacity(0.14))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }

    // MARK: Groups

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
        sessionMenu
        collapseButton
    }

    // MARK: Buttons

    private var keyboardButton: some View {
        Button(action: onShowKeyboard) {
            Image(systemName: "keyboard")
        }
        .buttonStyle(StripButtonStyle())
        .accessibilityLabel("Toggle Keyboard")
    }

    private var collapseButton: some View {
        Button(action: toggleCollapsed) {
            Image(systemName: isCollapsed
                ? (dock.isLeading ? "chevron.right" : "chevron.left")
                : (dock.isLeading ? "chevron.left" : "chevron.right"))
                .font(.body.weight(.semibold))
        }
        .buttonStyle(StripButtonStyle())
        .accessibilityLabel(isCollapsed ? "Expand controls" : "Collapse controls")
        .accessibilityIdentifier("session.toolbar.collapse")
        .accessibilityHint("Drag the controls to move them to another corner.")
    }

    private var sessionMenu: some View {
        Menu {
            Picker("Touch", selection: $touchMode) {
                ForEach(InputController.TouchMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Section {
                Button(action: onSendClipboard) {
                    Label("Send Clipboard to Mac", systemImage: "doc.on.clipboard")
                }
            }

            Section {
                Menu {
                    Picker("Corner", selection: Binding(get: { dock }, set: { move(to: $0) })) {
                        ForEach(ToolbarDock.allCases) { position in
                            Label(position.label, systemImage: position.symbol).tag(position)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Move Controls", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button(action: toggleCollapsed) {
                    Label("Collapse Controls", systemImage: "rectangle.compress.vertical")
                }
            }

            Section {
                Button(role: .destructive, action: onDisconnect) {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuOrder(.fixed)
        .buttonStyle(StripButtonStyle())
        .accessibilityLabel("Session Options")
    }

    private func modifierButton(_ title: String, _ symbol: String, _ modifier: KeyModifiers) -> some View {
        let isOn = stickyModifiers.contains(modifier)
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if isOn { stickyModifiers.remove(modifier) } else { stickyModifiers.insert(modifier) }
            }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(StripButtonStyle(isActive: isOn))
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func keyButton(_ title: String, _ symbol: String, _ keyCode: UInt16) -> some View {
        Button {
            onKey(keyCode, stickyModifiers)
            withAnimation(.snappy(duration: 0.2)) { stickyModifiers = [] }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(StripButtonStyle())
        .accessibilityLabel(title)
    }

    // MARK: Actions

    /// Expanding gets a lively spring; collapsing settles quietly. Reduce Motion keeps both short.
    private func toggleCollapsed() {
        let animation: Animation = isCollapsed
            ? .spring(duration: 0.5, bounce: 0.28)
            : .smooth(duration: 0.34)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : animation) {
            isCollapsed.toggle()
        }
    }

    private func move(to position: ToolbarDock) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.55, bounce: 0.2)) {
            dock = position
        }
    }
}

/// A 44-point glyph button that lives on glass: no chrome of its own, a soft press highlight,
/// and a tinted ring when the key is held (sticky modifiers).
private struct StripButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .frame(width: 44, height: 44)
            .background {
                Circle()
                    .fill(isActive ? Color.accentColor.opacity(0.2) : Color.primary.opacity(configuration.isPressed ? 0.12 : 0))
                    .padding(4)
            }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
            .animation(.snappy(duration: 0.2), value: isActive)
    }
}

import SwiftUI
import VantageCore

/// Floating session controls: modifier keys, navigation keys, keyboard, and a session menu.
/// Collapses to a compact pill. Both states sit on one glass surface that resizes between them
/// instead of cutting.
struct ControlStrip: View {
    @Binding var isCollapsed: Bool
    @Binding var dock: ToolbarDock
    @Binding var stickyModifiers: KeyModifiers
    @Binding var touchMode: InputController.TouchMode
    let onKey: (UInt16, KeyModifiers) -> Void
    let onShowKeyboard: () -> Void
    let onSendClipboard: () -> Void
    let onSendPassword: () -> Void
    let onHostCommand: (HostCommand) -> Void
    let onDisconnect: () -> Void
    /// Dictation is listening (the mic button shows as active).
    var isDictating = false
    var onDictation: (DictationPress) -> Void = { _ in }
    /// Set while the strip is being dragged between corners, so the button under the finger
    /// doesn't also fire when it's let go.
    var tapGuard: StripTapGuard?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        #if os(visionOS)
        // On visionOS the strip sits in an ornament under the window, so there are no corners to
        // move it between; it only collapses.
        glassSurface
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: isCollapsed ? "Expand controls" : "Collapse controls") { toggleCollapsed() }
        #else
        glassSurface
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
        #endif
    }

    #if os(visionOS)
    /// visionOS has no Liquid Glass; the ornament gets the system glass material instead.
    @ViewBuilder private var glassSurface: some View {
        if isCollapsed {
            compact
                .transition(.blurReplace)
                .glassBackgroundEffect(in: .capsule)
        } else {
            expanded
                .transition(.blurReplace)
                .glassBackgroundEffect(in: .rect(cornerRadius: stripButtonSide / 2 + 4))
        }
    }
    #else
    /// One glass surface that changes size, rather than two glass shapes asked to morph: the
    /// morph swapped shapes in a single frame, which is what made opening and closing feel
    /// abrupt. The surface is sized by the current buttons only (the outgoing set is already
    /// out of layout), so its frame animates from one size to the other, and the clip lets the
    /// closing edge sweep over the buttons that are leaving.
    private var glassSurface: some View {
        ZStack(alignment: dock.alignment) {
            if isCollapsed {
                compact.transition(contentTransition)
            } else {
                expanded.transition(contentTransition)
            }
        }
        .clipShape(.rect(cornerRadius: 26))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
    }

    private var contentTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: AnyTransition(StripContentTransition(anchor: dock.anchor))
                .animation(.smooth(duration: 0.26).delay(0.07)),
            removal: AnyTransition(StripContentTransition(anchor: dock.anchor))
                .animation(.easeOut(duration: 0.12)))
    }
    #endif

    // MARK: States

    private var compact: some View {
        HStack(spacing: 0) {
            dictationButton
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
                shortcuts
                separator
                actions
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) { modifiers; separator; shortcuts }
                HStack(spacing: 0) { keys; separator; actions }
            }
            VStack(spacing: 0) {
                HStack(spacing: 0) { modifiers }
                HStack(spacing: 0) { keys }
                HStack(spacing: 0) { shortcuts; separator; actions }
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

    /// The Mac shortcuts worth a button of their own. Everything else lives in the session menu.
    @ViewBuilder private var shortcuts: some View {
        shortcutButton(MacShortcut.spotlight)
        shortcutButton(MacShortcut.missionControl)
        passwordButton
    }

    @ViewBuilder private var actions: some View {
        dictationButton
        keyboardButton
        sessionMenu
        collapseButton
    }

    private var passwordButton: some View {
        Button { guarded(onSendPassword) } label: {
            Image(systemName: "key.radiowaves.forward")
        }
        .buttonStyle(StripButtonStyle())
        .accessibilityLabel("Type Password")
        .accessibilityHint("Types this Mac's saved password and presses Return.")
    }

    private func shortcutButton(_ shortcut: MacShortcut) -> some View {
        Button { guarded { send(shortcut) } } label: {
            Image(systemName: shortcut.symbol)
        }
        .buttonStyle(StripButtonStyle())
        .accessibilityLabel(shortcut.label)
    }

    /// Mac shortcuts ignore whatever modifiers are being held — ⌃↑ means Mission Control, not
    /// ⇧⌃↑ — and clear them, the same as tapping a key.
    private func send(_ shortcut: MacShortcut) {
        onKey(shortcut.keyCode, shortcut.modifiers)
        if !stickyModifiers.isEmpty {
            withAnimation(.snappy(duration: 0.2)) { stickyModifiers = [] }
        }
    }

    // MARK: Buttons

    /// Hold to talk (release stops), or tap to start and tap again to stop. A drag gesture
    /// rather than a Button so the press and the release are both visible.
    private var dictationButton: some View {
        DictationStripButton(isActive: isDictating, onPress: onDictation)
    }

    private var keyboardButton: some View {
        Button { guarded(onShowKeyboard) } label: {
            Image(systemName: "keyboard")
        }
        .buttonStyle(StripButtonStyle())
        .accessibilityLabel("Toggle Keyboard")
    }

    private var collapseButton: some View {
        Button { guarded(toggleCollapsed) } label: {
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
            #if !os(visionOS) // look and pinch always points absolutely
            Picker("Touch", selection: $touchMode) {
                ForEach(InputController.TouchMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
            #endif

            Section {
                Button(action: onSendClipboard) {
                    Label("Send Clipboard to Mac", systemImage: "doc.on.clipboard")
                }
                Button(action: onSendPassword) {
                    Label("Type Password", systemImage: "key.radiowaves.forward")
                }
            }

            Section("Mac") {
                ForEach(MacShortcut.menuOrder) { shortcut in
                    Button { send(shortcut) } label: { Label(shortcut.label, systemImage: shortcut.symbol) }
                }
                Button { onHostCommand(.sleepDisplay) } label: {
                    Label("Sleep Display", systemImage: "moon")
                }
                Button { onHostCommand(.lockScreen) } label: {
                    Label("Lock Mac", systemImage: "lock")
                }
            }

            #if !os(visionOS)
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
            #endif

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
        .disabled(tapGuard?.isDragging == true) // a drag that starts here mustn't open the menu
        .accessibilityLabel("Session Options")
    }

    private func modifierButton(_ title: String, _ symbol: String, _ modifier: KeyModifiers) -> some View {
        let isOn = stickyModifiers.contains(modifier)
        return Button {
            guarded {
                withAnimation(.snappy(duration: 0.2)) {
                    if isOn { stickyModifiers.remove(modifier) } else { stickyModifiers.insert(modifier) }
                }
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
            guarded {
                onKey(keyCode, stickyModifiers)
                withAnimation(.snappy(duration: 0.2)) { stickyModifiers = [] }
            }
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(StripButtonStyle())
        .accessibilityLabel(title)
    }

    // MARK: Actions

    private func guarded(_ action: () -> Void) {
        if tapGuard?.allowsTap ?? true { action() }
    }

    /// One family of spring both ways so opening and closing feel like the same object: a touch
    /// of life on the way out, none on the way back. Reduce Motion keeps both short.
    private func toggleCollapsed() {
        let animation: Animation = isCollapsed
            ? .spring(duration: 0.38, bounce: 0.12)
            : .spring(duration: 0.32, bounce: 0)
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

#if os(visionOS)
/// Look and pinch needs roomier targets than a finger on glass (the HIG asks for about 60 points
/// per control, spacing included).
private let stripButtonSide: CGFloat = 56
#else
private let stripButtonSide: CGFloat = 44
#endif

/// A 44-point glyph button that lives on glass: no chrome of its own, a soft press highlight,
/// and a tinted ring when the key is held (sticky modifiers).
private struct StripButtonStyle: ButtonStyle {
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(StripGlyph(isActive: isActive, isPressed: configuration.isPressed))
    }
}

/// The strip button look, shared by `StripButtonStyle` and controls that track their own press.
private struct StripGlyph: ViewModifier {
    var isActive: Bool
    var isPressed: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            .frame(width: stripButtonSide, height: stripButtonSide)
            .background {
                Circle()
                    .fill(isActive ? Color.accentColor.opacity(0.2) : Color.primary.opacity(isPressed ? 0.12 : 0))
                    .padding(4)
            }
            .contentShape(Rectangle())
            #if os(visionOS)
            .contentShape(.hoverEffect, Circle().inset(by: 4))
            .hoverEffect()
            #endif
            .scaleEffect(isPressed ? 0.88 : 1)
            .animation(.snappy(duration: 0.18), value: isPressed)
            .animation(.snappy(duration: 0.2), value: isActive)
    }
}

extension ToolbarDock {
    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    /// The corner the strip grows from.
    var anchor: UnitPoint {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

/// Tells the strip's buttons a drag is moving the strip. SwiftUI still counts the release as a
/// tap, since the button travels along under the finger, so the buttons check this first. Taps
/// stay blocked for a moment after the drag, whichever of the two callbacks arrives first.
@MainActor @Observable
final class StripTapGuard {
    private(set) var isDragging = false
    @ObservationIgnored private var blockedUntil = Date.distantPast

    var allowsTap: Bool { !isDragging && Date.now >= blockedUntil }

    func dragMoved() {
        if !isDragging { isDragging = true }
    }

    func dragEnded() {
        isDragging = false
        blockedUntil = .now.addingTimeInterval(0.3)
    }
}

/// The strip's buttons fading, shrinking slightly toward the docked corner, and softening as
/// they go. Never from nothing: 0.94 scale and a 3-point blur are enough to read as motion.
private struct StripContentTransition: Transition {
    var anchor: UnitPoint

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .scaleEffect(phase.isIdentity ? 1 : 0.94, anchor: anchor)
            .blur(radius: phase.isIdentity ? 0 : 3)
    }
}

/// A press on the control strip's mic button.
enum DictationPress {
    case began
    /// `held` is true for a press of ~0.3 s or more (push-to-talk).
    case ended(held: Bool)
    /// The finger moved off as the start of a drag of the whole strip: undo what `began` did.
    case cancelled
    /// VoiceOver / Full Keyboard Access: start or stop in one action.
    case toggle
}

private struct DictationStripButton: View {
    let isActive: Bool
    let onPress: (DictationPress) -> Void
    @State private var pressedAt: Date?
    @State private var cancelled = false

    var body: some View {
        Image(systemName: isActive ? "mic.fill" : "mic")
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, isActive: isActive)
            .modifier(StripGlyph(isActive: isActive, isPressed: pressedAt != nil))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if pressedAt == nil {
                        pressedAt = .now
                        cancelled = false
                        onPress(.began)
                    } else if !cancelled, hypot(value.translation.width, value.translation.height) > 12 {
                        // The strip moves with the finger, so the finger never leaves this button.
                        cancelled = true
                        onPress(.cancelled)
                    }
                }
                .onEnded { _ in
                    let held = pressedAt.map { Date.now.timeIntervalSince($0) >= 0.3 } ?? false
                    pressedAt = nil
                    if !cancelled { onPress(.ended(held: held)) }
                })
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isActive ? "Stop Dictation" : "Dictate")
            .accessibilityHint("Hold to talk, or tap to start and tap again to stop.")
            .accessibilityAction { onPress(.toggle) }
            .accessibilityIdentifier("session.toolbar.dictate")
    }
}

/// A macOS keyboard shortcut Vantage can send as one tap. These are the system defaults; a Mac
/// with remapped shortcuts in System Settings → Keyboard will do whatever it was remapped to.
struct MacShortcut: Identifiable, Hashable {
    let id: String
    let label: String
    let symbol: String
    let keyCode: UInt16
    let modifiers: KeyModifiers

    static let spotlight = MacShortcut(id: "spotlight", label: "Spotlight", symbol: "magnifyingglass",
                                       keyCode: 0x31, modifiers: .command)
    static let missionControl = MacShortcut(id: "missionControl", label: "Mission Control", symbol: "rectangle.3.group",
                                            keyCode: 0x7E, modifiers: .control)
    static let applicationWindows = MacShortcut(id: "appWindows", label: "Application Windows", symbol: "rectangle.on.rectangle",
                                                keyCode: 0x7D, modifiers: .control)
    static let showDesktop = MacShortcut(id: "showDesktop", label: "Show Desktop", symbol: "menubar.dock.rectangle",
                                         keyCode: 0x67, modifiers: [])

    static let menuOrder: [MacShortcut] = [spotlight, missionControl, applicationWindows, showDesktop]
}

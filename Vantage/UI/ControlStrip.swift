import SwiftUI
import VantageCore

/// Floating session controls: the controls in the Mac's `ControlStripLayout`, then the session
/// menu and the collapse button. Collapses to a compact pill. Both states sit on one glass
/// surface that resizes between them instead of cutting.
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
    /// The controls to show, in order (the session resolves the Mac's own layout or the
    /// default). The session menu and the collapse button always follow them.
    var items: [StripItem] = ControlStripLayout.standard.items
    /// Opens the controls editor from the session menu; nil leaves the menu item out.
    var onCustomize: (() -> Void)?
    /// A picture of the strip for the controls editor: plain glass, and nothing for VoiceOver
    /// (the editor describes it instead).
    var isPreview = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isPreview {
            glassSurface // its buttons are hidden inside the glass, see `expanded`
        } else {
            liveSurface
        }
    }

    @ViewBuilder private var liveSurface: some View {
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
        .glassEffect(isPreview ? .regular : .regular.interactive(), in: .rect(cornerRadius: 26))
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

    /// Dictate and Keyboard stay reachable while collapsed, if the layout has them.
    private var compact: some View {
        HStack(spacing: 0) {
            ForEach(items.filter { $0 == .dictate || $0 == .keyboard }) { item in
                itemView(item)
            }
            collapseButton
        }
        .padding(4)
    }

    /// The layout in one row where it fits, otherwise in two to five rows split where the
    /// category changes (see `ControlStripLayout.rows`).
    private var expanded: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(rowLayouts, id: \.count) { rows in
                rowsView(rows)
            }
        }
        .padding(4)
        // Glass hosts its content in a view of its own, so hiding the preview has to happen in
        // here: an `accessibilityHidden` outside the glass doesn't reach these buttons.
        .accessibilityHidden(isPreview)
    }

    /// The layout followed by the fixed trailing buttons.
    private var slots: [StripSlot] { items.map(StripSlot.item) + [.menu, .collapse] }

    /// One candidate per row count, dropping counts that can't be filled.
    private var rowLayouts: [[[StripSlot]]] {
        let slots = self.slots
        var layouts: [[[StripSlot]]] = []
        for count in 1...5 {
            let rows = ControlStripLayout.rows(slots, count: count, separatorWeight: 9 / stripButtonSide) { $0.category }
            if rows.count > (layouts.last?.count ?? 0) { layouts.append(rows) }
        }
        return layouts
    }

    private func rowsView(_ rows: [[StripSlot]]) -> some View {
        VStack(alignment: rowAlignment, spacing: 0) {
            ForEach(rows, id: \.first) { row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.element) { index, slot in
                        HStack(spacing: 0) {
                            if index > 0, row[index - 1].category != slot.category { separator }
                            slotView(slot)
                        }
                    }
                }
            }
        }
    }

    /// Short rows line up with the docked edge, so the collapse button stays in the corner.
    private var rowAlignment: HorizontalAlignment {
        #if os(visionOS)
        .center
        #else
        dock.isLeading ? .leading : .trailing
        #endif
    }

    private var separator: some View {
        Capsule()
            .fill(.primary.opacity(0.14))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }

    // MARK: Items

    @ViewBuilder private func slotView(_ slot: StripSlot) -> some View {
        switch slot {
        case .item(let item): itemView(item)
        case .menu: sessionMenu
        case .collapse: collapseButton
        }
    }

    @ViewBuilder private func itemView(_ item: StripItem) -> some View {
        switch item {
        case .control: modifierButton(item, .control)
        case .option: modifierButton(item, .option)
        case .command: modifierButton(item, .command)
        case .shift: modifierButton(item, .shift)
        case .escape: keyButton(item, 0x35)
        case .tab: keyButton(item, 0x30)
        case .leftArrow: keyButton(item, 0x7B)
        case .upArrow: keyButton(item, 0x7E)
        case .downArrow: keyButton(item, 0x7D)
        case .rightArrow: keyButton(item, 0x7C)
        case .spotlight: shortcutButton(.spotlight)
        case .missionControl: shortcutButton(.missionControl)
        case .applicationWindows: shortcutButton(.applicationWindows)
        case .showDesktop: shortcutButton(.showDesktop)
        case .typePassword: passwordButton
        case .sendClipboard: clipboardButton
        case .dictate: dictationButton
        case .keyboard: keyboardButton
        case .disconnect: disconnectButton
        }
    }

    /// Red so it reads as the way out. No confirmation: reconnecting is one tap, and the tap
    /// guard already keeps a drag of the strip from landing here.
    private var disconnectButton: some View {
        Button { guarded(onDisconnect) } label: {
            Image(systemName: StripItem.disconnect.symbol)
        }
        .buttonStyle(StripButtonStyle(tint: .red))
        .accessibilityLabel("Disconnect")
        .accessibilityIdentifier("session.toolbar.disconnect")
    }

    private var clipboardButton: some View {
        Button { guarded(onSendClipboard) } label: {
            Image(systemName: StripItem.sendClipboard.symbol)
        }
        .buttonStyle(StripButtonStyle())
        .accessibilityLabel("Send Clipboard to Mac")
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
                .font(.system(size: 17, weight: .semibold)) // fixed like the other glyphs; it outgrew its 44 pt at large text sizes
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

            Section {
                #if !os(visionOS)
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
                #endif
                if let onCustomize {
                    Button(action: onCustomize) {
                        Label("Customize Controls…", systemImage: "slider.horizontal.3")
                    }
                }
                #if !os(visionOS)
                Button(action: toggleCollapsed) {
                    Label("Collapse Controls", systemImage: "rectangle.compress.vertical")
                }
                #endif
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
        .disabled(tapGuard?.isDragging == true) // a drag that starts here mustn't open the menu
        .accessibilityLabel("Session Options")
    }

    private func modifierButton(_ item: StripItem, _ modifier: KeyModifiers) -> some View {
        let isOn = stickyModifiers.contains(modifier)
        return Button {
            guarded {
                withAnimation(.snappy(duration: 0.2)) {
                    if isOn { stickyModifiers.remove(modifier) } else { stickyModifiers.insert(modifier) }
                }
            }
        } label: {
            Image(systemName: item.symbol)
        }
        .buttonStyle(StripButtonStyle(isActive: isOn))
        .accessibilityLabel(item.label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func keyButton(_ item: StripItem, _ keyCode: UInt16) -> some View {
        Button {
            guarded {
                onKey(keyCode, stickyModifiers)
                withAnimation(.snappy(duration: 0.2)) { stickyModifiers = [] }
            }
        } label: {
            Image(systemName: item.symbol)
        }
        .buttonStyle(StripButtonStyle())
        .accessibilityLabel(item.label)
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
    /// The glyph colour when it isn't active (Disconnect is red).
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(StripGlyph(isActive: isActive, isPressed: configuration.isPressed, tint: tint))
    }
}

/// The strip button look, shared by `StripButtonStyle` and controls that track their own press.
private struct StripGlyph: ViewModifier {
    var isActive: Bool
    var isPressed: Bool
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isActive ? Color.accentColor : (tint ?? Color.primary))
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

/// A place on the strip: one of the layout's controls, or a fixed trailing button.
private enum StripSlot: Hashable {
    case item(StripItem)
    case menu
    case collapse

    /// The fixed buttons group with the actions, so no separator splits them from Disconnect.
    var category: StripItem.Category {
        if case .item(let item) = self { item.category } else { .actions }
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

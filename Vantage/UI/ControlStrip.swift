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
    var items: [StripItem] = ControlStripLayout.platformStandard.visibleItems()
    /// Opens the controls editor from the session menu; nil leaves the menu item out.
    var onCustomize: (() -> Void)?
    /// The Mac Audio toggle (the session owns the player and the per-Mac setting).
    var macAudio = MacAudioToggle()
    /// Send File and the Transfers list (the session owns the transfers).
    var files = SendFileAction()
    /// What the host runs: names the controls (Search or Spotlight, Win or ⌘) and picks the
    /// shortcuts they send. Nil (the default layout's preview) shows the Mac's names.
    var host: HostPlatform?
    /// A picture of the strip for the controls editor: plain glass, and nothing for VoiceOver
    /// (the editor describes it instead).
    var isPreview = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The last modifier the user tapped, for its haptic. Modifiers that clear themselves after a
    /// key press stay quiet; only your own tap latches or releases one.
    @State private var modifierTap = ModifierTap()

    private var noun: HostNoun { HostNoun(host) }

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
            #if os(macOS)
            .pointerStyle(.default) // the session hides the pointer over the Mac's picture only
            #endif
            .haptic(trigger: modifierTap) { _, tap in tap.latched ? .latch : .unlatch }
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
                .glassBackgroundEffect(in: .rect(cornerRadius: stripCornerRadius))
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
        .clipShape(.rect(cornerRadius: stripCornerRadius))
        .glassEffect(glass, in: .rect(cornerRadius: stripCornerRadius))
    }

    /// Glass that answers a finger on iPad; a plain pane on the Mac, where the buttons on it
    /// highlight under the pointer instead.
    private var glass: Glass {
        #if os(macOS)
        .regular
        #else
        isPreview ? .regular : .regular.interactive()
        #endif
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
    /// category changes (see `ControlStripLayout.rows`), or, where whole groups would need
    /// another row, carrying a group on into the next one.
    private var expanded: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Array(rowLayouts.enumerated()), id: \.offset) { _, rows in
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

    /// Candidates from fewest rows to most, dropping counts that can't be filled. Each count
    /// tries whole groups first, then the same count with a group carried on into the next row,
    /// so a phone gets three rows rather than four before it gets another row.
    private var rowLayouts: [[[StripSlot]]] {
        let slots = self.slots
        var layouts: [[[StripSlot]]] = []
        for count in 1...5 {
            for splitting in [false, true] {
                let rows = ControlStripLayout.rows(slots, count: count, separatorWeight: 9 / stripButtonSide,
                                                   splittingGroups: splitting) { $0.category }
                guard rows.count == count, !layouts.contains(rows) else { continue }
                layouts.append(rows)
            }
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
            .frame(width: 1, height: stripButtonSide / 2)
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
        case .startMenu, .spotlight, .missionControl, .applicationWindows, .showDesktop, .taskManager: shortcutButton(item)
        case .typePassword: passwordButton
        case .sendClipboard: clipboardButton
        case .sendFile: sendFileButton
        case .macAudio: macAudioButton
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
        .help("Disconnect")
        .accessibilityLabel("Disconnect")
        .accessibilityIdentifier("session.toolbar.disconnect")
    }

    /// A toggle like the modifier keys: tinted and filled while the Mac's sound plays here. Dimmed,
    /// with the reason as its VoiceOver hint, when the host can't send audio.
    private var macAudioButton: some View {
        let isOn = macAudio.isOn
        return Button { guarded(toggleMacAudio) } label: {
            Image(systemName: isOn ? "speaker.wave.2.fill" : StripItem.macAudio.symbol)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(StripButtonStyle(isActive: isOn, isDimmed: macAudio.unavailableReason != nil))
        .disabled(macAudio.unavailableReason != nil)
        .help(StripItem.macAudio.label)
        .accessibilityLabel(StripItem.macAudio.label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(macAudio.unavailableReason ?? "Plays the Mac's sound on \(LocalDevice.this).")
        .accessibilityIdentifier("session.toolbar.macAudio")
    }

    /// Opens the Files picker. While files are moving, a thin ring round the glyph fills with
    /// their progress. Dimmed, with the reason as its VoiceOver hint, when the Mac can't take files.
    private var sendFileButton: some View {
        Button { guarded(files.onSend) } label: {
            Image(systemName: StripItem.sendFile.symbol)
                .overlay {
                    if let fraction = files.progress {
                        SendFileProgressRing(fraction: fraction)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: files.progress == nil)
        }
        .buttonStyle(StripButtonStyle(isDimmed: files.unavailableReason != nil))
        .disabled(files.unavailableReason != nil)
        .help(StripItem.sendFile.label)
        .accessibilityLabel(StripItem.sendFile.label)
        .accessibilityValue(files.progress.map { "Sending, \(Int(($0 * 100).rounded())) percent" } ?? "")
        .accessibilityHint(files.unavailableReason ?? "Choose files on \(LocalDevice.this) to send to \(noun.thePossessive) Downloads folder.")
        .accessibilityIdentifier("session.toolbar.sendFile")
        .contextMenu {
            Button(action: files.onSend) {
                Label("Send Files…", systemImage: StripItem.sendFile.symbol)
            }
            .disabled(files.unavailableReason != nil)
            Button(action: files.onShowTransfers) {
                Label("Transfers…", systemImage: "arrow.up.arrow.down")
            }
        }
    }

    private func toggleMacAudio() {
        withAnimation(.snappy(duration: 0.2)) { macAudio.onToggle() }
    }

    private var clipboardButton: some View {
        Button { guarded(onSendClipboard) } label: {
            Image(systemName: StripItem.sendClipboard.symbol)
        }
        .buttonStyle(StripButtonStyle())
        .help("Send Clipboard to \(noun.name)")
        .accessibilityLabel("Send Clipboard to \(noun.name)")
    }

    private var passwordButton: some View {
        Button { guarded(onSendPassword) } label: {
            Image(systemName: "key.radiowaves.forward")
        }
        .buttonStyle(StripButtonStyle())
        .help("Type Password")
        .accessibilityLabel("Type Password")
        .accessibilityHint("Types \(noun.thePossessive) saved password and presses Return.")
    }

    /// The host's shortcut for this slot. Start and Task Manager have none on a Mac, where the
    /// strip never shows them; the default layout's preview shows them as on a PC.
    @ViewBuilder private func shortcutButton(_ item: StripItem) -> some View {
        if let shortcut = HostShortcut.forItem(item, on: host) ?? HostShortcut.forItem(item, on: .windows) {
            Button { guarded { send(shortcut) } } label: {
                Image(systemName: shortcut.symbol)
            }
            .buttonStyle(StripButtonStyle())
            .help(shortcut.label)
            .accessibilityLabel(shortcut.label)
        }
    }

    /// Shortcuts ignore whatever modifiers are being held — ⌃↑ means Mission Control, not
    /// ⇧⌃↑ — and clear them, the same as tapping a key.
    private func send(_ shortcut: HostShortcut) {
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
        .help("Toggle Keyboard")
        .accessibilityLabel("Toggle Keyboard")
    }

    private var collapseButton: some View {
        Button { guarded(toggleCollapsed) } label: {
            Image(systemName: isCollapsed
                ? (dock.isLeading ? "chevron.right" : "chevron.left")
                : (dock.isLeading ? "chevron.left" : "chevron.right"))
                .font(.system(size: stripGlyphSize, weight: .semibold)) // fixed like the other glyphs; it outgrew its 44 pt at large text sizes
        }
        .buttonStyle(StripButtonStyle())
        .help(isCollapsed ? "Expand Controls" : "Collapse Controls")
        .accessibilityLabel(isCollapsed ? "Expand controls" : "Collapse controls")
        .accessibilityIdentifier("session.toolbar.collapse")
        .accessibilityHint("Drag the controls to move them to another corner.")
    }

    private var sessionMenu: some View {
        Menu {
            #if os(iOS) // look and pinch, and a Mac's own pointer, always point absolutely
            Picker("Touch", selection: $touchMode) {
                ForEach(InputController.TouchMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
            #endif

            Section {
                if !noun.isWindows { // a PC has no audio to send
                    Toggle(isOn: Binding(get: { macAudio.isOn }, set: { _ in toggleMacAudio() })) {
                        Label(StripItem.macAudio.label, systemImage: StripItem.macAudio.symbol)
                    }
                    .disabled(macAudio.unavailableReason != nil)
                    .accessibilityIdentifier("session.menu.macAudio")
                }
                Button(action: files.onSend) {
                    Label("Send File to \(noun.name)…", systemImage: StripItem.sendFile.symbol)
                }
                .disabled(files.unavailableReason != nil)
                .accessibilityIdentifier("session.menu.sendFile")
                Button(action: files.onShowTransfers) {
                    Label("Transfers…", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("session.menu.transfers")
                Button(action: onSendClipboard) {
                    Label("Send Clipboard to \(noun.name)", systemImage: "doc.on.clipboard")
                }
                if !noun.isWindows { // saved-password typing is for a Mac
                    Button(action: onSendPassword) {
                        Label("Type Password", systemImage: "key.radiowaves.forward")
                    }
                }
            }

            Section(noun.name) {
                ForEach(HostShortcut.sessionMenu(for: host)) { shortcut in
                    Button { send(shortcut) } label: { Label(shortcut.label, systemImage: shortcut.symbol) }
                }
                Button { onHostCommand(.sleepDisplay) } label: {
                    Label("Sleep Display", systemImage: "moon")
                }
                Button { onHostCommand(.lockScreen) } label: {
                    Label("Lock \(noun.name)", systemImage: "lock")
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
        .help("Session Options")
        .accessibilityLabel("Session Options")
    }

    private func modifierButton(_ item: StripItem, _ modifier: KeyModifiers) -> some View {
        let isOn = stickyModifiers.contains(modifier)
        return Button {
            guarded {
                withAnimation(.snappy(duration: 0.2)) {
                    if isOn { stickyModifiers.remove(modifier) } else { stickyModifiers.insert(modifier) }
                }
                modifierTap = ModifierTap(count: modifierTap.count + 1, latched: !isOn)
            }
        } label: {
            if let keycap = item.keycapText(for: host) {
                Text(keycap).font(.system(size: 13, weight: .semibold)).fixedSize()
            } else {
                Image(systemName: item.symbol)
            }
        }
        .buttonStyle(StripButtonStyle(isActive: isOn))
        .help(item.label(for: host))
        .accessibilityLabel(item.label(for: host))
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
        .help(item.label)
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
private let stripGlyphSize: CGFloat = 17
#elseif os(macOS)
/// A pointer needs less room than a finger; Mac toolbar-sized buttons.
private let stripButtonSide: CGFloat = 36
private let stripGlyphSize: CGFloat = 15
#else
private let stripButtonSide: CGFloat = 44
private let stripGlyphSize: CGFloat = 17
#endif
/// Concentric with the buttons: half a button plus the strip's 4 pt inset.
private let stripCornerRadius: CGFloat = stripButtonSide / 2 + 4

/// A 44-point glyph button (36 on the Mac) that lives on glass: no chrome of its own, a soft
/// press highlight (and hover highlight on the Mac), and a tinted ring when the key is held
/// (sticky modifiers).
private struct StripButtonStyle: ButtonStyle {
    var isActive = false
    /// The glyph colour when it isn't active (Disconnect is red).
    var tint: Color?
    /// Shown as unavailable (Mac Audio on a host that can't send it).
    var isDimmed = false

    init(isActive: Bool = false, tint: Color? = nil, isDimmed: Bool = false) {
        self.isActive = isActive
        self.tint = tint
        self.isDimmed = isDimmed
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(StripGlyph(isActive: isActive, isPressed: configuration.isPressed, tint: tint))
            .opacity(isDimmed ? 0.35 : 1)
    }
}

/// The strip button look, shared by `StripButtonStyle` and controls that track their own press.
private struct StripGlyph: ViewModifier {
    var isActive: Bool
    var isPressed: Bool
    var tint: Color?
    #if os(macOS)
    @State private var isHovered = false
    #endif

    func body(content: Content) -> some View {
        content
            .font(.system(size: stripGlyphSize, weight: .medium))
            .foregroundStyle(isActive ? Color.accentColor : (tint ?? Color.primary))
            .frame(width: stripButtonSide, height: stripButtonSide)
            .background {
                Circle()
                    .fill(isActive ? Color.accentColor.opacity(0.2) : Color.primary.opacity(highlight))
                    .padding(4)
            }
            .contentShape(Rectangle())
            #if os(visionOS)
            .contentShape(.hoverEffect, Circle().inset(by: 4))
            .hoverEffect()
            #elseif os(macOS)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
            }
            #endif
            // At the largest text sizes, a long press shows the glyph big (the strip itself
            // stays a fixed size so it fits the Mac's screen).
            .accessibilityShowsLargeContentViewer()
            .scaleEffect(isPressed ? 0.88 : 1)
            .animation(.snappy(duration: 0.18), value: isPressed)
            .animation(.snappy(duration: 0.2), value: isActive)
    }

    private var highlight: Double {
        if isPressed { return 0.12 }
        #if os(macOS)
        if isHovered { return 0.07 }
        #endif
        return 0
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

/// A tap on a sticky modifier: which way it went, and a count so two taps the same way both play.
struct ModifierTap: Equatable {
    var count = 0
    var latched = false
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: isActive ? "mic.fill" : "mic")
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, isActive: isActive && !reduceMotion) // the fill and tint still say it's on
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
            .help(isActive ? "Stop Dictation" : "Dictate")
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isActive ? "Stop Dictation" : "Dictate")
            .accessibilityHint("Hold to talk, or \(LocalDevice.tap) to start and \(LocalDevice.tap) again to stop.")
            .accessibilityAction { onPress(.toggle) }
            .accessibilityIdentifier("session.toolbar.dictate")
    }
}

/// What the strip needs to draw and flip the Mac Audio toggle.
struct MacAudioToggle {
    /// The user wants the Mac's sound here (and nothing has failed this session).
    var isOn = false
    /// Nil when the host can send audio; otherwise why the toggle is dimmed.
    var unavailableReason: String?
    var onToggle: () -> Void = {}
}

/// What the strip needs for Send File and the Transfers list.
struct SendFileAction {
    /// Nil when the Mac can take files; otherwise why Send File is dimmed.
    var unavailableReason: String?
    /// Progress of the files moving now (0…1), or nil when nothing is.
    var progress: Double?
    /// Something has moved (or is moving) this session, so Transfers… is worth offering.
    var hasTransfers = false
    var onSend: () -> Void = {}
    var onShowTransfers: () -> Void = {}
}

/// A hairline ring hugging the Send File glyph, filled to the transfer's progress.
private struct SendFileProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Progress arrives every tenth of a second; linear over the same span reads as
                // one continuous fill instead of steps.
                .animation(.linear(duration: 0.12), value: fraction)
        }
        .frame(width: stripButtonSide - 10, height: stripButtonSide - 10)
        .accessibilityHidden(true)
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

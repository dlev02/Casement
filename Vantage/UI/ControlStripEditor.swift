import SwiftUI
import VantageCore

/// Chooses and orders the session controls, in the manner of Control Center's customization:
/// a live preview of the strip on top, the shown controls (drag to reorder, minus to remove),
/// then the rest (plus to add). Edits the default layout, or with `macName` one Mac's own layout,
/// which falls back to the default while it's nil.
struct ControlStripEditor: View {
    private let mac: MacTarget?

    @AppStorage(ControlStripLayout.defaultsKey) private var defaultLayout = ControlStripLayout.platformStandard
    @AppStorage("vantage.toolbarDock") private var dock = ToolbarDock.bottomLeft
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if !os(macOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @State private var showDefaultEditor = false

    /// Edits the default layout (Settings → Controls).
    init() { mac = nil }

    /// Edits one Mac's or PC's layout; nil means it uses the default. `platform` names the
    /// controls for that host and leaves out the ones it can't use.
    init(macName: String, platform: HostPlatform? = .macOS, layout: Binding<ControlStripLayout?>) {
        mac = MacTarget(name: macName, platform: platform, layout: layout)
    }

    private struct MacTarget {
        let name: String
        let platform: HostPlatform?
        let layout: Binding<ControlStripLayout?>
    }

    /// The host being edited for; nil for the default layout, which shows every control.
    private var platform: HostPlatform? { mac?.platform }
    private var unavailable: Set<StripItem> { StripItem.unavailable(on: platform) }

    var body: some View {
        List {
            if let mac { macSection(mac) }
            if !pinsPreview {
                Section { preview }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            shownSection
            moreSection
            resetSection
        }
        #if !os(macOS)
        // Always editing, so the reorder handles show, as in Control Center.
        .environment(\.editMode, .constant(.active))
        #endif
        .safeAreaInset(edge: .top, spacing: 0) {
            if pinsPreview {
                preview
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Self.groupedBackground)
                    // Rows fade out as they pass under the preview instead of being cut off.
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [Self.groupedBackground, Self.groupedBackground.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 16)
                            .offset(y: 16)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
            }
        }
        .sensoryFeedback(.selection, trigger: layout)
        .navigationTitle("Customize Controls")
        .modifier(MacSubtitle(name: mac?.name))
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(isPresented: $showDefaultEditor) { ControlStripEditor() }
    }

    // MARK: State

    private var layout: ControlStripLayout { mac.map { $0.layout.wrappedValue ?? defaultLayout } ?? defaultLayout }

    /// The default is always editable; a Mac only once it has its own layout.
    private var isEditable: Bool { mac.map { $0.layout.wrappedValue != nil } ?? true }

    /// A Mac resets to the default layout; the default resets to the standard one.
    private var resetTarget: ControlStripLayout { mac == nil ? .platformStandard : defaultLayout }

    /// What this device shows of the layout. A Mac skips controls it can't use (the on-screen
    /// keyboard), and every edit goes through `replacingVisible`, so a layout synced from an
    /// iPad keeps them.
    private var visible: ControlStripLayout { ControlStripLayout(items: layout.visibleItems(excluding: unavailable)) }

    /// Pinned above the list so it stays in view while editing further down, except where there
    /// isn't the height for it (iPhone in landscape) and on visionOS, where it scrolls with the list.
    private var pinsPreview: Bool {
        #if os(visionOS)
        false
        #elseif os(macOS)
        true
        #else
        verticalSizeClass != .compact
        #endif
    }

    #if os(macOS)
    private static var groupedBackground: Color { Color(nsColor: .windowBackgroundColor) }
    #else
    private static var groupedBackground: Color { Color(.systemGroupedBackground) }
    #endif

    /// Gentle and quick, no overshoot to speak of. Reduce Motion swaps the preview with a
    /// crossfade instead of sliding its buttons around (see `preview`).
    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.3, bounce: 0.1)
    }

    private func update(_ change: (inout ControlStripLayout) -> Void) {
        var edited = visible
        change(&edited)
        let next = layout.replacingVisible(with: edited.items, unavailable: unavailable)
        guard next != layout else { return }
        withAnimation(motion) {
            if let mac { mac.layout.wrappedValue = next } else { defaultLayout = next }
        }
    }

    // MARK: Sections

    private var preview: some View {
        ControlStripPreview(items: visible.items, dock: dock, host: platform)
            .id(reduceMotion ? visible.rawValue : "")
            .transition(.opacity)
    }

    private func macSection(_ mac: MacTarget) -> some View {
        Section {
            Toggle("Customize for This \(HostNoun(mac.platform).name)", isOn: Binding(
                get: { mac.layout.wrappedValue != nil },
                set: { on in withAnimation(motion) { mac.layout.wrappedValue = on ? defaultLayout : nil } }))
            if !isEditable {
                // A button rather than a NavigationLink: links don't respond while a list is editing.
                Button { showDefaultEditor = true } label: {
                    HStack {
                        Text("Edit Default Layout")
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .tint(.primary) // a way through, like a navigation row, not an action
            }
        } footer: {
            Text(isEditable
                 ? "Only \(mac.name) uses these controls. Other Macs and PCs keep the default layout."
                 : "Uses the layout from Settings → Controls.")
                .wrapsInFooter()
        }
    }

    private var shownSection: some View {
        Section {
            ForEach(visible.items) { item in
                StripItemRow(item: item, host: platform, control: isEditable ? .remove : .none, reorderable: isEditable) {
                    update { $0.remove(item) }
                }
                .accessibilityActions {
                    if isEditable {
                        if item != visible.items.first {
                            Button("Move Up") { update { $0.move(item, by: -1) } }
                        }
                        if item != visible.items.last {
                            Button("Move Down") { update { $0.move(item, by: 1) } }
                        }
                    }
                }
            }
            .onMove(perform: isEditable ? { source, destination in
                update { $0.move(fromOffsets: source, toOffset: destination) }
            } : nil)
            if visible.items.isEmpty {
                Text("No controls. Add some from More Controls.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Shown")
        } footer: {
            Text(mac == nil
                 ? "The menu and the collapse button are always at the end. Macs and PCs you've customized keep their own controls. Start and Task Manager show only for a PC, Type Password and Mac Audio only for a Mac."
                 : "The menu and the collapse button are always at the end.")
                .wrapsInFooter()
        }
        .disabled(!isEditable)
    }

    private var moreSection: some View {
        Section("More Controls") {
            ForEach(visible.hiddenItems(excluding: unavailable)) { item in
                StripItemRow(item: item, host: platform, control: isEditable ? .add : .none, reorderable: false) {
                    update { $0.add(item) }
                }
            }
            if visible.hiddenItems(excluding: unavailable).isEmpty {
                Text("Every control is shown.")
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!isEditable)
    }

    private var resetSection: some View {
        Section {
            Button("Reset to Default") { update { $0 = resetTarget } }
                .disabled(!isEditable || layout == resetTarget)
        } footer: {
            if mac != nil && isEditable {
                Text("Resetting matches the default layout from Settings → Controls.")
                    .wrapsInFooter()
            }
        }
    }
}

private extension Text {
    /// A Mac List keeps a section footer to one line and cuts it off; let it wrap.
    @ViewBuilder func wrapsInFooter() -> some View {
        #if os(macOS)
        fixedSize(horizontal: false, vertical: true)
        #else
        self
        #endif
    }
}

/// Names the Mac under the title when editing its own layout (iOS; visionOS has no subtitle, so
/// the toggle's footer carries the name there).
private struct MacSubtitle: ViewModifier {
    let name: String?

    func body(content: Content) -> some View {
        #if os(visionOS)
        content
        #else
        if let name { content.navigationSubtitle(name) } else { content }
        #endif
    }
}

/// Edits one saved Mac's controls straight in the store, so the change syncs with the device list
/// and an open session's strip follows along.
struct MacControlStripEditor: View {
    let deviceID: UUID
    @Environment(DeviceStore.self) private var store

    var body: some View {
        let device = store.devices.first { $0.id == deviceID }
        ControlStripEditor(
            macName: device?.name ?? "This Mac", platform: device?.platform ?? .macOS,
            layout: Binding(get: { store.devices.first { $0.id == deviceID }?.controlStrip },
                            set: { store.setControlStrip($0, for: deviceID) }))
    }
}

// MARK: - Rows

/// Symbol tile, name, and what it sends, with the add or remove button in front.
private struct StripItemRow: View {
    enum Control { case add, remove, none }

    let item: StripItem
    /// Names the control for this host; nil describes it for any host.
    var host: HostPlatform?
    let control: Control
    /// Shows a grip on the Mac, where rows reorder by dragging with no edit mode to show handles.
    var reorderable = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 4) {
            switch control {
            case .remove: circleButton("minus.circle.fill", tint: .red, label: "Remove \(item.label(for: host))")
            case .add: circleButton("plus.circle.fill", tint: .green, label: "Add \(item.label(for: host))")
            case .none: EmptyView()
            }
            HStack(spacing: 12) {
                // Decorative; at accessibility sizes the name needs the room more.
                if !dynamicTypeSize.isAccessibilitySize { StripItemTile(item: item, host: host) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label(for: host))
                    Text(item.detail(for: host))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                #if os(macOS)
                if reorderable {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .help("Drag to reorder")
                }
                #endif
            }
            // The name is the label and what it sends the value ("Escape, Esc key"). The system
            // reorder handle takes its name from the row's label, so a description folded into
            // the label would make it "Reorder Escape, Esc key".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.label(for: host))
            .accessibilityValue(item.detail(for: host))
            // Read the name before the button, which also gives the reorder handle "Reorder
            // Escape" rather than "Reorder Remove Escape".
            .accessibilitySortPriority(1)
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    #if os(macOS)
    private static let buttonHeight: CGFloat = 28 // a pointer needs less than a finger
    #else
    private static let buttonHeight: CGFloat = 44
    #endif

    private func circleButton(_ symbol: String, tint: Color, label: String) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
                .frame(minWidth: 36, minHeight: Self.buttonHeight, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

/// A Settings-style icon: the control's symbol on a rounded square tinted by its group.
private struct StripItemTile: View {
    let item: StripItem
    var host: HostPlatform?
    @ScaledMetric(relativeTo: .body) private var scaledSide: CGFloat = 30
    /// Grows with the text, but not so far that the name has no room left at the largest sizes.
    private var side: CGFloat { min(scaledSide, 40) }

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.27, style: .continuous)
            .fill(item.tileTint.gradient)
            .frame(width: side, height: side)
            .overlay {
                Group {
                    if let keycap = item.keycapText(for: host) {
                        Text(keycap)
                            .font(.system(size: side * 0.34, weight: .bold))
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 2)
                    } else {
                        Image(systemName: item.symbol(for: host))
                            .symbolVariant(.fill)
                            .font(.system(size: side * 0.5, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

extension StripItem {
    /// Groups share a colour; Disconnect is red, like the button on the strip.
    var tileTint: Color {
        if self == .disconnect { return .red }
        switch category {
        case .modifiers: return .indigo
        case .keys: return .gray
        case .shortcuts: return .blue
        case .actions: return .orange
        }
    }
}

// MARK: - Preview

/// The real strip, expanded and inert, on a small dark desktop so it reads as the session.
struct ControlStripPreview: View {
    let items: [StripItem]
    var dock: ToolbarDock = .bottomLeft
    var host: HostPlatform?

    /// A miniature: small enough that the strip wraps as it would across a whole iPad or a
    /// landscape iPhone rather than across this sheet, still big enough to read every symbol.
    private static let scale: CGFloat = 0.75

    var body: some View {
        ControlStrip(
            isCollapsed: .constant(false), dock: .constant(dock), stickyModifiers: .constant([]),
            touchMode: .constant(.trackpad), onKey: { _, _ in }, onShowKeyboard: {}, onSendClipboard: {},
            onSendPassword: {}, onHostCommand: { _ in }, onDisconnect: {}, items: items, host: host, isPreview: true)
            .allowsHitTesting(false)
            .scaleEffect(Self.scale)
            .modifier(ScaledLayout(scale: Self.scale))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: dock.isLeading ? .leading : .trailing)
            .padding(12)
            .padding(.top, 16) // never over the menu bar, as in a session
            .frame(minHeight: 132, alignment: dock.isTop ? .top : .bottom)
            .background { SessionBackdrop() }
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            }
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of the session controls")
            .accessibilityValue(items.isEmpty ? "Menu and collapse button only" : items.map { $0.label(for: host) }.joined(separator: ", "))
    }
}

/// Lays its content out as if it had `1 / scale` times the room, and takes up the scaled size, so
/// a `scaleEffect(scale)` inside it wraps like the full-size strip would in a wider window.
private struct ScaledLayout: ViewModifier {
    let scale: CGFloat

    func body(content: Content) -> some View {
        ScaledLayoutContainer(scale: scale) { content }
    }
}

private struct ScaledLayoutContainer: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(unscaled(proposal))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: unscaled(ProposedViewSize(bounds.size)))
    }

    private func unscaled(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })
    }
}

/// A night-time desktop in miniature: a deep mesh gradient, a hint of a menu bar, and one
/// window, all quiet enough that the strip stays the subject.
private struct SessionBackdrop: View {
    var body: some View {
        ZStack(alignment: .top) {
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ], colors: [
                Color(red: 0.11, green: 0.14, blue: 0.34), Color(red: 0.20, green: 0.12, blue: 0.38), Color(red: 0.06, green: 0.22, blue: 0.40),
                Color(red: 0.07, green: 0.09, blue: 0.22), Color(red: 0.16, green: 0.17, blue: 0.42), Color(red: 0.08, green: 0.13, blue: 0.30),
                Color(red: 0.03, green: 0.04, blue: 0.11), Color(red: 0.08, green: 0.06, blue: 0.19), Color(red: 0.04, green: 0.08, blue: 0.17),
            ])

            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(0.06))
                    .strokeBorder(.white.opacity(0.10))
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 4) {
                            ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.22)).frame(width: 5, height: 5) }
                        }
                        .padding(7)
                    }
                    .frame(width: proxy.size.width * 0.46, height: proxy.size.height * 0.5)
                    .position(x: proxy.size.width * 0.62, y: proxy.size.height * 0.42)
            }

            HStack(spacing: 8) {
                Circle().fill(.white.opacity(0.5)).frame(width: 6, height: 6)
                ForEach([22.0, 16, 26, 18], id: \.self) { width in
                    Capsule().fill(.white.opacity(0.22)).frame(width: width, height: 4)
                }
                Spacer()
                Capsule().fill(.white.opacity(0.22)).frame(width: 30, height: 4)
            }
            .padding(.horizontal, 12)
            .frame(height: 16)
            .background(.white.opacity(0.06))
        }
        .accessibilityHidden(true)
    }
}

import SwiftUI
import VantageCore

/// Where things go while an iPhone Duo sits like a laptop: the inner display folded part way with
/// the fold running across it. The picture takes the half that stands up, to be seen from a
/// distance; the keyboard, trackpad and control strip take the half on the desk, a steady
/// surface to tap (the HIG's tabletop rule). Rects are in full-screen points.
nonisolated struct TabletopLayout: Equatable, Sendable {
    var picture: CGRect
    var deck: CGRect

    /// Neither half is worth splitting for below this.
    private static let minimumHalf: CGFloat = 160

    #if os(iOS)
    /// From the fold's reserved region, never the hinge angle. Nil when there's no active fold,
    /// when it runs top to bottom (held like a book, which keeps today's layout), or when a half
    /// would be too small to use.
    @available(iOS 27.1, *)
    init?(_ proxy: GeometryProxy) {
        let folds = proxy.reservedRegions(kind: .division)
            .filter { $0.isActive && $0.frame.width > $0.frame.height }
        guard let fold = folds.first else { return nil }
        let size = proxy.size
        // The picture runs up to the fold; the deck's controls also keep the fold's margin.
        let pictureBottom = fold.frame.minY
        let deckTop = fold.frame.maxY + fold.margins.bottom
        guard pictureBottom >= Self.minimumHalf, size.height - deckTop >= Self.minimumHalf else { return nil }
        picture = CGRect(x: 0, y: 0, width: size.width, height: pictureBottom)
        deck = CGRect(x: 0, y: deckTop, width: size.width, height: size.height - deckTop)
    }
    #endif
}

/// What the lower half holds in tabletop. Trackpad first: a quick visit to a Mac is mostly
/// pointing and clicking, and the strip's Keyboard button still brings up the system keyboard.
enum TabletopDeckMode: String, CaseIterable, Identifiable {
    case trackpad, keyboard, both
    static let defaultsKey = "vantage.tabletopDeck"
    /// Whether an iPhone Duo set up like a laptop gets the split layout at all.
    static let enabledKey = "vantage.tabletopLayout"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .trackpad: "Trackpad"
        case .keyboard: "Keyboard"
        case .both: "Keyboard and Trackpad"
        }
    }
    var symbol: String {
        switch self {
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .keyboard: "keyboard"
        case .both: "rectangle.split.2x1"
        }
    }
}

#if os(iOS)
/// The lower half in tabletop: the control strip, with a switch beside it, over a big trackpad,
/// a full-width Mac keyboard, or both side by side like a Magic Keyboard and Magic Trackpad (the
/// half is about 669 × 400 pt, so a laptop's keyboard over a trackpad would leave the trackpad
/// about 75 pt tall).
struct TabletopDeck<Strip: View>: View {
    let input: InputController
    @Binding var stickyModifiers: KeyModifiers
    let host: HostPlatform
    let onKey: (UInt16, KeyModifiers) -> Void
    @ViewBuilder let strip: () -> Strip
    @AppStorage(TabletopDeckMode.defaultsKey) private var mode = TabletopDeckMode.trackpad
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                strip()
                    .frame(maxWidth: .infinity)
                modePicker
            }
            GeometryReader { geometry in
                HStack(spacing: 12) {
                    if mode != .trackpad {
                        TabletopKeyboard(host: host, modifiers: $stickyModifiers, onKey: onKey)
                            .transition(.opacity)
                    }
                    if mode != .keyboard {
                        trackpad
                            .frame(width: mode == .both ? min(geometry.size.width * 0.3, 300) : nil)
                            .transition(.opacity)
                    }
                }
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.3), value: mode)
    }

    private var trackpad: some View {
        TrackpadSurface(input: input, stickyModifiers: stickyModifiers)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
    }

    /// Three small buttons stacked beside the strip, the height of its two rows.
    private var modePicker: some View {
        VStack(spacing: 4) {
            ForEach(TabletopDeckMode.allCases) { option in
                Button {
                    mode = option
                } label: {
                    Image(systemName: option.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 40, height: 28)
                        .foregroundStyle(mode == option ? .white : .primary)
                        .background(mode == option ? Color.accentColor : .clear, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(mode == option ? .isSelected : [])
            }
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lower Half")
    }
}

/// A US Mac keyboard drawn on screen, five rows to fit the lower half. Every key is a real key
/// press (so ⌘C, ⌥←, Esc and the rest work) and the modifier keys are the strip's sticky
/// modifiers: tap one, then the key.
struct TabletopKeyboard: View {
    let host: HostPlatform
    @Binding var modifiers: KeyModifiers
    let onKey: (UInt16, KeyModifiers) -> Void

    private static let spacing: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            let rowHeight = (geometry.size.height - Self.spacing * CGFloat(rows.count - 1)) / CGFloat(rows.count)
            VStack(spacing: Self.spacing) {
                ForEach(rows.indices, id: \.self) { index in
                    row(rows[index], width: geometry.size.width, height: rowHeight)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard")
    }

    private func row(_ keys: [KeyCap], width: CGFloat, height: CGFloat) -> some View {
        let units = keys.reduce(0) { $0 + $1.units }
        let unit = (width - Self.spacing * CGFloat(keys.count - 1)) / units
        return HStack(spacing: Self.spacing) {
            ForEach(keys) { key in
                Group {
                    if case .arrowsUpDown = key.kind {
                        VStack(spacing: 2) {
                            keyButton(KeyCap("↑", 0x7E, name: "Up Arrow"), height: (height - 2) / 2)
                            keyButton(KeyCap("↓", 0x7D, name: "Down Arrow"), height: (height - 2) / 2)
                        }
                    } else {
                        keyButton(key, height: height)
                    }
                }
                .frame(width: unit * key.units)
            }
        }
    }

    private func keyButton(_ key: KeyCap, height: CGFloat) -> some View {
        let latched = key.modifier.map { modifiers.contains($0) } ?? false
        return Button {
            press(key)
        } label: {
            label(for: key)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, key.units > 1.2 ? 6 : 0)
                .padding(.vertical, key.units > 1.2 ? 4 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: key.alignment)
        }
        .buttonStyle(KeyCapStyle(latched: latched))
        .frame(height: height)
        .accessibilityLabel(key.name)
        .accessibilityAddTraits(latched ? .isSelected : [])
    }

    @ViewBuilder
    private func label(for key: KeyCap) -> some View {
        let shifted = modifiers.contains(.shift)
        if let shiftLabel = key.shiftLabel {
            VStack(spacing: 0) {
                Text(shiftLabel).font(.system(size: 11)).opacity(shifted ? 1 : 0.6)
                Text(key.label).font(.system(size: 15)).opacity(shifted ? 0.6 : 1)
            }
        } else if key.kind == .letter {
            Text(shifted ? key.label.uppercased() : key.label).font(.system(size: 17))
        } else {
            Text(keycapText(key)).font(.system(size: keycapText(key).count > 2 ? 13 : 16))
        }
    }

    /// A PC's modifiers wear their own names; the codes are the same (the host maps ⌘ to Win).
    private func keycapText(_ key: KeyCap) -> String {
        guard host == .windows, let modifier = key.modifier else { return key.label }
        switch modifier {
        case .control: return "ctrl"
        case .option: return "alt"
        case .command: return "win"
        default: return key.label
        }
    }

    private func press(_ key: KeyCap) {
        if let modifier = key.modifier {
            if modifiers.contains(modifier) { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
            return
        }
        onKey(key.code, modifiers)
        modifiers = []
    }

    private var rows: [[KeyCap]] { Self.layout }

    private static let layout: [[KeyCap]] = [
        [KeyCap("`", 0x32, shift: "~"), KeyCap("1", 0x12, shift: "!"), KeyCap("2", 0x13, shift: "@"),
         KeyCap("3", 0x14, shift: "#"), KeyCap("4", 0x15, shift: "$"), KeyCap("5", 0x17, shift: "%"),
         KeyCap("6", 0x16, shift: "^"), KeyCap("7", 0x1A, shift: "&"), KeyCap("8", 0x1C, shift: "*"),
         KeyCap("9", 0x19, shift: "("), KeyCap("0", 0x1D, shift: ")"), KeyCap("-", 0x1B, shift: "_"),
         KeyCap("=", 0x18, shift: "+"), KeyCap("delete", 0x33, units: 1.5, alignment: .bottomTrailing, name: "Delete")],
        [KeyCap("tab", 0x30, units: 1.5, alignment: .bottomLeading, name: "Tab")]
            + KeyCap.letters("qwertyuiop", codes: [0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x10, 0x20, 0x22, 0x1F, 0x23])
            + [KeyCap("[", 0x21, shift: "{"), KeyCap("]", 0x1E, shift: "}"), KeyCap("\\", 0x2A, shift: "|")],
        [KeyCap("caps lock", 0x39, units: 1.75, alignment: .bottomLeading, name: "Caps Lock")]
            + KeyCap.letters("asdfghjkl", codes: [0x00, 0x01, 0x02, 0x03, 0x05, 0x04, 0x26, 0x28, 0x25])
            + [KeyCap(";", 0x29, shift: ":"), KeyCap("'", 0x27, shift: "\""),
               KeyCap("return", 0x24, units: 1.75, alignment: .bottomTrailing, name: "Return")],
        [KeyCap("shift", 0x38, units: 2.25, alignment: .bottomLeading, modifier: .shift, name: "Shift")]
            + KeyCap.letters("zxcvbnm", codes: [0x06, 0x07, 0x08, 0x09, 0x0B, 0x2D, 0x2E])
            + [KeyCap(",", 0x2B, shift: "<"), KeyCap(".", 0x2F, shift: ">"), KeyCap("/", 0x2C, shift: "?"),
               KeyCap("shift", 0x3C, units: 2.25, alignment: .bottomTrailing, modifier: .shift, name: "Right Shift")],
        [KeyCap("esc", 0x35, name: "Escape"),
         KeyCap("⌃", 0x3B, modifier: .control, name: "Control"),
         KeyCap("⌥", 0x3A, modifier: .option, name: "Option"),
         KeyCap("⌘", 0x37, units: 1.25, modifier: .command, name: "Command"),
         KeyCap("", 0x31, units: 5, name: "Space"),
         KeyCap("⌘", 0x36, units: 1.25, modifier: .command, name: "Right Command"),
         KeyCap("⌥", 0x3D, modifier: .option, name: "Right Option"),
         KeyCap("←", 0x7B, name: "Left Arrow"),
         KeyCap(kind: .arrowsUpDown),
         KeyCap("→", 0x7C, name: "Right Arrow")],
    ]
}

/// One key: what it shows, the macOS virtual key code it sends, and its width in key units.
struct KeyCap: Identifiable {
    enum Kind: Equatable { case key, letter, arrowsUpDown }

    let id = UUID()
    var label = ""
    var shiftLabel: String?
    var code: UInt16 = 0
    var units: CGFloat = 1
    var alignment: Alignment = .center
    var modifier: KeyModifiers?
    var name = ""
    var kind = Kind.key

    init(_ label: String, _ code: UInt16, shift: String? = nil, units: CGFloat = 1, alignment: Alignment = .center,
         modifier: KeyModifiers? = nil, name: String? = nil, kind: Kind = .key) {
        self.label = label
        self.shiftLabel = shift
        self.code = code
        self.units = units
        self.alignment = alignment
        self.modifier = modifier
        self.name = name ?? label
        self.kind = kind
    }

    init(kind: Kind) {
        self.kind = kind
        self.name = "Up and Down Arrows"
    }

    static func letters(_ letters: String, codes: [UInt16]) -> [KeyCap] {
        zip(letters, codes).map { KeyCap(String($0), $1, name: String($0).uppercased(), kind: .letter) }
    }
}

/// Dark keys on the black deck, lighter while pressed; a latched modifier takes the accent.
private struct KeyCapStyle: ButtonStyle {
    let latched: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(background(pressed: configuration.isPressed),
                        in: .rect(cornerRadius: 7, style: .continuous))
            .contentShape(.rect(cornerRadius: 7, style: .continuous))
    }

    private func background(pressed: Bool) -> AnyShapeStyle {
        if latched { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(Color.white.opacity(pressed ? 0.32 : 0.14))
    }
}
#endif

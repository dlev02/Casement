import CoreGraphics
import VantageCore

/// Turns the client's key events into what a Mac keyboard itself sends, so macOS and apps can't
/// tell the two apart where it matters:
///
/// - Modifier keys are `flagsChanged` events carrying the state after the change, with the
///   device bit for their side (`NX_DEVICELCMDKEYMASK` and friends in IOLLEvent.h).
/// - A chord that arrives as one key with modifiers (a strip button, a sticky ⌘) presses those
///   modifiers first as their own keys and lets them go after the key, like a hand would.
/// - Arrow, function, and navigation keys carry the Fn flag, and arrows and the keypad the
///   keypad flag, as they do from a real keyboard. The system shortcuts are stored with them:
///   Mission Control is ⌃↑ *with* Fn (`com.apple.symbolichotkeys` 32 = 0x840000), Show Desktop
///   is F11 with Fn, and a key without the flag matches nothing.
///
/// Pure bookkeeping (no CGEvent posting) so the sequences can be tested.
nonisolated struct KeyboardSequencer: Sendable {
    struct Stroke: Equatable, Sendable, CustomStringConvertible {
        enum Kind: Equatable, Sendable { case keyDown, keyUp, flagsChanged }
        var kind: Kind
        var keyCode: UInt16
        var flags: CGEventFlags
        var isRepeat = false

        var description: String { "\(kind) 0x\(String(keyCode, radix: 16)) flags 0x\(String(flags.rawValue, radix: 16))" }
    }

    /// Modifier keys down right now, left and right apart.
    private(set) var heldModifierKeys: Set<UInt16> = []
    private(set) var heldKeys: Set<UInt16> = []
    /// Modifiers pressed on a key's behalf, let go after that key.
    private var impliedModifiers: [UInt16: [UInt16]] = [:]
    /// Keys whose press was handled another way (⌘Space opening Raycast); their release is dropped.
    private var consumedKeys: Set<UInt16> = []

    /// The modifiers held right now, as flags (pointer events carry these too).
    var modifierFlags: CGEventFlags { Self.flags(forHeldModifierKeys: heldModifierKeys) }

    mutating func strokes(for event: KeyEvent) -> [Stroke] {
        if consumedKeys.contains(event.keyCode) {
            if !event.isDown { consumedKeys.remove(event.keyCode) }
            return []
        }
        if Self.modifierFlag(forKeyCode: event.keyCode) != nil {
            return [press(modifier: event.keyCode, isDown: event.isDown)]
        }
        var strokes: [Stroke] = []
        if event.isDown && !event.isRepeat && !heldKeys.contains(event.keyCode) {
            let implied = Self.modifierKeys(for: event.modifiers).filter { !isSideHeld(of: $0) }
            strokes += implied.map { press(modifier: $0, isDown: true) }
            if !implied.isEmpty { impliedModifiers[event.keyCode] = implied }
        }
        let flags = modifierFlags.union(Self.flags(for: event.modifiers)).union(Self.hardwareFlags(forKeyCode: event.keyCode))
        strokes.append(Stroke(kind: event.isDown ? .keyDown : .keyUp, keyCode: event.keyCode, flags: flags, isRepeat: event.isRepeat))
        if event.isDown {
            heldKeys.insert(event.keyCode)
        } else {
            heldKeys.remove(event.keyCode)
            if let implied = impliedModifiers.removeValue(forKey: event.keyCode) {
                strokes += implied.reversed().compactMap { heldModifierKeys.contains($0) ? press(modifier: $0, isDown: false) : nil }
            }
        }
        return strokes
    }

    /// Takes this key press out of the stream (it was handled another way); its release and any
    /// repeats are dropped too.
    mutating func consume(_ event: KeyEvent) {
        if event.isDown { consumedKeys.insert(event.keyCode) }
    }

    /// Lets go of every key and modifier still down, keys first. For disconnects and focus loss.
    mutating func releaseAll() -> [Stroke] {
        var strokes = heldKeys.sorted().map {
            Stroke(kind: .keyUp, keyCode: $0, flags: modifierFlags.union(Self.hardwareFlags(forKeyCode: $0)))
        }
        heldKeys.removeAll()
        impliedModifiers.removeAll()
        consumedKeys.removeAll()
        strokes += heldModifierKeys.sorted().map { press(modifier: $0, isDown: false) }
        return strokes
    }

    private mutating func press(modifier keyCode: UInt16, isDown: Bool) -> Stroke {
        if isDown { heldModifierKeys.insert(keyCode) } else { heldModifierKeys.remove(keyCode) }
        return Stroke(kind: .flagsChanged, keyCode: keyCode, flags: modifierFlags)
    }

    /// Either side of this modifier is already down.
    private func isSideHeld(of keyCode: UInt16) -> Bool {
        guard let flag = Self.modifierFlag(forKeyCode: keyCode) else { return false }
        return heldModifierKeys.contains { Self.modifierFlag(forKeyCode: $0) == flag }
    }

    // MARK: Tables

    static func modifierFlag(forKeyCode keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 0x37, 0x36: .maskCommand      // L/R Command
        case 0x38, 0x3C: .maskShift        // L/R Shift
        case 0x3B, 0x3E: .maskControl      // L/R Control
        case 0x3A, 0x3D: .maskAlternate    // L/R Option
        case 0x39: .maskAlphaShift         // Caps Lock
        case 0x3F: .maskSecondaryFn        // Fn
        default: nil
        }
    }

    /// The flags for a set of held modifier keys: each modifier plus its side's device bit.
    static func flags(forHeldModifierKeys keys: Set<UInt16>) -> CGEventFlags {
        keys.reduce(into: CGEventFlags()) { flags, key in
            if let flag = modifierFlag(forKeyCode: key) { flags.insert(flag) }
            flags.insert(CGEventFlags(rawValue: deviceBit(forKeyCode: key)))
        }
    }

    static func deviceBit(forKeyCode keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 0x3B: 0x0000_0001 // left Control
        case 0x38: 0x0000_0002 // left Shift
        case 0x3C: 0x0000_0004 // right Shift
        case 0x37: 0x0000_0008 // left Command
        case 0x36: 0x0000_0010 // right Command
        case 0x3A: 0x0000_0020 // left Option
        case 0x3D: 0x0000_0040 // right Option
        case 0x3E: 0x0000_2000 // right Control
        default: 0
        }
    }

    /// The client's modifier bits as event flags.
    static func flags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// The left-hand keys for a chord's modifiers, in the order a hand presses them. Caps Lock
    /// and Fn stay flags: Caps Lock is a toggle, and Fn is what the key itself carries.
    static func modifierKeys(for modifiers: KeyModifiers) -> [UInt16] {
        var keys: [UInt16] = []
        if modifiers.contains(.control) { keys.append(0x3B) }
        if modifiers.contains(.option) { keys.append(0x3A) }
        if modifiers.contains(.shift) { keys.append(0x38) }
        if modifiers.contains(.command) { keys.append(0x37) }
        return keys
    }

    /// Flags macOS puts on a key from a real keyboard: Fn on the arrow, function, and navigation
    /// keys; the keypad bit on the arrows and the keypad (see `NSEvent.ModifierFlags`).
    static func hardwareFlags(forKeyCode keyCode: UInt16) -> CGEventFlags {
        switch keyCode {
        case 0x7B...0x7E: [.maskSecondaryFn, .maskNumericPad] // arrows
        case 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, // F1–F12
             0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A, // F13–F20
             0x72, 0x73, 0x74, 0x75, 0x77, 0x79: // Help, Home, Page Up, Forward Delete, End, Page Down
            .maskSecondaryFn
        case 0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51...0x59, 0x5B, 0x5C: // keypad
            .maskNumericPad
        default: []
        }
    }
}

/// ⌘Space goes to whatever the Mac has on it. Spotlight's shortcut is a system hot key, and so
/// are the Carbon hot keys most launchers register: Vantage's keystrokes trigger both. Raycast's
/// doesn't answer them: it only opens for a physical keyboard (it checks presses against its own
/// HID listener). So when Spotlight has given ⌘Space up and Raycast is running, the host opens
/// Raycast itself with its URL.
nonisolated enum SearchShortcut {
    static let raycastBundleID = "com.raycast.macos"
    static let raycastURL = "raycast://"
    /// `com.apple.symbolichotkeys` id for "Show Spotlight search".
    static let spotlightHotKeyID = "64"

    /// A press of Space with ⌘ and no other modifier (held or carried).
    static func isCommandSpace(_ event: KeyEvent, heldFlags: CGEventFlags) -> Bool {
        guard event.keyCode == 0x31, event.isDown, !event.isRepeat else { return false }
        let flags = heldFlags.union(KeyboardSequencer.flags(for: event.modifiers))
            .intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        return flags == .maskCommand
    }

    /// Whether Spotlight still has ⌘Space, from `AppleSymbolicHotKeys` in
    /// `com.apple.symbolichotkeys` (missing means the default: on, ⌘Space).
    static func spotlightOwnsCommandSpace(_ symbolicHotKeys: [String: Any]?) -> Bool {
        guard let entry = symbolicHotKeys?[spotlightHotKeyID] as? [String: Any] else { return true }
        if let enabled = entry["enabled"] as? Bool, !enabled { return false }
        if let enabled = entry["enabled"] as? Int, enabled == 0 { return false }
        guard let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [Int],
              parameters.count >= 3 else { return true }
        return parameters[1] == 0x31 && UInt64(parameters[2]) & 0x00FF_0000 == CGEventFlags.maskCommand.rawValue
    }
}

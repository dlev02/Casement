import VantageCore

/// Turns this Mac's own key events (an `NSEvent`'s type, key code, raw modifier flags and repeat
/// flag) into the wire's key events, so the remote Mac sees the keyboard the way this one does.
///
/// `NSEvent.keyCode` is already a macOS virtual key code, the wire's format. Modifier keys go over
/// as keys of their own, left and right apart (the host's `KeyboardSequencer` posts them as
/// `flagsChanged` with the matching device bit), so a held ⌘ is held on the Mac too, and a
/// right-⌘ shortcut stays a right-⌘ shortcut. Whether a modifier went down or up comes from its
/// device bit (`NX_DEVICELCMDKEYMASK` and friends); a flag without device bits falls back to what
/// was already held.
///
/// Caps Lock only reports its new state, once per press, so each change goes over as a tap. The
/// Fn/Globe key never goes over on its own (macOS keeps it for itself; the host puts Fn on the
/// keys that carry it). A release or repeat for a key this translator never saw go down (it went
/// down before the window had the keyboard, or it was kept for Vantage) is dropped.
///
/// Pure bookkeeping, no AppKit, so it can be tested.
nonisolated struct KeyTranslator: Sendable {
    enum Kind: Sendable { case keyDown, keyUp, flagsChanged }

    /// Screens' "Swap ⌘ and ⌃": this Mac's ⌘ keys press ⌃ on the remote Mac and the other way
    /// round, for a PC keyboard or a hand used to one. Release everything before changing it.
    var swapsCommandAndControl = false

    /// Keys (not modifiers) down on the remote Mac, by key code.
    private(set) var heldKeys: Set<UInt16> = []
    /// Modifier keys down on the remote Mac, by the key code sent (after any swap).
    private(set) var heldModifierKeys: Set<UInt16> = []
    /// Caps Lock's state when last seen; nil until then.
    private var capsLockOn: Bool?

    // Raw `NSEvent.ModifierFlags` / `CGEventFlags` bits (the two share them).
    static let capsLockFlag: UInt64 = 1 << 16
    static let shiftFlag: UInt64 = 1 << 17
    static let controlFlag: UInt64 = 1 << 18
    static let optionFlag: UInt64 = 1 << 19
    static let commandFlag: UInt64 = 1 << 20
    /// The device-dependent bits for the eight left/right modifier keys (IOLLEvent.h).
    static let deviceBits: UInt64 = 0x207F

    static let capsLockKey: UInt16 = 0x39
    static let functionKey: UInt16 = 0x3F

    /// Whether `keyCode` went down through this translator and hasn't come up.
    func isHolding(keyCode: UInt16) -> Bool { heldKeys.contains(keyCode) }

    /// The wire events for one local key event; empty when nothing should be sent.
    mutating func translate(_ kind: Kind, keyCode: UInt16, flags: UInt64, isRepeat: Bool = false) -> [KeyEvent] {
        let modifiers = modifiers(fromFlags: flags)
        switch kind {
        case .flagsChanged:
            return modifierChanged(keyCode: keyCode, flags: flags, modifiers: modifiers)
        case .keyDown:
            guard Self.genericFlag(forModifierKey: keyCode) == nil, keyCode != Self.functionKey else { return [] }
            if isRepeat {
                guard heldKeys.contains(keyCode) else { return [] }
                return [KeyEvent(keyCode: keyCode, isDown: true, modifiers: modifiers, isRepeat: true)]
            }
            heldKeys.insert(keyCode)
            return [KeyEvent(keyCode: keyCode, isDown: true, modifiers: modifiers)]
        case .keyUp:
            guard heldKeys.remove(keyCode) != nil else { return [] }
            return [KeyEvent(keyCode: keyCode, isDown: false, modifiers: modifiers)]
        }
    }

    /// Lets go of every key and then every modifier still down on the remote Mac. For losing the
    /// keyboard (another window or app, capture off, View Only, the lock, a disconnect).
    mutating func releaseAll() -> [KeyEvent] {
        var events: [KeyEvent] = []
        let modifiers = Self.modifiers(forModifierKeys: heldModifierKeys)
        for keyCode in heldKeys.sorted() {
            events.append(KeyEvent(keyCode: keyCode, isDown: false, modifiers: modifiers))
        }
        heldKeys.removeAll()
        for keyCode in heldModifierKeys.sorted() {
            heldModifierKeys.remove(keyCode)
            events.append(KeyEvent(keyCode: keyCode, isDown: false, modifiers: Self.modifiers(forModifierKeys: heldModifierKeys)))
        }
        return events
    }

    /// The modifiers a local event's flags stand for on the remote Mac (after any swap). Fn is
    /// left out: the host adds it to the keys that carry it.
    func modifiers(fromFlags flags: UInt64) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags & Self.capsLockFlag != 0 { modifiers.insert(.capsLock) }
        if flags & Self.shiftFlag != 0 { modifiers.insert(.shift) }
        if flags & Self.optionFlag != 0 { modifiers.insert(.option) }
        let command = flags & Self.commandFlag != 0, control = flags & Self.controlFlag != 0
        if swapsCommandAndControl ? control : command { modifiers.insert(.command) }
        if swapsCommandAndControl ? command : control { modifiers.insert(.control) }
        return modifiers
    }

    /// The key code to send for a local modifier key.
    func sentKeyCode(forModifierKey keyCode: UInt16) -> UInt16 {
        guard swapsCommandAndControl else { return keyCode }
        switch keyCode {
        case 0x37: return 0x3B // left ⌘ → left ⌃
        case 0x36: return 0x3E // right ⌘ → right ⌃
        case 0x3B: return 0x37
        case 0x3E: return 0x36
        default: return keyCode
        }
    }

    // MARK: Modifiers

    private mutating func modifierChanged(keyCode: UInt16, flags: UInt64, modifiers: KeyModifiers) -> [KeyEvent] {
        if keyCode == Self.capsLockKey {
            let on = flags & Self.capsLockFlag != 0
            guard capsLockOn != on else { return [] }
            capsLockOn = on
            return [KeyEvent(keyCode: keyCode, isDown: true, modifiers: modifiers),
                    KeyEvent(keyCode: keyCode, isDown: false, modifiers: modifiers)]
        }
        guard let generic = Self.genericFlag(forModifierKey: keyCode) else { return [] } // Fn, or not a modifier
        let sent = sentKeyCode(forModifierKey: keyCode)
        let genericOn = flags & generic != 0
        let isDown: Bool
        if flags & Self.deviceBits != 0 || !genericOn {
            isDown = genericOn && flags & Self.deviceBit(forModifierKey: keyCode) != 0
        } else {
            isDown = !heldModifierKeys.contains(sent) // no device bits to tell: it toggled
        }
        if isDown {
            guard heldModifierKeys.insert(sent).inserted else { return [] }
        } else {
            guard heldModifierKeys.remove(sent) != nil else { return [] }
        }
        return [KeyEvent(keyCode: sent, isDown: isDown, modifiers: modifiers)]
    }

    /// The device-independent flag for a left/right modifier key (not Caps Lock or Fn).
    static func genericFlag(forModifierKey keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case 0x37, 0x36: commandFlag
        case 0x38, 0x3C: shiftFlag
        case 0x3B, 0x3E: controlFlag
        case 0x3A, 0x3D: optionFlag
        default: nil
        }
    }

    /// `NX_DEVICE…KEYMASK` for a left/right modifier key.
    static func deviceBit(forModifierKey keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 0x3B: 0x0001 // left Control
        case 0x38: 0x0002 // left Shift
        case 0x3C: 0x0004 // right Shift
        case 0x37: 0x0008 // left Command
        case 0x36: 0x0010 // right Command
        case 0x3A: 0x0020 // left Option
        case 0x3D: 0x0040 // right Option
        case 0x3E: 0x2000 // right Control
        default: 0
        }
    }

    /// The modifiers a set of sent modifier keys holds on the remote Mac.
    static func modifiers(forModifierKeys keys: Set<UInt16>) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        for key in keys {
            switch key {
            case 0x37, 0x36: modifiers.insert(.command)
            case 0x38, 0x3C: modifiers.insert(.shift)
            case 0x3B, 0x3E: modifiers.insert(.control)
            case 0x3A, 0x3D: modifiers.insert(.option)
            default: break
            }
        }
        return modifiers
    }
}

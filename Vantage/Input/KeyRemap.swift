import VantageCore

/// "⌘ acts as Ctrl" for a PC: the keyboard's ⌘ keys press Ctrl on the host and its Control keys
/// press the Windows key, so ⌘C, ⌘V and ⌘Z do on a PC what they do on a Mac.
///
/// The host maps key codes literally (⌘ → Windows key, ⌃ → Ctrl), so the swap happens here, on
/// the keys a keyboard sends: the iPad's hardware keyboard (`InputController.key(hidUsage:…)`)
/// and the Mac client's `KeyTranslator`. Control-strip modifiers (labelled Ctrl, Alt and Win on
/// a PC) and `HostShortcut`s are sent as written and never pass through it.
nonisolated struct KeyRemap: Hashable, Sendable {
    var swapsCommandAndControl = false

    static let none = KeyRemap()
    static let commandAsControl = KeyRemap(swapsCommandAndControl: true)

    /// A saved device's setting: on for a PC unless turned off, never for a Mac (whose own
    /// "Swap ⌘ and ⌃" on the Mac client is a separate, global setting).
    static func forHost(_ platform: HostPlatform?, commandSendsControl: Bool?) -> KeyRemap {
        guard platform == .windows else { return .none }
        return (commandSendsControl ?? true) ? .commandAsControl : .none
    }

    /// Left ⌘ ↔ left ⌃ and right ⌘ ↔ right ⌃; every other key is unchanged.
    func keyCode(_ keyCode: UInt16) -> UInt16 {
        guard swapsCommandAndControl else { return keyCode }
        switch keyCode {
        case 0x37: return 0x3B
        case 0x3B: return 0x37
        case 0x36: return 0x3E
        case 0x3E: return 0x36
        default: return keyCode
        }
    }

    /// The command and control bits trade places; the rest are unchanged.
    func modifiers(_ modifiers: KeyModifiers) -> KeyModifiers {
        guard swapsCommandAndControl else { return modifiers }
        var result = modifiers.subtracting([.command, .control])
        if modifiers.contains(.command) { result.insert(.control) }
        if modifiers.contains(.control) { result.insert(.command) }
        return result
    }

    func event(_ event: KeyEvent) -> KeyEvent {
        KeyEvent(keyCode: keyCode(event.keyCode), isDown: event.isDown, modifiers: modifiers(event.modifiers),
                 isRepeat: event.isRepeat)
    }
}

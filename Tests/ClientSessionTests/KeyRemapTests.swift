import Testing
import VantageCore
@testable import VantageClientLogic

/// "⌘ acts as Ctrl" for a PC: easy to break without noticing, since everything still types.
@MainActor @Suite struct KeyRemapTests {
    @Test func commandAndControlKeysTradePlacesLeftAndRight() {
        let remap = KeyRemap.commandAsControl
        #expect(remap.keyCode(0x37) == 0x3B) // left ⌘ → left Ctrl
        #expect(remap.keyCode(0x3B) == 0x37) // left ⌃ → left Windows key
        #expect(remap.keyCode(0x36) == 0x3E) // right ⌘ → right Ctrl
        #expect(remap.keyCode(0x3E) == 0x36)
        for other: UInt16 in [0x08, 0x09, 0x38, 0x3A, 0x3D, 0x3C, 0x31, 0x24] { // C, V, shifts, options, Space, Return
            #expect(remap.keyCode(other) == other)
        }
        #expect(KeyRemap.none.keyCode(0x37) == 0x37)
    }

    @Test func commandAndControlBitsTradePlaces() {
        let remap = KeyRemap.commandAsControl
        #expect(remap.modifiers(.command) == .control)
        #expect(remap.modifiers(.control) == .command)
        #expect(remap.modifiers([.command, .control, .shift]) == [.command, .control, .shift])
        #expect(remap.modifiers([.command, .option, .shift, .capsLock]) == [.control, .option, .shift, .capsLock])
        #expect(KeyRemap.none.modifiers(.command) == .command)
        // ⌘C typed on the iPad's keyboard reaches a PC as Ctrl+C.
        let copy = remap.event(KeyEvent(keyCode: 0x08, isDown: true, modifiers: .command))
        #expect(copy == KeyEvent(keyCode: 0x08, isDown: true, modifiers: .control))
    }

    @Test func onForAPCUnlessTurnedOffAndNeverForAMac() {
        #expect(KeyRemap.forHost(.windows, commandSendsControl: nil) == .commandAsControl)
        #expect(KeyRemap.forHost(.windows, commandSendsControl: true) == .commandAsControl)
        #expect(KeyRemap.forHost(.windows, commandSendsControl: false) == .none)
        #expect(KeyRemap.forHost(.macOS, commandSendsControl: true) == .none)
        #expect(KeyRemap.forHost(nil, commandSendsControl: nil) == .none)
        #expect(SavedDevice(name: "PC", host: "pc", os: "Windows").keyRemap == .commandAsControl)
        #expect(SavedDevice(name: "PC", host: "pc", os: "windows", commandSendsControl: false).keyRemap == .none)
        #expect(SavedDevice(name: "Mac", host: "mac").keyRemap == .none)
    }

    /// The iPad's hardware keyboard: the key code is swapped, the modifiers go as the caller
    /// passed them (the view swaps the keyboard's own and adds the strip's sticky ones as labelled).
    @Test func hardwareKeysAreSwappedButStripModifiersAreNot() {
        let input = InputController()
        var sent: [KeyEvent] = []
        input.send = { if case .keyEvent(let event) = $0 { sent.append(event) } }
        input.keyRemap = .commandAsControl
        input.key(hidUsage: 0xE3, isDown: true, modifiers: .control) // left ⌘ held on the keyboard
        input.tapChord(keyCode: 0x08, modifiers: .control) // the strip's Ctrl, then C
        input.tapChord(keyCode: HostShortcut.start.keyCode, modifiers: HostShortcut.start.modifiers)
        #expect(sent.map(\.keyCode) == [0x3B, 0x08, 0x08, 0x37, 0x37])
        #expect(sent[1].modifiers == .control)
    }

    /// The Mac client's keyboard goes through `KeyTranslator` with the same swap.
    @Test func macKeyboardSwapsTheSameWay() {
        var translator = KeyTranslator()
        translator.swapsCommandAndControl = true
        let down = translator.translate(.flagsChanged, keyCode: 0x37, flags: KeyTranslator.commandFlag | 0x0008)
        #expect(down == [KeyEvent(keyCode: 0x3B, isDown: true, modifiers: .control)])
        let c = translator.translate(.keyDown, keyCode: 0x08, flags: KeyTranslator.commandFlag | 0x0008)
        #expect(c == [KeyEvent(keyCode: 0x08, isDown: true, modifiers: .control)])
    }
}

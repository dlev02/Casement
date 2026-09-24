import Testing
import VantageCore
@testable import VantageClientLogic

/// The Mac client's keyboard: what goes over the wire for each of this Mac's own key events.
@Suite struct KeyTranslatorTests {
    // Raw NSEvent flags: generic modifier bits plus the left/right device bits.
    let command: UInt64 = 1 << 20, control: UInt64 = 1 << 18, option: UInt64 = 1 << 19, shift: UInt64 = 1 << 17
    let capsLock: UInt64 = 1 << 16, function: UInt64 = 1 << 23
    let leftCommand: UInt64 = 0x8, rightCommand: UInt64 = 0x10, leftShift: UInt64 = 0x2, rightShift: UInt64 = 0x4
    let leftControl: UInt64 = 0x1, leftOption: UInt64 = 0x20

    private func key(_ code: UInt16, _ down: Bool, _ modifiers: KeyModifiers = [], repeat isRepeat: Bool = false) -> KeyEvent {
        KeyEvent(keyCode: code, isDown: down, modifiers: modifiers, isRepeat: isRepeat)
    }

    /// ⌘Q typed with the left ⌘: the ⌘ key goes down on its own, then Q with ⌘, then both up.
    @Test func commandQGoesOverAsTheKeysPressed() {
        var translator = KeyTranslator()
        var sent = translator.translate(.flagsChanged, keyCode: 0x37, flags: command | leftCommand)
        sent += translator.translate(.keyDown, keyCode: 0x0C, flags: command | leftCommand)
        sent += translator.translate(.keyUp, keyCode: 0x0C, flags: command | leftCommand)
        sent += translator.translate(.flagsChanged, keyCode: 0x37, flags: 0)
        #expect(sent == [key(0x37, true, .command), key(0x0C, true, .command), key(0x0C, false, .command), key(0x37, false)])
        #expect(translator.heldKeys.isEmpty && translator.heldModifierKeys.isEmpty)
    }

    /// Left and right come from the device bits, so releasing one side while the other is still
    /// down lets go of the right key.
    @Test func leftAndRightModifiersStayApart() {
        var translator = KeyTranslator()
        #expect(translator.translate(.flagsChanged, keyCode: 0x38, flags: shift | leftShift) == [key(0x38, true, .shift)])
        #expect(translator.translate(.flagsChanged, keyCode: 0x3C, flags: shift | leftShift | rightShift) == [key(0x3C, true, .shift)])
        #expect(translator.translate(.flagsChanged, keyCode: 0x38, flags: shift | rightShift) == [key(0x38, false, .shift)])
        #expect(translator.heldModifierKeys == [0x3C])
        #expect(translator.translate(.flagsChanged, keyCode: 0x3C, flags: 0) == [key(0x3C, false)])
    }

    @Test func rightCommandIsSentAsRightCommand() {
        var translator = KeyTranslator()
        #expect(translator.translate(.flagsChanged, keyCode: 0x36, flags: command | rightCommand) == [key(0x36, true, .command)])
    }

    /// Without device bits (some keyboards and remappers), a modifier's flag toggles it.
    @Test func modifierWithoutDeviceBitsToggles() {
        var translator = KeyTranslator()
        #expect(translator.translate(.flagsChanged, keyCode: 0x3A, flags: option) == [key(0x3A, true, .option)])
        #expect(translator.translate(.flagsChanged, keyCode: 0x3A, flags: 0) == [key(0x3A, false)])
    }

    /// Caps Lock reports its new state once per press; each change is a tap on the remote Mac,
    /// and letters carry it.
    @Test func capsLockIsATapPerChange() {
        var translator = KeyTranslator()
        #expect(translator.translate(.flagsChanged, keyCode: 0x39, flags: capsLock) == [key(0x39, true, .capsLock), key(0x39, false, .capsLock)])
        #expect(translator.translate(.flagsChanged, keyCode: 0x39, flags: capsLock).isEmpty) // the same state again
        #expect(translator.translate(.keyDown, keyCode: 0x00, flags: capsLock) == [key(0x00, true, .capsLock)])
        #expect(translator.translate(.flagsChanged, keyCode: 0x39, flags: 0) == [key(0x39, true), key(0x39, false)])
        #expect(translator.heldModifierKeys.isEmpty)
    }

    /// Fn/Globe is macOS's own; it never goes over by itself, and it isn't a modifier on the wire
    /// (the host puts Fn on the keys that carry it).
    @Test func fnIsDropped() {
        var translator = KeyTranslator()
        #expect(translator.translate(.flagsChanged, keyCode: 0x3F, flags: function).isEmpty)
        #expect(translator.translate(.keyDown, keyCode: 0x3F, flags: function).isEmpty)
        #expect(translator.translate(.keyDown, keyCode: 0x7E, flags: function | (1 << 21)) == [key(0x7E, true)])
    }

    @Test func repeatsCarryTheRepeatFlag() {
        var translator = KeyTranslator()
        _ = translator.translate(.keyDown, keyCode: 0x33, flags: 0)
        #expect(translator.translate(.keyDown, keyCode: 0x33, flags: 0, isRepeat: true) == [key(0x33, true, repeat: true)])
    }

    /// A key that went down before the window had the keyboard (or went to Vantage) is none of
    /// the remote Mac's business: its repeats and release are dropped.
    @Test func upOrRepeatWithoutDownIsDropped() {
        var translator = KeyTranslator()
        #expect(translator.translate(.keyUp, keyCode: 0x0D, flags: command).isEmpty)
        #expect(translator.translate(.keyDown, keyCode: 0x0D, flags: 0, isRepeat: true).isEmpty)
        #expect(translator.translate(.flagsChanged, keyCode: 0x37, flags: 0).isEmpty)
        #expect(!translator.isHolding(keyCode: 0x0D))
    }

    /// Losing the keyboard lets go of the keys first, then the modifiers, each modifier's
    /// release carrying what's still held.
    @Test func releaseAllLetsGoOfModifiersLast() {
        var translator = KeyTranslator()
        _ = translator.translate(.flagsChanged, keyCode: 0x3B, flags: control | leftControl)
        _ = translator.translate(.flagsChanged, keyCode: 0x37, flags: control | command | leftControl | leftCommand)
        _ = translator.translate(.keyDown, keyCode: 0x02, flags: control | command | leftControl | leftCommand)
        let released = translator.releaseAll()
        #expect(released == [key(0x02, false, [.control, .command]), key(0x37, false, .control), key(0x3B, false)])
        #expect(translator.releaseAll().isEmpty)
        #expect(translator.translate(.keyUp, keyCode: 0x02, flags: 0).isEmpty) // its real release comes later
    }

    /// "Swap ⌘ and ⌃": this Mac's ⌘ presses ⌃ on the remote Mac, side for side, and the other
    /// way round; everything else is untouched.
    @Test func swapCommandAndControl() {
        var translator = KeyTranslator()
        translator.swapsCommandAndControl = true
        #expect(translator.translate(.flagsChanged, keyCode: 0x37, flags: command | leftCommand) == [key(0x3B, true, .control)])
        #expect(translator.translate(.keyDown, keyCode: 0x08, flags: command | leftCommand) == [key(0x08, true, .control)])
        #expect(translator.translate(.flagsChanged, keyCode: 0x3E, flags: command | control | leftCommand | 0x2000) == [key(0x36, true, [.command, .control])])
        #expect(translator.heldModifierKeys == [0x3B, 0x36])
        #expect(translator.translate(.keyDown, keyCode: 0x00, flags: shift | option | leftShift | leftOption).first?.modifiers == [.shift, .option])
    }
}

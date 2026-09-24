import CoreGraphics
import Testing
import VantageCore
@testable import VantageHostInput

/// What the host posts for each key and chord. The masks the system shortcuts are stored with
/// come from this Mac's `defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys`.
@Suite struct KeyboardSequencerTests {
    typealias Stroke = KeyboardSequencer.Stroke

    /// A tap as the strip sends it: key down and up, both carrying the chord's modifiers.
    private func tap(_ keyCode: UInt16, _ modifiers: KeyModifiers, on sequencer: inout KeyboardSequencer) -> [Stroke] {
        sequencer.strokes(for: KeyEvent(keyCode: keyCode, isDown: true, modifiers: modifiers))
            + sequencer.strokes(for: KeyEvent(keyCode: keyCode, isDown: false, modifiers: modifiers))
    }

    /// The modifier bits a symbolic hot key compares (device-independent, keypad bit aside:
    /// macOS stores Mission Control as 0x840000 although a real arrow also carries the keypad bit).
    private func hotKeyMask(_ flags: CGEventFlags) -> UInt64 {
        flags.rawValue & 0x00FF_0000 & ~CGEventFlags.maskNumericPad.rawValue
    }

    @Test func missionControlPressesControlAndCarriesFn() {
        var sequencer = KeyboardSequencer()
        let strokes = tap(0x7E, .control, on: &sequencer) // what the iPad sent before this fix
        #expect(strokes.map(\.kind) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        #expect(strokes[0].keyCode == 0x3B && strokes[0].flags == CGEventFlags(rawValue: 0x40001))
        #expect(hotKeyMask(strokes[1].flags) == 0x840000) // symbolic hot key 32
        #expect(strokes[1].flags.contains(.maskNumericPad))
        #expect(strokes[3].keyCode == 0x3B && strokes[3].flags.isEmpty)
        #expect(sequencer.heldKeys.isEmpty && sequencer.heldModifierKeys.isEmpty)
    }

    @Test func shortcutsMatchTheirSystemHotKeys() {
        let cases: [(UInt16, KeyModifiers, UInt64)] = [
            (0x7E, [.control], 0x840000),            // 32 Mission Control
            (0x7D, [.control], 0x840000),            // 33 Application windows
            (0x7E, [.control, .function], 0x840000), // what the strip sends now
            (0x67, [], 0x800000),                    // 36 Show Desktop (F11)
            (0x67, .function, 0x800000),
            (0x7B, [.control], 0x840000),            // 79 Move left a space
            (0x31, .command, 0x100000),              // 64 Spotlight
        ]
        for (keyCode, modifiers, mask) in cases {
            var sequencer = KeyboardSequencer()
            let down = tap(keyCode, modifiers, on: &sequencer).first { $0.kind == .keyDown }
            #expect(down.map { hotKeyMask($0.flags) } == mask, "key 0x\(String(keyCode, radix: 16)) \(modifiers)")
        }
    }

    @Test func commandSpaceIsARealChord() {
        var sequencer = KeyboardSequencer()
        let strokes = tap(0x31, .command, on: &sequencer)
        #expect(strokes == [
            Stroke(kind: .flagsChanged, keyCode: 0x37, flags: CGEventFlags(rawValue: 0x100008)),
            Stroke(kind: .keyDown, keyCode: 0x31, flags: CGEventFlags(rawValue: 0x100008)),
            Stroke(kind: .keyUp, keyCode: 0x31, flags: CGEventFlags(rawValue: 0x100008)),
            Stroke(kind: .flagsChanged, keyCode: 0x37, flags: []),
        ])
    }

    @Test func hardwareChordDoesNotPressTheModifierTwice() {
        // ⌘C from a keyboard on the iPad: ⌘ arrives as its own key, then C carrying ⌘.
        var sequencer = KeyboardSequencer()
        var strokes = sequencer.strokes(for: KeyEvent(keyCode: 0x37, isDown: true, modifiers: []))
        strokes += tap(0x08, .command, on: &sequencer)
        strokes += sequencer.strokes(for: KeyEvent(keyCode: 0x37, isDown: false, modifiers: []))
        #expect(strokes.map(\.kind) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        #expect(strokes[1].flags == CGEventFlags(rawValue: 0x100008))
        #expect(strokes[3].flags.isEmpty)
    }

    @Test func commandTabHoldsCommandAcrossTheTab() {
        var sequencer = KeyboardSequencer()
        _ = sequencer.strokes(for: KeyEvent(keyCode: 0x37, isDown: true, modifiers: []))
        let tabs = tap(0x30, .command, on: &sequencer) + tap(0x30, .command, on: &sequencer)
        #expect(tabs.allSatisfy { $0.kind != .flagsChanged && $0.flags.contains(.maskCommand) })
        #expect(sequencer.heldModifierKeys == [0x37])
    }

    @Test func rightSideModifiersKeepTheirSide() {
        var sequencer = KeyboardSequencer()
        let command = sequencer.strokes(for: KeyEvent(keyCode: 0x36, isDown: true, modifiers: []))
        #expect(command == [Stroke(kind: .flagsChanged, keyCode: 0x36, flags: CGEventFlags(rawValue: 0x100010))])
        // A chord carrying ⌘ doesn't add a left ⌘ while the right one is down.
        let key = tap(0x08, .command, on: &sequencer)
        #expect(key.map(\.kind) == [.keyDown, .keyUp])
    }

    @Test func plainTypingIsUnchanged() {
        var sequencer = KeyboardSequencer()
        let letter = tap(0x00, [], on: &sequencer)
        #expect(letter == [Stroke(kind: .keyDown, keyCode: 0x00, flags: []), Stroke(kind: .keyUp, keyCode: 0x00, flags: [])])
        // Keystrokes mode types "A" as ⇧A: Shift goes down around the key.
        let capital = tap(0x00, .shift, on: &sequencer)
        #expect(capital.map(\.kind) == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        #expect(capital[1].flags == CGEventFlags(rawValue: 0x20002))
        // Caps Lock stays a flag, never a key press.
        let capsLocked = tap(0x00, .capsLock, on: &sequencer)
        #expect(capsLocked.map(\.kind) == [.keyDown, .keyUp] && capsLocked[0].flags == .maskAlphaShift)
    }

    @Test func stickyModifierWithAnArrowKey() {
        // ⌘ held on the strip, then the strip's ← key: ⌘← with the arrow's own Fn and keypad bits.
        var sequencer = KeyboardSequencer()
        let strokes = tap(0x7B, .command, on: &sequencer)
        #expect(strokes[1].flags == [.maskCommand, .maskSecondaryFn, .maskNumericPad, CGEventFlags(rawValue: 0x8)])
    }

    @Test func repeatsDoNotPressModifiersAgain() {
        var sequencer = KeyboardSequencer()
        let first = sequencer.strokes(for: KeyEvent(keyCode: 0x7D, isDown: true, modifiers: .shift))
        let repeated = sequencer.strokes(for: KeyEvent(keyCode: 0x7D, isDown: true, modifiers: .shift, isRepeat: true))
        #expect(first.count == 2)
        #expect(repeated.count == 1 && repeated[0].isRepeat)
        let up = sequencer.strokes(for: KeyEvent(keyCode: 0x7D, isDown: false, modifiers: .shift))
        #expect(up.map(\.kind) == [.keyUp, .flagsChanged] && up[1].flags.isEmpty)
    }

    @Test func releaseAllLetsGoOfKeysThenModifiers() {
        var sequencer = KeyboardSequencer()
        _ = sequencer.strokes(for: KeyEvent(keyCode: 0x3A, isDown: true, modifiers: []))
        _ = sequencer.strokes(for: KeyEvent(keyCode: 0x7E, isDown: true, modifiers: [.option, .control]))
        let released = sequencer.releaseAll()
        #expect(released.map(\.kind) == [.keyUp, .flagsChanged, .flagsChanged])
        #expect(released.first?.keyCode == 0x7E && released.last?.flags.isEmpty == true)
        #expect(sequencer.heldKeys.isEmpty && sequencer.heldModifierKeys.isEmpty && sequencer.modifierFlags.isEmpty)
    }

    @Test func aConsumedPressDropsItsReleaseToo() {
        var sequencer = KeyboardSequencer()
        let press = KeyEvent(keyCode: 0x31, isDown: true, modifiers: .command)
        sequencer.consume(press)
        #expect(sequencer.strokes(for: KeyEvent(keyCode: 0x31, isDown: false, modifiers: .command)).isEmpty)
        #expect(sequencer.heldModifierKeys.isEmpty)
        // The next ⌘Space is typed normally.
        #expect(tap(0x31, .command, on: &sequencer).count == 4)
    }
}

@Suite struct SearchShortcutTests {
    @Test func recognisesCommandSpaceOnly() {
        let space = { (modifiers: KeyModifiers) in KeyEvent(keyCode: 0x31, isDown: true, modifiers: modifiers) }
        #expect(SearchShortcut.isCommandSpace(space(.command), heldFlags: []))
        #expect(SearchShortcut.isCommandSpace(space([]), heldFlags: CGEventFlags(rawValue: 0x100008))) // ⌘ held on the keyboard
        #expect(SearchShortcut.isCommandSpace(space([.command, .capsLock]), heldFlags: []))
        #expect(!SearchShortcut.isCommandSpace(space([.command, .shift]), heldFlags: []))
        #expect(!SearchShortcut.isCommandSpace(space([]), heldFlags: []))
        #expect(!SearchShortcut.isCommandSpace(KeyEvent(keyCode: 0x31, isDown: false, modifiers: .command), heldFlags: []))
        #expect(!SearchShortcut.isCommandSpace(KeyEvent(keyCode: 0x31, isDown: true, modifiers: .command, isRepeat: true), heldFlags: []))
    }

    @Test func readsWhetherSpotlightStillHasCommandSpace() {
        // This Mac, with Raycast on ⌘Space: `64 = { enabled = 0; value = { parameters = (32, 49, 1048576) } }`.
        let raycastMac: [String: Any] = ["64": ["enabled": 0, "value": ["parameters": [32, 49, 1_048_576], "type": "standard"]]]
        #expect(!SearchShortcut.spotlightOwnsCommandSpace(raycastMac))
        let stock: [String: Any] = ["64": ["enabled": 1, "value": ["parameters": [32, 49, 1_048_576], "type": "standard"]]]
        #expect(SearchShortcut.spotlightOwnsCommandSpace(stock))
        #expect(SearchShortcut.spotlightOwnsCommandSpace(nil)) // never changed: the default
        #expect(SearchShortcut.spotlightOwnsCommandSpace(["65": ["enabled": 1]]))
        let moved: [String: Any] = ["64": ["enabled": true, "value": ["parameters": [32, 49, 1_572_864]]]] // ⌥⌘Space
        #expect(!SearchShortcut.spotlightOwnsCommandSpace(moved))
    }
}

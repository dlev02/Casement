import Testing
import VantageCore
@testable import VantageClientLogic

/// Which keys a Mac session window keeps and which go to the remote Mac.
@Suite struct KeyCapturePolicyTests {
    private func route(_ keyCode: UInt16, _ modifiers: KeyModifiers, capturing: Bool) -> KeyCapturePolicy.Route {
        KeyCapturePolicy.route(keyCode: keyCode, modifiers: modifiers, capturesShortcuts: capturing)
    }

    /// Sending shortcuts (the default): ⌘Q quits the remote Mac's app, not Vantage.
    @Test func capturingSendsShortcutsToTheMac() {
        let chords: [(UInt16, KeyModifiers)] = [(0x0C, .command), (0x0D, .command), (0x04, .command), (0x2B, .command),
                                                (0x03, [.control, .command]), (0x00, []), (0x7E, .control), (0x09, .command)]
        for (keyCode, modifiers) in chords {
            #expect(route(keyCode, modifiers, capturing: true) == .forward, "\(keyCode) \(modifiers)")
        }
    }

    /// ⌃⌥⌘ is how you talk to Vantage, whatever else is held and whatever the setting.
    @Test func vantageChordStaysLocal() {
        for capturing in [true, false] {
            #expect(route(0x28, [.control, .option, .command], capturing: capturing) == .local)
            #expect(route(0x0D, [.control, .option, .command, .shift], capturing: capturing) == .local)
            #expect(route(0x0D, [.control, .option, .command, .capsLock], capturing: capturing) == .local)
        }
        #expect(route(0x28, [.option, .command], capturing: true) == .forward)
    }

    /// Not sending shortcuts: the ones that act on this Mac's windows stay here, exactly as
    /// pressed; the rest still go over.
    @Test func notCapturingKeepsWindowShortcuts() {
        let local: [(UInt16, KeyModifiers)] = [(0x0C, .command), (0x0D, .command), (0x04, .command), (0x04, [.option, .command]),
                                               (0x2E, .command), (0x2B, .command), (0x32, .command), (0x32, [.shift, .command]),
                                               (0x03, [.control, .command]), (0x0C, [.command, .capsLock])]
        for (keyCode, modifiers) in local {
            #expect(route(keyCode, modifiers, capturing: false) == .local, "\(keyCode) \(modifiers)")
        }
        let forwarded: [(UInt16, KeyModifiers)] = [(0x09, .command), (0x08, .command), (0x0C, [.shift, .command]),
                                                   (0x0D, [.option, .command]), (0x0C, []), (0x03, .command)]
        for (keyCode, modifiers) in forwarded {
            #expect(route(keyCode, modifiers, capturing: false) == .forward, "\(keyCode) \(modifiers)")
        }
    }
}

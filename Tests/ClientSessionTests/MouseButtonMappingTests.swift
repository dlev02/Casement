import Testing
import VantageCore
@testable import VantageClientLogic

@Suite struct MouseButtonMappingTests {
    /// A remapped button sends its shortcut for the computer at hand, and nothing else; its own
    /// click otherwise. Start has nothing to send on a Mac, so the button keeps its click there,
    /// and left and right are never remapped.
    @Test func buttonsSendTheirOwnClickOrTheHostsShortcut() {
        #expect(MouseButtonMapping.press(.middle, action: .click, on: .macOS) == .button(.middle))
        #expect(MouseButtonMapping.press(.middle, action: .missionControl, on: .macOS) == .shortcut(.missionControl))
        #expect(MouseButtonMapping.press(.middle, action: .missionControl, on: .windows) == .shortcut(.taskView))
        #expect(MouseButtonMapping.press(.back, action: .applicationWindows, on: .macOS) == .shortcut(.applicationWindows))
        #expect(MouseButtonMapping.press(.forward, action: .showDesktop, on: .windows) == .shortcut(.pcShowDesktop))
        #expect(MouseButtonMapping.press(.middle, action: .appSwitcher, on: .macOS) == .shortcut(.appSwitcher))
        #expect(MouseButtonMapping.press(.middle, action: .appSwitcher, on: .windows) == .shortcut(.switchApps))
        #expect(MouseButtonMapping.press(.middle, action: .start, on: .windows) == .shortcut(.start))
        #expect(MouseButtonMapping.press(.middle, action: .start, on: .macOS) == .button(.middle))
        #expect(MouseButtonMapping.press(.left, action: .missionControl, on: .macOS) == .button(.left))
    }
}

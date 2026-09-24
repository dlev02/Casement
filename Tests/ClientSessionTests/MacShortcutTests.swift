import Testing
import VantageCore
@testable import VantageClientLogic

@Suite struct MacShortcutTests {
    /// macOS stores these with Fn (`com.apple.symbolichotkeys` 32, 33, 36), so older hosts that
    /// don't add it themselves still need it from the client.
    @Test func arrowAndFunctionKeyShortcutsCarryFn() {
        #expect(MacShortcut.missionControl.keyCode == 0x7E && MacShortcut.missionControl.modifiers == [.control, .function])
        #expect(MacShortcut.applicationWindows.keyCode == 0x7D && MacShortcut.applicationWindows.modifiers == [.control, .function])
        #expect(MacShortcut.showDesktop.keyCode == 0x67 && MacShortcut.showDesktop.modifiers == .function)
    }

    @Test func commandSpaceIsPlainCommandSpace() {
        #expect(MacShortcut.spotlight.keyCode == 0x31 && MacShortcut.spotlight.modifiers == .command)
        #expect(MacShortcut.menuOrder.map(\.id) == ["spotlight", "missionControl", "appWindows", "showDesktop"])
    }
}

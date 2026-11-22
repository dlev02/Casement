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

    /// Three-finger swipes send what each platform's own trackpad does. On a Mac the Spaces
    /// shortcuts are stored with Fn like the other arrow shortcuts (hot keys 79 and 81), and the
    /// picture follows the fingers: swiping left brings in the Space to the right.
    @Test func threeFingerSwipesSendEachPlatformsShortcuts() {
        #expect(HostShortcut.forSwipe(.left, on: .macOS).keyCode == 0x7C && HostShortcut.forSwipe(.left, on: .macOS).modifiers == [.control, .function])
        #expect(HostShortcut.forSwipe(.right, on: .macOS).keyCode == 0x7B && HostShortcut.forSwipe(.right, on: .macOS).modifiers == [.control, .function])
        #expect(HostShortcut.forSwipe(.up, on: nil) == .missionControl && HostShortcut.forSwipe(.down, on: nil) == .applicationWindows)
        #expect(HostShortcut.forSwipe(.left, on: .windows).keyCode == 0x7C && HostShortcut.forSwipe(.left, on: .windows).modifiers == [.control, .command])
        #expect(HostShortcut.forSwipe(.right, on: .windows).keyCode == 0x7B)
        #expect(HostShortcut.forSwipe(.up, on: .windows) == .taskView && HostShortcut.forSwipe(.down, on: .windows) == .pcShowDesktop)
    }

    @Test func commandSpaceIsPlainCommandSpace() {
        #expect(MacShortcut.spotlight.keyCode == 0x31 && MacShortcut.spotlight.modifiers == .command)
        #expect(MacShortcut.menuOrder.map(\.id) == ["spotlight", "missionControl", "appWindows", "showDesktop"])
    }

    /// The Mac client's own ⌘Tab stays on the Mac it runs on, so its session menu sends one.
    @Test func macClientOffersTheAppSwitcher() {
        #expect(MacShortcut.appSwitcher.keyCode == 0x30 && MacShortcut.appSwitcher.modifiers == .command)
        #expect(MacShortcut.sessionMenu.map(\.id) == ["spotlight", "missionControl", "appWindows", "showDesktop", "appSwitcher"])
    }
}

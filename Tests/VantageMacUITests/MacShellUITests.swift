import XCTest

/// The Mac app's shell: the device list window, a window per session, the menu bar following the
/// key window, and Settings on ⌘,.
///
/// Runs against a synthetic host (`SyntheticHost`, port 47856, never the live host's 47820), unless
/// `TEST_RUNNER_VANTAGE_TEST_HOST=127.0.0.1:<port>` names one already up.
/// macOS UI tests need Automation Mode approved once:
/// `automationmodetool enable-automationmode-without-authentication` (as an admin).
nonisolated final class MacShellUITests: XCTestCase {
    nonisolated(unsafe) private static var host = "127.0.0.1:47856"

    override class func setUp() {
        super.setUp()
        host = SyntheticHost.address(environmentVariable: "VANTAGE_TEST_HOST", defaultPort: 47856)
    }

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageSeedHost", Self.host, "-VantagePairingCode", "246810",
                               "-vantage.requireBiometrics", "NO", "-vantage.availabilityChecks", "NO",
                               "-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        app.activate()
        return app
    }

    /// The device list window, in front and ready for clicks.
    @MainActor private func deviceList(_ app: XCUIApplication) -> XCUIElement {
        let window = app.windows["main"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "the device list window opens")
        return window
    }

    /// This test's Mac in the sidebar (the seed adds it; its row is keyed by host).
    @MainActor private func row(in window: XCUIElement) -> XCUIElement {
        window.outlines["devices.sidebar"].staticTexts["devices.row.\(Self.host)"].firstMatch
    }

    /// The session's controls: they're only there once a session window is up and connected.
    @MainActor private func sessionControls(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["session.toolbar.disconnect"].firstMatch
    }

    @MainActor private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        return XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
    }

    /// Session windows: every window but the device list (and Settings, which these tests close).
    @MainActor private func sessionWindows(_ app: XCUIApplication) -> Int {
        app.windows.matching(NSPredicate(format: "identifier != 'main' AND identifier != 'com_apple_SwiftUI_Settings_window'")).count
    }

    @MainActor func testConnectOpensTheMacInItsOwnWindow() {
        let app = launch()
        let list = deviceList(app)
        let mac = row(in: list)
        XCTAssertTrue(mac.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilHittable(mac), "the sidebar row can be clicked")
        XCTAssertEqual(sessionWindows(app), 0)
        mac.click()
        let connect = list.buttons["devices.connect"].firstMatch
        XCTAssertTrue(waitUntilHittable(connect), "Connect can be clicked")
        connect.click()
        XCTAssertTrue(sessionControls(app).waitForExistence(timeout: 20), "the session should connect")
        XCTAssertEqual(sessionWindows(app), 1, "the Mac opens in a new window beside the list")
        XCTAssertTrue(list.exists, "the device list stays open")
    }

    @MainActor func testSessionMenuFollowsTheFocusedWindow() {
        let app = launch()
        let list = deviceList(app)
        let mac = row(in: list)
        XCTAssertTrue(waitUntilHittable(mac))
        mac.click()
        let session = app.menuBars.menuBarItems["Session"]
        let disconnect = app.menuBars.menuItems["Disconnect"]

        // The device list in front: the session's items stay in the menu, dimmed, and File ›
        // Connect follows the list's selection.
        session.click()
        XCTAssertTrue(disconnect.exists, "unavailable items are dimmed, never hidden")
        XCTAssertFalse(disconnect.isEnabled, "Disconnect is dimmed with the list in front")
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["File"].click()
        let connect = app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Connect to '")).firstMatch
        XCTAssertTrue(connect.isEnabled, "File › Connect to ⟨Mac⟩ follows the selection")
        connect.click()

        // The session window in front: Session › Disconnect works.
        XCTAssertTrue(sessionControls(app).waitForExistence(timeout: 20), "the session should connect")
        session.click()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: disconnect)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, "Disconnect is enabled with the session in front")
        XCTAssertTrue(app.menuBars.menuItems["Send Keyboard Shortcuts to Mac"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor func testSettingsOpensWithCommandComma() {
        let app = launch()
        _ = deviceList(app)
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "⌘, opens Settings")
        settings.toolbars.buttons["Controls"].click()
        // A Mac form's switch carries no label of its own; its title is the text beside it.
        XCTAssertTrue(settings.staticTexts["Send keyboard shortcuts to the Mac"].waitForExistence(timeout: 3),
                      "Controls has the Mac keyboard settings")
        XCTAssertTrue(settings.staticTexts["Swap ⌘ and ⌃"].exists)
        settings.toolbars.buttons["Privacy & Security"].click()
        XCTAssertTrue(settings.staticTexts["Require Touch ID"].waitForExistence(timeout: 3), "Privacy & Security has Require Touch ID")
        XCTAssertFalse(settings.staticTexts["Sync with iCloud"].exists, "iCloud sync isn't offered on the Mac yet")
        settings.buttons["_XCUI:CloseWindow"].click()
    }
}

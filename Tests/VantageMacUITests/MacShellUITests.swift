import AppKit
import XCTest

/// The Mac app's shell: the device list window, a window per session, the menu bar following the
/// key window, and Settings on ⌘,.
///
/// Runs against a synthetic host (`--synthetic-capture`, loopback, pairing code 246810). Each run
/// starts its own from the products folder next to this bundle on port 47856 (never the live
/// host's 47820), unless `TEST_RUNNER_VANTAGE_TEST_HOST=127.0.0.1:<port>` names one already up.
/// macOS UI tests need Automation Mode approved once:
/// `automationmodetool enable-automationmode-without-authentication` (as an admin).
nonisolated final class MacShellUITests: XCTestCase {
    static let host = ProcessInfo.processInfo.environment["VANTAGE_TEST_HOST"] ?? "127.0.0.1:47856"
    nonisolated(unsafe) private static var syntheticHost: NSRunningApplication?

    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["VANTAGE_TEST_HOST"] == nil else { return }
        // …/Debug/VantageMacUITests-Runner.app/Contents/PlugIns/VantageMacUITests.xctest
        let products = Bundle(for: MacShellUITests.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let app = products.appending(path: "VantageHost.app")
        let port = String(host.split(separator: ":").last ?? "47856")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = ["--synthetic-capture", "--port", port, "--pairing-code", "246810", "--exit-after", "600"]
        let started = XCTestExpectation(description: "synthetic host")
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { running, _ in
            syntheticHost = running
            started.fulfill()
        }
        _ = XCTWaiter.wait(for: [started], timeout: 20)
        Thread.sleep(forTimeInterval: 1) // let the listener come up
    }

    override class func tearDown() {
        syntheticHost?.terminate()
        syntheticHost = nil
        super.tearDown()
    }

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(connecting: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-VantageSeedHost", Self.host, "-VantagePairingCode", "246810",
                         "-vantage.requireBiometrics", "NO", "-vantage.availabilityChecks", "NO",
                         "-ApplePersistenceIgnoreState", "YES"]
        if connecting { arguments += ["-VantageAutoConnect", Self.host] }
        app.launchArguments = arguments + extra
        app.launch()
        return app
    }

    /// The session's controls: they're only there once a session window is up and connected.
    @MainActor private func sessionControls(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["session.toolbar.disconnect"].firstMatch
    }

    @MainActor func testConnectOpensTheMacInItsOwnWindow() {
        let app = launch(connecting: false)
        let row = app.descendants(matching: .any)["devices.row.\(Self.host)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let windowsBefore = app.windows.count
        row.click()
        app.buttons["devices.connect"].firstMatch.click()
        XCTAssertTrue(sessionControls(app).waitForExistence(timeout: 20), "the session should connect")
        XCTAssertEqual(app.windows.count, windowsBefore + 1, "the Mac opens in a new window beside the list")
        XCTAssertTrue(row.exists, "the device list stays open")
        attach(app, "Session window")

        // Connecting again brings the same window forward instead of opening a second one.
        app.windows.element(boundBy: app.windows.count - 1).click()
        row.doubleClick()
        XCTAssertEqual(app.windows.count, windowsBefore + 1)
    }

    @MainActor func testSessionMenuFollowsTheFocusedWindow() {
        let app = launch(connecting: true)
        XCTAssertTrue(sessionControls(app).waitForExistence(timeout: 20))
        let session = app.menuBars.menuBarItems["Session"]
        session.click()
        XCTAssertTrue(app.menuItems["Disconnect"].isEnabled, "the session window is key, so Session › Disconnect works")
        XCTAssertTrue(app.menuItems["Send Keyboard Shortcuts to Mac"].exists)
        app.typeKey(.escape, modifierFlags: [])

        // The device list in front: the same items stay in the menu, dimmed.
        app.descendants(matching: .any)["devices.row.\(Self.host)"].firstMatch.click()
        session.click()
        XCTAssertTrue(app.menuItems["Disconnect"].exists, "unavailable items are dimmed, never hidden")
        XCTAssertFalse(app.menuItems["Disconnect"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        // File › Connect follows the list's selection instead.
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Connect to '")).firstMatch.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor func testSettingsOpensWithCommandComma() {
        let app = launch(connecting: false)
        XCTAssertTrue(app.descendants(matching: .any)["devices.sidebar"].waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "settings").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.toolbars.buttons["Controls"].click()
        XCTAssertTrue(settings.checkBoxes["settings.captureShortcuts"].waitForExistence(timeout: 3)
                      || settings.switches["settings.captureShortcuts"].exists,
                      "Controls has the Mac keyboard settings")
        attach(app, "Settings › Controls")
        settings.toolbars.buttons["Privacy & Security"].click()
        XCTAssertTrue(settings.staticTexts["Require Touch ID"].waitForExistence(timeout: 3)
                      || settings.checkBoxes["settings.requireBiometrics"].exists)
        XCTAssertFalse(settings.staticTexts["Sync with iCloud"].exists, "iCloud sync isn't offered on the Mac yet")
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

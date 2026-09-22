import XCTest

/// Requires the debug synthetic host on loopback port 47821 (see docs/testing).
nonisolated final class SessionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testToolbarCollapseDockAndForegroundRecovery() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", "127.0.0.1:47821", "-VantagePairingCode", "246810",
                               "-vantage.toolbarCollapsed", "NO", "-vantage.toolbarDock", "bottomLeft", "-vantage.requireBiometrics", "NO"]
        app.launch()
        let toggle = app.buttons["session.toolbar.collapse"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        toggle.tap()
        XCTAssertTrue(NSPredicate(format: "label == %@", "Expand controls").evaluate(with: toggle))
        XCTAssertFalse(app.buttons["Command"].exists)
        let start = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.15))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertLessThan(toggle.frame.midY, app.frame.midY)
        XCTAssertGreaterThan(toggle.frame.midX, app.frame.midX)
        screenshot("Collapsed at top right", app)
        toggle.tap()
        XCTAssertTrue(app.buttons["Command"].waitForExistence(timeout: 3))
        screenshot("Expanded at top right", app)
        let expandedStart = toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        expandedStart.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.85)))
        XCTAssertGreaterThan(toggle.frame.midY, app.frame.midY)
        toggle.tap()
        XCTAssertEqual(toggle.label, "Expand controls")
        XCTAssertLessThan(toggle.frame.midX, app.frame.midX)
        toggle.tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Command"].exists)
        screenshot("Session resumed", app)
    }

    @MainActor func testAvailabilityAndAppearanceNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageSeedHost", "127.0.0.1:47821", "-vantage.requireBiometrics", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Host status: Available")).firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["Settings"].tap()
        app.buttons["Appearance"].tap()
        XCTAssertTrue(app.buttons["Dark"].waitForExistence(timeout: 3), app.debugDescription)
        app.buttons["Dark"].tap()
        screenshot("Dark appearance", app)
        app.buttons["Light"].tap()
        screenshot("Light appearance", app)
    }

    @MainActor func testTailscalePickerShowsMacsAndUnsupportedDevices() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageTailscaleFixture", "1", "-VantageOpenTailscaleDevices", "1",
                               "-vantage.requireBiometrics", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Studio Mac"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Not Supported Yet"].exists)
        XCTAssertTrue(app.staticTexts["Drew-PC"].exists)
        XCTAssertTrue(app.buttons["Add"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Add"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Added"].firstMatch.waitForExistence(timeout: 3))
        screenshot("Tailscale device picker", app)
    }

    @MainActor private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

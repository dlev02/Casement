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

    /// The throws that used to misfire: a fast sideways flick that drifts vertically, a vertical
    /// flick, and a slow drag all the way across (it used to stop at half the screen).
    @MainActor func testToolbarThrowsLandInTheIntendedCorner() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", "127.0.0.1:47821", "-VantagePairingCode", "246810",
                               "-vantage.toolbarCollapsed", "YES", "-vantage.toolbarDock", "bottomLeft", "-vantage.requireBiometrics", "NO"]
        app.launch()
        let toggle = app.buttons["session.toolbar.collapse"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        func throwStrip(to point: CGVector, velocity: XCUIGestureVelocity) {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: point),
                       withVelocity: velocity, thenHoldForDuration: 0)
            _ = toggle.waitForNonExistence(timeout: 0.8) // let the spring settle
        }

        // Sideways flick from the bottom left, rising ~15° as a thumb does: stays on the bottom.
        let start = toggle.frame
        let rise = (app.frame.width * 0.45) * 0.27 / app.frame.height
        throwStrip(to: CGVector(dx: start.midX / app.frame.width + 0.45,
                                dy: start.midY / app.frame.height - rise), velocity: .fast)
        XCTAssertGreaterThan(toggle.frame.midX, app.frame.midX, "flick should reach the right")
        XCTAssertGreaterThan(toggle.frame.midY, app.frame.midY, "flick should stay on the bottom")
        screenshot("Flicked to bottom right", app)

        // Upward flick that leans left: only goes up.
        throwStrip(to: CGVector(dx: toggle.frame.midX / app.frame.width - 0.06, dy: 0.45), velocity: .fast)
        XCTAssertGreaterThan(toggle.frame.midX, app.frame.midX, "vertical flick should stay right")
        XCTAssertLessThan(toggle.frame.midY, app.frame.midY, "vertical flick should reach the top")
        screenshot("Flicked to top right", app)

        // Slow drag right across to the far side, released without a throw.
        throwStrip(to: CGVector(dx: 0.08, dy: 0.1), velocity: .slow)
        XCTAssertLessThan(toggle.frame.midX, app.frame.midX, "slow drag should reach the left")
        XCTAssertLessThan(toggle.frame.midY, app.frame.midY)
        screenshot("Dragged to top left", app)

        // Expand and collapse a few times for the recording.
        for _ in 0..<2 {
            toggle.tap()
            XCTAssertTrue(app.buttons["Command"].waitForExistence(timeout: 3))
            _ = toggle.waitForNonExistence(timeout: 0.8)
            toggle.tap()
            _ = toggle.waitForNonExistence(timeout: 0.8)
        }
        XCTAssertEqual(toggle.label, "Expand controls")
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
        let add = app.buttons["Add"].firstMatch
        if add.exists { add.tap() }
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

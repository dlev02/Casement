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

    /// The strip's own Disconnect button ends the session straight away, no confirmation.
    @MainActor func testDisconnectButtonReturnsToDeviceList() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", "127.0.0.1:47821", "-VantagePairingCode", "246810",
                               "-vantage.toolbarCollapsed", "NO", "-vantage.toolbarDock", "bottomLeft", "-vantage.requireBiometrics", "NO"]
        app.launch()
        let disconnect = app.buttons["session.toolbar.disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(disconnect.label, "Disconnect")
        screenshot("Strip with Disconnect", app)
        disconnect.tap()
        XCTAssertTrue(disconnect.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Vantage"].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Mac Audio from the strip against the synthetic host's chime: the toggle turns on, packets
    /// arrive and play with the buffer holding its depth, and it turns off again.
    @MainActor func testMacAudioToggleStreamsTheMacsSound() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", "127.0.0.1:47821", "-VantagePairingCode", "246810", "-VantageMacAudio", "0",
                               "-vantage.toolbarCollapsed", "NO", "-vantage.toolbarDock", "bottomLeft", "-vantage.requireBiometrics", "NO"]
        app.launch()
        let toggle = app.buttons["session.toolbar.macAudio"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(toggle.label, "Mac Audio")
        XCTAssertEqual(toggle.value as? String, "Off")
        XCTAssertTrue(toggle.isEnabled, "the synthetic host offers audio")
        toggle.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == %@", "On"), evaluatedWith: toggle)], timeout: 3)

        let probe = app.otherElements["session.macAudioStats"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5), app.debugDescription)
        func stat(_ name: String) -> Int {
            let words = probe.label.split(separator: " ")
            guard let index = words.firstIndex(of: Substring(name)), index + 1 < words.count else { return -1 }
            return Int(words[index + 1]) ?? -1
        }
        let playing = expectation(for: NSPredicate(format: "label BEGINSWITH %@", "playing 1"), evaluatedWith: probe)
        wait(for: [playing], timeout: 10)
        let pushedAtStart = stat("pushed")
        // Twelve seconds: six chimes, and one of the player's 10 s stats lines in the log.
        Thread.sleep(forTimeInterval: 12)
        screenshot("Strip with Mac Audio on", app)
        let pushed = stat("pushed"), played = stat("played")
        print("mac audio probe: \(probe.label)")
        XCTAssertGreaterThan(pushed - pushedAtStart, 48_000 * 10, "about 12 s of audio should have arrived")
        XCTAssertGreaterThan(played, 48_000 * 10)
        XCTAssertLessThanOrEqual(stat("underruns"), 1, probe.label)
        XCTAssertEqual(stat("skips"), 0, probe.label)
        let depth = stat("depth"), target = stat("target")
        XCTAssertTrue((20...120).contains(depth) && (40...80).contains(target), probe.label)

        toggle.tap()
        wait(for: [expectation(for: NSPredicate(format: "value == %@", "Off"), evaluatedWith: toggle)], timeout: 3)
        let stopped = expectation(for: NSPredicate(format: "label BEGINSWITH %@", "playing 0"), evaluatedWith: probe)
        wait(for: [stopped], timeout: 5)
        screenshot("Strip with Mac Audio off", app)
    }

    /// Customize Controls… in the session menu gives this Mac its own strip, and the strip behind
    /// the sheet follows each edit.
    @MainActor func testCustomizeControlsFromTheSession() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", "127.0.0.1:47821", "-VantagePairingCode", "246810",
                               "-vantage.toolbarCollapsed", "NO", "-vantage.toolbarDock", "bottomLeft", "-vantage.requireBiometrics", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["session.toolbar.collapse"].waitForExistence(timeout: 20))
        openSessionEditor(app)
        let customize = app.switches["Customize for This Mac"]
        XCTAssertTrue(customize.waitForExistence(timeout: 5), app.debugDescription)
        if (customize.value as? String) == "1" { flip(customize) } // start from the default
        XCTAssertFalse(app.buttons["Remove Option"].exists, "the default layout is read-only here")
        screenshot("Per-Mac editor using the default", app)
        flip(customize)
        XCTAssertTrue(app.buttons["Remove Option"].waitForExistence(timeout: 3), app.debugDescription)
        // The session keeps drawing video behind the sheet, and XCUITest never calls this row
        // hittable there, so tap where it is.
        app.buttons["Remove Option"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Remove Option"].waitForNonExistence(timeout: 3))
        screenshot("Per-Mac editor customized", app)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Command"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Option"].exists, "the strip should follow this Mac's layout")
        screenshot("Strip without Option", app)

        openSessionEditor(app)
        flip(customize)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Option"].waitForExistence(timeout: 5), "back on the default layout")
    }

    /// The editor opened straight from a launch argument, for screenshots: remove, add, reorder
    /// by drag, then back to the default.
    @MainActor func testControlStripEditorScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageOpenScreen", "controlStrip", "-vantage.requireBiometrics", "NO"]
        app.launch()
        XCTAssertTrue(app.otherElements["Preview of the session controls"].waitForExistence(timeout: 15), app.debugDescription)
        resetDefaultLayout(app)
        XCTAssertTrue(app.buttons["Remove Escape"].waitForExistence(timeout: 3))
        screenshot("Editor", app)

        app.buttons["Remove Escape"].tap()
        XCTAssertTrue(app.buttons["Remove Escape"].waitForNonExistence(timeout: 3))
        let addDesktop = app.buttons["Add Show Desktop"]
        for _ in 0..<8 where !(addDesktop.exists && addDesktop.isHittable) { app.swipeUp() }
        XCTAssertTrue(app.buttons["Add Escape"].exists, "Escape should move to More Controls")
        addDesktop.tap()
        XCTAssertTrue(app.buttons["Remove Show Desktop"].waitForExistence(timeout: 3))
        screenshot("More Controls", app)

        // Drag Tab by its reorder handle to the top of the list.
        for _ in 0..<8 where !app.buttons["Remove Control"].isHittable { app.swipeDown() }
        let handles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reorder"))
        let tab = app.buttons["Reorder Tab"]
        XCTAssertTrue(tab.waitForExistence(timeout: 3), app.debugDescription)
        tab.press(forDuration: 0.6, thenDragTo: app.buttons["Reorder Control"])
        XCTAssertEqual(handles.firstMatch.label, "Reorder Tab")
        screenshot("Tab moved first", app)

        resetDefaultLayout(app)
    }

    /// Scrolls to Reset to Default and taps it if the layout isn't already the default.
    @MainActor private func resetDefaultLayout(_ app: XCUIApplication) {
        let reset = app.buttons["Reset to Default"]
        for _ in 0..<8 where !(reset.exists && reset.isHittable) { app.swipeUp() }
        if reset.isEnabled { reset.tap() }
        XCTAssertFalse(reset.isEnabled)
        for _ in 0..<8 where !app.buttons["Remove Control"].isHittable { app.swipeDown() }
    }

    /// Taps the switch itself: a SwiftUI toggle row doesn't flip when its label is tapped.
    @MainActor private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
    }

    @MainActor private func openSessionEditor(_ app: XCUIApplication) {
        let menu = app.buttons["Session Options"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let item = app.buttons["Customize Controls…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), app.debugDescription)
        item.tap()
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

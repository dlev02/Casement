import XCTest

/// Which session moments play a haptic, read from the `-VantageHapticProbe` element (a simulator
/// can't be felt, and an iPad plays nothing, so `-VantageForceHaptics` turns the calls on). Needs
/// the debug synthetic host (VANTAGE_SYNTHETIC_HOST, default 127.0.0.1:47821).
nonisolated final class HapticsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private var syntheticHost: String {
        ProcessInfo.processInfo.environment["VANTAGE_SYNTHETIC_HOST"] ?? "127.0.0.1:47821"
    }

    @MainActor private func launch(_ extra: [String] = []) -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", syntheticHost, "-VantagePairingCode", "246810",
                               "-VantageForceHaptics", "1", "-VantageHapticProbe", "1",
                               "-vantage.toolbarCollapsed", "NO", "-vantage.toolbarDock", "bottomLeft",
                               "-vantage.touchMode", "trackpad", "-vantage.requireBiometrics", "NO"] + extra
        app.launch()
        let probe = app.otherElements["session.hapticProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Command"].waitForExistence(timeout: 20))
        return (app, probe)
    }

    /// Waits for the probe to list exactly `expected`, then checks nothing else arrives.
    @MainActor private func expectPlayed(_ expected: String, _ probe: XCUIElement, _ step: String) {
        let deadline = Date().addingTimeInterval(3)
        while probe.value as? String != expected, Date() < deadline { usleep(100_000) }
        XCTAssertEqual(probe.value as? String, expected, step)
    }

    @MainActor func testSessionMomentsThatPlayAHaptic() {
        let (app, probe) = launch()
        expectPlayed("", probe, "connecting is quiet")

        let command = app.buttons["Command"]
        command.tap()
        expectPlayed("latch", probe, "latching ⌘")
        app.buttons["Escape"].tap()
        expectPlayed("latch", probe, "a key clearing ⌘ is quiet")
        command.tap()
        command.tap()
        expectPlayed("latch latch unlatch", probe, "latching and releasing ⌘")

        let screen = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4))
        screen.tap()
        expectPlayed("latch latch unlatch", probe, "a plain tap (click) is quiet")
        screen.press(forDuration: 0.8)
        expectPlayed("latch latch unlatch press", probe, "a long press")
        app.windows.firstMatch.twoFingerTap()
        expectPlayed("latch latch unlatch press secondaryClick", probe, "a two-finger tap (right-click)")

        let collapse = app.buttons["session.toolbar.collapse"]
        collapse.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.15)))
        expectPlayed("latch latch unlatch press secondaryClick snap", probe, "the controls landing in a corner")
    }

    @MainActor func testDictationStartAndFailure() {
        let (_, listening) = launch(["-VantageDictationFixture", "listening"])
        expectPlayed("start", listening, "the microphone opening")
        let (_, failed) = launch(["-VantageDictationFixture", "failed"])
        expectPlayed("error", failed, "dictation failing")
    }

    /// Settings → Controls → Haptics in light, dark, and at a large accessibility text size.
    @MainActor func testHapticsSettingScreens() {
        for (name, extra) in [("light", ["-vantage.appearance", "light"]),
                              ("dark", ["-vantage.appearance", "dark"]),
                              ("large text", ["-vantage.appearance", "light", "-UIPreferredContentSizeCategoryName",
                                              "UICTContentSizeCategoryAccessibilityXL"])] {
            let app = XCUIApplication()
            app.launchArguments = ["-VantageOpenScreen", "controls", "-VantageForceHaptics", "1",
                                   "-vantage.requireBiometrics", "NO"] + extra
            app.launch()
            // The form's rows load as they scroll into view, so scroll the Controls form (the one
            // with the Keyboard section) until the toggle is there.
            let form = app.collectionViews.containing(NSPredicate(format: "label == %@", "Keyboard")).firstMatch
            XCTAssertTrue(form.waitForExistence(timeout: 15))
            let frame = form.frame // the query stops matching once Keyboard scrolls away
            func point(_ y: CGFloat) -> XCUICoordinate {
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: frame.minY + frame.height * y))
            }
            let toggle = app.switches["settings.haptics"]
            // Until the row and its footer sit in the middle of the sheet, not at its bottom edge.
            for _ in 0..<15 where !(toggle.exists && toggle.isHittable && toggle.frame.midY < frame.midY + 60) {
                point(0.8).press(forDuration: 0.05, thenDragTo: point(0.6))
            }
            XCTAssertTrue(toggle.isHittable)
            XCTAssertEqual(toggle.value as? String, "1", "on by default")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Haptics setting (\(name))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testTurningHapticsOffSilencesThem() {
        let (app, probe) = launch(["-vantage.haptics", "NO"])
        app.buttons["Command"].tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)).press(forDuration: 0.8)
        expectPlayed("", probe, "Settings → Controls → Haptics off")
    }
}

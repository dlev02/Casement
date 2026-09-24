import XCTest

/// Requires the debug synthetic host on loopback port 47821 (see docs/testing), or wherever
/// `VANTAGE_TEST_HOST` points (`TEST_RUNNER_VANTAGE_TEST_HOST=127.0.0.1:47851 xcodebuild test …`).
nonisolated final class SessionUITests: XCTestCase {
    static let host = ProcessInfo.processInfo.environment["VANTAGE_TEST_HOST"] ?? "127.0.0.1:47821"

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testToolbarCollapseDockAndForegroundRecovery() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", Self.host, "-VantagePairingCode", "246810",
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
        app.launchArguments = ["-VantageAutoConnect", Self.host, "-VantagePairingCode", "246810",
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
        app.launchArguments = ["-VantageAutoConnect", Self.host, "-VantagePairingCode", "246810",
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
        app.launchArguments = ["-VantageAutoConnect", Self.host, "-VantagePairingCode", "246810", "-VantageMacAudio", "0",
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

    /// Files both ways against the synthetic host started with
    /// `--send-file-on-connect "…/Quarterly Report.pdf"`: the app queues a 3 MiB test file for the
    /// Mac (`-VantageSendTestFile`) while the Mac sends its file here. Both finish, the received
    /// notice appears, and the Transfers sheet lists both.
    @MainActor func testFilesMoveBothWays() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", Self.host, "-VantagePairingCode", "246810",
                               "-VantageSendTestFile", "3145728",
                               "-vantage.toolbarCollapsed", "NO", "-vantage.toolbarDock", "bottomLeft", "-vantage.requireBiometrics", "NO"]
        app.launch()
        let send = app.buttons["session.toolbar.sendFile"]
        XCTAssertTrue(send.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(send.label, "Send File")
        XCTAssertTrue(send.isEnabled, "the synthetic host takes files")

        let notice = app.descendants(matching: .any)["session.receivedNotice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20), app.debugDescription)
        // "Quarterly Report 2.pdf" and so on when an earlier run already received one.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Received Quarterly Report")).firstMatch.exists,
                      app.debugDescription)
        screenshot("Received notice and Send File", app)

        let menu = app.buttons["Session Options"]
        menu.tap()
        let transfers = app.buttons["Transfers…"]
        XCTAssertTrue(transfers.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.buttons["Send File to Mac…"].exists)
        screenshot("Session menu with Transfers", app)
        transfers.tap()

        func row(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        }
        let sent = row("Vantage Test.bin")
        XCTAssertTrue(sent.waitForExistence(timeout: 10), app.debugDescription)
        wait(for: [expectation(for: NSPredicate(format: "value BEGINSWITH %@", "Sent"), evaluatedWith: sent)], timeout: 30)
        let received = row("Quarterly Report")
        XCTAssertTrue(received.exists, app.debugDescription)
        XCTAssertTrue((received.value as? String)?.hasPrefix("Received") == true, "\(String(describing: received.value))")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Share Quarterly Report")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show Quarterly Report")).firstMatch.exists)
        screenshot("Transfers after both directions", app)
        app.buttons["Done"].tap()
        XCTAssertTrue(send.waitForExistence(timeout: 5))
    }

    /// Disconnect while a file is moving: no question, the screen closes, the file carries on,
    /// and the Mac's row in the device list shows it; tapping that opens Transfers, where it can
    /// be cancelled. `-VantageSlowFiles 3000` holds each 256 KiB chunk for 3 s, so the file is
    /// still moving throughout and the UI goes quiet between chunks (XCUITest waits for an idle
    /// app before every tap).
    @MainActor func testDisconnectKeepsFilesMovingAndTheListShowsThem() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", Self.host, "-VantagePairingCode", "246810",
                               "-VantageSendTestFile", "3145728", "-VantageSlowFiles", "3000",
                               "-vantage.toolbarCollapsed", "NO", "-vantage.toolbarDock", "bottomLeft", "-vantage.requireBiometrics", "NO"]
        app.launch()
        let send = app.buttons["session.toolbar.sendFile"]
        XCTAssertTrue(send.waitForExistence(timeout: 20), app.debugDescription)
        wait(for: [expectation(for: NSPredicate(format: "value BEGINSWITH %@", "Sending"), evaluatedWith: send)], timeout: 10)
        screenshot("Send File with progress", app)

        let disconnect = app.buttons["session.toolbar.disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        disconnect.tap()
        XCTAssertTrue(app.navigationBars["Vantage"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.alerts.firstMatch.exists, "Disconnect doesn't ask any more")

        let badge = app.buttons["devices.transfers"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(Self.isMoving(badge.value), "\(String(describing: badge.value))")
        screenshot("Device list with the transfer carrying on", app)
        badge.tap()

        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Vantage Test.bin")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue((row.value as? String)?.hasPrefix("Sending to") == true, "\(String(describing: row.value))")
        screenshot("Transfers from the device list", app)
        app.buttons["Cancel Vantage Test.bin"].tap()
        wait(for: [expectation(for: NSPredicate(format: "value == %@", "Cancelled"), evaluatedWith: row)], timeout: 5)
        app.buttons["Done"].tap()
        XCTAssertTrue(badge.waitForNonExistence(timeout: 5), "nothing moving, so the row is plain again")
    }

    /// Send Files from the device list, no screen: the Mac's menu offers it (the Files picker
    /// opens), and a file queued without a session (`-VantageSendTestFile` with no auto-connect,
    /// as if picked there) goes over a files-only session while the row shows it, then lands.
    @MainActor func testSendFilesFromTheDeviceList() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageSeedHost", Self.host, "-VantageSendTestFile", "3145728", "-VantageSlowFiles", "1500",
                               "-vantage.requireBiometrics", "NO"]
        app.launch()
        let badge = app.buttons["devices.transfers"]
        XCTAssertTrue(badge.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(Self.isMoving(badge.value), "\(String(describing: badge.value))")
        XCTAssertFalse(app.buttons["session.toolbar.disconnect"].exists, "no screen session")
        screenshot("Sending from the device list", app)

        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "My Mac")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.press(forDuration: 1.2)
        let sendFiles = app.buttons["Send Files…"]
        XCTAssertTrue(sendFiles.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Transfers…"].exists)
        screenshot("Mac menu with Send Files", app)
        sendFiles.tap()
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the Files picker opens: \(app.debugDescription)")
        screenshot("Files picker for the Mac", app)
        cancel.tap()

        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        badge.tap()
        let transfer = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Vantage Test.bin")).firstMatch
        XCTAssertTrue(transfer.waitForExistence(timeout: 5), app.debugDescription)
        wait(for: [expectation(for: NSPredicate(format: "value BEGINSWITH %@", "Sent"), evaluatedWith: transfer)], timeout: 60)
        screenshot("Sent without opening the screen", app)
        app.buttons["Done"].tap()
    }

    /// Progress shows up on its own: a capsule appears as soon as a file starts moving, on the
    /// edge away from the control strip (top while the strip is at the bottom, and the other way
    /// round), opens Transfers when tapped, and turns into a checkmark when the file is done
    /// before it goes. `VANTAGE_UI_APPEARANCE` / `VANTAGE_UI_TEXT_SIZE` rerun it in dark mode or
    /// at a large text size for screenshots.
    @MainActor func testTransferCapsuleAppearsOnItsOwn() {
        for dock in ["bottomLeft", "topRight"] {
            let app = XCUIApplication()
            app.launchArguments = ["-VantageAutoConnect", Self.host, "-VantagePairingCode", "246810",
                                   "-VantageSendTestFile", "2621440", "-VantageSlowFiles", "1200",
                                   "-vantage.toolbarCollapsed", "NO", "-vantage.toolbarDock", dock, "-vantage.requireBiometrics", "NO"]
                + Self.appearanceArguments
            app.launch()
            let capsule = app.buttons["session.transferCapsule"]
            XCTAssertTrue(capsule.waitForExistence(timeout: 20), app.debugDescription)
            XCTAssertTrue(Self.isMoving(capsule.value), "\(String(describing: capsule.value))")
            let strip = app.buttons["session.toolbar.collapse"]
            XCTAssertTrue(strip.waitForExistence(timeout: 5))
            if dock.hasPrefix("bottom") {
                XCTAssertLessThan(capsule.frame.maxY, app.frame.midY, "top, away from the strip")
            } else {
                XCTAssertGreaterThan(capsule.frame.minY, app.frame.midY, "bottom, away from the strip")
            }
            XCTAssertFalse(capsule.frame.intersects(strip.frame), "capsule clear of the strip")
            screenshot("Capsule while sending (strip \(dock))", app)

            if dock.hasPrefix("bottom") {
                capsule.tap()
                XCTAssertTrue(app.navigationBars["Transfers"].waitForExistence(timeout: 5), app.debugDescription)
                app.buttons["Done"].tap()
            }
            // "Sent to My Mac", or "Moved 2 files" when the host also sends one (`--send-file-on-connect`).
            wait(for: [expectation(for: NSPredicate(format: "value BEGINSWITH %@ OR value BEGINSWITH %@", "Sent to", "Moved"),
                                   evaluatedWith: capsule)], timeout: 40)
            screenshot("Capsule done (strip \(dock))", app)
            XCTAssertTrue(capsule.waitForNonExistence(timeout: 10), "gets out of the way")
            app.terminate()
        }
    }

    /// A run on its way to the Mac: "Sending to My Mac, …", or "Moving files with My Mac, …" when
    /// a host started with `--send-file-on-connect` is sending one back at the same time.
    private static func isMoving(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return value.hasPrefix("Sending to") || value.hasPrefix("Moving files with")
    }

    private static var appearanceArguments: [String] {
        var arguments: [String] = []
        let environment = ProcessInfo.processInfo.environment
        if let appearance = environment["VANTAGE_UI_APPEARANCE"] { arguments += ["-vantage.appearance", appearance] }
        if let size = environment["VANTAGE_UI_TEXT_SIZE"] { arguments += ["-UIPreferredContentSizeCategoryName", size] }
        return arguments
    }

    /// The "Drop to send" hint, forced on for a screenshot (a drag can't be scripted here).
    @MainActor func testDropHint() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", Self.host, "-VantagePairingCode", "246810", "-VantageDropHint", "1",
                               "-vantage.toolbarCollapsed", "NO", "-vantage.toolbarDock", "bottomLeft", "-vantage.requireBiometrics", "NO"]
        app.launch()
        let hint = app.descendants(matching: .any)["session.dropHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(hint.label.hasPrefix("Drop to send to "), hint.label)
        screenshot("Drop hint", app)
    }

    /// `-VantageOpenScreen transfers`: one row in each state, light and dark.
    @MainActor func testTransfersSheetScreens() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["-VantageOpenScreen", "transfers", "-vantage.appearance", appearance, "-vantage.requireBiometrics", "NO"]
            if let size = ProcessInfo.processInfo.environment["VANTAGE_UI_TEXT_SIZE"] {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
            }
            app.launch()
            XCTAssertTrue(app.navigationBars["Transfers"].waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(app.buttons["Cancel Quarterly Report.pdf"].exists)
            let summary = app.descendants(matching: .any)["transfers.summary"]
            XCTAssertTrue(summary.exists, "the run is summed up above its files")
            XCTAssertTrue(summary.label.contains("All transfers"), summary.label)
            screenshot("Transfers sheet (\(appearance))", app)
            let share = app.buttons["Share Invoice 1042.pdf"]
            for _ in 0..<4 where !(share.exists && share.isHittable) { app.swipeUp() }
            XCTAssertTrue(share.exists, app.debugDescription)
            screenshot("Transfers sheet, finished files (\(appearance))", app)
            app.terminate()
        }
    }

    /// Customize Controls… in the session menu gives this Mac its own strip, and the strip behind
    /// the sheet follows each edit.
    @MainActor func testCustomizeControlsFromTheSession() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", Self.host, "-VantagePairingCode", "246810",
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

    /// Sleep Display from the session menu, against a synthetic host started with
    /// `--display-asleep` (a pretend display that sleeps and wakes like a real one): the Mac's
    /// screen gets the asleep note, the session stays put with no video, and Wake (or a tap
    /// anywhere) brings it back. `TEST_RUNNER_VANTAGE_SYNTHETIC_HOST` picks another host:port;
    /// `TEST_RUNNER_VANTAGE_TEXT_SIZE` (a UIContentSizeCategory name) screenshots it at that size.
    @MainActor func testSleepDisplayShowsAsleepStateAndWakes() {
        let environment = ProcessInfo.processInfo.environment
        let host = environment["VANTAGE_SYNTHETIC_HOST"] ?? "127.0.0.1:47821"
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", host, "-VantagePairingCode", "246810",
                               "-vantage.toolbarCollapsed", "NO", "-vantage.toolbarDock", "bottomLeft", "-vantage.requireBiometrics", "NO"]
        if let size = environment["VANTAGE_TEXT_SIZE"] { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
        app.launch()
        let menu = app.buttons["Session Options"]
        let wake = app.buttons["session.wakeDisplay"]
        func sleepDisplay() {
            XCTAssertTrue(menu.waitForExistence(timeout: 20), app.debugDescription)
            menu.tap()
            let item = app.buttons["Sleep Display"]
            XCTAssertTrue(item.waitForExistence(timeout: 3), app.debugDescription)
            item.tap()
            XCTAssertTrue(wake.waitForExistence(timeout: 10), app.debugDescription)
        }

        sleepDisplay()
        XCTAssertTrue(app.staticTexts["The Mac's display is asleep"].exists)
        screenshot("Mac display asleep", app)
        // No picture for a while is fine: same session, no reconnecting.
        XCTAssertFalse(wake.waitForNonExistence(timeout: 4), "the asleep state should stay until woken")
        XCTAssertFalse(app.staticTexts["Reconnecting…"].exists)
        wake.tap()
        XCTAssertTrue(wake.waitForNonExistence(timeout: 10), app.debugDescription)
        screenshot("Mac display awake again", app)

        // Again, woken by a tap on the Mac's screen this time.
        sleepDisplay()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        XCTAssertTrue(wake.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(menu.exists, "still in the session")
    }

    /// Against a synthetic host started with `--capture-fails-for 6`: the Mac is awake but there's
    /// no picture, so after ~3 s the session says so ("Waiting for the Mac's screen…") instead of
    /// showing nothing; Retry reaches the host, and the note clears once frames arrive.
    /// `TEST_RUNNER_VANTAGE_UNAVAILABLE_HOST` picks the host:port (default 127.0.0.1:47822).
    @MainActor func testMissingPictureIsExplainedUntilFramesReturn() {
        let host = ProcessInfo.processInfo.environment["VANTAGE_UNAVAILABLE_HOST"] ?? "127.0.0.1:47822"
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", host, "-VantagePairingCode", "246810",
                               "-vantage.toolbarCollapsed", "NO", "-vantage.toolbarDock", "bottomLeft", "-vantage.requireBiometrics", "NO"]
        app.launch()
        let retry = app.buttons["session.retryScreen"]
        XCTAssertTrue(retry.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Waiting for the Mac's screen…"].exists)
        XCTAssertTrue(app.buttons["Session Options"].exists, "still in the session")
        screenshot("Waiting for the Mac's screen", app)
        retry.tap()
        XCTAssertTrue(retry.waitForNonExistence(timeout: 20), "the note should clear once frames arrive")
        XCTAssertFalse(app.staticTexts["Reconnecting…"].exists)
        screenshot("Picture back", app)
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
        app.launchArguments = ["-VantageSeedHost", Self.host, "-vantage.requireBiometrics", "NO"]
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

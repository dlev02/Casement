import XCTest

/// The Mac client's session surface: the pointer maps onto the Mac with its edges reachable, and
/// ⌘Q goes to the Mac while shortcuts are captured.
///
/// Runs against its own synthetic host on 47857 (or `TEST_RUNNER_VANTAGE_INPUT_HOST=127.0.0.1:<port>`).
/// The synthetic host runs on this same Mac, so the client would start in View Only
/// (`-VantageAllowSelfControl 1` keeps input on). `-VantagePointerProbe 1` exposes the Mac
/// position last sent as `session.pointerProbe`'s value ("x y of width height"), and
/// `-VantageKeyProbe 1` the keys sent lately as `session.keyProbe`'s label. Needs Automation Mode
/// (`automationmodetool enable-automationmode-without-authentication`, as an admin).
nonisolated final class SessionInputUITests: XCTestCase {
    nonisolated(unsafe) private static var host = "127.0.0.1:47857"

    override class func setUp() {
        super.setUp()
        host = SyntheticHost.address(environmentVariable: "VANTAGE_INPUT_HOST", defaultPort: 47857)
    }

    override func setUpWithError() throws { continueAfterFailure = false }

    /// `capturingShortcuts` sets "Send keyboard shortcuts to the Mac" for this launch only (the
    /// argument domain), so no run leaves it changed for the next.
    @MainActor private func launchSession(capturingShortcuts: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageSeedHost", Self.host, "-VantageAutoConnect", Self.host, "-VantagePairingCode", "246810",
                               "-vantage.requireBiometrics", "NO", "-vantage.availabilityChecks", "NO",
                               "-ApplePersistenceIgnoreState", "YES", "-VantageAllowSelfControl", "1",
                               "-VantagePointerProbe", "1", "-VantageKeyProbe", "1",
                               "-vantage.mac.captureShortcuts", capturingShortcuts ? "YES" : "NO"]
        app.launch()
        return app
    }

    /// "x y of width height" → the point and the display size.
    private func parse(_ value: Any?) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let parts = (value as? String)?.split(separator: " "), parts.count == 5,
              let x = Double(parts[0]), let y = Double(parts[1]), let width = Double(parts[3]), let height = Double(parts[4])
        else { return nil }
        return (x, y, width, height)
    }

    @MainActor func testPointerMapsAndEdgesPinInFullScreen() throws {
        let app = launchSession()
        let probe = app.descendants(matching: .any)["session.pointerProbe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "the session should connect")

        probe.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        var position = try XCTUnwrap(parse(probe.value))
        XCTAssertEqual(position.x, position.width / 2, accuracy: 2, "the middle of the picture is the middle of the Mac")
        XCTAssertEqual(position.y, position.height / 2, accuracy: 2)

        // Full screen (View › Full Screen, ⌃⌥⌘F, stays with Vantage while shortcuts go to the Mac).
        app.typeKey("f", modifierFlags: [.control, .option, .command])
        sleep(2)
        let edges: [(CGVector, (Double, Double) -> Bool, String)] = [
            (CGVector(dx: 0.5, dy: 0), { _, y in y == 0 }, "top edge: the Mac's menu bar row"),
            (CGVector(dx: 0.5, dy: 0.9999), { _, y in y == position.height - 1 }, "bottom edge: the Mac's Dock row"),
            (CGVector(dx: 0, dy: 0.5), { x, _ in x == 0 }, "left edge"),
            (CGVector(dx: 0.9999, dy: 0.5), { x, _ in x == position.width - 1 }, "right edge"),
            (CGVector(dx: 0.9999, dy: 0.9999), { x, y in x == position.width - 1 && y == position.height - 1 }, "bottom-right hot corner"),
        ]
        for (offset, check, name) in edges {
            probe.coordinate(withNormalizedOffset: offset).hover()
            position = try XCTUnwrap(parse(probe.value))
            XCTAssertTrue(check(position.x, position.y), "\(name): \(position)")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Full-screen session"
        shot.lifetime = .keepAlways
        add(shot)
        app.typeKey("f", modifierFlags: [.control, .option, .command])
    }

    @MainActor func testCommandQGoesToTheMacWhileCapturing() {
        let app = launchSession()
        let probe = app.descendants(matching: .any)["session.pointerProbe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "the session should connect")
        probe.click() // the picture takes the keyboard

        app.typeKey("q", modifierFlags: .command)
        let keys = app.descendants(matching: .any)["session.keyProbe"].firstMatch
        XCTAssertTrue(keys.waitForExistence(timeout: 5))
        XCTAssertTrue(keys.label.contains("0xc down command"), "⌘Q went to the Mac: \(keys.label)")
        XCTAssertEqual(app.state, .runningForeground, "and Vantage is still running")

        // Shortcuts off: ⌘W closes the session window instead.
        app.terminate()
        let local = launchSession(capturingShortcuts: false)
        let picture = local.descendants(matching: .any)["session.pointerProbe"].firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 20))
        picture.click()
        local.typeKey("w", modifierFlags: .command)
        let closed = NSPredicate { _, _ in !picture.exists }
        wait(for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: 5)
        XCTAssertEqual(local.state, .runningForeground, "the list stays; only the session window closed")
    }
}

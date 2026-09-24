import XCTest

/// A mouse or trackpad pointer (synthesized with `hover()`) pushed to each edge of the iPad must
/// leave the Mac's pointer on that edge — the Dock, the menu bar, and hot corners need the
/// outermost row or column — and keep it there when iPadOS takes the pointer at the edge and
/// ends the hover. Needs the debug synthetic host (VANTAGE_SYNTHETIC_HOST, default
/// 127.0.0.1:47821; pass it to xcodebuild as TEST_RUNNER_VANTAGE_SYNTHETIC_HOST).
nonisolated final class PointerEdgeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private var syntheticHost: String {
        ProcessInfo.processInfo.environment["VANTAGE_SYNTHETIC_HOST"] ?? "127.0.0.1:47821"
    }

    /// The Mac pointer the app last sent, from the `-VantagePointerProbe` element.
    private struct MacPointer {
        var x, y, width, height: Double
        init?(_ value: Any?) {
            let parts = (value as? String)?.split(separator: " ").compactMap { Double($0) } ?? []
            guard parts.count == 4 else { return nil }
            (x, y, width, height) = (parts[0], parts[1], parts[2], parts[3])
        }
    }

    @MainActor func testPointerPushedToEachEdgeStaysOnTheMacsEdge() {
        let app = XCUIApplication()
        app.launchArguments = ["-VantageAutoConnect", syntheticHost, "-VantagePairingCode", "246810",
                               "-VantagePointerProbe", "1", "-vantage.toolbarCollapsed", "YES",
                               "-vantage.toolbarDock", "topRight", "-vantage.requireBiometrics", "NO"]
        app.launch()
        let probe = app.otherElements["session.pointerProbe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20))

        // The simulator sometimes drops the first synthesized hovers after a launch (the pointer
        // is still hidden from the last touch), so wake it until the app sees one.
        let start = probe.value as? String
        for attempt in 0..<8 where probe.value as? String == start {
            app.coordinate(withNormalizedOffset: CGVector(dx: attempt.isMultiple(of: 2) ? 0.4 : 0.6, dy: 0.5)).hover()
            usleep(500_000)
        }
        XCTAssertNotEqual(probe.value as? String, start, "no hover reached the app")

        /// Hovers to `offset`, then waits until the Mac pointer satisfies `check` — and still does
        /// a second later, after iPadOS has had time to end the hover at the edge.
        func push(to offset: CGVector, _ name: String, _ check: @escaping (MacPointer) -> Bool) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
            app.coordinate(withNormalizedOffset: offset).hover()
            let deadline = Date().addingTimeInterval(3)
            var pointer = MacPointer(probe.value)
            while !(pointer.map(check) ?? false), Date() < deadline {
                usleep(100_000)
                pointer = MacPointer(probe.value)
            }
            XCTAssertTrue(pointer.map(check) ?? false, "\(name): Mac pointer at \(probe.value ?? "nil")")
            usleep(1_000_000)
            XCTAssertTrue(MacPointer(probe.value).map(check) ?? false,
                          "\(name): Mac pointer left the edge for \(probe.value ?? "nil")")
        }

        push(to: CGVector(dx: 0.5, dy: 1), "bottom (Dock)") { $0.y == $0.height - 1 && $0.x > 0 }
        push(to: CGVector(dx: 0.5, dy: 0), "top (menu bar)") { $0.y == 0 && $0.x > 0 }
        push(to: CGVector(dx: 0, dy: 0.5), "left") { $0.x == 0 && $0.y > 0 }
        push(to: CGVector(dx: 1, dy: 0.5), "right") { $0.x == $0.width - 1 && $0.y > 0 }
        push(to: CGVector(dx: 1, dy: 1), "bottom-right corner") { $0.x == $0.width - 1 && $0.y == $0.height - 1 }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    }
}

import AppKit
import Foundation
import Testing
import VantageCore
@testable import VantageClientLogic

/// Opt-in, against a real Debug host on this Mac, and it moves the real pointer:
///
///     open -n .deriveddata/Build/Products/Debug/VantageHost.app --args --pairing-code 246810 --port 47841
///     VANTAGE_LIVE_DOCK_HOST=127.0.0.1:47841 xcrun swift test --filter LiveDockEdgeTests
///
/// Checks what the client has to deliver for macOS to reveal an auto-hidden Dock: one pointer move
/// onto the bottom row is enough (no deltas, no repeated "push"), and three points short isn't.
/// Pairs a throwaway key with the host (a Debug host shares the real host's trust list), listed
/// under this Mac's own name: the private key dies with the test process, so the entry can't be
/// used, but revoke it in the host's menu to tidy up. Never use a fixed or checked-in key here.
/// Keeps away from the bottom corners, which may be hot corners.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VANTAGE_LIVE_DOCK_HOST"] != nil
                && UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") == true),
       .timeLimit(.minutes(2)))
struct LiveDockEdgeTests {
    @Test @MainActor func oneMoveOntoTheBottomRowRevealsTheDock() async throws {
        let session = ClientSession(identity: DeviceIdentity())
        session.connect(to: SavedDevice(name: "Edge test", host: ProcessInfo.processInfo.environment["VANTAGE_LIVE_DOCK_HOST"]!),
                        viewport: Viewport(widthPoints: 1210, heightPoints: 834, scale: 2), pairingCode: "246810")
        defer { session.disconnect() }
        let deadline = ContinuousClock.now + .seconds(20)
        while session.state != .connected || session.activeConfig == nil {
            try #require(ContinuousClock.now < deadline, "no session: \(session.state)")
            try await Task.sleep(for: .milliseconds(50))
        }
        let display = try #require(session.activeConfig?.display)
        let height = Double(display.pointHeight), x = Double(display.pointWidth) / 2 + 40

        func move(_ y: Double) { session.send(.pointerEvent(PointerEvent(action: .move, x: Float(x), y: Float(y)))) }
        func dockShows(within seconds: Double) async throws -> Bool {
            let start = ContinuousClock.now
            while ContinuousClock.now - start < .seconds(seconds) {
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                if windows.contains(where: { ($0[kCGWindowOwnerName as String] as? String) == "Dock" && ($0[kCGWindowLayer as String] as? Int) == 20 }) {
                    return true
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        /// Glides down from the middle and stops at `y`, the way a mouse arrives at an edge.
        func arrive(at y: Double) async throws -> Bool {
            move(height / 2)
            try await Task.sleep(for: .seconds(1.5)) // let a shown Dock hide
            var step = height - 140
            while step < y { move(step); step += 10; try await Task.sleep(for: .milliseconds(8)) }
            move(y)
            return try await dockShows(within: 2)
        }

        #expect(try await arrive(at: height - 1), "one move onto the bottom row")
        #expect(try await !arrive(at: height - 3), "three points short")
        move(height / 2)
    }
}

import CoreGraphics
import Foundation
import VantageCore
import os

/// Manages an app-owned virtual display sized to the client viewport, via BetterDisplay's CLI.
///
/// v1 uses BetterDisplay because its virtual-screen definitions persist in preferences and can be
/// connected/disconnected without being discarded, which sidesteps the `CGVirtualDisplay`
/// removal/lifetime landmines. The manager only ever touches a display it owns (identified by a
/// stable name) and records what it changed so it can restore afterwards. A future backend can
/// swap in `CGVirtualDisplay` behind the same interface.
nonisolated final class VirtualDisplayManager: @unchecked Sendable {
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "virtualdisplay")
    private let screenName = "Casement Virtual"
    private let cliPath = "/opt/homebrew/bin/betterdisplaycli"

    struct Lease {
        var displayID: CGDirectDisplayID
        var previousMainID: CGDirectDisplayID
        var createdVirtual: Bool
    }

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: cliPath) }

    /// After the display shows the requested mode, the window server still moves and redraws
    /// windows onto it for a moment; capture starts once that has settled, so the device never
    /// watches the layout shift.
    static let layoutSettle: Duration = .milliseconds(500)
    /// How long to wait for BetterDisplay's display to show the requested mode.
    static let modeLimit: Duration = .seconds(4)

    /// Ensures a virtual display of the requested logical size at 2x exists, is connected and
    /// shows that mode, and returns its CGDirectDisplayID. One that already shows the mode is
    /// returned at once without touching the CLI (a reconnect, or the same window size again).
    /// Otherwise it returns once the mode has shown and the layout has settled; a display that
    /// never reaches the mode within `modeLimit` is returned as it is (the old behaviour), one
    /// that never appears throws.
    func provision(pointWidth: Int, pointHeight: Int) async throws -> CGDirectDisplayID {
        guard isAvailable else { throw VirtualDisplayError.cliUnavailable }
        let pixelWidth = pointWidth * 2
        let pixelHeight = pointHeight * 2
        if let id = existingVirtualDisplayID(), Self.shows(id, pointWidth: pointWidth, pointHeight: pointHeight) { return id }

        if existingVirtualDisplayID() == nil {
            _ = try? runCLI(["set", "-namelike=\(screenName)", "-connected=on"])
            if existingVirtualDisplayID() == nil {
                _ = try? runCLI(["create", "-virtualScreen", "-name=\(screenName)",
                                 "-resolution=\(pixelWidth)x\(pixelHeight)", "-hidpi=on"])
            }
        }
        _ = try? runCLI(["set", "-namelike=\(screenName)", "-resolution=\(pixelWidth)x\(pixelHeight)", "-hidpi=on"])

        // Poll CoreGraphics for the display and its new mode. This runs on the connect path, so
        // give up quickly; the caller falls back to the main display if it never appears.
        let started = ContinuousClock.now
        var appeared: CGDirectDisplayID?
        while ContinuousClock.now - started < Self.modeLimit {
            if let id = existingVirtualDisplayID() {
                appeared = id
                if Self.shows(id, pointWidth: pointWidth, pointHeight: pointHeight) {
                    try await Task.sleep(for: Self.layoutSettle)
                    log.info("virtual display \(id) at \(pointWidth)x\(pointHeight) after \((ContinuousClock.now - started).components.seconds) s")
                    return id
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let appeared else { throw VirtualDisplayError.didNotAppear }
        log.error("virtual display \(appeared) never showed \(pointWidth)x\(pointHeight); streaming it as it is")
        return appeared
    }

    /// The display shows this size in points at 2× (a point either way for rounding).
    private static func shows(_ id: CGDirectDisplayID, pointWidth: Int, pointHeight: Int) -> Bool {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return false }
        return abs(mode.width - pointWidth) <= 1 && abs(mode.height - pointHeight) <= 1 && mode.pixelWidth >= mode.width * 2 - 2
    }

    func disconnect() {
        guard isAvailable else { return }
        _ = try? runCLI(["set", "-namelike=\(screenName)", "-connected=off"])
    }

    /// Finds a virtual display whose geometry we manage. Matches by "virtual + not built-in".
    private func existingVirtualDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.first { DisplayEnumerator.isVirtual($0) }
    }

    @discardableResult
    private func runCLI(_ arguments: [String], timeout: TimeInterval = 3) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let group = DispatchGroup()
        group.enter()
        var output = Data()
        DispatchQueue.global().async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw VirtualDisplayError.cliTimedOut
        }
        process.waitUntilExit()
        return output
    }
}

enum VirtualDisplayError: Error {
    case cliUnavailable
    case cliTimedOut
    case didNotAppear
}

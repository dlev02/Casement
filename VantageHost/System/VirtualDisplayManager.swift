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
    private let screenName = "Vantage Virtual"
    private let cliPath = "/opt/homebrew/bin/betterdisplaycli"

    struct Lease {
        var displayID: CGDirectDisplayID
        var previousMainID: CGDirectDisplayID
        var createdVirtual: Bool
    }

    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: cliPath) }

    /// Ensures a virtual display of the requested logical size at 2x exists and is connected.
    /// Returns the CGDirectDisplayID once it appears (polls up to ~15s).
    func provision(pointWidth: Int, pointHeight: Int) async throws -> CGDirectDisplayID {
        guard isAvailable else { throw VirtualDisplayError.cliUnavailable }
        let pixelWidth = pointWidth * 2
        let pixelHeight = pointHeight * 2

        if existingVirtualDisplayID() == nil {
            _ = try? runCLI(["set", "-namelike=\(screenName)", "-connected=on"])
            if existingVirtualDisplayID() == nil {
                _ = try? runCLI(["create", "-virtualScreen", "-name=\(screenName)",
                                 "-resolution=\(pixelWidth)x\(pixelHeight)", "-hidpi=on"])
            }
        }
        _ = try? runCLI(["set", "-namelike=\(screenName)", "-resolution=\(pixelWidth)x\(pixelHeight)", "-hidpi=on"])

        // Poll CoreGraphics for the display to come online.
        for _ in 0 ..< 60 {
            if let id = existingVirtualDisplayID() { return id }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw VirtualDisplayError.didNotAppear
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
    private func runCLI(_ arguments: [String], timeout: TimeInterval = 8) throws -> Data {
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

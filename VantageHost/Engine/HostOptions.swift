import Foundation

/// Launch-argument driven options, mostly for headless testing.
///
/// - `--synthetic-capture`: stream a rendered test pattern instead of the real display.
/// - `--pairing-code 123456`: use a fixed pairing code instead of a random one.
/// - `--open-settings dictation`: open the Settings window on that tab at launch (screenshots).
nonisolated final class HostOptions: @unchecked Sendable {
    static let shared = HostOptions()

    let syntheticCapture: Bool
    let fixedPairingCode: String?
    let port: UInt16
    /// Settings tab to show at launch (DEBUG only).
    let openSettingsTab: String?

    private init() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        syntheticCapture = args.contains("--synthetic-capture")
        if let index = args.firstIndex(of: "--port"), index + 1 < args.count,
           let value = UInt16(args[index + 1]), value > 0 { port = value }
        else { port = 47820 }
        if let index = args.firstIndex(of: "--pairing-code"), index + 1 < args.count {
            fixedPairingCode = args[index + 1]
        } else {
            fixedPairingCode = nil
        }
        if let index = args.firstIndex(of: "--open-settings"), index + 1 < args.count {
            openSettingsTab = args[index + 1]
        } else {
            openSettingsTab = nil
        }
        #else
        syntheticCapture = false
        fixedPairingCode = nil
        port = 47820
        openSettingsTab = nil
        #endif
    }
}

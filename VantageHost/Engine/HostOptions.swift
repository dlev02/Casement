import Foundation
import VantageCore

/// Launch-argument driven options, mostly for headless testing.
///
/// - `--synthetic-capture`: stream a rendered test pattern instead of the real display.
/// - `--pairing-code 123456`: use a fixed pairing code instead of a random one.
/// - `--open-settings dictation|files`: open the Settings window on that tab at launch (screenshots).
/// - `--send-file-on-connect /path`: send that file to each client whose file channel attaches
///   (tests the Mac → iPad direction without the open panel).
/// - `--receive-folder /path`: save received files there instead of Downloads (or the synthetic
///   temp folder), so tests never touch the real Downloads.
/// - `--arrival-actions`: run the real arrival path (notification, on-screen notice, Finder) for a
///   synthetic host too; it's skipped there otherwise.
/// - `--preview-arrival /path[,/path…]`: show the on-screen arrival notice for those files at launch.
/// - `--appearance light|dark`: force the host's own windows into one appearance (screenshots).
/// - `--open-setup`: show the first-run setup window at launch as a preview: nothing it shows is
///   saved (setup isn't marked done, Start at Login isn't changed). Screenshots.
/// - `--open-menu`: show the menu bar popover's content in a window too (screenshots when the
///   menu bar is too crowded to show the item).
/// - `--log-input-events`: log the key events reaching the session (`InputEventLog`).
/// - `--exit-after 300`: quit after that many seconds, so a test host never outlives its run.
/// - `--display-asleep`: pretend the display starts asleep (`DisplayPower.fake`); synthetic hosts
///   then behave like a Mac whose screen is off until something wakes it.
/// - `--capture-fails-for 6`: each session's capture can't start for that many seconds after its
///   first stream request, as when ScreenCaptureKit lists no displays while the Mac is awake.
/// - `--synthetic-image /path.png`: a synthetic host streams that picture instead of the test
///   pattern, and its pretend display takes the picture's size at 2x (README screenshots).
/// - `--platform windows|macos`: the platform the host tells clients it runs (`HostPlatform`), so
///   the client can be tried against a pretend Windows PC. Any other value is sent as given.
///
/// Updates (none of this exists in a release build, and a Debug or synthetic host doesn't update
/// at all without a feed). Sparkle reads its public key only from Info.plist, so a test key is a
/// build setting (`CASEMENT_UPDATE_PUBLIC_KEY=…` on the xcodebuild line), not a flag.
/// - `--update-feed URL`: run the updater for real against this appcast.
/// - `--update-soon`: skip the waits (first check, five quiet minutes), not what they wait for.
/// - `--update-check-now`: check at launch as if Check for Updates had been pressed.
/// - `--update-restart-when-ready`: press Restart to Update as soon as it appears.
/// - `--preview-update uptodate|checking|downloading|preparing|ready|installing|manual|failed|off|none`:
///   show that state, with no updater running (screenshots). `none` is a copy that doesn't update.
///
/// A relaunch after an update loses the command line, so a DEBUG host also reads one argument per
/// line from `casement-host-test-arguments` beside its bundle, if that file exists.
nonisolated final class HostOptions: @unchecked Sendable {
    static let shared = HostOptions()

    let syntheticCapture: Bool
    let fixedPairingCode: String?
    let port: UInt16
    /// A client on this same Mac may raise the curtain (DEBUG only; for testing it). Real capture
    /// and input, with a throwaway identity and trust list, so a test never touches the Keychain.
    let allowsSelfCurtain: Bool
    /// Settings tab to show at launch (DEBUG only).
    let openSettingsTab: String?
    /// File to send to every client once its file channel attaches (DEBUG only).
    let sendFileOnConnect: String?
    /// Folder received files go to, overriding Settings (DEBUG only).
    let receiveFolder: String?
    /// Arrival actions run even in synthetic mode (DEBUG only).
    let arrivalActions: Bool
    /// Files to show the arrival notice for at launch (DEBUG only).
    let previewArrival: [String]
    /// "light" or "dark" (DEBUG only).
    let appearance: String?
    /// Also host the menu's content in a window at launch (DEBUG only).
    let openMenu: Bool
    /// Show the setup window as a preview at launch (DEBUG only).
    let openSetup: Bool
    /// Log key events with their flags through a listen-only tap (DEBUG only).
    let logInputEvents: Bool
    /// Quit this long after launch (DEBUG only).
    let exitAfterSeconds: Double?
    /// A pretend display that starts asleep (DEBUG only).
    let fakeDisplaySleep: Bool
    /// Seconds each session's capture fails for, from its first stream request (DEBUG only).
    let captureFailsForSeconds: Double?
    /// What the host tells clients it runs (`--platform`, DEBUG only; always macOS in release).
    let platform: HostPlatform
    /// A still picture a synthetic host streams instead of its test pattern (DEBUG only).
    let syntheticImage: String?
    /// The appcast to update from instead of the release feed (DEBUG only).
    let updateFeed: String?
    /// Skip the updater's waits (DEBUG only).
    let updateSoon: Bool
    /// Check for updates at launch as if asked (DEBUG only).
    let updateCheckNow: Bool
    /// Press Restart to Update when it appears (DEBUG only).
    let updateRestartWhenReady: Bool
    /// The Updates state to show, with no updater running (DEBUG only).
    let previewUpdate: String?

    private init() {
        #if DEBUG
        var args = ProcessInfo.processInfo.arguments
        let survivesRelaunch = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "casement-host-test-arguments")
        if let extra = try? String(contentsOf: survivesRelaunch, encoding: .utf8) {
            args += extra.split(whereSeparator: \.isNewline).map(String.init)
        }
        syntheticCapture = args.contains("--synthetic-capture")
        if let index = args.firstIndex(of: "--port"), index + 1 < args.count,
           let value = UInt16(args[index + 1]), value > 0 { port = value }
        else { port = 47820 }
        if let index = args.firstIndex(of: "--pairing-code"), index + 1 < args.count {
            fixedPairingCode = args[index + 1]
        } else {
            fixedPairingCode = nil
        }
        allowsSelfCurtain = args.contains("--allow-self-curtain")
        if let index = args.firstIndex(of: "--open-settings"), index + 1 < args.count {
            openSettingsTab = args[index + 1]
        } else {
            openSettingsTab = nil
        }
        if let index = args.firstIndex(of: "--send-file-on-connect"), index + 1 < args.count {
            sendFileOnConnect = args[index + 1]
        } else {
            sendFileOnConnect = nil
        }
        if let index = args.firstIndex(of: "--receive-folder"), index + 1 < args.count {
            receiveFolder = args[index + 1]
        } else {
            receiveFolder = nil
        }
        arrivalActions = args.contains("--arrival-actions")
        if let index = args.firstIndex(of: "--preview-arrival"), index + 1 < args.count {
            previewArrival = args[index + 1].split(separator: ",").map(String.init)
        } else {
            previewArrival = []
        }
        if let index = args.firstIndex(of: "--appearance"), index + 1 < args.count {
            appearance = args[index + 1]
        } else {
            appearance = nil
        }
        openMenu = args.contains("--open-menu")
        openSetup = args.contains("--open-setup")
        logInputEvents = args.contains("--log-input-events")
        if let index = args.firstIndex(of: "--exit-after"), index + 1 < args.count,
           let seconds = Double(args[index + 1]), seconds > 0 {
            exitAfterSeconds = seconds
        } else {
            exitAfterSeconds = nil
        }
        fakeDisplaySleep = args.contains("--display-asleep")
        if let index = args.firstIndex(of: "--capture-fails-for"), index + 1 < args.count,
           let seconds = Double(args[index + 1]), seconds > 0 {
            captureFailsForSeconds = seconds
        } else {
            captureFailsForSeconds = nil
        }
        if let index = args.firstIndex(of: "--platform"), index + 1 < args.count, !args[index + 1].isEmpty {
            platform = HostPlatform(rawValue: args[index + 1].lowercased())
        } else {
            platform = .macOS
        }
        if let index = args.firstIndex(of: "--synthetic-image"), index + 1 < args.count {
            syntheticImage = args[index + 1]
        } else {
            syntheticImage = nil
        }
        if let index = args.firstIndex(of: "--update-feed"), index + 1 < args.count {
            updateFeed = args[index + 1]
        } else {
            updateFeed = nil
        }
        updateSoon = args.contains("--update-soon")
        updateCheckNow = args.contains("--update-check-now")
        updateRestartWhenReady = args.contains("--update-restart-when-ready")
        if let index = args.firstIndex(of: "--preview-update"), index + 1 < args.count {
            previewUpdate = args[index + 1]
        } else {
            previewUpdate = nil
        }
        #else
        syntheticCapture = false
        fixedPairingCode = nil
        port = 47820
        allowsSelfCurtain = false
        openSettingsTab = nil
        sendFileOnConnect = nil
        receiveFolder = nil
        arrivalActions = false
        previewArrival = []
        appearance = nil
        openMenu = false
        openSetup = false
        logInputEvents = false
        exitAfterSeconds = nil
        fakeDisplaySleep = false
        captureFailsForSeconds = nil
        platform = .macOS
        syntheticImage = nil
        updateFeed = nil
        updateSoon = false
        updateCheckNow = false
        updateRestartWhenReady = false
        previewUpdate = nil
        #endif
    }
}

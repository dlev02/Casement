import Foundation

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
/// - `--open-menu`: show the menu bar popover's content in a window too (screenshots when the
///   menu bar is too crowded to show the item).
/// - `--log-input-events`: log the key events reaching the session (`InputEventLog`).
/// - `--exit-after 300`: quit after that many seconds, so a test host never outlives its run.
/// - `--display-asleep`: pretend the display starts asleep (`DisplayPower.fake`); synthetic hosts
///   then behave like a Mac whose screen is off until something wakes it.
/// - `--capture-fails-for 6`: each session's capture can't start for that many seconds after its
///   first stream request, as when ScreenCaptureKit lists no displays while the Mac is awake.
nonisolated final class HostOptions: @unchecked Sendable {
    static let shared = HostOptions()

    let syntheticCapture: Bool
    let fixedPairingCode: String?
    let port: UInt16
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
    /// Log key events with their flags through a listen-only tap (DEBUG only).
    let logInputEvents: Bool
    /// Quit this long after launch (DEBUG only).
    let exitAfterSeconds: Double?
    /// A pretend display that starts asleep (DEBUG only).
    let fakeDisplaySleep: Bool
    /// Seconds each session's capture fails for, from its first stream request (DEBUG only).
    let captureFailsForSeconds: Double?

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
        #else
        syntheticCapture = false
        fixedPairingCode = nil
        port = 47820
        openSettingsTab = nil
        sendFileOnConnect = nil
        receiveFolder = nil
        arrivalActions = false
        previewArrival = []
        appearance = nil
        openMenu = false
        logInputEvents = false
        exitAfterSeconds = nil
        fakeDisplaySleep = false
        captureFailsForSeconds = nil
        #endif
    }
}

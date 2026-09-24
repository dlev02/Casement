#if os(macOS)
import AppKit
import Observation
import os

/// The Mac client's answer to iOS's background transfer task: a Mac app keeps running in the
/// background anyway, but App Nap throttles it and idle sleep stops it.
///
/// - While files move to or from any Mac, a `.userInitiated` activity keeps the Mac from idle
///   sleeping mid-transfer (display sleep is still allowed).
/// - While a screen session is up, a `.userInitiatedAllowingIdleSystemSleep` activity keeps App
///   Nap from throttling the session's timers and network when its window is hidden.
/// - After the Mac wakes, every Mac with files waiting tries again at once
///   (`FileTransferCenter.retryAll`), picking up from the partial files, instead of waiting out a
///   backoff that slept along with the machine.
///
/// Start it once from the app root: `MacTransferActivity.shared.start()`.
@MainActor
final class MacTransferActivity {
    static let shared = MacTransferActivity()

    private let center: FileTransferCenter
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "files")
    private var filesActivity: (any NSObjectProtocol)?
    private var sessionActivity: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?
    private var watching = false

    init(center: FileTransferCenter = .shared) {
        self.center = center
    }

    /// Starts following transfers and sessions (once, at launch).
    func start() {
        guard !watching else { return }
        watching = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        watch()
    }

    /// Re-armed on every change to what it reads (Observation fires once per registration).
    private func watch() {
        let (filesMoving, sessionUp) = withObservationTracking {
            let summary = center.overallSummary
            return (summary.isActive && !summary.isPaused, center.links.values.contains { $0.screen != .none })
        } onChange: { [weak self] in
            Task { @MainActor in self?.watch() }
        }
        update(filesMoving: filesMoving, sessionUp: sessionUp)
    }

    private func update(filesMoving: Bool, sessionUp: Bool) {
        let info = ProcessInfo.processInfo
        if filesMoving, filesActivity == nil {
            filesActivity = info.beginActivity(options: .userInitiated, reason: "Moving files with a Mac")
            log.info("files moving: holding off idle sleep")
        } else if !filesMoving, let activity = filesActivity {
            info.endActivity(activity)
            filesActivity = nil
            log.info("files settled: idle sleep allowed again")
        }
        if sessionUp, sessionActivity == nil {
            sessionActivity = info.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Connected to a Mac")
        } else if !sessionUp, let activity = sessionActivity {
            info.endActivity(activity)
            sessionActivity = nil
        }
    }

    private func didWake() {
        guard center.hasActiveTransfers else { return }
        log.info("woke with files waiting; retrying now")
        center.retryAll()
    }
}
#endif

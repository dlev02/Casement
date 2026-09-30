#if os(iOS)
import BackgroundTasks
import Observation
import UIKit
import os

/// Keeps files moving while Vantage is in the background.
///
/// When a run of files starts in the foreground (big enough to be worth it), this submits a
/// `BGContinuedProcessingTask` (iOS 26): the system keeps the app running after it's backgrounded
/// and shows the progress, which this reports from every Mac's transfers, in a Live Activity the
/// person can stop. The task ends when the files do. If the system expires it (or the person
/// stops it), the file channels close cleanly: both sides keep their partial files, and everything
/// resumes where it stopped when Vantage is back in the foreground (`FileTransferCenter.retryAll`).
///
/// Identifiers are `com.benjaminlevinson.vantage.transfers.<UUID>`, under the wildcard in
/// `BGTaskSchedulerPermittedIdentifiers`; each is registered just before it's submitted (continued
/// processing tasks are exempt from registering at launch). Where the task can't run (the
/// simulator, background work turned off, a refused submission) the usual ~30 s of background time
/// (`beginBackgroundTask`) lets the current chunk land before the same clean pause.
@MainActor
final class TransferBackgroundActivity {
    static let shared = TransferBackgroundActivity()
    static let identifierPrefix = "com.benjaminlevinson.vantage.transfers."
    /// Runs smaller than this finish in the foreground before a Live Activity would help.
    static let minimumBytes: UInt64 = 32 << 20

    private let center: FileTransferCenter
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "files")
    private var task: BGContinuedProcessingTask?
    /// Submitted and not finished yet (it may still be waiting to start).
    private var submitted: String?
    /// This run already asked (once per run, whether or not the system said yes).
    private var askedThisRun = false
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var lastTitleUpdate = ContinuousClock.now - .seconds(10)
    private var isActive = true
    private var watching = false

    init(center: FileTransferCenter = .shared) {
        self.center = center
    }

    /// Starts following the transfers (once, at launch).
    func start() {
        guard !watching else { return }
        watching = true
        watch()
    }

    /// Follows every Mac's run through Observation: each change re-arms the watch.
    private func watch() {
        let progress = withObservationTracking { center.overallSummary } onChange: { [weak self] in
            Task { @MainActor in self?.watch() }
        }
        update(progress)
    }

    private func update(_ summary: FileTransferController.Summary) {
        if summary.isActive {
            if !askedThisRun, isActive, summary.bytes >= Self.minimumBytes || summary.count > 20 {
                askedThisRun = true
                submit(summary)
            }
            report(summary)
        } else {
            finish(success: summary.failed == 0)
        }
    }

    // MARK: Continued processing

    private func submit(_ summary: FileTransferController.Summary) {
        let identifier = Self.identifierPrefix + UUID().uuidString
        // The handler runs on the main queue (`using: .main`), so it can hand the task straight
        // to the main actor.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { @Sendable task in
            nonisolated(unsafe) let task = task
            MainActor.assumeIsolated { TransferBackgroundActivity.shared.started(task, identifier: identifier) }
        }
        guard registered else {
            log.error("background transfers: identifier not permitted (BGTaskSchedulerPermittedIdentifiers)")
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title(summary), subtitle: subtitle(summary))
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            submitted = identifier
            log.info("background transfers: submitted a continued processing task")
        } catch {
            // The simulator, Background App Refresh off, or too many tasks: the grace period
            // covers what it can.
            log.error("background transfers: submit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func started(_ bgTask: BGTask, identifier: String) {
        guard let bgTask = bgTask as? BGContinuedProcessingTask else {
            bgTask.setTaskCompleted(success: false)
            return
        }
        // A queued task that starts after the files already finished has nothing to do.
        guard submitted == identifier, center.overallSummary.isActive else {
            bgTask.setTaskCompleted(success: true)
            if submitted == identifier { submitted = nil }
            return
        }
        bgTask.expirationHandler = { @Sendable in
            Task { @MainActor in TransferBackgroundActivity.shared.expired(identifier) }
        }
        task = bgTask
        log.info("background transfers: continued processing task running")
        report(center.overallSummary)
    }

    private func report(_ summary: FileTransferController.Summary) {
        guard let task else { return }
        task.progress.totalUnitCount = Int64(clamping: max(summary.bytes, 1))
        task.progress.completedUnitCount = Int64(clamping: min(summary.bytesDone, summary.bytes))
        if ContinuousClock.now - lastTitleUpdate >= .seconds(1) {
            lastTitleUpdate = .now
            task.updateTitle(title(summary), subtitle: subtitle(summary))
        }
    }

    /// The system (or the person, from the Live Activity) stopped the task: pause every channel
    /// cleanly so the files resume later instead of failing.
    private func expired(_ identifier: String) {
        guard submitted == identifier else { return }
        log.info("background transfers: the system ended the task; pausing until the app is back")
        pauseAll()
        task?.setTaskCompleted(success: false)
        task = nil
        submitted = nil
    }

    private func finish(success: Bool) {
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
            log.info("background transfers: done")
        } else if let submitted {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: submitted)
        }
        task = nil
        submitted = nil
        askedThisRun = false
        endGrace()
    }

    // MARK: App state

    func appDidEnterBackground() {
        isActive = false
        guard center.overallSummary.isActive, task == nil, grace == .invalid else { return }
        // No continued processing task (yet): the ordinary background grace, then a clean pause.
        // UIKit calls this on the main thread and wants the task ended before it returns.
        grace = UIApplication.shared.beginBackgroundTask(withName: "Porthole file transfers") { @Sendable in
            MainActor.assumeIsolated {
                let activity = TransferBackgroundActivity.shared
                if activity.task == nil {
                    activity.log.info("background transfers: background time ran out; pausing until the app is back")
                    activity.pauseAll()
                }
                activity.endGrace()
            }
        }
    }

    func appDidBecomeActive() {
        isActive = true
        endGrace()
        center.retryAll()
        update(center.overallSummary)
    }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    private func pauseAll() {
        for link in center.links.values where link.files.hasActiveTransfers { link.pause() }
    }

    // MARK: Words

    private func title(_ summary: FileTransferController.Summary) -> String {
        let busy = center.links.values.filter { $0.files.hasActiveTransfers }
        let mac = busy.count == 1 ? busy.first?.macName : nil
        if summary.receiving == 0 { return mac.map { "Sending files to \($0)" } ?? "Sending files" }
        if summary.sending == 0 { return mac.map { "Receiving files from \($0)" } ?? "Receiving files" }
        return mac.map { "Moving files with \($0)" } ?? "Moving files"
    }

    private func subtitle(_ summary: FileTransferController.Summary) -> String {
        var parts: [String] = []
        if summary.count > 1 { parts.append("\(summary.position) of \(summary.count)") }
        parts.append("\(TransferFormat.bytes(summary.bytesLeft)) left")
        if let seconds = summary.secondsRemaining { parts.append(TransferFormat.duration(seconds)) }
        return parts.joined(separator: " · ")
    }
}
#endif

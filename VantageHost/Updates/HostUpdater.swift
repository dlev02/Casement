import AppKit
import Observation
import Sparkle
import os

/// Keeps Casement Host current through Sparkle, on the Windows host's terms: a check two minutes
/// after launch and then daily while Install Updates Automatically is on (off means no background
/// network at all), and an unattended restart only after five quiet minutes.
///
/// Sparkle checks a release's EdDSA signature and the signed feed (`SURequireSignedFeed`,
/// `SUVerifyUpdateBeforeExtraction` in Info.plist), downloads, unpacks, and swaps the bundle. This
/// class is its user driver and delegate, so Sparkle never shows a window of its own: what it
/// reports becomes `stage`, which Settings and the menu show. `UpdatePolicy` decides when things
/// happen. A copy that can't replace itself only reads the feed (`checkForUpdateInformation`), so it
/// never asks for a password, and says to download the new version by hand.
@MainActor
@Observable
final class HostUpdater: NSObject {
    static let shared = HostUpdater()

    static let automaticKey = "updates.installAutomatically"
    static let lastCheckKey = "updates.lastCheck"
    /// Where a copy that can't replace itself sends people.
    static let downloadURL = URL(string: "https://github.com/dlev02/Casement/releases/latest")!
    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    /// Where things stand.
    private(set) var stage: UpdateStage = .idle
    /// This copy updates itself (a Debug host doesn't, unless given a test feed).
    private(set) var isAvailable = false
    private(set) var lastCheck = UserDefaults.standard.object(forKey: HostUpdater.lastCheckKey) as? Date

    /// Install Updates Automatically, on by default.
    var installsAutomatically = UserDefaults.standard.object(forKey: HostUpdater.automaticKey) as? Bool ?? true {
        didSet {
            #if DEBUG
            // A preview is only a picture: it leaves the real setting alone.
            guard HostOptions.shared.previewUpdate == nil else { return }
            #endif
            UserDefaults.standard.set(installsAutomatically, forKey: Self.automaticKey)
            sparkle?.automaticallyDownloadsUpdates = installsAutomatically
            log.info("install updates automatically: \(self.installsAutomatically, privacy: .public)")
        }
    }

    var row: UpdateRow {
        guard isAvailable else { return UpdateRow(status: "This build doesn't update itself.", action: .none) }
        return UpdateRow.for(stage, automatic: installsAutomatically, lastCheck: lastCheck)
    }

    @ObservationIgnored private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "updates")
    @ObservationIgnored private var sparkle: SPUUpdater?
    @ObservationIgnored private weak var controller: HostController?
    @ObservationIgnored private var canReplaceItself = true
    /// The version on offer, once the feed has named one.
    @ObservationIgnored private var offeredVersion = ""
    /// Restarts into the update; set only while `stage` is `.ready`.
    @ObservationIgnored private var install: (() -> Void)?
    @ObservationIgnored private var cancelInFlight: (() -> Void)?
    @ObservationIgnored private var expectedBytes: UInt64 = 0
    @ObservationIgnored private var receivedBytes: UInt64 = 0
    @ObservationIgnored private var startedAt = Date.now
    @ObservationIgnored private var lastBusyAt = Date.now
    @ObservationIgnored private var nextCheckAllowed = Date.distantPast
    @ObservationIgnored private var tick: Task<Void, Never>?

    func start(controller: HostController) {
        self.controller = controller
        #if DEBUG
        if let preview = HostOptions.shared.previewUpdate {
            isAvailable = preview != "none"
            showPreview(preview)
            return
        }
        // Debug and synthetic hosts leave updates alone unless a test asks for them.
        guard HostOptions.shared.updateFeed != nil else { return }
        #endif
        canReplaceItself = Self.bundleCanBeReplaced()
        let sparkle = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        sparkle.sendsSystemProfile = false
        sparkle.automaticallyDownloadsUpdates = installsAutomatically
        do {
            try sparkle.start()
        } catch {
            log.error("the updater couldn't start: \(Self.describe(error), privacy: .public)")
            stage = .failed(message: error.localizedDescription)
            return
        }
        self.sparkle = sparkle
        isAvailable = true
        startedAt = .now
        lastBusyAt = startedAt
        log.info("""
            version \(Self.currentVersion, privacy: .public) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?", privacy: .public)), \
            automatic \(self.installsAutomatically, privacy: .public), can replace itself \(self.canReplaceItself, privacy: .public), \
            screen recording \(controller.hasScreenPermission, privacy: .public), accessibility \(controller.hasInputPermission, privacy: .public)
            """)
        tick = Task { [weak self] in
            while !Task.isCancelled {
                self?.onTick()
                #if DEBUG
                let interval = HostOptions.shared.updateSoon ? 2.0 : 30.0
                #else
                let interval = 30.0
                #endif
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
        #if DEBUG
        if HostOptions.shared.updateCheckNow { checkNow() }
        #endif
    }

    /// The Updates row's button or the menu's row.
    func perform(_ action: UpdateRowAction) {
        switch action {
        case .none: break
        case .check, .tryAgain: checkNow()
        case .restart: restartToUpdate()
        case .download: NSWorkspace.shared.open(Self.downloadURL)
        }
    }

    // MARK: Checking

    /// Someone asked. This is the only way a check happens with the setting off.
    private func checkNow() {
        guard let sparkle, !sparkle.sessionInProgress else { return }
        log.info("checking for updates: asked")
        stage = .checking
        if canReplaceItself {
            sparkle.checkForUpdates()
        } else {
            sparkle.checkForUpdateInformation()
        }
    }

    private func checkInBackground() {
        guard let sparkle, !sparkle.sessionInProgress else { return }
        log.info("checking for updates: scheduled")
        stage = .checking
        if canReplaceItself {
            sparkle.checkForUpdatesInBackground()
        } else {
            sparkle.checkForUpdateInformation()
        }
    }

    private func onTick() {
        let now = Date.now
        var activity = controller?.updateActivity ?? UpdateActivity()
        activity.windowOpen = Self.aWindowIsOpen
        if !activity.isClear { lastBusyAt = now }
        let lastBusy = max(lastBusyAt, controller?.lastConnectionEndedAt ?? .distantPast)
        var quietFor = now.timeIntervalSince(lastBusy)
        var sinceLaunch = now.timeIntervalSince(startedAt)
        #if DEBUG
        if HostOptions.shared.updateSoon {
            quietFor = UpdatePolicy.quietBeforeInstall
            sinceLaunch = UpdatePolicy.firstCheckDelay
        }
        #endif
        switch stage {
        case .ready:
            #if DEBUG
            if HostOptions.shared.updateRestartWhenReady { restartToUpdate(); return }
            #endif
            if UpdatePolicy.mayInstallUnattended(automatic: installsAutomatically, activity: activity, quietFor: quietFor) {
                log.info("nothing going on for \(Int(quietFor), privacy: .public) s: installing")
                installNow()
            } else if !activity.isClear {
                log.debug("""
                    update waits: \(activity.connections, privacy: .public) connections, \
                    \(activity.activeTransfers, privacy: .public) transfers, pairing \(activity.showingPairingCode, privacy: .public), \
                    window \(activity.windowOpen, privacy: .public)
                    """)
            }
        case .checking, .downloading, .preparing, .installing:
            break
        case .idle, .upToDate, .manualOnly, .failed:
            guard now >= nextCheckAllowed,
                  UpdatePolicy.shouldCheck(automatic: installsAutomatically, sinceLaunch: sinceLaunch, lastCheck: lastCheck, now: now)
            else { return }
            nextCheckAllowed = now.addingTimeInterval(60)
            checkInBackground()
        }
    }

    private func checkAnswered() {
        lastCheck = .now
        UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
    }

    // MARK: Installing

    /// Restart to Update, which asks first if anything is using the host.
    private func restartToUpdate() {
        guard case .ready = stage else { return }
        let activeFiles = controller?.updateActivity.activeTransfers ?? 0
        let devices = controller?.connectedDevices.map(\.name) ?? []
        if let warning = UpdateRow.restartWarning(connectedDevices: devices, movingFiles: activeFiles) {
            log.info("asking before restarting: \(devices.count, privacy: .public) connected, \(activeFiles, privacy: .public) files")
            let alert = NSAlert()
            alert.messageText = "Restart Casement Host to Update?"
            alert.informativeText = warning
            alert.addButton(withTitle: "Restart to Update")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else {
                log.info("restart to update cancelled")
                return
            }
        }
        installNow()
    }

    private func installNow() {
        guard case .ready(let version) = stage else { return }
        log.info("restarting into \(version, privacy: .public)")
        stage = .installing(version: version)
        let run = install
        install = nil
        run?()
    }

    // MARK: Failures

    private func finish(with error: Error) {
        // Sparkle reports one failure to both the delegate and the user driver.
        switch stage {
        case .idle, .upToDate, .manualOnly, .failed: return
        case .checking, .downloading, .preparing, .ready, .installing: break
        }
        let error = error as NSError
        log.error("update stopped: \(Self.describe(error), privacy: .public)")
        install = nil
        cancelInFlight = nil
        guard error.domain == SUSparkleErrorDomain else {
            fail(error)
            return
        }
        switch Int32(error.code) {
        case Int32(SUError.noUpdateError.rawValue):
            checkAnswered()
            stage = .upToDate
        case Int32(SUError.installationCanceledError.rawValue):
            stage = .idle
        case Int32(SUError.installationAuthorizeLaterError.rawValue), Int32(SUError.installationWriteNoPermissionError.rawValue):
            // Sparkle found out what `bundleCanBeReplaced` couldn't.
            canReplaceItself = false
            checkAnswered()
            stage = .manualOnly(version: offeredVersion)
        default:
            if case .checking = stage, Self.isNotFound(error) {
                // A release without an appcast (Windows only, say) offers nothing to a Mac.
                log.info("the latest release has no appcast")
                checkAnswered()
                stage = .upToDate
            } else {
                fail(error)
            }
        }
    }

    private func fail(_ error: NSError) {
        nextCheckAllowed = Date.now.addingTimeInterval(UpdatePolicy.retryAfterFailure)
        stage = .failed(message: error.localizedDescription)
    }

    /// Sparkle has no field for the HTTP status: its downloader ends the innermost error's message
    /// with "(404)". If that wording ever changes this reads as a failed check, which is safe.
    private static func isNotFound(_ error: NSError) -> Bool {
        var current: NSError? = error
        while let next = current {
            if next.domain == SUSparkleErrorDomain, next.code == SUError.downloadError.rawValue, next.localizedDescription.hasSuffix("(404)") { return true }
            current = next.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        var text = "\(error.domain) \(error.code): \(error.localizedDescription)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " (\(underlying.domain) \(underlying.code): \(underlying.localizedDescription))"
        }
        return text
    }

    // MARK: This copy

    /// Any window of ours on screen: the menu, Settings, the setup window. The menu bar item's own
    /// window is always there and doesn't count.
    private static var aWindowIsOpen: Bool {
        NSApp.windows.contains { $0.isVisible && !String(describing: type(of: $0)).contains("StatusBar") }
    }

    private static func bundleCanBeReplaced() -> Bool {
        let bundle = Bundle.main.bundleURL
        let files = FileManager.default
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return UpdatePolicy.canReplaceItself(bundlePath: bundle.path(percentEncoded: false),
                                             parentIsWritable: files.isWritableFile(atPath: bundle.deletingLastPathComponent().path(percentEncoded: false)),
                                             bundleIsWritable: files.isWritableFile(atPath: bundle.path(percentEncoded: false)),
                                             volumeIsReadOnly: readOnly)
    }

    #if DEBUG
    /// `--preview-update`: a state to look at, with no updater behind it.
    private func showPreview(_ name: String) {
        let version = "1.5"
        lastCheck = .now
        switch name {
        case "checking": stage = .checking
        case "downloading": stage = .downloading(version: version, fraction: 0.42)
        case "preparing": stage = .preparing(version: version)
        case "ready": stage = .ready(version: version)
        case "installing": stage = .installing(version: version)
        case "manual": stage = .manualOnly(version: version)
        case "failed": stage = .failed(message: "The update is improperly signed and could not be validated.")
        case "off":
            lastCheck = nil
            installsAutomatically = false
        default: stage = .upToDate
        }
    }
    #endif
}

// MARK: - What Sparkle reports, whoever asked

extension HostUpdater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        HostOptions.shared.updateFeed
        #else
        nil
        #endif
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        offeredVersion = item.displayVersionString
        log.info("the feed offers \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
        if !canReplaceItself {
            log.info("this copy can't replace itself: offering the download")
            checkAnswered()
            stage = .manualOnly(version: offeredVersion)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        log.info("no newer version on offer")
        checkAnswered()
        stage = .upToDate
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        offeredVersion = item.displayVersionString
        log.info("downloading \(request.url?.absoluteString ?? "?", privacy: .public)")
        checkAnswered()
        stage = .downloading(version: offeredVersion, fraction: nil)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        log.error("the download failed: \(Self.describe(error), privacy: .public)")
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        log.info("downloaded; verifying and unpacking")
        stage = .preparing(version: item.displayVersionString)
    }

    /// The background path's end: downloaded, verified and unpacked. Sparkle would install on quit;
    /// holding on to this block lets the policy pick the moment, with no alert from Sparkle.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        log.info("\(item.displayVersionString, privacy: .public) is ready")
        install = immediateInstallHandler
        stage = .ready(version: item.displayVersionString)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        finish(with: error)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        log.info("relaunching")
    }
}

// MARK: - Sparkle's questions and progress, without its windows

extension HostUpdater: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Never reached (SUEnableAutomaticChecks settles it): the schedule above is ours.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        cancelInFlight = cancellation
        stage = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        offeredVersion = appcastItem.displayVersionString
        if state.stage == .installing {
            // Already staged by an earlier run of the driver: it only needs its moment.
            install = { reply(.install) }
            stage = .ready(version: offeredVersion)
        } else if appcastItem.isInformationOnlyUpdate {
            reply(.dismiss)
            stage = .manualOnly(version: offeredVersion)
        } else {
            reply(.install)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        cancelInFlight = nil
        checkAnswered()
        stage = .upToDate
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        finish(with: error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        cancelInFlight = cancellation
        expectedBytes = 0
        receivedBytes = 0
        stage = .downloading(version: offeredVersion, fraction: 0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        guard expectedBytes > 0 else { return }
        stage = .downloading(version: offeredVersion, fraction: min(1, Double(receivedBytes) / Double(expectedBytes)))
    }

    func showDownloadDidStartExtractingUpdate() {
        cancelInFlight = nil
        stage = .preparing(version: offeredVersion)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log.info("\(self.offeredVersion, privacy: .public) is ready")
        install = { reply(.install) }
        stage = .ready(version: offeredVersion)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        log.info("installing; application terminated: \(applicationTerminated, privacy: .public)")
        stage = .installing(version: offeredVersion)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        cancelInFlight = nil
        // The end of every cycle: a result stays up; only something still under way resets.
        switch stage {
        case .checking, .downloading, .preparing, .installing: stage = .idle
        default: break
        }
    }
}

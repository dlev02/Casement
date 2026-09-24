import AppKit
import Foundation
import VantageCore
import os

/// What the Mac does as files come and go, driven by the controller's transfer events:
///
/// - Arrivals are batched (`ArrivalBatcher`): files that land together get one notification, one
///   on-screen notice, and one Finder window selecting all of them.
/// - What happens to a batch follows Settings → Files (`ArrivalPlan`). A synthetic host skips all
///   of it unless it runs with `--arrival-actions`.
@MainActor
final class FileArrivals {
    /// An iPad is streaming this Mac's screen, so macOS counts the screen as shared.
    var isViewedRemotely: () -> Bool = { false }

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "files")
    private var batcher = ArrivalBatcher()
    private var flush: Task<Void, Never>?

    private var actsOnArrivals: Bool {
        !HostOptions.shared.syntheticCapture || HostOptions.shared.arrivalActions
    }

    func started(_ transfer: HostTransfer) {
        guard transfer.direction == .receiving else { return }
        batcher.started(transfer.id, at: .now)
        scheduleFlush()
    }

    func finished(_ transfer: HostTransfer, _ outcome: FileTransferOutcome) {
        switch outcome {
        case .received(let url):
            batcher.arrived(transfer.id, .init(url: url, device: transfer.deviceName, byteCount: transfer.byteCount), at: .now)
            if !actsOnArrivals {
                log.info("synthetic host saved a received file at \(url.path(percentEncoded: false), privacy: .public)")
            }
        case .sent:
            if actsOnArrivals { HostNotifications.shared.sent(transfer.name, to: transfer.deviceName) }
        case .failed(let reason):
            batcher.ended(transfer.id, at: .now)
            if actsOnArrivals {
                HostNotifications.shared.failed(transfer.name, sending: transfer.direction == .sending,
                                                device: transfer.deviceName, reason: reason)
            }
        case .cancelled:
            batcher.ended(transfer.id, at: .now)
        }
        scheduleFlush()
    }

    // MARK: Batches

    private func scheduleFlush() {
        flush?.cancel()
        guard let deadline = batcher.deadline else { return }
        flush = Task { @MainActor in
            let wait = max(0, deadline.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            self.flushIfReady()
        }
    }

    private func flushIfReady() {
        guard let batch = batcher.takeBatch(now: .now) else {
            scheduleFlush()
            return
        }
        scheduleFlush()
        guard actsOnArrivals else { return }
        Task { await deliver(batch) }
    }

    private func deliver(_ batch: [ArrivalBatcher.Arrival]) async {
        let files = batch.map(\.url)
        guard let folder = files.first?.deletingLastPathComponent() else { return }
        let settings = FileArrivalSettings(defaults: .standard)
        let viewed = isViewedRemotely()
        let bannersShow = viewed ? await HostNotifications.shared.bannersShowWhileShared() : true
        let plan = ArrivalPlan.make(files: files, settings: settings, viewedRemotely: viewed, bannersShowWhileShared: bannersShow)
        let summary = ArrivalSummary(files: files, devices: batch.map(\.device),
                                     folderName: FileManager.default.displayName(atPath: folder.path(percentEncoded: false)),
                                     isDownloads: folder.standardizedFileURL.path == HostFileStore.downloads.standardizedFileURL.path,
                                     notOpenedCount: plan.notOpened.count, tooManyToOpen: plan.tooManyToOpen)
        log.info("\(files.count, privacy: .public) received file(s): notify \(plan.notify, privacy: .public), on screen \(plan.showOnScreen, privacy: .public) (watched \(viewed, privacy: .public), banners while shared \(bannersShow, privacy: .public)), reveal \(plan.reveal.count, privacy: .public), open \(plan.open.count, privacy: .public)")

        if !plan.open.isEmpty { open(plan.open) }
        if !plan.reveal.isEmpty { HostNotifications.reveal(plan.reveal) }
        if plan.notify { HostNotifications.shared.received(summary, files: files) }
        if plan.showOnScreen { ArrivalNotice.shared.show(summary, files: files) }
    }

    /// Opens files in their usual apps, several of the same kind in one go (Preview gets one window).
    private func open(_ urls: [URL]) {
        var byApp: [URL: [URL]] = [:]
        var unclaimed: [URL] = []
        for url in urls {
            if let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
                byApp[app, default: []].append(url)
            } else {
                unclaimed.append(url)
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let log = log
        for (app, files) in byApp {
            NSWorkspace.shared.open(files, withApplicationAt: app, configuration: configuration) { _, error in
                if let error { log.error("couldn't open received files: \(error.localizedDescription, privacy: .public)") }
            }
        }
        if !unclaimed.isEmpty { HostNotifications.reveal(unclaimed) }
    }
}

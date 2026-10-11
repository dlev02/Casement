import AppKit
import Foundation
import QuickLookThumbnailing
import UserNotifications
import os

/// File transfer notifications on the Mac: "Received Report.pdf" (one per batch, with a preview
/// and Show in Finder), and the outcome of files sent to the iPad. Asks for permission the first
/// time it has something to say, not at launch.
///
/// macOS mutes banners while the screen is mirrored or shared unless the user allows them in
/// System Settings → Notifications ("Allow notifications when mirroring or sharing the display",
/// off by default), and ScreenCaptureKit capture counts as sharing: every banner posted while an
/// iPad watches lands silently in Notification Center ("muted by display state (displayShared)"
/// in NotificationCenter's log). `bannersShowWhileShared()` tells the arrival path when to show
/// its own on-screen notice instead.
@MainActor
final class HostNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = HostNotifications()

    /// How a notification from Vantage Host reaches the user right now.
    enum Delivery: Equatable {
        /// Banners (or alerts) show, even while an iPad is watching.
        case banners
        /// Banners show, except while the screen is shared, which is whenever an iPad is watching.
        case hiddenWhileSharing
        /// Turned off, or delivered quietly to Notification Center only.
        case off
        /// Not asked yet; macOS asks with the first file.
        case notAsked
    }

    private static let receivedCategory = "vantage.fileReceived"
    private nonisolated static let showInFinderAction = "vantage.showInFinder"
    private nonisolated static let pathsKey = "paths"
    /// Notifications posted before batches carried one path.
    private nonisolated static let legacyPathKey = "path"
    private static let threadIdentifier = "vantage.files"
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "files")
    private var didSetUp = false

    /// Installs the delegate so a click on a notification works even after a relaunch.
    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let show = UNNotificationAction(identifier: Self.showInFinderAction, title: "Show in Finder", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.receivedCategory, actions: [show], intentIdentifiers: []),
        ])
    }

    /// One notification for a batch of received files; its action selects all of them in Finder.
    func received(_ summary: ArrivalSummary, files: [URL]) {
        let paths = files.map { $0.path(percentEncoded: false) }
        let preview = files.count == 1 ? files.first : nil
        post(title: summary.notificationTitle, body: summary.notificationBody, category: Self.receivedCategory,
             userInfo: [Self.pathsKey: paths], preview: preview)
    }

    func sent(_ name: String, to device: String, destination: String? = nil) {
        let body = destination == "Downloads" ? "It's in Downloads on \(device)." : "It's in Files on \(device), in the Porthole folder."
        post(title: "Sent \(name)", body: body, category: nil, userInfo: [:])
    }

    func failed(_ name: String, sending: Bool, device: String, reason: String) {
        post(title: sending ? "Couldn't Send \(name)" : "Couldn't Receive \(name)",
             body: sending ? "\(device): \(reason)" : reason, category: nil, userInfo: [:])
    }

    /// Whether a banner would be seen while an iPad is watching this Mac's screen.
    func bannersShowWhileShared() async -> Bool {
        await delivery() == .banners
    }

    func delivery() async -> Delivery {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notAsked
        case .authorized: break
        default: return .off
        }
        guard settings.alertSetting == .enabled, settings.alertStyle != .none else { return .off }
        return SharingNotificationPreference.allowsBannersWhileSharing ? .banners : .hiddenWhileSharing
    }

    /// Asks macOS to allow notifications now, rather than with the first file.
    func requestPermission() async {
        didSetUp = true
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("notification permission: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// System Settings → Notifications: the top of the pane has "Allow notifications when mirroring
    /// or sharing the display"; with `forThisApp`, Vantage Host's own page instead.
    func openSystemSettings(forThisApp: Bool) {
        var address = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if forThisApp, let bundleID = Bundle.main.bundleIdentifier { address += "?id=\(bundleID)" }
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    private func post(title: String, body: String, category: String?, userInfo: [String: Any], preview: URL? = nil) {
        let userInfo = NotificationUserInfo(value: userInfo)
        Task {
            let center = UNUserNotificationCenter.current()
            if !didSetUp {
                didSetUp = true
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                } catch {
                    log.error("notification permission: \(error.localizedDescription, privacy: .public)")
                }
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = userInfo.value
            content.threadIdentifier = Self.threadIdentifier
            if let category { content.categoryIdentifier = category }
            if let preview, let attachment = await Self.thumbnailAttachment(for: preview) {
                content.attachments = [attachment]
            }
            do {
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            } catch {
                log.error("couldn't post a notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A preview of the file for the notification. The system moves an attachment into its own
    /// store, so it gets a thumbnail written to a temp file, never the received file itself.
    private static func thumbnailAttachment(for url: URL) async -> UNNotificationAttachment? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 256, height: 256), scale: 2,
                                                   representationTypes: .thumbnail)
        guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
              let png = NSBitmapImageRep(cgImage: thumbnail.cgImage).representation(using: .png, properties: [:])
        else { return nil }
        let file = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "vantage-preview-\(UUID().uuidString).png")
        do {
            try png.write(to: file)
            return try UNNotificationAttachment(identifier: "preview", url: file,
                                                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.png"])
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let paths = info[Self.pathsKey] as? [String] ?? (info[Self.legacyPathKey] as? String).map { [$0] } ?? []
        guard !paths.isEmpty,
              response.actionIdentifier == Self.showInFinderAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        await MainActor.run { Self.reveal(paths.map { URL(fileURLWithPath: $0) }) }
    }

    /// Selects the files that are still there in Finder, or opens the folder they were in.
    static func reveal(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        if existing.isEmpty, let folder = urls.first?.deletingLastPathComponent() {
            NSWorkspace.shared.open(folder)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }
}

/// `userInfo` is plist values only; this carries it into the posting task.
private struct NotificationUserInfo: @unchecked Sendable {
    let value: [String: Any]
}

/// macOS's "Allow notifications when mirroring or sharing the display" (System Settings →
/// Notifications), off unless the user turned it on. Read-only, from Notification Center's own
/// preferences (`com.apple.ncprefs` → `dnd_prefs` → `dndMirrored`, true = hold banners while
/// mirrored or shared). If that ever moves, assume the default: banners are held.
nonisolated enum SharingNotificationPreference {
    static var allowsBannersWhileSharing: Bool {
        guard let data = CFPreferencesCopyAppValue("dnd_prefs" as CFString, "com.apple.ncprefs" as CFString) as? Data,
              let prefs = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let holdsBanners = prefs["dndMirrored"] as? Bool
        else { return false }
        return !holdsBanners
    }
}

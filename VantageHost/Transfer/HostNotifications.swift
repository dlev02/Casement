import AppKit
import Foundation
import UserNotifications
import os

/// File transfer notifications on the Mac: "Received Report.pdf from Drew's iPad" with Show in
/// Finder, and the outcome of files sent to the iPad. Asks for permission the first time it has
/// something to say, not at launch.
@MainActor
final class HostNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = HostNotifications()

    private static let receivedCategory = "vantage.fileReceived"
    private nonisolated static let showInFinderAction = "vantage.showInFinder"
    private nonisolated static let pathKey = "path"
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

    func received(_ url: URL, from device: String) {
        post(title: "Received \(url.lastPathComponent)", body: "From \(device). It's in your Downloads folder.",
             category: Self.receivedCategory, userInfo: [Self.pathKey: url.path(percentEncoded: false)])
    }

    func sent(_ name: String, to device: String) {
        post(title: "Sent \(name)", body: "It's in Files on \(device), in the Vantage folder.", category: nil, userInfo: [:])
    }

    func failed(_ name: String, sending: Bool, device: String, reason: String) {
        post(title: sending ? "Couldn't Send \(name)" : "Couldn't Receive \(name)",
             body: sending ? "\(device): \(reason)" : reason, category: nil, userInfo: [:])
    }

    private func post(title: String, body: String, category: String?, userInfo: [String: String]) {
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
            content.userInfo = userInfo
            if let category { content.categoryIdentifier = category }
            do {
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            } catch {
                log.error("couldn't post a notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo[Self.pathKey] as? String,
              response.actionIdentifier == Self.showInFinderAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        else { return }
        await MainActor.run {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                NSWorkspace.shared.open(url.deletingLastPathComponent())
            }
        }
    }
}

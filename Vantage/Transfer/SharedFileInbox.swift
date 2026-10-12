import Foundation
import Observation
import os

/// Files handed to Vantage by other apps ("Open in Vantage" / the share sheet's app row), waiting
/// for a session to send them to the Mac. `ContentView` fills it from `onOpenURL` and opens the
/// most recent Mac if no session is up; the session screen empties it into its transfer queue.
@MainActor
@Observable
final class SharedFileInbox {
    static let shared = SharedFileInbox()

    /// Copies in the outbox, ready for `FileTransferController.sendOutboxCopy`.
    private(set) var pending: [URL] = []
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "files")

    /// Takes a file another app opened in Vantage. Copies it out (the original may be another
    /// app's, open in place, or a copy iOS left in `Documents/Inbox`, which is then removed so it
    /// doesn't linger in Files).
    func accept(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let copy = try FileTransferController.copyToOutbox(url)
            pending.append(copy)
            let inbox = URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory).standardizedFileURL.path
            if url.standardizedFileURL.path.hasPrefix(inbox) { try? FileManager.default.removeItem(at: url) }
        } catch {
            log.error("couldn't take a file opened in Casement: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Everything waiting, once.
    func take() -> [URL] {
        defer { pending.removeAll() }
        return pending
    }
}

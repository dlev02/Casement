import Foundation
import Observation
import os

/// Files handed to Vantage by other apps ("Open in Vantage" / the share sheet's app row). Nothing
/// is sent until the person says so: a request to open a file can come from any app or from the
/// system, not only from someone choosing Casement in a share sheet, so each file is `offered`
/// first and moves to `pending` only when the person taps Send (`SharedFileConfirmation`). The
/// session screen, or the device list, then empties `pending` into a Mac's transfer queue.
/// Nothing here ever lists a folder: only the one URL that was opened is looked at.
@MainActor
@Observable
final class SharedFileInbox {
    static let shared = SharedFileInbox()

    /// Copies in the outbox waiting for the person's answer.
    private(set) var offered: [URL] = []
    /// Copies the person agreed to send, ready for `FileTransferController.sendOutboxCopy`.
    private(set) var pending: [URL] = []
    /// Folders no shared file ever comes from (`isOfferable`). Tests point it elsewhere.
    var privateFolders: [URL] = SharedFileInbox.defaultPrivateFolders
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "files")

    /// Takes a file another app opened in Vantage. Copies it out (the original may be another
    /// app's, open in place, or a copy iOS left in `Documents/Inbox`, which is then removed so it
    /// doesn't linger in Files) and offers it; it isn't sent until `approve()`.
    func accept(_ url: URL) {
        guard Self.isOfferable(url, privateFolders: privateFolders) else {
            log.error("ignored a file opened in Casement from somewhere nothing is shared from: \(url.path, privacy: .private)")
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let copy = try FileTransferController.copyToOutbox(url)
            offered.append(copy)
            if Self.isInside(url, Self.openInInbox) { try? FileManager.default.removeItem(at: url) }
        } catch {
            log.error("couldn't take a file opened in Casement: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The person said Send: what was offered is queued.
    func approve() {
        pending.append(contentsOf: offered)
        offered.removeAll()
    }

    /// The person said Don't Send: the copies go.
    func decline() {
        for copy in offered { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        offered.removeAll()
    }

    /// Everything the person agreed to send, once.
    func take() -> [URL] {
        defer { pending.removeAll() }
        return pending
    }

    // MARK: Where a shared file may come from

    /// Where iOS puts a copy of a file that was opened in Casement.
    nonisolated static var openInInbox: URL {
        URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory)
    }

    /// The App Group shared with the widgets (`DeviceCatalog.appGroup`, which this file can't see
    /// in the test package). Any app signed into the same group can write there.
    private nonisolated static let appGroup = "group.me.drewlevinson.casement"

    /// The App Group container and this app's own Library: databases, caches, settings. No share
    /// sheet hands over a file from either, and another app on the same team can write to the
    /// group container, so a request to send something from there is never honoured.
    nonisolated static var defaultPrivateFolders: [URL] {
        var folders = [URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).appending(path: "Library", directoryHint: .isDirectory)]
        #if !os(macOS) // the Mac app isn't in the group
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { folders.append(group) }
        #endif
        return folders
    }

    /// One ordinary file from outside `privateFolders` (`Documents/Inbox` is always fine: that's
    /// where iOS copies a file opened in Casement). Folders aren't sent.
    nonisolated static func isOfferable(_ url: URL, privateFolders: [URL]) -> Bool {
        guard url.isFileURL else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
        if isInside(url, openInInbox) { return true }
        return !privateFolders.contains { isInside(url, $0) }
    }

    private nonisolated static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

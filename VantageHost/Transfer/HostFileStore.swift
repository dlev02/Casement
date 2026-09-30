import CoreServices
import Foundation
import VantageCore
import os

/// Where files from the iPad land on the Mac, and how they're marked.
///
/// Normally `~/Downloads` (the host isn't sandboxed; macOS asks once for access to the folder), or
/// the folder chosen in Settings → Files while it exists and is writable; if it goes missing,
/// Downloads again. With `--synthetic-capture` they go to a temp folder instead, so loopback tests
/// never touch the user's Downloads (`--receive-folder` picks another scratch folder).
///
/// Every received file gets `com.apple.quarantine`, set explicitly on that file rather than
/// through `LSFileQuarantineEnabled`, which would also quarantine everything else the host writes
/// (dictation WAVs, the Parakeet model). Gatekeeper then treats a received app or script like a
/// browser download: it checks it and asks before the first open.
nonisolated struct HostFileStore: Sendable {
    let directory: URL
    let isSynthetic: Bool
    /// The folder chosen in Settings, when it can't be used right now and Downloads stands in.
    var unavailableChoice: String? = nil

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    static var current: HostFileStore {
        let options = HostOptions.shared
        if let path = options.receiveFolder {
            return HostFileStore(directory: URL(fileURLWithPath: path, isDirectory: true), isSynthetic: options.syntheticCapture)
        }
        if options.syntheticCapture {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appending(path: "VantageSynthetic/Received", directoryHint: .isDirectory)
            return HostFileStore(directory: directory, isSynthetic: true)
        }
        let choice = FileArrivalSettings(defaults: .standard).folderPath
        let resolved = ReceiveFolder.resolve(choice: choice, downloads: downloads)
        return HostFileStore(directory: resolved.url, isSynthetic: false, unavailableChoice: resolved.unavailableChoice)
    }

    /// "Downloads", or the folder's name as Finder shows it.
    var displayName: String { FileManager.default.displayName(atPath: directory.path(percentEncoded: false)) }

    var isDownloads: Bool { directory.standardizedFileURL.path == Self.downloads.standardizedFileURL.path }

    var configuration: FileTransferConfiguration {
        FileTransferConfiguration(receiveDirectory: directory, afterSave: { url, offer in
            Self.quarantine(url, typeIdentifier: offer.uti)
        })
    }

    private static let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "files")

    /// Marks a received file the way Safari marks a download (agent "Vantage Host").
    static func quarantine(_ url: URL, typeIdentifier: String?) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Porthole Host",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
            kLSQuarantineTimeStampKey as String: Date.now,
        ]
        var target = url
        do {
            try target.setResourceValues(values)
        } catch {
            log.error("couldn't quarantine a received file: \(error.localizedDescription, privacy: .public)")
        }
    }
}

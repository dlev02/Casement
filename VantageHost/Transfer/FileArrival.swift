import Foundation
import UniformTypeIdentifiers

// What Vantage Host does after files from the iPad are saved: the choices in Settings → Files and
// the decisions that follow from them. Nothing here touches AppKit, so the SPM tests run it as is.

/// Settings → Files → "Then".
nonisolated enum FileArrivalAction: String, CaseIterable, Identifiable, Sendable {
    case nothing
    case showInFinder = "reveal"
    case open

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nothing: "Do Nothing"
        case .showInFinder: "Show in Finder"
        case .open: "Open the File"
        }
    }
}

/// Settings → Files, as stored in the host's defaults.
nonisolated struct FileArrivalSettings: Equatable, Sendable {
    enum Key {
        static let notify = "files.notify"
        static let action = "files.afterArrival"
        static let showOnScreen = "files.showOnScreen"
        static let folder = "files.saveFolder"
    }

    /// Post a notification ("Received Report.pdf").
    var notify = true
    /// Then: select the files in Finder (he asked to be taken to them), open them, or nothing.
    var action: FileArrivalAction = .showInFinder
    /// While an iPad is watching, show arrivals on the Mac's screen when macOS hides the banner.
    var showOnScreen = true
    /// A folder chosen in Settings; nil means Downloads.
    var folderPath: String?

    init(notify: Bool = true, action: FileArrivalAction = .showInFinder, showOnScreen: Bool = true, folderPath: String? = nil) {
        self.notify = notify
        self.action = action
        self.showOnScreen = showOnScreen
        self.folderPath = folderPath
    }

    init(defaults: UserDefaults) {
        notify = defaults.object(forKey: Key.notify) as? Bool ?? true
        action = defaults.string(forKey: Key.action).flatMap(FileArrivalAction.init(rawValue:)) ?? .showInFinder
        showOnScreen = defaults.object(forKey: Key.showOnScreen) as? Bool ?? true
        let path = defaults.string(forKey: Key.folder)
        folderPath = path?.isEmpty == false ? path : nil
    }
}

/// Where received files go: the folder chosen in Settings while it's still there and writable,
/// otherwise Downloads.
nonisolated enum ReceiveFolder {
    struct Resolution: Equatable, Sendable {
        let url: URL
        /// The chosen folder can't be used (moved, deleted, unmounted, read-only), so this is
        /// Downloads instead; the path that was chosen.
        let unavailableChoice: String?
        var isFallback: Bool { unavailableChoice != nil }
    }

    static func resolve(choice: String?, downloads: URL, fileManager: FileManager = .default) -> Resolution {
        guard let choice else { return Resolution(url: downloads, unavailableChoice: nil) }
        let url = URL(fileURLWithPath: choice, isDirectory: true)
        return isUsable(url, fileManager: fileManager)
            ? Resolution(url: url, unavailableChoice: nil)
            : Resolution(url: downloads, unavailableChoice: choice)
    }

    static func isUsable(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        let path = url.path(percentEncoded: false)
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            && fileManager.isWritableFile(atPath: path)
    }
}

/// Which received files "Open the File" may open by itself. An allowlist of passive content
/// (pictures, movies, music, PDFs, text, office and iWork documents) minus anything that can run
/// code, install something, or point somewhere else. Everything else is shown in Finder instead,
/// where macOS still checks it (it's quarantined) before its first launch.
nonisolated enum AutoOpen {
    /// Types a received file is never opened as, even when it also looks like a document.
    private static let refused: [UTType] = [
        .executable, .script, .sourceCode, .bundle, .package, .diskImage, .archive,
        .aliasFile, .symbolicLink, .html, .webArchive, .svg, .internetShortcut,
    ] + [
        "com.apple.installer-package-archive", "com.apple.web-internet-location", "com.apple.generic-internet-location",
        "com.apple.file-internet-location", "com.apple.shortcut", "com.apple.terminal.settings", "com.apple.mobileconfig",
        "com.apple.automator-workflow",
    ].compactMap { UTType($0) }

    /// Content that only ever opens in a viewer or an editor.
    private static let allowed: [UTType] = [
        .image, .audiovisualContent, .pdf, .plainText, .rtf, .json, .presentation, .spreadsheet, .compositeContent, .usdz,
    ] + ["com.microsoft.word.doc", "com.microsoft.excel.xls", "com.microsoft.powerpoint.ppt"].compactMap { UTType($0) }

    /// Office's macro-enabled formats; not all of them declare themselves executable.
    private static let macroExtensions: Set<String> = ["docm", "dotm", "xlsm", "xltm", "xlsb", "pptm", "potm", "ppsm", "sldm"]

    static func isSafe(_ url: URL) -> Bool {
        if macroExtensions.contains(url.pathExtension.lowercased()) { return false }
        // What's on disk wins (an extensionless executable reads as one); the name is the fallback.
        let onDisk = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        guard let type = onDisk ?? UTType(filenameExtension: url.pathExtension) else { return false }
        if let byName = UTType(filenameExtension: url.pathExtension), !isSafe(byName) { return false }
        return isSafe(type)
    }

    static func isSafe(_ type: UTType) -> Bool {
        if refused.contains(where: { type.conforms(to: $0) }) { return false }
        return allowed.contains(where: { type.conforms(to: $0) })
    }
}

/// Collects files as they land so a batch gets one notification and one Finder window: it hands
/// the files over once nothing has arrived for `settle` and nothing else is still coming in, or
/// once the oldest has waited `maxHold` behind a long transfer.
nonisolated struct ArrivalBatcher: Sendable {
    struct Arrival: Equatable, Sendable {
        let url: URL
        let device: String
        let byteCount: UInt64
    }

    var settle: TimeInterval = 1.5
    var maxHold: TimeInterval = 20
    private(set) var receiving: Set<UUID> = []
    private(set) var pending: [Arrival] = []
    private var lastChange: Date?
    private var oldestPending: Date?

    init(settle: TimeInterval = 1.5, maxHold: TimeInterval = 20) {
        self.settle = settle
        self.maxHold = maxHold
    }

    mutating func started(_ id: UUID, at now: Date) {
        receiving.insert(id)
        lastChange = now
    }

    mutating func arrived(_ id: UUID, _ arrival: Arrival, at now: Date) {
        receiving.remove(id)
        pending.append(arrival)
        lastChange = now
        if oldestPending == nil { oldestPending = now }
    }

    /// A receive failed or was cancelled.
    mutating func ended(_ id: UUID, at now: Date) {
        guard receiving.remove(id) != nil else { return }
        lastChange = now
    }

    /// When the batch will be ready if nothing else happens; nil while there's nothing to hand over.
    var deadline: Date? {
        guard !pending.isEmpty, let lastChange, let oldestPending else { return nil }
        let held = oldestPending.addingTimeInterval(maxHold)
        return receiving.isEmpty ? min(lastChange.addingTimeInterval(settle), held) : held
    }

    mutating func takeBatch(now: Date) -> [Arrival]? {
        guard let deadline, now >= deadline else { return nil }
        defer {
            pending.removeAll()
            oldestPending = nil
        }
        return pending
    }
}

/// What to do with one batch.
nonisolated struct ArrivalPlan: Equatable, Sendable {
    /// More than this many files are shown in Finder rather than opened one after another.
    static let maxOpenedAtOnce = 5

    var notify: Bool
    /// Show the arrival on the Mac's screen (for an iPad that's watching and can't see banners).
    var showOnScreen: Bool
    /// Select these in Finder (one window when they share a folder).
    var reveal: [URL]
    var open: [URL]
    /// Files "Open the File" left alone because they could run code; they're in `reveal`.
    var notOpened: [URL]
    /// "Open the File" showed the batch in Finder because it was too many to open.
    var tooManyToOpen: Bool

    /// - Parameters:
    ///   - viewedRemotely: an iPad is streaming this Mac's screen right now.
    ///   - bannersShowWhileShared: macOS would still show a banner while the screen is shared
    ///     (notifications allowed as banners or alerts, and "Allow notifications when mirroring or
    ///     sharing the display" on).
    static func make(files: [URL], settings: FileArrivalSettings, viewedRemotely: Bool, bannersShowWhileShared: Bool,
                     isSafe: (URL) -> Bool = AutoOpen.isSafe) -> ArrivalPlan {
        var plan = ArrivalPlan(notify: settings.notify,
                               showOnScreen: settings.showOnScreen && viewedRemotely && !(settings.notify && bannersShowWhileShared),
                               reveal: [], open: [], notOpened: [], tooManyToOpen: false)
        guard !files.isEmpty else { return plan }
        switch settings.action {
        case .nothing:
            break
        case .showInFinder:
            plan.reveal = files
        case .open:
            let safe = files.filter(isSafe)
            if safe.count > maxOpenedAtOnce {
                plan.reveal = files
                plan.tooManyToOpen = true
            } else {
                plan.open = safe
                plan.notOpened = files.filter { !safe.contains($0) }
                plan.reveal = plan.notOpened
            }
        }
        return plan
    }
}

/// The words for a batch, shared by the notification and the on-screen notice.
nonisolated struct ArrivalSummary: Equatable, Sendable {
    let names: [String]
    let devices: [String]
    /// "Downloads", or the chosen folder's name.
    let folderName: String
    /// Downloads reads as a place ("in Downloads"); any other folder is quoted by name.
    let isDownloads: Bool
    /// "Open the File" left these in Finder because they aren't documents or media.
    let notOpenedCount: Int
    /// "Open the File" showed the whole batch in Finder because it was more than it opens at once.
    let tooManyToOpen: Bool

    init(files: [URL], devices: [String], folderName: String, isDownloads: Bool, notOpenedCount: Int = 0,
         tooManyToOpen: Bool = false) {
        names = files.map(\.lastPathComponent)
        var unique: [String] = []
        for device in devices where !unique.contains(device) { unique.append(device) }
        self.devices = unique
        self.folderName = folderName
        self.isDownloads = isDownloads
        self.notOpenedCount = notOpenedCount
        self.tooManyToOpen = tooManyToOpen
    }

    var sender: String {
        switch devices.count {
        case 0: "your iPad"
        case 1: devices[0]
        default: ListFormatter.localizedString(byJoining: devices)
        }
    }

    /// "Report.pdf", or "3 Files".
    var headline: String {
        names.count == 1 ? names[0] : "\(names.count) Files"
    }

    /// Notification title: "Received Report.pdf".
    var notificationTitle: String { "Received \(headline)" }

    /// Notification body: who from, which files for a batch, where they are, and why an app wasn't opened.
    var notificationBody: String {
        var parts: [String] = []
        if names.count == 1 {
            parts.append("From \(sender). It's in \(folderPhrase).")
        } else {
            parts.append("\(listedNames), from \(sender). They're in \(folderPhrase).")
        }
        if let note = notOpenedNote { parts.append(note) }
        return parts.joined(separator: " ")
    }

    /// On-screen subtitle: "From Drew's iPad · in Downloads".
    var subtitle: String { "From \(sender) · in \(folderPhrase)" }

    /// Why "Open the File" showed something in Finder instead.
    var notOpenedNote: String? {
        if tooManyToOpen { return "That's more than Porthole opens at once, so they're shown in Finder." }
        guard notOpenedCount > 0 else { return nil }
        if names.count == 1 { return "Porthole only opens documents and media by itself, so it's shown in Finder." }
        return notOpenedCount == 1
            ? "Porthole only opens documents and media by itself, so one is shown in Finder."
            : "Porthole only opens documents and media by itself, so \(notOpenedCount) are shown in Finder."
    }

    /// The same, short enough for the on-screen notice.
    var shortNotOpenedNote: String? {
        if tooManyToOpen { return "Too many to open at once" }
        guard notOpenedCount > 0 else { return nil }
        return names.count == 1 ? "Shown instead of opened" : "\(notOpenedCount) shown instead of opened"
    }

    /// Spoken by VoiceOver when the notice appears.
    var announcement: String { "Received \(names.count == 1 ? names[0] : "\(names.count) files") from \(sender)" }

    private var folderPhrase: String { isDownloads ? folderName : "“\(folderName)”" }

    /// "Report.pdf and photo.jpg", "Report.pdf, photo.jpg and 2 more".
    private var listedNames: String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

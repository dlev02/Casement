import Foundation
import Observation

/// The last few dictations sent from this device, so text that landed in the wrong place (or
/// nowhere) can be copied or sent again.
///
/// Kept on this device only: one small file in Application Support, protected while the device is
/// locked, left out of backups, never synced and never logged. Settings → Controls → Dictation
/// turns it off, which also deletes what was saved.
@MainActor
@Observable
final class DictationHistory {
    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        var date: Date
        /// The computer it was sent to, by the name it had then.
        var computer: String?
    }

    static let shared = DictationHistory()
    static let enabledKey = "vantage.dictationHistory"
    /// The newest this many are kept.
    static let limit = 30

    /// Newest first.
    private(set) var entries: [Entry] = []
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let defaults: UserDefaults

    init(file: URL = DictationHistory.defaultFile, defaults: UserDefaults = .standard) {
        self.file = file
        self.defaults = defaults
    }

    /// On unless switched off in Settings.
    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    /// Reads the saved list the first time anything needs it.
    func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard isEnabled, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = Array(saved.prefix(Self.limit))
    }

    /// Remembers text that was just sent or copied. The same text again moves to the top rather
    /// than filling the list with repeats.
    func add(_ text: String, computer: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEnabled, !text.isEmpty else { return }
        load()
        entries.removeAll { $0.text == text }
        entries.insert(Entry(text: text, date: .now, computer: computer), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func remove(_ entry: Entry) {
        load()
        entries.removeAll { $0.id == entry.id }
        save()
    }

    /// Forgets everything and deletes the file.
    func clear() {
        hasLoaded = true
        entries = []
        try? FileManager.default.removeItem(at: file)
    }

    private func save() {
        guard !entries.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var options: Data.WritingOptions = [.atomic]
            #if !os(macOS)
            options.insert(.completeFileProtection)
            #endif
            try JSONEncoder().encode(entries).write(to: file, options: options)
            var url = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            // Nothing to tell the user: the list just doesn't outlive this launch.
        }
    }

    /// Beside the device catalog. A test runner (no Casement bundle) gets a scratch file, so
    /// tests never write into the real app's history.
    nonisolated static var defaultFile: URL {
        guard Bundle.main.bundleIdentifier == "me.drewlevinson.casement" else {
            return URL.temporaryDirectory.appending(path: "VantageDictationHistory.json")
        }
        return URL.applicationSupportDirectory.appending(path: "Vantage/dictation-history.json")
    }
}

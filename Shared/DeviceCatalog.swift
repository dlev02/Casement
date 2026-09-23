import Foundation
import os

/// The slice of the saved-device list that Siri, Shortcuts, and widgets need: names, addresses,
/// and when each Mac was last used. The app writes it; the widget extension only reads it.
///
/// It lives in the App Group container so the widget process can see it. A personal team can't
/// sign for App Groups, so on such builds `containerURL` is nil and the catalog falls back to the
/// app's own Application Support — Siri and Shortcuts keep working (they run inside the app) while
/// widgets show their empty state until the entitlement exists. The simulator doesn't enforce the
/// entitlement, which is how widgets get verified before then.
nonisolated enum DeviceCatalog {
    static let appGroup = "group.com.benjaminlevinson.vantage"
    /// Widget and control kinds, shared so the app reloads exactly these when the catalog changes.
    static let widgetKind = "com.benjaminlevinson.vantage.connect"
    static let controlKind = "com.benjaminlevinson.vantage.connect-control"
    private static let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "catalog")

    /// One Mac as the system surfaces see it. Kept deliberately small and stable.
    struct Mac: Codable, Identifiable, Hashable, Sendable {
        var id: UUID
        var name: String
        var host: String
        var lastConnected: Date?
    }

    /// The URL scheme the widget uses to ask the app to connect. Lives here so both sides agree.
    static func connectURL(for id: UUID) -> URL {
        URL(string: "vantage://connect/\(id.uuidString)")!
    }

    static func macID(from url: URL) -> UUID? {
        guard url.scheme == "vantage", url.host() == "connect" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    // MARK: Reading

    static func load() -> [Mac] {
        for url in candidateURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let macs = try? decoder.decode([Mac].self, from: data) { return macs }
        }
        return []
    }

    static func mac(withID id: UUID) -> Mac? {
        load().first { $0.id == id }
    }

    /// Most recently used first; never-used Macs keep their saved order at the end.
    static func recents() -> [Mac] {
        load().sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
    }

    // MARK: Writing (app only)

    static func save(_ macs: [Mac]) {
        guard let data = try? encoder.encode(macs) else { return }
        // Write the shared copy when there is one, and always the local copy, so in-app callers
        // never depend on the entitlement.
        for url in candidateURLs {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("could not write catalog to \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Locations

    /// Shared container first, then the app's private copy.
    private static var candidateURLs: [URL] {
        var urls: [URL] = []
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            urls.append(group.appending(path: "Library/Application Support/Vantage/catalog.json"))
        }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(support.appending(path: "Vantage/catalog.json"))
        }
        return urls
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

import AppIntents
import CoreSpotlight
import Foundation
import os

/// A saved Mac as Siri, Shortcuts, Spotlight, and widget configuration see it.
///
/// This is a thin view over `DeviceCatalog.Mac` rather than `SavedDevice` itself, so the intents
/// surface stays stable when the saved-device model grows and the widget extension never needs
/// the app's model code. It is an `IndexedEntity`, so each Mac can appear in Spotlight and
/// opening the result runs `ConnectToMacIntent` (the entity's `OpenIntent`).
struct MacEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mac")
    static let defaultQuery = MacQuery()

    let id: UUID
    let name: String
    let host: String

    init(_ mac: DeviceCatalog.Mac) {
        id = mac.id
        name = mac.name
        host = mac.host
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(host)", image: .init(systemName: "laptopcomputer"))
    }

    /// Title and subtitle come from the display representation; keywords let "remote" or the
    /// Tailscale name find the Mac too.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.keywords = ["Mac", "remote desktop", "Porthole", host]
        return attributes
    }
}

/// Answers "which Macs?" for parameter pickers and for Siri matching a spoken name.
struct MacQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [MacEntity] {
        DeviceCatalog.load().filter { identifiers.contains($0.id) }.map(MacEntity.init)
    }

    /// Recents first, so the Mac you use most is the one Siri and widgets offer first.
    func suggestedEntities() async throws -> [MacEntity] {
        DeviceCatalog.recents().map(MacEntity.init)
    }

    func entities(matching string: String) async throws -> [MacEntity] {
        DeviceCatalog.recents()
            .filter { $0.name.localizedCaseInsensitiveContains(string) || $0.host.localizedCaseInsensitiveContains(string) }
            .map(MacEntity.init)
    }

    func defaultResult() async -> MacEntity? {
        DeviceCatalog.recents().first.map(MacEntity.init)
    }
}

/// The system can ask for the Spotlight entries to be rebuilt (after a restore, or when it drops
/// the index). Answer from the catalog, honouring the app lock the same way publishing does.
@available(iOS 27, macOS 27, *)
extension MacQuery: IndexedEntityQuery {
    func reindexEntities(for identifiers: [UUID], indexDescription: CSSearchableIndexDescription) async throws {
        let macs = DeviceCatalog.load()
        let present = macs.filter { identifiers.contains($0.id) }
        let gone = identifiers.filter { id in !macs.contains { $0.id == id } }
        await MacSpotlight.sync(present, removed: gone)
    }

    func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
        await MacSpotlight.sync(DeviceCatalog.load(), removed: [], replacingAll: true)
    }
}

/// Keeps each saved Mac in Spotlight, or none of them while the app lock is on — a locked app
/// shouldn't list your Macs to anyone who picks up the iPad.
nonisolated enum MacSpotlight {
    /// The same key `AppLock` and Settings use.
    static let appLockKey = "vantage.requireBiometrics"
    private static let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "spotlight")

    /// Only the app decides what Spotlight holds. The widget extension can't read the app-lock
    /// setting (no shared defaults without an App Group), so it leaves the index alone.
    static var isAppProcess: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static var isHidden: Bool { UserDefaults.standard.bool(forKey: appLockKey) }

    static func sync(_ macs: [DeviceCatalog.Mac], removed: [UUID], replacingAll: Bool = false) async {
        guard isAppProcess else { return }
        let index = CSSearchableIndex.default()
        do {
            if isHidden {
                try await index.deleteAppEntities(ofType: MacEntity.self)
                return
            }
            if replacingAll {
                try await index.deleteAppEntities(ofType: MacEntity.self)
            } else if !removed.isEmpty {
                try await index.deleteAppEntities(identifiedBy: removed, ofType: MacEntity.self)
            }
            if !macs.isEmpty {
                try await index.indexAppEntities(macs.map(MacEntity.init))
            }
        } catch {
            log.error("spotlight update failed: \(String(describing: error), privacy: .public)")
        }
    }
}

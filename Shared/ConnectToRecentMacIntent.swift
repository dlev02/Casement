import AppIntents
import Foundation
import Observation

/// "Connect to Recent Mac" — the Control Center / Lock Screen / Action button control, and a
/// Shortcuts action. Parameterless on purpose: a control has no room to ask which Mac.
///
/// Compiled into both the app and the widget extension (the control needs the type), but it runs
/// in the app: `.foreground` brings Vantage forward and `perform` hands the Mac to
/// `PendingConnection`, the same slot Siri and widget taps use.
struct ConnectToRecentMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Recent Mac"
    static let description = IntentDescription("Opens Casement and connects to the Mac you used most recently.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        // No Macs yet: opening the app is still the right answer, it shows how to add one.
        if let mac = DeviceCatalog.recents().first {
            PendingConnection.shared.requestedMacID = mac.id
        }
        return .result()
    }
}

/// The one-slot mailbox between an intent or URL and the device list. `ContentView` watches it
/// (including its value at launch) and opens the session once the app is on screen and unlocked.
@MainActor
@Observable
final class PendingConnection {
    static let shared = PendingConnection()
    var requestedMacID: UUID?
    private init() {}
}

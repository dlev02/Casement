import AppIntents
import Foundation

/// "Connect to Studio Mac in Vantage" — from Siri, Spotlight, the Shortcuts app, or the Action
/// button. Runs inside the app so it can open the session directly; nothing here needs the
/// network or an entitlement.
///
/// An `OpenIntent`, so it is also what runs when a Mac is opened from Spotlight.
struct ConnectToMacIntent: OpenIntent {
    static let title: LocalizedStringResource = "Connect to Mac"
    static let description = IntentDescription("Opens Vantage and connects to one of your Macs.")
    /// The session is the whole point, so the app always comes forward.
    static let supportedModes: IntentModes = .foreground(.immediate)

    /// Asked for when a phrase doesn't name the Mac ("Connect to a Mac with Vantage").
    @Parameter(title: "Mac", requestValueDialog: IntentDialog("Which Mac do you want to connect to?"))
    var target: MacEntity

    init() {}
    init(target: MacEntity) { self.target = target }

    static var parameterSummary: some ParameterSummary {
        Summary("Connect to \(\.$target)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingConnection.shared.requestedMacID = target.id
        return .result()
    }
}

/// The phrases Siri and Spotlight listen for. Most are parameterised on the Mac so "Connect to
/// Studio Mac in Vantage" works with no follow-up question; the parameter list is refreshed by
/// the device store whenever a Mac is added, renamed, or removed. The unnamed phrase asks which.
struct VantageShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectToMacIntent(),
            phrases: [
                "Connect to \(\.$target) in \(.applicationName)",
                "Connect to \(\.$target) with \(.applicationName)",
                "Open \(\.$target) in \(.applicationName)",
                "Control \(\.$target) with \(.applicationName)",
                "Connect to a Mac with \(.applicationName)",
                "Connect to a Mac in \(.applicationName)",
            ],
            shortTitle: "Connect to Mac",
            systemImageName: "laptopcomputer"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .navy
}

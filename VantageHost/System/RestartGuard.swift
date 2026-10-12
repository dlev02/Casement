import AppKit
import CoreServices

/// Asks for confirmation when macOS tries to restart, shut down, or log out while a device is
/// connected. Returning `.terminateCancel` from `applicationShouldTerminate` makes loginwindow
/// abandon the whole restart ("Vantage Host canceled restart"), the same mechanism an editor with
/// unsaved documents uses. Restarts that bypass apps (`sudo reboot`, a kernel panic) can't be caught.
enum RestartGuard {
    static let defaultsKey = "confirmRestartWhileConnected"

    enum Reason {
        case restart, shutDown, logOut
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The reason loginwindow attached to the quit Apple event, or nil for an ordinary quit
    /// (the menu's Quit button, ⌘Q, `NSApp.terminate`).
    static func systemQuitReason() -> Reason? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication),
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        else { return nil }
        switch reason {
        case OSType(kAERestart), OSType(kAEShowRestartDialog): return .restart
        case OSType(kAEShutDown), OSType(kAEShowShutdownDialog): return .shutDown
        case OSType(kAELogOut), OSType(kAEReallyLogOut): return .logOut
        default: return nil
        }
    }

    /// Shows a modal alert on the Mac (which the remote user sees in the stream). Returns true to proceed.
    /// With `canRestartSafely`, a restart can first stage a one-time FileVault unlock key.
    @MainActor
    static func confirm(_ reason: Reason, fileVaultOn: Bool?, canRestartSafely: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch reason {
        case .restart:
            alert.messageText = "Restart while you're connected remotely?"
        case .shutDown:
            alert.messageText = "Shut down while you're connected remotely?"
        case .logOut:
            alert.messageText = "Log out while you're connected remotely?"
        }
        let offerSafe = canRestartSafely && reason == .restart && fileVaultOn == true
        alert.informativeText = consequence(of: reason, fileVaultOn: fileVaultOn)
            + (offerSafe ? " Restart Safely skips the FileVault screen for this one restart." : "")
        alert.addButton(withTitle: cancelTitle(for: reason))
        if offerSafe { alert.addButton(withTitle: "Restart Safely…") }
        let proceed = alert.addButton(withTitle: proceedTitle(for: reason))
        proceed.hasDestructiveAction = true
        NSApp.activate()
        alert.window.level = .modalPanel
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return false
        case .alertSecondButtonReturn where offerSafe:
            return SafeRestartPrompt.run(explanation: SafeRestart.promptExplanation)
        default:
            return true
        }
    }

    private static func consequence(of reason: Reason, fileVaultOn: Bool?) -> String {
        let connected = "A device is controlling this Mac through Casement."
        switch reason {
        case .shutDown:
            return connected + " Once it shuts down, nobody can turn it back on remotely."
        case .logOut:
            return connected + " After logging out, Casement Host stops until someone logs in again, so you won't be able to reconnect."
        case .restart where fileVaultOn == true:
            return connected + " FileVault is on, so after the restart this Mac waits at the FileVault unlock screen. Casement and Tailscale can't reach it until someone unlocks it in person."
        case .restart:
            return connected + " After the restart, Casement Host only starts again once someone logs in, so you may not be able to reconnect."
        }
    }

    private static func cancelTitle(for reason: Reason) -> String {
        switch reason {
        case .restart: "Cancel Restart"
        case .shutDown: "Cancel Shut Down"
        case .logOut: "Cancel Log Out"
        }
    }

    private static func proceedTitle(for reason: Reason) -> String {
        switch reason {
        case .restart: "Restart Anyway"
        case .shutDown: "Shut Down Anyway"
        case .logOut: "Log Out Anyway"
        }
    }
}

import Foundation
import VantageCore

/// Why the key button couldn't just type the password.
nonisolated enum PasswordPrompt: String, Identifiable, Sendable {
    /// No password saved for this Mac yet — offer to save one without leaving the session.
    case missing
    /// macOS is blocking ordinary keystrokes; Screen Sharing can type it but needs the account name.
    case needsAccount
    var id: String { rawValue }
}

/// What Type Password does, decided from what is saved and what the host reports. macOS drops
/// Casement Host's keystrokes while a password field, auth dialog, or the lock screen holds
/// Secure Event Input, so then the password goes through the Mac's own Screen Sharing server
/// instead (which signs in, so it needs the account name).
nonisolated enum TypePasswordDecision: Equatable, Sendable {
    /// A PC has no saved password to type (Macs only).
    case nothing
    /// Ask for one of the two things Type Password still needs.
    case ask(PasswordPrompt)
    /// Type it as keystrokes through the host, then Return.
    case type(String)
    /// Type it through the Mac's Screen Sharing server.
    case screenSharing

    static func decide(host: HostNoun, password: String?, hasAccountName: Bool, status: HostStatus?) -> TypePasswordDecision {
        guard !host.isWindows else { return .nothing }
        guard let password else { return .ask(.missing) }
        let blocked = status.map { $0.isSecureInputActive || $0.isScreenLocked } ?? false
        guard blocked else { return .type(password) }
        return hasAccountName ? .screenSharing : .ask(.needsAccount)
    }
}

/// Progress of a password typed through the Mac's Screen Sharing server.
nonisolated enum ScreenSharingTypingState: Equatable, Sendable {
    case typing, sent
}

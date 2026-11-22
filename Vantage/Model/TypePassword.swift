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

/// The button in the status banner while a Mac's lock screen or a secure field blocks typing:
/// Unlock or Approve types the saved password through Screen Sharing, after Face ID. Without a
/// saved password and account name it offers to save them first. Nothing for a PC, which has no
/// saved password.
nonisolated struct HostUnlockOffer: Equatable, Sendable {
    enum Purpose: Equatable, Sendable {
        /// The lock screen (a hot corner, the Mac's own timer, ⌃⌘Q).
        case unlock
        /// A password field, an authentication or Keychain dialog, sudo in Terminal.
        case approve
    }

    var purpose: Purpose
    var hasPassword: Bool
    var hasAccountName: Bool
    /// Screen Sharing is typing it now.
    var isBusy: Bool

    static func make(host: HostNoun, status: HostStatus?, hasPassword: Bool, hasAccountName: Bool, isTyping: Bool) -> HostUnlockOffer? {
        guard !host.isWindows, let status else { return nil }
        let purpose: Purpose
        if status.isScreenLocked { purpose = .unlock } else if status.isSecureInputActive { purpose = .approve } else { return nil }
        return HostUnlockOffer(purpose: purpose, hasPassword: hasPassword, hasAccountName: hasAccountName, isBusy: isTyping)
    }

    /// "Unlock with Face ID", "Approve with Touch ID", "Unlock" where nothing is asked first, or
    /// what's missing.
    func title(confirmation biometry: String?) -> String {
        if !hasPassword { return "Save Password…" }
        if !hasAccountName { return "Add Account Name…" }
        let verb = purpose == .unlock ? "Unlock" : "Approve"
        return biometry.map { "\(verb) with \($0)" } ?? verb
    }

    var symbol: String {
        guard hasPassword, hasAccountName else { return "key" }
        return purpose == .unlock ? "lock.open" : "checkmark.shield"
    }
}

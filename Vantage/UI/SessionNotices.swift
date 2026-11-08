import SwiftUI
import VantageCore

// The screen session's banners, badges and the password sheet (`RemoteSessionLayout` places them).

/// Explains why input may be ignored: the host is locked or a secure field has focus. A locked
/// PC can't be unlocked from here (there's no saved password to type), so it says where to go.
struct HostStatusBanner: View {
    let status: HostStatus
    var host = HostNoun.mac

    private var text: String {
        if host.isWindows {
            if status.isScreenLocked { return "The PC is locked. Unlock it at the PC, or sign in with Remote Desktop." }
            return status.message ?? "Typing is blocked by a Windows security prompt"
        }
        return status.message ?? (status.isScreenLocked ? "The Mac is locked" : "Typing is blocked by a secure field")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.isScreenLocked ? "lock.fill" : "key.fill")
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .platformGlass(in: .capsule)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
        .announcing(text)
    }
}

/// The session's haptics (see `Haptic`): the strip landing in a corner, dictation's microphone
/// opening and closing, a dropped or restored connection, and outcomes you'd otherwise have to
/// look for. Pointer and touch gestures buzz from `RemoteInteractionView`.
struct SessionHaptics: ViewModifier {
    let state: ClientSession.State
    let pairingError: String?
    let dock: ToolbarDock
    let dictationPhase: DictationController.Phase?
    let screenSharingTyping: ScreenSharingTypingState?
    let screenSharingError: String?
    @State private var connection = ConnectionHaptics()

    func body(content: Content) -> some View {
        content
            .haptic(.snap, trigger: dock)
            .haptic(trigger: dictationPhase, Self.dictation)
            .haptic(trigger: pairingError, Self.failure)
            .haptic(trigger: screenSharingTyping, Self.typed)
            .haptic(trigger: screenSharingError, Self.failure)
            .onChange(of: state) { old, new in
                if let haptic = connection.haptic(from: old, to: new) { Haptics.play(haptic) }
            }
            #if DEBUG
            .overlay(alignment: .bottomLeading) {
                if ClientOptions.hapticProbe {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement()
                            .accessibilityIdentifier("session.hapticProbe")
                            .accessibilityValue(Haptics.played.map { "\($0)" }.joined(separator: " "))
                    }
                    .allowsHitTesting(false)
                }
            }
            #endif
    }

    private static func dictation(_ old: DictationController.Phase?, _ new: DictationController.Phase?) -> Haptic? {
        guard let old, let new else { return nil }
        return DictationController.Phase.haptic(from: old, to: new)
    }

    /// An error message appeared: a rejected pairing code, a password Screen Sharing couldn't type.
    private static func failure(_ old: String?, _ new: String?) -> Haptic? { new == nil ? nil : .error }

    private static func typed(_ old: ScreenSharingTypingState?, _ new: ScreenSharingTypingState?) -> Haptic? {
        new == .sent ? .success : nil
    }
}

/// Why the Mac's sound stopped or didn't start; clears itself after a few seconds.
struct MacAudioNotice: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .accessibilityHidden(true)
            Text(message)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .platformGlass(in: .capsule)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session.macAudioNotice")
        .announcing(message)
    }
}

struct ScreenSharingTypingBadge: View {
    let state: ScreenSharingTypingState

    var body: some View {
        HStack(spacing: 8) {
            if state == .typing {
                ProgressView().controlSize(.small)
                Text("Typing password with Screen Sharing…")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Password sent")
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .platformGlass(in: .capsule)
        .accessibilityElement(children: .combine)
        .announcing(state == .typing ? "Typing password with Screen Sharing" : "Password sent")
    }
}

private extension View {
    /// Reads `text` aloud when the view appears and whenever it changes: these notices show up
    /// without VoiceOver's focus moving to them.
    func announcing(_ text: String) -> some View {
        onChange(of: text, initial: true) { _, text in
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

/// Saves a Mac's password (and the account name Screen Sharing needs) mid-session. The fields
/// are its own, so the password never sits in the session's state.
struct PasswordPromptSheet: View {
    let prompt: PasswordPrompt
    let onCancel: () -> Void
    /// Save & Type: the password (for `.missing`) and the account name, empty when not given.
    let onSave: (_ password: String?, _ accountName: String?) -> Void
    @State private var password = ""
    @State private var username = ""

    private var canSave: Bool {
        switch prompt {
        case .missing: !password.isEmpty
        case .needsAccount: !username.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if prompt == .needsAccount {
                    Section {
                        Label("macOS is blocking ordinary typing", systemImage: "lock.shield")
                            .font(.headline)
                    } footer: {
                        Text("A password field, an authentication dialog, or the lock screen has focus, so macOS ignores keystrokes from apps. Casement can type the password through the Mac's own Screen Sharing instead. It signs in with your Mac account, so it needs the account name that goes with this password.")
                    }
                }
                Section {
                    TextField("Account name", text: $username)
                        .textContentType(.username)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    if prompt == .missing {
                        PasswordField(title: "Mac Password", text: $password)
                    }
                } footer: {
                    Text(prompt == .missing
                         ? "Casement keeps these in the Keychain and types the password when you \(LocalDevice.tap) the key button. The account name is optional; with it, the key button also works in password fields and on the lock screen."
                         : "Your short account name or full name, as shown in System Settings → Users & Groups. Screen Sharing must be on for this account (System Settings → General → Sharing).")
                }
            }
            .macGroupedForm()
            .navigationTitle(prompt == .missing ? "Save Password" : "Mac Account")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save & Type") {
                        onSave(prompt == .missing ? password : nil, username.isEmpty ? nil : username)
                    }
                    .disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 260, idealHeight: 320)
        #endif
        .presentationDetents([.medium])
    }
}

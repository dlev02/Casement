import Foundation
import VantageCore

// What the control strip, the session menu and the Mac menu bar need from a screen session to
// draw and flip its controls (`ScreenSessionModel` builds these).

/// A press on the control strip's mic button.
enum DictationPress {
    case began
    /// `held` is true for a press of ~0.3 s or more (push-to-talk).
    case ended(held: Bool)
    /// The finger moved off as the start of a drag of the whole strip: undo what `began` did.
    case cancelled
    /// VoiceOver / Full Keyboard Access: start or stop in one action.
    case toggle
}

/// What the strip needs to draw and flip the Mac (or PC) Audio toggle.
struct MacAudioToggle {
    /// The user wants the host's sound here (and nothing has failed this session).
    var isOn = false
    /// Nil when the host can send audio; otherwise why the toggle is dimmed.
    var unavailableReason: String?
    var onToggle: () -> Void = {}
}

/// What the strip needs to draw and flip Curtain.
struct CurtainToggle {
    var isOn = false
    /// Nil when the host can do it; otherwise why the toggle is dimmed.
    var unavailableReason: String?
    var onToggle: () -> Void = {}
}

/// What the strip needs for Send File and the Transfers list.
struct SendFileAction {
    /// Nil when the Mac can take files; otherwise why Send File is dimmed.
    var unavailableReason: String?
    /// Progress of the files moving now (0…1), or nil when nothing is.
    var progress: Double?
    /// Something has moved (or is moving) this session, so Transfers… is worth offering.
    var hasTransfers = false
    var onSend: () -> Void = {}
    var onShowTransfers: () -> Void = {}
}

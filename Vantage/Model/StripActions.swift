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

/// What the session menu needs to draw and flip Fit Display (PC) / Virtual Display (Mac).
struct FitDisplayToggle {
    var isOn = false
    /// Connected to a host that can fit its display to this device (matches the Mac Session menu).
    var isAvailable = false
    /// Why the toggle is dimmed while connected to a host that can't fit its display.
    var unavailableReason: String?
    var onToggle: () -> Void = {}
}

/// The session menu's Quality choice.
struct QualityChoice {
    var selection: QualityPreset = .auto
    var onSelect: (QualityPreset) -> Void = { _ in }
}

extension QualityPreset {
    /// What Casement offers, in menu order (`maximum` is the host's alone).
    static let offered: [QualityPreset] = [.motion, .auto, .text]

    var label: String {
        switch self {
        case .motion: String(localized: "Fluid")
        case .auto: String(localized: "Balanced")
        case .text: String(localized: "Sharp Text")
        case .maximum: String(localized: "Maximum")
        }
    }

    /// What it trades, for the Edit sheet.
    var summary: String {
        switch self {
        case .motion: String(localized: "Fluid keeps motion at 60 frames per second and never spends extra on a still screen.")
        case .auto: String(localized: "Balanced follows what's on the screen and sharpens text as soon as it stops moving.")
        case .text, .maximum: String(localized: "Sharp Text spends more on detail so text stays crisp, at some cost to motion on a slow connection.")
        }
    }
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

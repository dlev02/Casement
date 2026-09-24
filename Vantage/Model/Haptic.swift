import Foundation

/// A moment worth feeling, named for what happened rather than how it feels. Play one with
/// `.haptic(_:trigger:)` from a view or `Haptics.play(_:)` from a callback (`UI/Haptics.swift`).
///
/// Haptics confirm what the eye can't: a gesture that was recognized, a state that changed under
/// the thumb, an outcome that happened out of sight. Pointer movement, scrolling, typing, and plain
/// taps never buzz.
nonisolated enum Haptic: Equatable, Sendable {
    /// A sticky modifier (or similar latch) turned on.
    case latch
    /// …and off again, by the user.
    case unlatch
    /// Something you hold started: the microphone opened for dictation.
    case start
    /// …and stopped.
    case stop
    /// Something dragged settled into place: the session controls landed in a corner.
    case snap
    /// A touch gesture became a mouse press: a long press grabbed (Direct Touch) or clicked.
    case press
    /// A multi-finger tap became a right- or middle-click.
    case secondaryClick
    /// Something you were waiting on worked: reconnected, a password typed, a file moved.
    case success
    /// Something needs attention but isn't over: the connection dropped and is being retried.
    case warning
    /// Something failed.
    case error

    /// `@AppStorage` key for Settings → Controls → Haptics (on unless turned off).
    static let settingKey = "vantage.haptics"
}

/// Connection changes worth feeling. Connecting and leaving are quiet (you're watching the screen
/// change); an open session dropping warns, getting it back is a success, giving up is an error.
struct ConnectionHaptics {
    /// An open session dropped and hasn't come back yet.
    private var dropped = false

    mutating func haptic(from old: ClientSession.State, to new: ClientSession.State) -> Haptic? {
        switch new {
        case .reconnecting where old == .connected:
            dropped = true
            return .warning
        case .connected where dropped:
            dropped = false
            return .success
        case .failed:
            dropped = false
            return .error
        case .idle, .suspended:
            dropped = false // you left, or the app went to the background
            return nil
        default:
            return nil
        }
    }
}

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Haptic feedback, in one place. Every buzz goes through here so it follows Settings → Controls →
// Haptics; iPhone's own System Haptics switch still applies on top (UIKit honours it).
//
//     .haptic(.snap, trigger: dock)                      // a view whose state changes
//     .haptic(trigger: phase) { old, new in … }          // pick one per change, or nil
//     Haptics.play(.success)                             // a callback with no view state
//
// iPad has no Taptic Engine, so on iPad the modifiers add nothing and `play` returns straight
// away; visionOS compiles them out.

@MainActor
enum Haptics {
    /// This device can play haptics: iPhone. `-VantageForceHaptics 1` (DEBUG) pretends an iPad
    /// can, so the setting and call sites can be exercised in the iPad simulator.
    static let isSupported: Bool = {
        #if os(visionOS) || !canImport(UIKit)
        return false
        #else
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-VantageForceHaptics") { return true }
        #endif
        return UIDevice.current.userInterfaceIdiom == .phone
        #endif
    }()

    /// Supported, and not turned off in Settings (on by default).
    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        return isSupported && (defaults.object(forKey: Haptic.settingKey) == nil || defaults.bool(forKey: Haptic.settingKey))
    }

    #if DEBUG
    /// The haptics played so far, newest last, for `-VantageHapticProbe 1` (UI tests can't feel).
    static var played: [Haptic] = []
    #endif

    /// Notes a haptic that is about to play.
    fileprivate static func record(_ haptic: Haptic) {
        #if DEBUG
        played.append(haptic)
        #endif
    }

    /// Plays `haptic` now, for code that reacts to a callback rather than to view state (a file
    /// arriving, a task finishing). In a view, prefer `.haptic(_:trigger:)`.
    static func play(_ haptic: Haptic) {
        #if canImport(UIKit) && !os(visionOS)
        guard isEnabled, let window = foregroundWindow else { return }
        record(haptic)
        if generators?.window !== window {
            generators?.detach()
            generators = WindowGenerators(window: window)
        }
        generators?.play(haptic)
        #endif
    }

    #if canImport(UIKit) && !os(visionOS)
    private static var generators: WindowGenerators?

    private static var foregroundWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
    }

    /// Generators attached to the window that plays them (UIKit ties feedback to a view).
    private final class WindowGenerators {
        weak var window: UIWindow?
        let notification: UINotificationFeedbackGenerator
        let light, medium, soft, rigid: UIImpactFeedbackGenerator

        init(window: UIWindow) {
            self.window = window
            notification = UINotificationFeedbackGenerator(view: window)
            light = UIImpactFeedbackGenerator(style: .light, view: window)
            medium = UIImpactFeedbackGenerator(style: .medium, view: window)
            soft = UIImpactFeedbackGenerator(style: .soft, view: window)
            rigid = UIImpactFeedbackGenerator(style: .rigid, view: window)
        }

        func play(_ haptic: Haptic) {
            switch haptic {
            case .success: notification.notificationOccurred(.success)
            case .warning: notification.notificationOccurred(.warning)
            case .error: notification.notificationOccurred(.error)
            default:
                let style = haptic.impactStyle
                let generator = switch style.style {
                case .light: light
                case .soft: soft
                case .rigid: rigid
                default: medium
                }
                generator.impactOccurred(intensity: style.intensity)
            }
        }

        func detach() {
            for interaction in [notification, light, medium, soft, rigid] as [UIInteraction] {
                window?.removeInteraction(interaction)
            }
        }
    }
    #endif
}

/// Haptics for a UIKit view that knows where the touch was (the session's interaction view).
/// Location lets the system play them where they belong; `prepare()` when a touch lands so the
/// feedback isn't late when the gesture is recognized.
@MainActor
final class ViewHaptics {
    #if canImport(UIKit) && !os(visionOS)
    /// Nil where haptics can't play (iPad), so nothing is created there.
    private let light: UIImpactFeedbackGenerator?
    private let medium: UIImpactFeedbackGenerator?

    init(view: UIView) {
        let supported = Haptics.isSupported
        light = supported ? UIImpactFeedbackGenerator(style: .light, view: view) : nil
        medium = supported ? UIImpactFeedbackGenerator(style: .medium, view: view) : nil
    }

    /// A touch landed that may become a press or a multi-finger click.
    func prepare() {
        guard Haptics.isEnabled else { return }
        light?.prepare()
        medium?.prepare()
    }

    func play(_ haptic: Haptic, at location: CGPoint) {
        guard Haptics.isEnabled else { return }
        Haptics.record(haptic)
        let style = haptic.impactStyle
        let generator = style.style == .light ? light : medium
        generator?.impactOccurred(intensity: style.intensity, at: location)
    }
    #else
    init(view: AnyObject) {}
    func prepare() {}
    func play(_ haptic: Haptic, at location: CGPoint) {}
    #endif
}

extension Haptic {
    /// How each moment feels, for SwiftUI: outcomes use the system's notification patterns,
    /// everything else an impact, so the UIKit rendering below can match it exactly.
    var sensoryFeedback: SensoryFeedback {
        switch self {
        case .latch: .impact(flexibility: .rigid, intensity: 0.7)
        case .unlatch: .impact(flexibility: .soft, intensity: 0.5)
        case .start: .impact(weight: .medium, intensity: 0.9)
        case .stop: .impact(weight: .light, intensity: 0.7)
        case .snap: .impact(weight: .medium, intensity: 0.6)
        case .press: .impact(weight: .medium, intensity: 0.8)
        case .secondaryClick: .impact(weight: .light, intensity: 0.6)
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }

    #if canImport(UIKit) && !os(visionOS)
    /// The same feel in UIKit terms (the notification cases are played separately).
    fileprivate var impactStyle: (style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat) {
        switch self {
        case .latch: (.rigid, 0.7)
        case .unlatch: (.soft, 0.5)
        case .start: (.medium, 0.9)
        case .stop: (.light, 0.7)
        case .snap: (.medium, 0.6)
        case .press: (.medium, 0.8)
        case .secondaryClick: (.light, 0.6)
        case .success, .warning, .error: (.medium, 1)
        }
    }
    #endif
}

extension View {
    /// Plays `haptic` whenever `trigger` changes (and haptics are on).
    func haptic<T: Equatable>(_ haptic: Haptic, trigger: T) -> some View {
        modifier(HapticModifier(trigger: trigger) { _, _ in haptic })
    }

    /// Plays whatever `haptic` returns for each change of `trigger`; nil plays nothing.
    func haptic<T: Equatable>(trigger: T, _ haptic: @escaping (_ old: T, _ new: T) -> Haptic?) -> some View {
        modifier(HapticModifier(trigger: trigger, haptic: haptic))
    }
}

private struct HapticModifier<T: Equatable>: ViewModifier {
    let trigger: T
    let haptic: (T, T) -> Haptic?

    // The supported check is fixed for the process, so this never flips between branches.
    @ViewBuilder func body(content: Content) -> some View {
        #if os(visionOS)
        content
        #else
        if Haptics.isSupported {
            content.sensoryFeedback(trigger: trigger) { old, new in
                guard Haptics.isEnabled, let chosen = haptic(old, new) else { return nil }
                Haptics.record(chosen)
                return chosen.sensoryFeedback
            }
        } else {
            content
        }
        #endif
    }
}

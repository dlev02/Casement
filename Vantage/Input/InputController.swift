import CoreGraphics
import Foundation
import VantageCore

/// Translates client-side gestures/keys into wire input events, tracking the pointer position
/// for both touch (absolute) and trackpad (relative) modes and normalizing to the streamed
/// display's point space.
@MainActor
final class InputController {
    enum TouchMode: String, CaseIterable, Identifiable, Sendable {
        case direct   // tap = click at point
        case trackpad // relative cursor movement
        var id: String { rawValue }
        var label: String { self == .direct ? "Direct Touch" : "Trackpad" }
        var symbol: String { self == .direct ? "hand.point.up.left" : "rectangle.and.hand.point.up.left" }
    }

    var mode: TouchMode = .trackpad
    var trackpadSensitivity: Double = 1.5
    var naturalScroll = true

    /// Point size of the streamed display (set from StreamConfig).
    var displayPointSize: CGSize = CGSize(width: 1210, height: 834)
    /// Size of the session view the video is aspect-fit into (set on every layout).
    var viewSize: CGSize = .zero
    /// Worked out from both sizes on every use: the display size usually arrives after the
    /// view's first layout, and a rect stored at layout time kept the default display's shape.
    var pointerMapping: PointerMapping { PointerMapping(displaySize: displayPointSize, viewSize: viewSize) }

    /// Current cursor position in display points (trackpad mode maintains this).
    private(set) var cursorPoint: CGPoint = CGPoint(x: 605, y: 417)

    var send: ((Message) -> Void)?

    // MARK: Pointer

    /// Absolute move to a point in the client view (pointer, Pencil, direct-touch tap/drag). Points
    /// past or at the edge of the picture land on the Mac's edge (see `PointerMapping`).
    func moveAbsolute(viewPoint: CGPoint, action: PointerAction, button: PointerButton = .left, clickCount: Int = 1, modifiers: KeyModifiers = []) {
        guard let point = pointerMapping.displayPoint(forViewPoint: viewPoint) else { return }
        cursorPoint = point
        emitPointer(action: action, button: button, clickCount: clickCount, modifiers: modifiers)
    }

    /// Relative move (trackpad mode).
    func moveRelative(translation: CGSize, action: PointerAction = .move, button: PointerButton = .left, modifiers: KeyModifiers = []) {
        let scale = trackpadSensitivity
        cursorPoint.x = (cursorPoint.x + translation.width * scale).clamped(0, displayPointSize.width - 1)
        cursorPoint.y = (cursorPoint.y + translation.height * scale).clamped(0, displayPointSize.height - 1)
        emitPointer(action: action, button: button, clickCount: 1, modifiers: modifiers)
    }

    /// Lets go of `button` where the pointer already is.
    func release(button: PointerButton = .left, modifiers: KeyModifiers = []) {
        emitPointer(action: .up, button: button, clickCount: 1, modifiers: modifiers)
    }

    func click(button: PointerButton, clickCount: Int = 1, modifiers: KeyModifiers = []) {
        emitPointer(action: .down, button: button, clickCount: clickCount, modifiers: modifiers)
        emitPointer(action: .up, button: button, clickCount: clickCount, modifiers: modifiers)
    }

    private func emitPointer(action: PointerAction, button: PointerButton, clickCount: Int, modifiers: KeyModifiers) {
        send?(.pointerEvent(PointerEvent(action: action, button: button, x: Float(cursorPoint.x), y: Float(cursorPoint.y), clickCount: UInt8(max(1, clickCount)), modifiers: modifiers)))
    }

    // MARK: Scroll

    func scroll(deltaX: Double, deltaY: Double, phase: ScrollPhase, momentum: MomentumPhase = .none, continuous: Bool,
                velocity: CGSize = .zero, modifiers: KeyModifiers = []) {
        send?(.scrollEvent(ScrollEvent(
            phase: phase, momentum: momentum, isContinuous: continuous,
            deltaX: Float(deltaX), deltaY: Float(deltaY),
            x: Float(cursorPoint.x), y: Float(cursorPoint.y),
            velocityX: Float(velocity.width), velocityY: Float(velocity.height), modifiers: modifiers)))
    }

    // MARK: Keyboard

    func key(hidUsage: UInt16, isDown: Bool, modifiers: KeyModifiers, isRepeat: Bool = false) {
        guard let keyCode = HIDKeyMap.virtualKey(forHIDUsage: hidUsage) else { return }
        send?(.keyEvent(KeyEvent(keyCode: keyCode, isDown: isDown, modifiers: modifiers, isRepeat: isRepeat)))
    }

    /// A key by macOS virtual key code, the wire's own format (the Mac client's `NSEvent.keyCode`).
    func keyCode(_ keyCode: UInt16, isDown: Bool, modifiers: KeyModifiers, isRepeat: Bool = false) {
        send?(.keyEvent(KeyEvent(keyCode: keyCode, isDown: isDown, modifiers: modifiers, isRepeat: isRepeat)))
    }

    /// Sends a modifier key as a discrete press+release (for the on-screen modifier strip acting
    /// as a sticky modifier is handled in the view; this is for one-shot chords).
    func tapChord(keyCode: UInt16, modifiers: KeyModifiers) {
        send?(.keyEvent(KeyEvent(keyCode: keyCode, isDown: true, modifiers: modifiers)))
        send?(.keyEvent(KeyEvent(keyCode: keyCode, isDown: false, modifiers: modifiers)))
    }

    func typeText(_ text: String) {
        send?(.textInput(TextInput(text: text)))
    }

    /// Types `text` as real key presses (US layout). Characters with no key mapping fall back to
    /// Unicode text so nothing is dropped. `modifiers` (sticky ⌘/⌥/⌃) apply to every stroke.
    func typeCharacters(_ text: String, modifiers: KeyModifiers = []) {
        var pendingText = ""
        func flushText() {
            guard !pendingText.isEmpty else { return }
            typeText(pendingText)
            pendingText = ""
        }
        for character in text {
            if let stroke = CharacterKeyMap.stroke(for: character) {
                flushText()
                tapChord(keyCode: stroke.keyCode, modifiers: stroke.modifiers.union(modifiers))
            } else {
                pendingText.append(character)
            }
        }
        flushText()
    }
}

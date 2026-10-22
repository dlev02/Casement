import CoreGraphics
import Foundation
import ImageIO
import VantageCore

/// The host's pointer as this device draws it: a PC sends its look (`cursorShape`) and leaves it
/// out of the video, so the pointer moves the moment the mouse does, the way Remote Desktop's
/// does, rather than a capture, encode, network trip and decode later.
nonisolated struct LocalCursor: @unchecked Sendable {
    let image: CGImage
    /// In host display points.
    let size: CGSize
    let hotspot: CGPoint

    init?(_ shape: CursorShape) {
        guard shape.widthPoints > 0, shape.heightPoints > 0,
              let source = CGImageSourceCreateWithData(shape.pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.image = image
        size = CGSize(width: shape.widthPoints, height: shape.heightPoints)
        hotspot = CGPoint(x: shape.hotspotX, y: shape.hotspotY)
    }

    /// How big to draw it for a picture scaled by `pictureScale`: with the picture, but never so
    /// small it's hard to find nor larger than the host's own size by much.
    static func drawScale(pictureScale: CGFloat) -> CGFloat { min(max(pictureScale, 0.75), 1.25) }
}

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
    /// "⌘ acts as Ctrl" for a PC. Applies to the hardware keyboard only: callers pass modifiers
    /// already remapped (`keyRemap.modifiers`) with the strip's sticky ones added as they are.
    var keyRemap = KeyRemap.none

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

    /// The host's pointer when this device draws it (nil: it's in the video).
    private(set) var localCursor: LocalCursor?
    /// The host hides its pointer (a game, typing): don't draw ours either.
    private(set) var localCursorVisible = true
    /// The session view redraws the pointer: after every move this controller sends, and when the
    /// shape or visibility changes.
    var onLocalCursorChange: (() -> Void)?

    func setCursorShape(_ shape: CursorShape?) {
        localCursor = shape.flatMap(LocalCursor.init)
        if shape == nil { localCursorVisible = true }
        onLocalCursorChange?()
    }

    func setCursorVisible(_ visible: Bool) {
        guard visible != localCursorVisible else { return }
        localCursorVisible = visible
        onLocalCursorChange?()
    }

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
        if localCursor != nil { onLocalCursorChange?() }
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

    /// A hardware keyboard key. Its key code goes through `keyRemap` (⌘ ↔ ⌃ on a PC);
    /// `modifiers` are sent as given.
    func key(hidUsage: UInt16, isDown: Bool, modifiers: KeyModifiers, isRepeat: Bool = false) {
        guard let keyCode = HIDKeyMap.virtualKey(forHIDUsage: hidUsage) else { return }
        send?(.keyEvent(KeyEvent(keyCode: keyRemap.keyCode(keyCode), isDown: isDown, modifiers: modifiers, isRepeat: isRepeat)))
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

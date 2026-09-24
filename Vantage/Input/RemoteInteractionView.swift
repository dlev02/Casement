#if canImport(UIKit)
import AVFoundation
import UIKit
import VantageCore

/// The core interaction surface: hosts the video layer and captures touch, trackpad/mouse pointer,
/// scroll, and hardware keyboard input, forwarding everything through `InputController`.
final class RemoteInteractionView: UIView {
    let input: InputController
    private let displayLayer: AVSampleBufferDisplayLayer
    private var hardwareModifiers: KeyModifiers = []
    private var stickyModifiers: KeyModifiers = []
    private var heldModifiers: KeyModifiers { hardwareModifiers.union(stickyModifiers) }

    /// Runs the action the user assigned to an Apple Pencil squeeze or double-tap.
    var onPencilAction: ((PencilAction) -> Void)?
    var pencilSqueezeAction: PencilAction = .collapseControls
    var pencilDoubleTapAction: PencilAction = .rightClick

    /// A Pencil points at what you mean, so it always positions the pointer absolutely no matter
    /// which touch mode fingers are using.
    private var isPencilTouch = false
    private var pointsAbsolutely: Bool {
        #if os(visionOS)
        // Look and pinch lands where you looked, so a relative trackpad mapping would only fight
        // you. The touch mode setting is an iPad concept.
        true
        #else
        input.mode == .direct || isPencilTouch
        #endif
    }

    init(input: InputController, displayLayer: AVSampleBufferDisplayLayer) {
        self.input = input
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(displayLayer)
        setupGestures()
        setupPointer()
        #if !os(visionOS)
        addInteraction(UIPencilInteraction(delegate: self))
        #endif
        #if DEBUG
        if ClientOptions.pointerProbe {
            isAccessibilityElement = true
            accessibilityIdentifier = "session.pointerProbe"
        }
        #endif
    }

    #if DEBUG
    /// `-VantagePointerProbe 1`: where the Mac's pointer was last sent, for UI tests.
    override var accessibilityValue: String? {
        get {
            guard ClientOptions.pointerProbe else { return super.accessibilityValue }
            let point = input.cursorPoint, size = input.displayPointSize
            return String(format: "%.1f %.1f of %.0f %.0f", point.x, point.y, size.width, size.height)
        }
        set { super.accessibilityValue = newValue }
    }
    #endif

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    #if !os(visionOS)
    /// Suppress the iPadOS hardware-keyboard shortcut bar; Vantage provides its own control strip.
    override var inputAssistantItem: UITextInputAssistantItem {
        let item = super.inputAssistantItem
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []
        return item
    }
    #endif

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
        input.viewSize = bounds.size
    }

    // MARK: Gestures

    /// Finger and Pencil gestures only. Trackpad and mouse input is handled in `touchesBegan` and
    /// friends so that button state can be diffed off `UIEvent.buttonMask` — a gesture recognizer
    /// can't tell a right-button drag from a left-button one.
    private func setupGestures() {
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        singleTap.allowedTouchTypes = Self.directTouchTypes
        addGestureRecognizer(singleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = Self.fingerTouchTypes
        addGestureRecognizer(twoFingerTap)

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.allowedTouchTypes = Self.fingerTouchTypes
        addGestureRecognizer(threeFingerTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = Self.directTouchTypes
        addGestureRecognizer(pan)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.allowedTouchTypes = Self.fingerTouchTypes
        addGestureRecognizer(twoFingerPan)

        // Trackpad and wheel scrolling arrive as scroll events rather than touches, and there is no
        // way to ask an update which kind produced it — so one recognizer per scroll type.
        for mask in [UIScrollTypeMask.continuous, .discrete] {
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleIndirectScroll))
            scroll.allowedScrollTypesMask = mask
            scroll.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            scroll.maximumNumberOfTouches = 0
            addGestureRecognizer(scroll)
            if mask == .discrete { discreteScrollRecognizer = scroll }
        }

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        #if os(visionOS)
        longPress.minimumPressDuration = 0.5 // a pinch held still for a beat, not a drag that starts slowly
        #else
        longPress.minimumPressDuration = 0.35
        #endif
        longPress.allowedTouchTypes = Self.directTouchTypes
        addGestureRecognizer(longPress)
    }

    private static let fingerTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    private static let directTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                           NSNumber(value: UITouch.TouchType.pencil.rawValue)]

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        if pointsAbsolutely {
            input.moveAbsolute(viewPoint: location, action: .move, modifiers: heldModifiers)
        }
        input.click(button: .left, clickCount: 1, modifiers: heldModifiers)
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        input.click(button: .right, modifiers: heldModifiers)
    }

    @objc private func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
        input.click(button: .middle, modifiers: heldModifiers)
    }

    private var lastPanPoint: CGPoint = .zero

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            lastPanPoint = location
            if pointsAbsolutely {
                input.moveAbsolute(viewPoint: location, action: .down, modifiers: heldModifiers)
            }
        case .changed:
            if pointsAbsolutely {
                input.moveAbsolute(viewPoint: location, action: .move, modifiers: heldModifiers)
            } else {
                let translation = CGSize(width: location.x - lastPanPoint.x, height: location.y - lastPanPoint.y)
                input.moveRelative(translation: translation, action: .move, modifiers: heldModifiers)
                lastPanPoint = location
            }
        case .ended:
            if pointsAbsolutely {
                input.moveAbsolute(viewPoint: location, action: .up, modifiers: heldModifiers)
            }
        case .cancelled:
            // A system gesture took the touch: let go where the pointer is rather than trusting
            // the location of a touch that's gone.
            if pointsAbsolutely { input.release(modifiers: heldModifiers) }
        default:
            break
        }
    }

    /// Trackpad and wheel scrolling. Continuous scrolls carry pixel deltas and gesture phases like
    /// a finger scroll; wheel notches are discrete, so they go over as line deltas with no phase.
    @objc private func handleIndirectScroll(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer !== discreteScrollRecognizer else {
            let translation = recognizer.translation(in: self)
            guard recognizer.state == .changed || recognizer.state == .began else { return }
            recognizer.setTranslation(.zero, in: self)
            let sign: Double = input.naturalScroll ? 1 : -1
            let lines = (x: (translation.x / Self.pointsPerScrollLine) * sign,
                         y: (translation.y / Self.pointsPerScrollLine) * sign)
            guard lines.x != 0 || lines.y != 0 else { return }
            input.scroll(deltaX: lines.x, deltaY: lines.y, phase: .none, continuous: false)
            return
        }
        handleScroll(recognizer)
    }

    /// One wheel notch on a Logitech mouse arrives as roughly this much translation.
    private static let pointsPerScrollLine: Double = 10

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {

        let translation = recognizer.translation(in: self)
        let velocity = recognizer.velocity(in: self)
        let sign: Double = input.naturalScroll ? 1 : -1
        switch recognizer.state {
        case .began:
            input.scroll(deltaX: Double(translation.x) * sign, deltaY: Double(translation.y) * sign, phase: .began, continuous: true)
        case .changed:
            input.scroll(deltaX: Double(translation.x) * sign, deltaY: Double(translation.y) * sign, phase: .changed, continuous: true)
            recognizer.setTranslation(.zero, in: self)
        case .ended:
            input.scroll(deltaX: 0, deltaY: 0, phase: .ended, momentum: .began, continuous: true, velocity: CGSize(width: velocity.x * sign, height: velocity.y * sign))
        case .cancelled:
            input.scroll(deltaX: 0, deltaY: 0, phase: .cancelled, continuous: true)
        default:
            break
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: self)
        #if os(visionOS)
        // A held pinch is visionOS's secondary action, and there's no two-finger tap, so it's the
        // right-click. Pinch and drag still drags, through the pan recognizer.
        if recognizer.state == .began {
            input.moveAbsolute(viewPoint: location, action: .move, modifiers: heldModifiers)
            input.click(button: .right, modifiers: heldModifiers)
        }
        #else
        switch recognizer.state {
        case .began:
            if pointsAbsolutely {
                input.moveAbsolute(viewPoint: location, action: .down, modifiers: heldModifiers)
            } else {
                input.click(button: .left, clickCount: 1, modifiers: heldModifiers) // long-press acts as press-and-hold
            }
        case .changed where pointsAbsolutely:
            input.moveAbsolute(viewPoint: location, action: .move, modifiers: heldModifiers)
        case .ended:
            if pointsAbsolutely {
                input.moveAbsolute(viewPoint: location, action: .up, modifiers: heldModifiers)
            }
        case .cancelled:
            if pointsAbsolutely { input.release(modifiers: heldModifiers) }
        default:
            break
        }
        #endif
    }

    // MARK: Pointer (Magic Keyboard trackpad / Bluetooth mouse)

    private var discreteScrollRecognizer: UIPanGestureRecognizer?
    private var lastButtonMask: UIEvent.ButtonMask = []

    /// Buttons UIKit actually delivers to third-party apps. Side buttons (4 and 5) never arrive
    /// through `buttonMask`, so they aren't listed.
    private static let pointerButtons: [(PointerButton, UIEvent.ButtonMask)] = [
        (.left, .primary), (.right, .secondary), (.middle, .button(3)),
    ]

    private func setupPointer() {
        let interaction = UIPointerInteraction(delegate: self)
        addInteraction(interaction)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(hover)

        // Apple Pencil Pro hovers too, and following it means the Mac's pointer is already where
        // you're about to tap.
        let pencilHover = UIHoverGestureRecognizer(target: self, action: #selector(handlePencilHover))
        pencilHover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        addGestureRecognizer(pencilHover)
    }

    @objc private func handlePencilHover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        input.moveAbsolute(viewPoint: recognizer.location(in: self), action: .move, modifiers: heldModifiers)
    }

    /// A trackpad or mouse always positions the Mac's pointer absolutely — you can see where the
    /// iPad's pointer is, so a relative mapping would only fight you. The touch mode setting is
    /// about fingers.
    ///
    /// Only `began` and `changed` carry a position. iPadOS ends the hover as soon as the pointer
    /// leaves the view, and it takes the pointer at a screen edge (the Dock, the menu bar) the
    /// moment you push against it; the end reports (0, 0). Following it threw the Mac's pointer
    /// to its top-left corner, so pushing to the bottom never showed the Mac's Dock. The Mac's
    /// pointer stays where the iPad's pointer left, which at an edge is on that edge.
    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        guard lastButtonMask.isEmpty else { return } // a drag is in progress; touchesMoved owns it
        input.moveAbsolute(viewPoint: recognizer.location(in: self), action: .move, modifiers: heldModifiers)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0.type == .indirectPointer }), let event else {
            if touches.contains(where: { $0.type == .pencil }) { isPencilTouch = true }
            super.touchesBegan(touches, with: event)
            return
        }
        updateButtons(mask: event.buttonMask, touch: touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0.type == .indirectPointer }), let event else {
            super.touchesMoved(touches, with: event)
            return
        }
        updateButtons(mask: event.buttonMask, touch: touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0.type == .indirectPointer }) else {
            // Cleared after the gesture recognizers have run, so the whole stroke stays absolute.
            if touches.contains(where: { $0.type == .pencil }) {
                DispatchQueue.main.async { self.isPencilTouch = false }
            }
            super.touchesEnded(touches, with: event)
            return
        }

        // An indirect-pointer touch runs from the first button press to the last release, and iOS
        // still reports the released button in the mask here — so treat the end as "nothing held".
        updateButtons(mask: [], touch: touch)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0.type == .indirectPointer }) else {
            if touches.contains(where: { $0.type == .pencil }) {
                DispatchQueue.main.async { self.isPencilTouch = false }
            }
            super.touchesCancelled(touches, with: event)
            return
        }

        updateButtons(mask: [], touch: touch)
    }

    /// Moves the pointer, then emits a down or up for every button whose state changed. Motion with
    /// a button held only arrives here, which is what makes right- and middle-button drags work.
    private func updateButtons(mask: UIEvent.ButtonMask, touch: UITouch) {
        let location = touch.location(in: self)
        let clickCount = max(1, touch.tapCount)
        input.moveAbsolute(viewPoint: location, action: .move, button: .left, clickCount: 1, modifiers: heldModifiers)
        for (button, flag) in Self.pointerButtons {
            let isDown = mask.contains(flag)
            let wasDown = lastButtonMask.contains(flag)
            guard isDown != wasDown else { continue }
            input.moveAbsolute(viewPoint: location, action: isDown ? .down : .up,
                               button: button, clickCount: clickCount, modifiers: heldModifiers)
        }
        lastButtonMask = mask
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            updateModifiers(from: key.modifierFlags)
            input.key(hidUsage: UInt16(key.keyCode.rawValue), isDown: true, modifiers: heldModifiers)
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            updateModifiers(from: key.modifierFlags)
            input.key(hidUsage: UInt16(key.keyCode.rawValue), isDown: false, modifiers: heldModifiers)
            handled = true
        }
        if !handled { super.pressesEnded(presses, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            if let key = press.key { updateModifiers(from: key.modifierFlags) }
        }
    }

    /// Sets modifiers held by the on-screen modifier strip; combined with hardware modifiers.
    func setStickyModifiers(_ modifiers: KeyModifiers) {
        stickyModifiers = modifiers
    }

    private func updateModifiers(from flags: UIKeyModifierFlags) {
        var modifiers: KeyModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.alphaShift) { modifiers.insert(.capsLock) }
        hardwareModifiers = modifiers
    }
}

extension RemoteInteractionView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }
}

#if !os(visionOS)
extension RemoteInteractionView: UIPencilInteractionDelegate {
    /// Both gestures report several phases; act once, on the end, so a squeeze doesn't fire twice.
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        perform(pencilSqueezeAction, at: squeeze.hoverPose?.location)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        perform(pencilDoubleTapAction, at: tap.hoverPose?.location)
    }

    /// Clicks land wherever the Pencil is hovering when the iPad can see it, and otherwise at the
    /// pointer's last position — the same place the Pencil last touched.
    private func perform(_ action: PencilAction, at location: CGPoint?) {
        switch action {
        case .none:
            return
        case .rightClick, .middleClick:
            let button: PointerButton = action == .rightClick ? .right : .middle
            if let location {
                input.moveAbsolute(viewPoint: location, action: .move, modifiers: heldModifiers)
            }
            input.click(button: button, modifiers: heldModifiers)
        case .collapseControls, .hideControls, .showKeyboard:
            onPencilAction?(action)
        }
    }
}
#endif
#endif

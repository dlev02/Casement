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

    init(input: InputController, displayLayer: AVSampleBufferDisplayLayer) {
        self.input = input
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(displayLayer)
        setupGestures()
        setupPointer()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeFirstResponder: Bool { true }

    /// Suppress the iPadOS hardware-keyboard shortcut bar; Vantage provides its own control strip.
    override var inputAssistantItem: UITextInputAssistantItem {
        let item = super.inputAssistantItem
        item.leadingBarButtonGroups = []
        item.trailingBarButtonGroups = []
        return item
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
        updateVideoRect()
    }

    private func updateVideoRect() {
        let aspect = input.displayPointSize
        input.videoRect = Geometry.aspectFit(aspect, in: bounds.size)
    }

    // MARK: Gestures

    private func setupGestures() {
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(singleTap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.allowedScrollTypesMask = [.continuous, .discrete]
        addGestureRecognizer(pan)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        addGestureRecognizer(twoFingerPan)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.35
        addGestureRecognizer(longPress)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        if input.mode == .direct {
            input.moveAbsolute(viewPoint: location, action: .move, modifiers: heldModifiers)
        }
        input.click(button: .left, clickCount: 1, modifiers: heldModifiers)
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
        input.click(button: .right, modifiers: heldModifiers)
    }

    private var lastPanPoint: CGPoint = .zero

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            lastPanPoint = location
            if input.mode == .direct {
                input.moveAbsolute(viewPoint: location, action: .down, modifiers: heldModifiers)
            }
        case .changed:
            if input.mode == .direct {
                input.moveAbsolute(viewPoint: location, action: .move, modifiers: heldModifiers)
            } else {
                let translation = CGSize(width: location.x - lastPanPoint.x, height: location.y - lastPanPoint.y)
                input.moveRelative(translation: translation, action: .move, modifiers: heldModifiers)
                lastPanPoint = location
            }
        case .ended, .cancelled:
            if input.mode == .direct {
                input.moveAbsolute(viewPoint: location, action: .up, modifiers: heldModifiers)
            }
        default:
            break
        }
    }

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
        switch recognizer.state {
        case .began:
            if input.mode == .direct {
                input.moveAbsolute(viewPoint: location, action: .down, modifiers: heldModifiers)
            } else {
                input.click(button: .left, clickCount: 1, modifiers: heldModifiers) // long-press acts as press-and-hold
            }
        case .changed where input.mode == .direct:
            input.moveAbsolute(viewPoint: location, action: .move, modifiers: heldModifiers)
        case .ended, .cancelled:
            if input.mode == .direct {
                input.moveAbsolute(viewPoint: location, action: .up, modifiers: heldModifiers)
            }
        default:
            break
        }
    }

    // MARK: Pointer (Magic Keyboard trackpad / Bluetooth mouse)

    private func setupPointer() {
        let interaction = UIPointerInteraction(delegate: self)
        addInteraction(interaction)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))
        addGestureRecognizer(hover)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        let location = recognizer.location(in: self)
        if input.mode == .direct {
            input.moveAbsolute(viewPoint: location, action: .move, modifiers: heldModifiers)
        }
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
#endif

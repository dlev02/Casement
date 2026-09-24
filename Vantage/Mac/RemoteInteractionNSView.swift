#if os(macOS)
import AppKit
import AVFoundation
import VantageCore

/// The Mac client's session surface: shows the Mac's picture and sends this Mac's pointer,
/// buttons and scrolling to it (the keyboard goes through `KeyboardCapture`).
///
/// Raw `mouseDown`/`scrollWheel` overrides on purpose: gesture recognizers don't give per-button
/// downs, ups and drags for every button, `clickCount`, or scroll and momentum phases.
///
/// The pointer always points absolutely through `PointerMapping`, so the picture's edges are the
/// Mac's edges: the last point of the view is the Mac's last row or column, and a drag that
/// leaves the view keeps arriving here and pins to the edge. The local cursor is blank over the
/// picture (the Mac draws its own pointer into the video) and normal over the SwiftUI overlays
/// on top (the control strip, notices), where moves aren't sent. Nothing is sent while View Only
/// is on, while locked, or for events the host posted itself (`isFromVantageHost`).
final class RemoteInteractionNSView: NSView {
    let input: InputController
    let keyboard: KeyboardCapture
    private let displayLayer: AVSampleBufferDisplayLayer

    /// Pointer, buttons, scrolling and keys go to the Mac (connected, not View Only, not locked).
    var sendsInput = false {
        didSet {
            guard sendsInput != oldValue else { return }
            if !sendsInput { releaseButtons() }
            keyboard.isActive = sendsInput
            window?.invalidateCursorRects(for: self)
            updateCursor(overPicture: sendsInput)
        }
    }
    /// Modifiers held from the control strip, added to every click and scroll.
    var stickyModifiers: KeyModifiers = []

    private var heldButtons: Set<PointerButton> = []
    private var scroll = ScrollTranslator()
    private var trackingArea: NSTrackingArea?
    private var showsBlankCursor = false

    init(input: InputController, displayLayer: AVSampleBufferDisplayLayer) {
        self.input = input
        self.displayLayer = displayLayer
        self.keyboard = KeyboardCapture(input: input)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
        keyboard.view = self
        keyboard.onLostKeyboard = { [weak self] in self?.releaseButtons() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// The click that brings the window forward only brings it forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
        input.viewSize = bounds.size
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        displayLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { keyboard.detach() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        displayLayer.contentsScale = window.backingScaleFactor
        keyboard.attach(to: window)
        window.makeFirstResponder(self)
    }

    /// Lets go of every button still down on the Mac (the window lost the keyboard, View Only,
    /// the session ended).
    func releaseButtons() {
        for button in heldButtons.sorted(by: { $0.rawValue < $1.rawValue }) {
            input.release(button: button)
        }
        heldButtons.removeAll()
    }

    // MARK: Tracking and cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(overPicture: !isOverOverlay(event))
    }

    override func mouseExited(with event: NSEvent) {
        updateCursor(overPicture: false)
    }

    /// Blank over the picture while input goes to the Mac; the arrow everywhere else.
    private func updateCursor(overPicture: Bool) {
        let blank = overPicture && sendsInput
        guard blank != showsBlankCursor else { return }
        showsBlankCursor = blank
        (blank ? Self.blankCursor : NSCursor.arrow).set()
    }

    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    /// The event is over something SwiftUI draws above the picture (the control strip, a notice).
    private func isOverOverlay(_ event: NSEvent) -> Bool {
        guard let frameView = window?.contentView?.superview else { return false }
        guard let hit = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil)) else { return false }
        return hit !== self && !hit.isDescendant(of: self)
    }

    // MARK: Pointer

    override func mouseMoved(with event: NSEvent) {
        let overlay = isOverOverlay(event)
        updateCursor(overPicture: !overlay)
        guard sendsInput, !overlay, !event.isFromVantageHost else { return }
        input.moveAbsolute(viewPoint: point(of: event), action: .move, modifiers: modifiers(of: event))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        press(.left, event)
    }
    override func mouseDragged(with event: NSEvent) { drag(event) }
    override func mouseUp(with event: NSEvent) { release(.left, event) }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        press(.right, event)
    }
    override func rightMouseDragged(with event: NSEvent) { drag(event) }
    override func rightMouseUp(with event: NSEvent) { release(.right, event) }

    override func otherMouseDown(with event: NSEvent) {
        guard let button = Self.button(number: event.buttonNumber) else { return }
        press(button, event)
    }
    override func otherMouseDragged(with event: NSEvent) { drag(event) }
    override func otherMouseUp(with event: NSEvent) {
        guard let button = Self.button(number: event.buttonNumber) else { return }
        release(button, event)
    }

    /// The Mac's own numbering: 2 is the middle button, 3 and 4 the side buttons.
    static func button(number: Int) -> PointerButton? {
        switch number {
        case 2: .middle
        case 3: .back
        case 4: .forward
        default: nil
        }
    }

    /// ⌃-click stays a left click with ⌃ held; the Mac makes it a secondary click itself.
    private func press(_ button: PointerButton, _ event: NSEvent) {
        guard sendsInput, !event.isFromVantageHost else { return }
        heldButtons.insert(button)
        input.moveAbsolute(viewPoint: point(of: event), action: .down, button: button,
                           clickCount: event.clickCount, modifiers: modifiers(of: event))
    }

    /// Drags keep arriving after the pointer leaves the view; `PointerMapping` pins them to the
    /// Mac's edge. The host turns a move with a button down into that button's drag.
    private func drag(_ event: NSEvent) {
        guard sendsInput, !heldButtons.isEmpty, !event.isFromVantageHost else { return }
        input.moveAbsolute(viewPoint: point(of: event), action: .move, modifiers: modifiers(of: event))
    }

    private func release(_ button: PointerButton, _ event: NSEvent) {
        guard heldButtons.remove(button) != nil, !event.isFromVantageHost else { return }
        input.moveAbsolute(viewPoint: point(of: event), action: .up, button: button,
                           clickCount: event.clickCount, modifiers: modifiers(of: event))
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        guard sendsInput, !event.isFromVantageHost else { return }
        let local = ScrollTranslator.Input(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                           isPrecise: event.hasPreciseScrollingDeltas,
                                           phase: event.phase.rawValue, momentumPhase: event.momentumPhase.rawValue)
        guard let wire = scroll.translate(local) else { return }
        input.scroll(deltaX: wire.deltaX, deltaY: wire.deltaY, phase: wire.phase, momentum: wire.momentum,
                     continuous: wire.isContinuous, modifiers: modifiers(of: event))
    }

    // MARK: Keyboard

    /// Keys reach the Mac through `KeyboardCapture`'s monitor before they get here. What does get
    /// here (Vantage's own ⌃⌥⌘ chords no menu took, keys while View Only) stops here instead of
    /// beeping.
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}

    // MARK: Helpers

    private func point(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func modifiers(of event: NSEvent) -> KeyModifiers {
        keyboard.modifiers(fromFlags: UInt64(event.modifierFlags.rawValue)).union(stickyModifiers)
    }

    // MARK: Probes

    #if DEBUG
    /// `-VantagePointerProbe 1`: the Mac pointer position last sent, as `session.pointerProbe`'s
    /// value, for UI tests.
    override func isAccessibilityElement() -> Bool { ClientOptions.pointerProbe || super.isAccessibilityElement() }
    override func accessibilityIdentifier() -> String { ClientOptions.pointerProbe ? "session.pointerProbe" : super.accessibilityIdentifier() }
    override func accessibilityRole() -> NSAccessibility.Role? { ClientOptions.pointerProbe ? .group : super.accessibilityRole() }
    override func accessibilityValue() -> Any? {
        guard ClientOptions.pointerProbe else { return super.accessibilityValue() }
        let point = input.cursorPoint, size = input.displayPointSize
        return String(format: "%.1f %.1f of %.0f %.0f", point.x, point.y, size.width, size.height)
    }
    #endif
}

// MARK: - Text input

/// Text that arrives without a key press (the Character Viewer, emoji) is typed on the Mac as
/// text. Key presses never go through here: `keyDown` doesn't call `interpretKeyEvents`.
extension RemoteInteractionNSView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard sendsInput else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        if !text.isEmpty { input.typeText(text) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {}

    /// Where the Character Viewer opens: by the Mac's pointer.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let mapping = input.pointerMapping, rect = mapping.videoRect
        let display = mapping.displaySize, cursor = input.cursorPoint
        let point = display.width > 0 && display.height > 0
            ? CGPoint(x: rect.minX + cursor.x / display.width * rect.width, y: rect.minY + cursor.y / display.height * rect.height)
            : CGPoint(x: bounds.midX, y: bounds.midY)
        let local = NSRect(origin: point, size: NSSize(width: 1, height: 16))
        return window?.convertToScreen(convert(local, to: nil)) ?? .zero
    }
}

extension NSEvent {
    /// Posted by Vantage Host (see `VantageProtocol.injectedEventMarker`): when the host runs on
    /// this same Mac, sending it on would loop it straight back.
    var isFromVantageHost: Bool {
        cgEvent?.getIntegerValueField(.eventSourceUserData) == VantageProtocol.injectedEventMarker
    }
}
#endif

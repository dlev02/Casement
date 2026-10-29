import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VantageCore
import os

/// Injects pointer, scroll, and keyboard events onto the host using CGEvent.
///
/// All events are posted to `.cgSessionEventTap`, each stamped with
/// `VantageProtocol.injectedEventMarker` so a client on this same Mac can tell them from the
/// user's own input and never sends them back. The injector tracks held buttons, modifier
/// flags, and pressed keys so it can release everything on disconnect (no stuck ⌘). Requires the
/// Post Event / Accessibility permission; the app must be unsandboxed.
nonisolated final class InputInjector: @unchecked Sendable {
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "input")
    private let queue = DispatchQueue(label: "vantage.input", qos: .userInteractive)
    private let source = CGEventSource(stateID: .combinedSessionState)
    private let tap: CGEventTapLocation = .cgSessionEventTap

    /// Global frame (points) of the display being controlled.
    private var displayFrame: CGRect
    private var heldButtons: Set<PointerButton> = []
    /// Keys and modifiers held, and how each key goes out.
    private var keyboard = KeyboardSequencer()
    /// The keyboard's modifiers, which pointer and scroll events carry too.
    private var currentFlags: CGEventFlags = []
    private var lastPointer: CGPoint = .zero
    private var naturalScroll: Bool
    private var pointerEventCount = 0
    /// The glide after an iPad flick, one frame per tick of `momentumTimer` (see `ScrollMomentum`).
    private var momentum: ScrollMomentum?
    private var momentumTimer: DispatchSourceTimer?
    private var momentumFlags: CGEventFlags = []

    init(displayFrame: CGRect, naturalScroll: Bool = false) {
        self.displayFrame = displayFrame
        self.naturalScroll = naturalScroll
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents], state: .eventSuppressionStateSuppressionInterval)
    }

    deinit {
        momentumTimer?.cancel() // an active dispatch source outlives its last reference
    }

    static func hasPermission() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestPermission() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func updateDisplayFrame(_ frame: CGRect) {
        queue.async { self.displayFrame = frame }
    }

    func setNaturalScroll(_ enabled: Bool) {
        queue.async { self.naturalScroll = enabled }
    }

    // MARK: Pointer

    func handle(_ event: PointerEvent) {
        queue.async { self.injectPointer(event) }
    }

    private func injectPointer(_ event: PointerEvent) {
        let point = clampToDisplay(CGPoint(x: Double(event.x) + displayFrame.minX, y: Double(event.y) + displayFrame.minY))
        lastPointer = point
        let flags = combinedFlags(with: event.modifiers)

        let type: CGEventType
        // A move while a button is held is a drag, and the drag has to name the button that is
        // actually down — the client sends moves without one.
        var effectiveButton = event.button
        switch event.action {
        case .move:
            if let held = heldButtons.first {
                effectiveButton = held
                type = dragType(for: held)
            } else {
                type = .mouseMoved
            }
        case .down:
            stopMomentum() // a click stops a glide, as touching the trackpad does
            heldButtons.insert(event.button)
            type = downType(for: event.button)
        case .up:
            heldButtons.remove(event.button)
            type = upType(for: event.button)
        }
        let button = cgButton(effectiveButton)

        guard let cgEvent = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            log.error("could not create pointer event")
            return
        }
        cgEvent.flags = flags
        if event.action != .move {
            cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, event.clickCount)))
        }
        if effectiveButton.rawValue >= 2 {
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(effectiveButton.rawValue))
        }

        post(cgEvent)
        pointerEventCount += 1
        if event.action != .move || pointerEventCount == 1 {
            log.info("pointer \(String(describing: event.action), privacy: .public) \(String(describing: event.button), privacy: .public) at \(Int(point.x)),\(Int(point.y)) clicks=\(event.clickCount) trusted=\(AXIsProcessTrusted())")
        }
    }

    // MARK: Scroll

    func handle(_ event: ScrollEvent) {
        queue.async { self.injectScroll(event) }
    }

    /// Continuous deltas are posted negated and line deltas as they come; clients send them
    /// accordingly (the iPad its own way, the Mac client so the posted event equals its own).
    /// Any scroll stops a glide still running.
    private func injectScroll(_ event: ScrollEvent) {
        stopMomentum()
        let flags = combinedFlags(with: event.modifiers)
        if event.isContinuous, event.phase == .ended, event.momentum == .began {
            // An iPad flick: end the gesture, then glide from the finger's velocity. A momentum
            // phase on the `ended` event itself would break the one-phase-at-a-time rule.
            postScroll(deltaX: Double(event.deltaX), deltaY: Double(event.deltaY), isContinuous: true,
                       phase: .ended, momentum: .none, flags: flags)
            startMomentum(ScrollMomentum(velocityX: Double(event.velocityX), velocityY: Double(event.velocityY)), flags: flags)
            return
        }
        postScroll(deltaX: Double(event.deltaX), deltaY: Double(event.deltaY), isContinuous: event.isContinuous,
                   phase: event.phase, momentum: event.momentum, flags: flags)
    }

    private func postScroll(deltaX: Double, deltaY: Double, isContinuous: Bool, phase: ScrollPhase, momentum: MomentumPhase, flags: CGEventFlags) {
        let sign: Double = naturalScroll ? 1 : -1
        let dyPixels = Int32((deltaY * sign).rounded())
        let dxPixels = Int32((deltaX * sign).rounded())
        let unit: CGScrollEventUnit = isContinuous ? .pixel : .line
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: source, units: unit, wheelCount: 2,
                                    wheel1: isContinuous ? dyPixels : Int32(deltaY.rounded()),
                                    wheel2: isContinuous ? dxPixels : Int32(deltaX.rounded()),
                                    wheel3: 0) else { return }
        if isContinuous {
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dyPixels))
            cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dxPixels))
            cgEvent.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(cgScrollPhase(phase)))
            cgEvent.setIntegerValueField(CGEventField(rawValue: 123)!, value: Int64(cgMomentumPhase(momentum)))
        }
        cgEvent.flags = flags
        post(cgEvent)
    }

    private func startMomentum(_ glide: ScrollMomentum?, flags: CGEventFlags) {
        guard let glide else { return }
        momentum = glide
        momentumFlags = flags
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + ScrollMomentum.frameInterval, repeating: ScrollMomentum.frameInterval)
        timer.setEventHandler { [weak self] in self?.stepMomentum() }
        timer.resume()
        momentumTimer = timer
    }

    private func stepMomentum() {
        guard var glide = momentum, let frame = glide.next() else {
            stopMomentum()
            return
        }
        momentum = glide
        postMomentum(frame)
        if glide.isFinished { stopMomentum() }
    }

    /// Ends a glide still running (with its `end` frame) and stops the timer.
    private func stopMomentum() {
        if var glide = momentum, let frame = glide.cancel() { postMomentum(frame) }
        momentum = nil
        momentumTimer?.cancel()
        momentumTimer = nil
    }

    private func postMomentum(_ frame: ScrollMomentum.Frame) {
        postScroll(deltaX: frame.deltaX, deltaY: frame.deltaY, isContinuous: true, phase: .none, momentum: frame.phase, flags: momentumFlags)
    }

    private func cgScrollPhase(_ phase: ScrollPhase) -> UInt32 {
        switch phase {
        case .none: 0
        case .began: 1
        case .changed: 2
        case .ended: 4
        case .cancelled: 8
        }
    }

    private func cgMomentumPhase(_ phase: MomentumPhase) -> UInt32 {
        switch phase {
        case .none: 0
        case .began: 1
        case .changed: 2
        case .ended: 3
        }
    }

    // MARK: Keyboard

    func handle(_ event: KeyEvent) {
        queue.async { self.injectKey(event) }
    }

    /// Keys go out the way a Mac keyboard sends them (`KeyboardSequencer`): modifiers as their own
    /// flagsChanged presses, Fn on arrows and function keys. ⌘Space opens Raycast directly when
    /// Raycast has taken it over, since Raycast ignores anything but a physical keyboard.
    private func injectKey(_ event: KeyEvent) {
        if SearchShortcut.isCommandSpace(event, heldFlags: keyboard.modifierFlags), let url = SearchShortcut.launcherURL() {
            keyboard.consume(event)
            log.info("⌘Space: opening \(url.absoluteString, privacy: .public)")
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return
        }
        post(keyboard.strokes(for: event))
    }

    private func post(_ strokes: [KeyboardSequencer.Stroke]) {
        for stroke in strokes {
            guard let cgEvent = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: stroke.kind == .keyDown) else { continue }
            if stroke.kind == .flagsChanged { cgEvent.type = .flagsChanged }
            cgEvent.flags = stroke.flags
            if stroke.isRepeat { cgEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            post(cgEvent)
        }
        currentFlags = keyboard.modifierFlags
    }

    /// ⌘V, pressed the way a Mac keyboard does (`KeyboardSequencer`).
    func pressPaste() {
        let v: UInt16 = 0x09 // kVK_ANSI_V
        handle(KeyEvent(keyCode: v, isDown: true, modifiers: .command))
        handle(KeyEvent(keyCode: v, isDown: false, modifiers: .command))
    }

    /// Types a Unicode string (software keyboard / dictation / emoji path), chunked to 16 units.
    func typeText(_ text: String) {
        queue.async {
            let units = Array(text.utf16)
            var index = 0
            while index < units.count {
                let chunk = Array(units[index ..< min(index + 16, units.count)])
                guard let down = CGEvent(keyboardEventSource: self.source, virtualKey: 0, keyDown: true) else { break }
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                self.post(down)
                if let up = CGEvent(keyboardEventSource: self.source, virtualKey: 0, keyDown: false) {
                    up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    self.post(up)
                }
                index += 16
            }
        }
    }

    // MARK: Cleanup

    /// Releases every held key and button and clears modifier state. Call on disconnect/focus loss.
    func releaseAll() {
        queue.async {
            self.stopMomentum()
            for button in self.heldButtons {
                if let cgEvent = CGEvent(mouseEventSource: self.source, mouseType: self.upType(for: button), mouseCursorPosition: self.lastPointer, mouseButton: self.cgButton(button)) {
                    self.post(cgEvent)
                }
            }
            self.heldButtons.removeAll()
            // Keys first, then each held modifier comes up as its own key.
            self.post(self.keyboard.releaseAll())
            if !self.currentFlags.isEmpty {
                self.currentFlags = []
                if let cgEvent = CGEvent(keyboardEventSource: self.source, virtualKey: 0, keyDown: false) {
                    cgEvent.type = .flagsChanged
                    cgEvent.flags = []
                    self.post(cgEvent)
                }
            }
        }
    }

    // MARK: Helpers

    /// Posts `event` stamped as Vantage's own (see `VantageProtocol.injectedEventMarker`).
    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: VantageProtocol.injectedEventMarker)
        event.post(tap: tap)
    }

    private func clampToDisplay(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.clamped(displayFrame.minX, displayFrame.maxX - 1),
                y: point.y.clamped(displayFrame.minY, displayFrame.maxY - 1))
    }

    private func combinedFlags(with modifiers: KeyModifiers) -> CGEventFlags {
        var flags = currentFlags
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    private func cgButton(_ button: PointerButton) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .center
        case .back: CGMouseButton(rawValue: 3) ?? .center
        case .forward: CGMouseButton(rawValue: 4) ?? .center
        }
    }

    private func downType(for button: PointerButton) -> CGEventType {
        switch button {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        default: .otherMouseDown
        }
    }

    private func upType(for button: PointerButton) -> CGEventType {
        switch button {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        default: .otherMouseUp
        }
    }

    private func dragType(for button: PointerButton) -> CGEventType {
        switch button {
        case .left: .leftMouseDragged
        case .right: .rightMouseDragged
        default: .otherMouseDragged
        }
    }
}

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VantageCore
import os

/// Injects pointer, scroll, and keyboard events onto the host using CGEvent.
///
/// All events are posted to `.cgSessionEventTap`. The injector tracks held buttons, modifier
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

    init(displayFrame: CGRect, naturalScroll: Bool = false) {
        self.displayFrame = displayFrame
        self.naturalScroll = naturalScroll
        source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitLocalKeyboardEvents], state: .eventSuppressionStateSuppressionInterval)
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

        cgEvent.post(tap: tap)
        pointerEventCount += 1
        if event.action != .move || pointerEventCount == 1 {
            log.info("pointer \(String(describing: event.action), privacy: .public) \(String(describing: event.button), privacy: .public) at \(Int(point.x)),\(Int(point.y)) clicks=\(event.clickCount) trusted=\(AXIsProcessTrusted())")
        }
    }

    // MARK: Scroll

    func handle(_ event: ScrollEvent) {
        queue.async { self.injectScroll(event) }
    }

    private func injectScroll(_ event: ScrollEvent) {
        let sign: Double = naturalScroll ? 1 : -1
        let dyPixels = Int32((Double(event.deltaY) * sign).rounded())
        let dxPixels = Int32((Double(event.deltaX) * sign).rounded())
        let unit: CGScrollEventUnit = event.isContinuous ? .pixel : .line
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: source, units: unit, wheelCount: 2,
                                    wheel1: event.isContinuous ? dyPixels : Int32(event.deltaY.rounded()),
                                    wheel2: event.isContinuous ? dxPixels : Int32(event.deltaX.rounded()),
                                    wheel3: 0) else { return }
        if event.isContinuous {
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dyPixels))
            cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dxPixels))
            cgEvent.setIntegerValueField(CGEventField(rawValue: 99)!, value: Int64(cgScrollPhase(event.phase)))
            cgEvent.setIntegerValueField(CGEventField(rawValue: 123)!, value: Int64(cgMomentumPhase(event.momentum)))
        }
        cgEvent.flags = combinedFlags(with: event.modifiers)
        cgEvent.post(tap: tap)
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
            cgEvent.post(tap: tap)
        }
        currentFlags = keyboard.modifierFlags
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
                down.post(tap: self.tap)
                if let up = CGEvent(keyboardEventSource: self.source, virtualKey: 0, keyDown: false) {
                    up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                    up.post(tap: self.tap)
                }
                index += 16
            }
        }
    }

    // MARK: Cleanup

    /// Releases every held key and button and clears modifier state. Call on disconnect/focus loss.
    func releaseAll() {
        queue.async {
            for button in self.heldButtons {
                if let cgEvent = CGEvent(mouseEventSource: self.source, mouseType: self.upType(for: button), mouseCursorPosition: self.lastPointer, mouseButton: self.cgButton(button)) {
                    cgEvent.post(tap: self.tap)
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
                    cgEvent.post(tap: self.tap)
                }
            }
        }
    }

    // MARK: Helpers

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

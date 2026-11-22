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
    /// An input-only session: there's no picture to aim at, so clicks land wherever the pointer
    /// is and only `moveBy` moves it (`followPointer`).
    private var followsPointer = false
    /// When this injector last posted a pointer event. A relative move after a pause starts from
    /// where the pointer really is (a mouse on the Mac may have moved it); within a gesture it
    /// follows its own count, since the system's position lags the events just posted.
    private var lastPointerPost: UInt64 = 0
    /// The active displays' frames, refreshed at the start of each relative gesture.
    private var screens: [CGRect] = []
    /// The Pencil is in range (a proximity event went out) and touching.
    private var stylusInRange = false
    private var stylusDown = false

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

    /// From now on clicks, drags and scrolls happen where the pointer already is, and `moveBy`
    /// moves it across every display: the device is a trackpad with no picture.
    func followPointer() {
        queue.async { self.followsPointer = true }
    }

    // MARK: Pointer

    func handle(_ event: PointerEvent) {
        queue.async { self.injectPointer(event) }
    }

    private func injectPointer(_ event: PointerEvent) {
        let point: CGPoint
        if event.action == .moveBy {
            let from = currentPointer()
            point = clampToScreens(CGPoint(x: from.x + Double(event.x), y: from.y + Double(event.y)), from: from)
        } else if followsPointer {
            point = currentPointer()
        } else {
            point = clampToDisplay(CGPoint(x: Double(event.x) + displayFrame.minX, y: Double(event.y) + displayFrame.minY))
        }
        lastPointer = point
        lastPointerPost = DispatchTime.now().uptimeNanoseconds
        let flags = combinedFlags(with: event.modifiers)

        let type: CGEventType
        // A move while a button is held is a drag, and the drag has to name the button that is
        // actually down — the client sends moves without one.
        var effectiveButton = event.button
        switch event.action {
        case .move, .moveBy:
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
        if event.action == .down || event.action == .up {
            cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, event.clickCount)))
        }
        if effectiveButton.rawValue >= 2 {
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(effectiveButton.rawValue))
        }

        post(cgEvent)
        pointerEventCount += 1
        if event.action == .down || event.action == .up || pointerEventCount == 1 {
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
            self.stylusDown = false
            if self.stylusInRange { self.postProximity(entering: false) }
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

    // MARK: Relative pointer

    /// Where a relative move starts: this injector's own position within a gesture, the
    /// system's after a pause.
    private func currentPointer() -> CGPoint {
        let pausedFor = DispatchTime.now().uptimeNanoseconds &- lastPointerPost
        guard lastPointerPost == 0 || pausedFor > 100_000_000 else { return lastPointer }
        screens = Self.activeScreens()
        return CGEvent(source: nil)?.location ?? lastPointer
    }

    /// Keeps the pointer on a display: a point between or beyond them stays at the edge of the
    /// display it came from, as a real trackpad's pointer does.
    private func clampToScreens(_ point: CGPoint, from: CGPoint) -> CGPoint {
        if screens.isEmpty { screens = Self.activeScreens() }
        if screens.contains(where: { $0.contains(point) }) { return point }
        let home = screens.first { $0.contains(from) } ?? screens.first ?? displayFrame
        return CGPoint(x: point.x.clamped(home.minX, home.maxX - 1), y: point.y.clamped(home.minY, home.maxY - 1))
    }

    private static func activeScreens() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    // MARK: Apple Pencil

    func handle(_ event: StylusEvent) {
        queue.async { self.injectStylus(event) }
    }

    /// The Pencil as a pen tablet: a proximity event when it comes into range, then mouse events
    /// tagged as tablet points with pressure and tilt (what drawing apps read), and a proximity
    /// event when it leaves. Touching is the left button, so everything else still sees clicks
    /// and drags.
    private func injectStylus(_ event: StylusEvent) {
        let point = clampToDisplay(CGPoint(x: Double(event.x) + displayFrame.minX, y: Double(event.y) + displayFrame.minY))
        lastPointer = point
        lastPointerPost = DispatchTime.now().uptimeNanoseconds
        let flags = combinedFlags(with: event.modifiers)
        if event.phase != .leave, !stylusInRange { postProximity(entering: true) }
        let type: CGEventType
        switch event.phase {
        case .hover:
            type = .mouseMoved
        case .down:
            stopMomentum()
            stylusDown = true
            heldButtons.insert(.left)
            type = .leftMouseDown
        case .move:
            type = stylusDown ? .leftMouseDragged : .mouseMoved
        case .up:
            stylusDown = false
            heldButtons.remove(.left)
            type = .leftMouseUp
        case .leave:
            if stylusDown {
                stylusDown = false
                heldButtons.remove(.left)
                postTablet(.leftMouseUp, at: point, event: event, flags: flags)
            }
            if stylusInRange { postProximity(entering: false) }
            return
        }
        postTablet(type, at: point, event: event, flags: flags)
    }

    private static let stylusDeviceID: Int64 = 0x5641 // "VA": one pen, the same in every event
    private static let tabletPointSubtype: Int64 = 1 // kCGEventMouseSubtypeTabletPoint
    private static let tabletProximitySubtype: Int64 = 2 // kCGEventMouseSubtypeTabletProximity

    private func postTablet(_ type: CGEventType, at point: CGPoint, event: StylusEvent, flags: CGEventFlags) {
        guard let cgEvent = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        let touching = type == .leftMouseDown || type == .leftMouseDragged
        let pressure = touching ? Double(max(event.pressure, 0.01)) : 0
        let tilt = event.tilt
        cgEvent.flags = flags
        cgEvent.setIntegerValueField(.mouseEventSubtype, value: Self.tabletPointSubtype)
        cgEvent.setDoubleValueField(.mouseEventPressure, value: pressure)
        cgEvent.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        cgEvent.setDoubleValueField(.tabletEventTiltX, value: tilt.x)
        cgEvent.setDoubleValueField(.tabletEventTiltY, value: tilt.y)
        cgEvent.setIntegerValueField(.tabletEventPointButtons, value: touching ? 1 : 0)
        cgEvent.setIntegerValueField(.tabletEventDeviceID, value: Self.stylusDeviceID)
        if type == .leftMouseDown || type == .leftMouseUp {
            cgEvent.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, event.clickCount)))
        }
        post(cgEvent)
    }

    private func postProximity(entering: Bool) {
        stylusInRange = entering
        guard let cgEvent = CGEvent(source: source) else { return }
        cgEvent.type = .tabletProximity
        cgEvent.location = lastPointer
        cgEvent.setIntegerValueField(.mouseEventSubtype, value: Self.tabletProximitySubtype)
        cgEvent.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        cgEvent.setIntegerValueField(.tabletProximityEventPointerType, value: 1) // pen
        cgEvent.setIntegerValueField(.tabletProximityEventDeviceID, value: Self.stylusDeviceID)
        cgEvent.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
        cgEvent.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
        // Device ID, absolute x and y, buttons, tilt x and y, pressure (NX_TABLET_CAPABILITY_*).
        cgEvent.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0001 | 0x0002 | 0x0004 | 0x0040 | 0x0080 | 0x0100 | 0x0400)
        post(cgEvent)
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

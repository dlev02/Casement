#if os(macOS)
import AppKit
import Observation
import VantageCore

/// Sends this Mac's keyboard to the remote Mac while a session window has it.
///
/// A local event monitor sees every key before the menu bar does, so ⌘Q, ⌘W, ⌘H and the rest go
/// to the remote Mac instead of acting on Vantage (`KeyCapturePolicy` decides, ⌃⌥⌘ chords always
/// stay here). It only acts while the session's own view has the keyboard in the key window and
/// input is on (`isActive`: connected, not View Only, not locked); anything else passes through.
/// `KeyTranslator` turns the events into the wire's, left/right modifiers and all.
///
/// Held keys are let go of on the remote Mac whenever the keyboard goes elsewhere (another
/// window or app, capture off, View Only, the lock, a disconnect), so nothing sticks.
///
/// **Full screen**: while capturing in a full-screen session the Dock, the menu bar and app
/// switching are turned off (`presentationOptions`), so ⌘Tab stays out of the way and the
/// pointer reaches the remote Mac's own Dock and menu bar at the screen's edges. The options go
/// back as soon as the window stops being key, capture stops, or full screen ends. Keys macOS
/// keeps for itself (⌘Space, Mission Control, screenshots, media keys) still never arrive.
@MainActor
final class KeyboardCapture {
    let input: InputController
    weak var view: NSView?

    /// Keys go to the remote Mac.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if !isActive { releaseAll() }
            updatePresentation()
        }
    }
    /// "Send keyboard shortcuts to the Mac" (`vantage.mac.captureShortcuts`).
    var capturesShortcuts = true {
        didSet {
            guard capturesShortcuts != oldValue else { return }
            updatePresentation()
        }
    }
    /// "Swap ⌘ and ⌃" (`vantage.mac.swapCommandControl`) for a Mac, "⌘ acts as Ctrl" for a PC.
    var swapsCommandAndControl: Bool {
        get { translator.swapsCommandAndControl }
        set {
            guard newValue != translator.swapsCommandAndControl else { return }
            releaseAll() // what went down under one mapping comes up under it
            translator.swapsCommandAndControl = newValue
        }
    }
    /// Called just before ⌘V goes over (Ctrl+V to a PC), so a clipboard copied here since the
    /// last sync can go first and the paste there has it.
    var onPaste: (() -> Void)?
    /// The host's paste chord's modifier, as sent (after any swap): ⌘ on a Mac, Ctrl on a PC.
    var pasteModifier: KeyModifiers = .command
    /// The keyboard went elsewhere: the view lets go of its mouse buttons too.
    var onLostKeyboard: (() -> Void)?
    #if DEBUG
    /// The keys sent, for `-VantageKeyProbe 1`.
    var probe: KeyProbe?
    #endif

    private var translator = KeyTranslator()
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private weak var window: NSWindow?
    /// The Dock, menu bar and app switching are off for a full-screen capture.
    private var capturesFullScreen = false

    init(input: InputController) {
        self.input = input
    }

    /// The remote Mac's view of this Mac's modifier flags (after "Swap ⌘ and ⌃"), for clicks
    /// and scrolls.
    func modifiers(fromFlags flags: UInt64) -> KeyModifiers {
        translator.modifiers(fromFlags: flags)
    }

    func attach(to window: NSWindow) {
        guard window !== self.window else { return }
        detach()
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumes(event) ?? false }
            return consumed ? nil : event
        }
        let center = NotificationCenter.default
        let lost: [Notification.Name] = [NSWindow.didResignKeyNotification, NSWindow.willExitFullScreenNotification,
                                         NSWindow.willCloseNotification]
        for name in lost {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyboardLeft() }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardLeft() }
        })
        // SwiftUI owns the window's delegate, so full screen is followed by notification; the
        // options can only change once the window is there.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEnterFullScreenNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePresentation() }
            })
        }
    }

    func detach() {
        releaseAll()
        restorePresentation()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window = nil
    }

    /// Lets go of every key and modifier still down on the remote Mac.
    func releaseAll() {
        send(translator.releaseAll())
    }

    private func keyboardLeft() {
        releaseAll()
        onLostKeyboard?()
        restorePresentation()
    }

    // MARK: Events

    /// Sends `event` to the remote Mac if it's the remote Mac's; true when it was (AppKit then
    /// never sees it).
    private func consumes(_ event: NSEvent) -> Bool {
        guard isActive, let window, event.window === window, window.isKeyWindow else { return false }
        // A text field in the session window (none today) keeps its typing.
        if let responder = window.firstResponder, responder !== view, responder is NSText { return false }
        if event.isFromVantageHost { return true } // the host on this same Mac: don't loop it back
        let flags = UInt64(event.modifierFlags.rawValue)
        switch event.type {
        case .flagsChanged:
            send(translator.translate(.flagsChanged, keyCode: event.keyCode, flags: flags))
            return true
        case .keyDown:
            let pressed = KeyTranslator().modifiers(fromFlags: flags) // as pressed here, before any swap
            guard KeyCapturePolicy.route(keyCode: event.keyCode, modifiers: pressed, capturesShortcuts: capturesShortcuts) == .forward else {
                return false
            }
            if event.keyCode == 0x09, !event.isARepeat, translator.modifiers(fromFlags: flags).contains(pasteModifier) {
                onPaste?() // ⌘V on the remote Mac, Ctrl+V on a PC
            }
            send(translator.translate(.keyDown, keyCode: event.keyCode, flags: flags, isRepeat: event.isARepeat))
            return true
        case .keyUp:
            guard translator.isHolding(keyCode: event.keyCode) else { return false } // its press stayed here
            send(translator.translate(.keyUp, keyCode: event.keyCode, flags: flags))
            return true
        default:
            return false
        }
    }

    private func send(_ events: [KeyEvent]) {
        for event in events {
            input.keyCode(event.keyCode, isDown: event.isDown, modifiers: event.modifiers, isRepeat: event.isRepeat)
        }
        #if DEBUG
        events.forEach { probe?.record($0) }
        #endif
    }

    // MARK: Full screen

    private func updatePresentation() {
        guard let window else { return }
        let wanted = isActive && capturesShortcuts && window.isKeyWindow && NSApp.isActive
            && window.styleMask.contains(.fullScreen)
        guard wanted else {
            restorePresentation()
            return
        }
        capturesFullScreen = true
        applyCaptureOptions()
        // AppKit puts its own full-screen options back just after the window enters full screen
        // (within 0.1 s here), so check again once the transition has settled.
        for delay in [0.15, 0.4, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.applyCaptureOptions() }
            }
        }
    }

    /// Full screen's own options (auto-hiding Dock and menu bar) swapped for hidden ones, and no
    /// app switching.
    private static let captureOptions: NSApplication.PresentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching]

    private func applyCaptureOptions() {
        let current = NSApp.presentationOptions
        guard capturesFullScreen, window?.styleMask.contains(.fullScreen) == true,
              !current.isSuperset(of: Self.captureOptions) else { return }
        // The hide options need the auto-hide ones gone; process switching needs the Dock hidden.
        NSApp.presentationOptions = current.subtracting([.autoHideDock, .autoHideMenuBar]).union(Self.captureOptions)
    }

    private func restorePresentation() {
        guard capturesFullScreen else { return }
        capturesFullScreen = false
        var options = NSApp.presentationOptions.subtracting(Self.captureOptions)
        if options.contains(.fullScreen) { options.formUnion([.autoHideDock, .autoHideMenuBar]) }
        NSApp.presentationOptions = options
    }
}

#if DEBUG
/// `-VantageKeyProbe 1`: the last few keys the session sent, newest last, as `session.keyProbe`'s
/// value ("0x37 down command, 0xc down command, …"), for UI tests.
@Observable
@MainActor
final class KeyProbe {
    private var recent: [String] = []
    var value: String { recent.joined(separator: ", ") }

    func record(_ event: KeyEvent) {
        var names: [String] = []
        if event.modifiers.contains(.control) { names.append("control") }
        if event.modifiers.contains(.option) { names.append("option") }
        if event.modifiers.contains(.shift) { names.append("shift") }
        if event.modifiers.contains(.command) { names.append("command") }
        recent.append("0x\(String(event.keyCode, radix: 16)) \(event.isDown ? "down" : "up") \(names.joined(separator: "+"))")
        if recent.count > 8 { recent.removeFirst(recent.count - 8) }
    }
}
#endif
#endif

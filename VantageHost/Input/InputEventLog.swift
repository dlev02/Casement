#if DEBUG
import CoreGraphics
import Foundation
import os

/// `--log-input-events` (DEBUG): a listen-only session event tap that logs the key and modifier
/// events reaching the session — the host's own injected events and the Mac's real keyboard
/// alike — with their flags, so the two can be compared (category `input`, lines start with
/// "tap"). Keys typed on the Mac's own keyboard that produce text are logged without their key
/// code, so this never records what someone types. Needs the Accessibility grant the host has.
nonisolated enum InputEventLog {
    private static let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "input")
    nonisolated(unsafe) private static var started = false

    static func startIfRequested() {
        guard HostOptions.shared.logInputEvents, !started else { return }
        started = true
        let thread = Thread {
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                              eventsOfInterest: CGEventMask(mask),
                                              callback: { _, type, event, _ in
                                                  InputEventLog.describe(type, event)
                                                  return Unmanaged.passUnretained(event)
                                              }, userInfo: nil) else {
                log.error("tap: could not create the event tap")
                return
            }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            log.info("tap: logging key events")
            CFRunLoopRun()
        }
        thread.name = "vantage.input-log"
        thread.start()
    }

    private static func describe(_ type: CGEventType, _ event: CGEvent) {
        let name = switch type {
        case .keyDown: "keyDown"
        case .keyUp: "keyUp"
        case .flagsChanged: "flagsChanged"
        default: "type \(type.rawValue)"
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        let state = event.getIntegerValueField(.eventSourceStateID)
        let repeatFlag = event.getIntegerValueField(.keyboardEventAutorepeat)
        let keyText = pid == 0 && !nonTextKeys.contains(key) ? "(text)" : "0x" + String(key, radix: 16)
        log.info("tap \(name, privacy: .public) key \(keyText, privacy: .public) flags 0x\(String(event.flags.rawValue, radix: 16), privacy: .public) pid \(pid, privacy: .public) state \(state, privacy: .public) repeat \(repeatFlag, privacy: .public)")
    }

    /// Modifiers, arrows, function and navigation keys, Space, Escape, Return, Tab, Delete:
    /// the keys shortcuts are made of, safe to log from the Mac's own keyboard.
    private static let nonTextKeys: Set<Int64> = Set(0x36...0x3F).union(0x7B...0x7E)
        .union([0x31, 0x35, 0x24, 0x30, 0x33, 0x75, 0x73, 0x77, 0x74, 0x79, 0x72, 0x4C])
        .union([0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A])
}
#endif

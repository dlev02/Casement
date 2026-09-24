import Foundation
import VantageCore

/// Launch-argument driven options for headless testing (DEBUG only):
/// `-VantageSeedHost <host>` adds a device, `-VantageAutoConnect <host>` opens a session to it,
/// `-VantagePairingCode 123456` supplies the pairing code automatically.
enum ClientOptions {
    static var seedHost: String? { value(for: "-VantageSeedHost") }
    static var autoConnectHost: String? { value(for: "-VantageAutoConnect") }
    static var pairingCode: String? { value(for: "-VantagePairingCode") }
    /// `-VantageTailscaleFixture 1` serves a fictional tailnet instead of calling the API.
    static var tailscaleFixture: [TailscaleDevice]? {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-VantageTailscaleFixture") else { return nil }
        return [
            TailscaleDevice(id: "1", name: "studio-mac.example.ts.net.", hostname: "Studio Mac", os: "macOS", addresses: ["100.101.1.10", "fd7a:115c:a1e0::1"], clientVersion: "1.90.0", lastSeen: ISO8601DateFormatter().string(from: Date()), authorized: true, user: "drew@example.com", tags: nil),
            TailscaleDevice(id: "2", name: "office-mac.example.ts.net.", hostname: "Office Mac", os: "macOS", addresses: ["100.101.1.11"], clientVersion: "1.90.0", lastSeen: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400)), authorized: true, user: "drew@example.com", tags: nil),
            TailscaleDevice(id: "3", name: "drew-pc.example.ts.net.", hostname: "Drew-PC", os: "windows", addresses: ["100.101.1.20"], clientVersion: "1.90.0", lastSeen: ISO8601DateFormatter().string(from: Date()), authorized: true, user: "drew@example.com", tags: nil),
            TailscaleDevice(id: "4", name: "homelab.example.ts.net.", hostname: "homelab", os: "linux", addresses: ["100.101.1.30"], clientVersion: "1.90.0", lastSeen: ISO8601DateFormatter().string(from: Date()), authorized: true, user: "drew@example.com", tags: ["tag:server"]),
            TailscaleDevice(id: "5", name: "drews-ipad.example.ts.net.", hostname: "Drew's iPad Pro", os: "iOS", addresses: ["100.101.1.40"], clientVersion: "1.90.0", lastSeen: ISO8601DateFormatter().string(from: Date()), authorized: true, user: "drew@example.com", tags: nil),
        ]
        #else
        return nil
        #endif
    }

    /// `-VantageOpenTailscaleDevices 1` presents the Tailscale picker on launch (screenshots/tests).
    static var openTailscaleDevices: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-VantageOpenTailscaleDevices")
        #else
        false
        #endif
    }

    /// `-VantageOpenScreen settings|controls|…|widgets|controlStrip|controlStripMac` presents that screen
    /// on launch so it can be screenshotted without driving the UI.
    static var openScreen: DebugScreen? {
        #if DEBUG
        value(for: "-VantageOpenScreen").flatMap(DebugScreen.init(rawValue:))
        #else
        nil
        #endif
    }

    /// `-VantageDictationFixture listening|review|macTranscribing|macReview|failed|download` shows the
    /// dictation panel in that state once connected, without opening the microphone (screenshots).
    static var dictationFixture: String? { value(for: "-VantageDictationFixture") }
    /// `-VantageDictationSpeak "text"` dictates synthesized speech to the Mac engine once connected.
    static var dictationSpeech: String? { value(for: "-VantageDictationSpeak") }
    /// `-VantageMacAudio 1|0` overrides the saved Mac Audio choice for this launch (tests).
    static var macAudio: Bool? { value(for: "-VantageMacAudio").map { $0 == "1" } }
    /// `-VantageSendTestFile <bytes>` queues a file of random bytes for the Mac once the file
    /// channel is up (the Files picker can't be scripted in UI tests).
    static var sendTestFileBytes: Int? { value(for: "-VantageSendTestFile").flatMap(Int.init) }
    /// `-VantageSlowFiles <ms>` pauses that long before each 256 KiB chunk the app sends.
    static var slowFilesMillis: Int? { value(for: "-VantageSlowFiles").flatMap(Int.init) }
    /// `-VantageDropHint 1` shows the "Drop to send" hint without a drag (screenshots).
    static var dropHintFixture: Bool { value(for: "-VantageDropHint") == "1" }
    /// `-VantagePointerProbe 1` exposes the Mac pointer position the app last sent as the value of
    /// an invisible `session.pointerProbe` element, so UI tests can check edges with a hover.
    static var pointerProbe: Bool { value(for: "-VantagePointerProbe") == "1" }

    static var seedSampleDevices: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-VantageSeedSamples")
        #else
        false
        #endif
    }

    private static func value(for flag: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
        #else
        return nil
        #endif
    }
}

/// Screens that `-VantageOpenScreen` can present directly (DEBUG only).
enum DebugScreen: String, Identifiable {
    case settings, controls, security, help, about, tailscale, tailscaleOAuth, tailscaleToken, addDevice, widgets
    /// The controls editor for the default layout, and for the first saved Mac.
    case controlStrip, controlStripMac
    /// The Transfers sheet with one row in each state.
    case transfers
    var id: String { rawValue }
}

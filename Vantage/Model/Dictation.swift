import Foundation
import VantageCore

/// Where dictated speech is turned into text (Settings → Controls). Which engine the Mac uses is
/// the Mac's choice (Casement Host → Settings → Dictation), so the client only picks a side.
/// A saved "parakeet" from before that falls back to `.mac`, which still reaches Parakeet when the
/// Mac puts it first.
nonisolated enum DictationEnginePreference: String, CaseIterable, Identifiable {
    /// The engine the Mac lists first, when it has MacWhisper or Parakeet; otherwise this device.
    case mac
    /// Apple's on-device speech model on this device (the case keeps its name on the Mac client).
    /// Works offline and when the Mac is busy.
    case iPad
    var id: String { rawValue }

    var label: String {
        switch self {
        case .mac: "On the Mac"
        case .iPad: "On \(LocalDevice.this)"
        }
    }
}

/// The engine one dictation actually uses.
nonisolated enum DictationRoute: Equatable {
    /// This device (iPad, or the Mac the client runs on).
    case iPad
    /// Stream audio to the host, which transcribes it with this engine.
    case mac(DictationEngineID)

    /// Picks the engine for a session. The Mac is used only when the host advertised MacWhisper
    /// or Parakeet: an older host (nil engines) would drop the session on the new message kinds,
    /// and a Mac with only Apple's engine offers nothing the iPad doesn't already have. Then it's
    /// the engine the host lists first, which is the one chosen in its Settings (older hosts list
    /// MacWhisper first).
    static func resolve(preference: DictationEnginePreference, hostEngines: [DictationEngineID]?) -> DictationRoute {
        guard preference == .mac, let hostEngines, let first = hostEngines.first,
              hostEngines.contains(where: { $0 == .macWhisper || $0 == .parakeet }) else { return .iPad }
        return .mac(first)
    }

    var label: String {
        switch self {
        #if os(macOS)
        case .iPad: "This Mac" // "On Mac" names the remote Mac's engine
        #else
        case .iPad: "On iPad"
        #endif
        case .mac(let engine): Self.label(for: engine)
        }
    }

    /// The name shown for a Mac engine in the dictation panel.
    static func label(for engine: DictationEngineID) -> String {
        switch engine {
        case .macWhisper: "MacWhisper"
        case .parakeet: "Parakeet"
        case .apple: "Apple on Mac"
        default: "On Mac"
        }
    }

    var symbol: String {
        switch self {
        case .iPad: LocalDevice.symbol
        case .mac: "macbook"
        }
    }
}

/// Live transcript assembly: finalized text is kept; the latest volatile guess replaces the last.
nonisolated struct DictationTranscript: Equatable {
    /// Text the user already had (a second dictation continues the first).
    var prefix = ""
    var finalized = ""
    var volatile = ""

    mutating func apply(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
    }

    /// What Send types: the prefix and the finalized text, whitespace-normalized at the join.
    var committed: String { Self.join(prefix, finalized) }
    /// Everything on screen, including the volatile tail.
    var display: String { Self.join(committed, volatile) }

    static func join(_ head: String, _ tail: String) -> String {
        let head = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " " + tail
    }
}

/// Slices 16 kHz PCM16 into 20 ms `micAudio` packets (640 bytes) for one clip.
nonisolated struct MicPacketizer {
    static let packetBytes = 640

    let dictationID: UUID
    private(set) var sequence: UInt32 = 0
    private var pending = Data()

    init(dictationID: UUID) {
        self.dictationID = dictationID
    }

    mutating func push(_ samples: Data) -> [MicAudio] {
        pending.append(samples)
        var packets: [MicAudio] = []
        while pending.count >= Self.packetBytes {
            packets.append(packet(Data(pending.prefix(Self.packetBytes))))
            pending.removeFirst(Self.packetBytes)
        }
        return packets
    }

    /// The final partial packet, if any audio is left over.
    mutating func flush() -> MicAudio? {
        guard !pending.isEmpty else { return nil }
        defer { pending = Data() }
        return packet(pending)
    }

    private mutating func packet(_ samples: Data) -> MicAudio {
        defer { sequence &+= 1 }
        return MicAudio(dictationID: dictationID, sequence: sequence, format: .pcm16LE16k, samples: samples)
    }
}

nonisolated enum DictationLanguage {
    /// ISO 639-1 code for the Mac engines ("en" from en-US), or nil to use MacWhisper's own setting.
    static func code(for locale: Locale = .current) -> String? {
        locale.language.languageCode?.identifier.lowercased()
    }
}

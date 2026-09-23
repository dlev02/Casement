import Foundation

// MARK: - Remote dictation
//
// The iPad records speech and either transcribes it itself (and types the result through
// `textInput`) or streams 16 kHz PCM to the host, which transcribes it with MacWhisper's `mw`
// CLI, its optional built-in Parakeet model, or macOS SpeechAnalyzer and returns the text for
// review. Every kind here is gated: the client sends `dictationControl`/`micAudio` only when
// `HostCapabilities.dictationEngines` lists the engine, and the host sends `dictationResult` only
// to a client whose `Hello.features` says it understands it. Older peers never see these kinds,
// so `VantageProtocol.version` stays put.

/// A transcription engine on the host. A string wrapper rather than an enum so a peer that
/// advertises an engine this build doesn't know still decodes.
public struct DictationEngineID: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// MacWhisper's `mw transcribe`, using whatever model is selected in MacWhisper.
    public static let macWhisper = DictationEngineID(rawValue: "macwhisper")
    /// NVIDIA Parakeet TDT v3 running inside Vantage Host (FluidAudio, Core ML). Optional: the
    /// host advertises it only after the user turned it on and the model finished downloading.
    public static let parakeet = DictationEngineID(rawValue: "parakeet")
    /// macOS SpeechAnalyzer; the host's fallback when MacWhisper is missing or fails.
    public static let apple = DictationEngineID(rawValue: "apple")

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

/// Optional client abilities, sent in `Hello`. Every field is optional so either side can add
/// one without breaking the other.
public struct ClientFeatures: Codable, Sendable, Equatable {
    /// The client understands `dictationResult`.
    public var dictation: Bool?
    /// The client understands `audioConfig` and `audioPacket` (it still has to ask for them).
    public var macAudio: Bool?
    /// The client can open a file channel and speaks the file transfer kinds on it.
    public var fileTransfer: Bool?

    public init(dictation: Bool? = nil, macAudio: Bool? = nil, fileTransfer: Bool? = nil) {
        self.dictation = dictation
        self.macAudio = macAudio
        self.fileTransfer = fileTransfer
    }
}

/// Uplink audio formats for `micAudio`.
public enum MicAudioFormat: UInt8, Codable, Sendable {
    /// 16 kHz, mono, signed 16-bit little-endian PCM: the speech models' native format.
    case pcm16LE16k = 0

    public var sampleRate: Double { 16_000 }
    public var bytesPerSample: Int { 2 }
}

/// Client → host: start, finish, or abandon one dictation clip.
public struct DictationControl: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        /// Audio for `id` follows as `micAudio`.
        case begin
        /// The clip is complete; transcribe it and answer with `dictationResult`.
        case commit
        /// Discard the clip; no result is sent.
        case cancel
    }

    public var action: Action
    public var id: UUID
    /// Requested engine (`begin` only). The host tries it first when it can, otherwise falls back
    /// (MacWhisper, then Parakeet, then Apple) and names the engine it used in the result. Nil or
    /// an engine the host doesn't know means "the host's best".
    public var engine: DictationEngineID?
    /// ISO 639-1 language code, or nil for the engine's own setting.
    public var language: String?
    public var format: MicAudioFormat?

    public init(action: Action, id: UUID, engine: DictationEngineID? = nil, language: String? = nil, format: MicAudioFormat? = nil) {
        self.action = action
        self.id = id
        self.engine = engine
        self.language = language
        self.format = format
    }
}

/// Host → client: the transcript for a committed clip, or why there isn't one.
public struct DictationResult: Codable, Sendable, Equatable {
    public var id: UUID
    public var text: String
    public var isFinal: Bool
    /// The engine that actually produced `text`.
    public var engine: DictationEngineID?
    /// A user-facing explanation when transcription failed; `text` is empty then.
    public var error: String?

    public init(id: UUID, text: String, isFinal: Bool = true, engine: DictationEngineID? = nil, error: String? = nil) {
        self.id = id
        self.text = text
        self.isFinal = isFinal
        self.engine = engine
        self.error = error
    }
}

/// Client → host dictation audio, sent while the user speaks (20 ms packets of 640 bytes).
public struct MicAudio: Sendable, Equatable {
    public var dictationID: UUID
    /// Increments per packet within one clip, so the host can spot loss or reordering.
    public var sequence: UInt32
    public var format: MicAudioFormat
    public var samples: Data

    public init(dictationID: UUID, sequence: UInt32, format: MicAudioFormat = .pcm16LE16k, samples: Data) {
        self.dictationID = dictationID
        self.sequence = sequence
        self.format = format
        self.samples = samples
    }

    func encode() -> Data {
        var writer = BinaryWriter(capacity: 21 + samples.count)
        var uuid = dictationID.uuid
        withUnsafeBytes(of: &uuid) { writer.writeRaw(Data($0)) }
        writer.write(sequence)
        writer.write(format.rawValue)
        writer.writeRaw(samples)
        return writer.data
    }

    static func decode(_ payload: Data) throws -> MicAudio {
        var reader = BinaryReader(payload)
        let idBytes = try reader.readRaw(16)
        let uuid = idBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        let sequence = try reader.readUInt32()
        let format = try reader.readEnum(MicAudioFormat.self)
        return MicAudio(dictationID: UUID(uuid: uuid), sequence: sequence, format: format, samples: reader.readRemaining())
    }
}

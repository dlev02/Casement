import Foundation
import VantageCore

/// Buffers the PCM for dictation clips between `begin` and `commit`/`cancel`.
///
/// Audio is accepted only for a clip the client opened, packets are appended in arrival order
/// (TCP already orders them; the sequence number just flags a gap), and a clip is capped at five
/// minutes so a stuck client can't grow the host without bound.
nonisolated struct DictationClipStore {
    struct Clip {
        var engine: DictationEngineID?
        var language: String?
        var format: MicAudioFormat
        var samples = Data()
        var nextSequence: UInt32 = 0
        var droppedPackets = 0
        var isTruncated = false
    }

    enum AppendOutcome: Equatable {
        case appended
        /// No open clip with that id (never begun, already committed, or cancelled).
        case unknownClip
        /// The clip hit `maxBytes`; later audio is dropped until it is committed.
        case truncated
    }

    /// 5 minutes of 16 kHz PCM16 mono: 9.6 MB.
    static let maxBytes = 5 * 60 * 16_000 * 2
    /// More simultaneous open clips than this is a misbehaving client.
    static let maxOpenClips = 2

    private(set) var clips: [UUID: Clip] = [:]

    /// Opens a clip. Reopening an id restarts it; beyond `maxOpenClips` the oldest is dropped.
    mutating func begin(_ control: DictationControl) {
        if clips[control.id] == nil, clips.count >= Self.maxOpenClips, let stale = clips.keys.first {
            clips[stale] = nil
        }
        clips[control.id] = Clip(engine: control.engine, language: control.language, format: control.format ?? .pcm16LE16k)
    }

    mutating func append(_ audio: MicAudio) -> AppendOutcome {
        guard var clip = clips[audio.dictationID], audio.format == clip.format else { return .unknownClip }
        defer { clips[audio.dictationID] = clip }
        if audio.sequence > clip.nextSequence {
            clip.droppedPackets += Int(audio.sequence - clip.nextSequence)
        }
        clip.nextSequence = audio.sequence &+ 1
        guard clip.samples.count + audio.samples.count <= Self.maxBytes else {
            clip.isTruncated = true
            return .truncated
        }
        clip.samples.append(audio.samples)
        return .appended
    }

    /// Closes a clip and hands back its audio for transcription.
    mutating func commit(_ id: UUID) -> Clip? {
        clips.removeValue(forKey: id)
    }

    mutating func cancel(_ id: UUID) {
        clips[id] = nil
    }

    mutating func removeAll() {
        clips.removeAll()
    }
}

/// Minimal RIFF/WAVE writer for mono 16-bit PCM, the format `mw` and AVAudioFile both read.
nonisolated enum WAVFile {
    static func pcm16Mono(_ samples: Data, sampleRate: Int) -> Data {
        var header = BinaryWriter(capacity: 44 + samples.count)
        let byteRate = UInt32(sampleRate * 2)
        header.writeRaw(Data("RIFF".utf8))
        header.write(UInt32(36 + samples.count))
        header.writeRaw(Data("WAVE".utf8))
        header.writeRaw(Data("fmt ".utf8))
        header.write(UInt32(16))          // fmt chunk size
        header.write(UInt16(1))           // PCM
        header.write(UInt16(1))           // mono
        header.write(UInt32(sampleRate))
        header.write(byteRate)
        header.write(UInt16(2))           // block align
        header.write(UInt16(16))          // bits per sample
        header.writeRaw(Data("data".utf8))
        header.write(UInt32(samples.count))
        header.writeRaw(samples)
        return header.data
    }
}

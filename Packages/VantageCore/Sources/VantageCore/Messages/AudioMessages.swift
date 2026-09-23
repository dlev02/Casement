import Foundation

// MARK: - Mac audio
//
// The host captures the Mac's sound output, encodes it as Opus in 10 ms packets, and streams it
// to the client, which plays it through a small adaptive jitter buffer. Every kind here is gated:
// the client sends `audioRequest` only to a host whose `HostCapabilities.audio` is true, and the
// host sends `audioConfig`/`audioPacket` only after a client that said `Hello.features.macAudio`
// asked for them. Audio is off until the client asks, so older peers never see these kinds and
// `VantageProtocol.version` stays put.

/// Client → host: start or stop streaming the Mac's audio for this session.
public struct AudioRequest: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Reserved for a Core Audio tap that silences the Mac while it streams. Hosts ignore it
    /// today (ScreenCaptureKit can't mute the Mac's output).
    public var muteMacOutput: Bool?

    public init(enabled: Bool, muteMacOutput: Bool? = nil) {
        self.enabled = enabled
        self.muteMacOutput = muteMacOutput
    }
}

/// Host → client: the format of the `audioPacket`s that follow, sent before the first packet and
/// whenever it changes. When `unavailable` is set, audio didn't start (or stopped) and no packets
/// follow; the text says why, for the user.
public struct AudioConfig: Codable, Sendable, Equatable {
    /// "opus" today. A string so a newer codec name still decodes.
    public var codec: String
    public var sampleRate: Int
    public var channels: Int
    /// Frames in every packet (480 = 10 ms at 48 kHz).
    public var framesPerPacket: Int
    /// Target bitrate in bits per second.
    public var bitrate: Int
    /// A user-facing reason audio isn't available; nil while it streams.
    public var unavailable: String?

    public static let opus = "opus"

    public init(codec: String = AudioConfig.opus, sampleRate: Int = 48_000, channels: Int = 2, framesPerPacket: Int = 480,
                bitrate: Int = 128_000, unavailable: String? = nil) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
        self.framesPerPacket = framesPerPacket
        self.bitrate = bitrate
        self.unavailable = unavailable
    }

    /// Audio didn't start or stopped, with the reason to show.
    public static func unavailable(_ reason: String) -> AudioConfig {
        AudioConfig(unavailable: reason)
    }
}

/// Host → client: one encoded audio packet.
///
/// Wire layout (little-endian): `sequence u64 | captureNanos u64 | frameCount u16 | codec bytes`.
public struct AudioPacket: Sendable, Equatable {
    /// Increments by one per packet for the life of one stream, so the client can spot loss.
    public var sequence: UInt64
    /// Host capture time of the packet's first frame, on the host's monotonic clock (like
    /// `VideoFrame.captureNanos`).
    public var captureNanos: UInt64
    /// PCM frames the packet decodes to.
    public var frameCount: UInt16
    public var data: Data

    /// Bytes before the codec payload.
    public static let headerLength = 18

    public init(sequence: UInt64, captureNanos: UInt64, frameCount: UInt16, data: Data) {
        self.sequence = sequence
        self.captureNanos = captureNanos
        self.frameCount = frameCount
        self.data = data
    }

    func encode() -> Data {
        var writer = BinaryWriter(capacity: Self.headerLength + data.count)
        writer.write(sequence)
        writer.write(captureNanos)
        writer.write(frameCount)
        writer.writeRaw(data)
        return writer.data
    }

    static func decode(_ payload: Data) throws -> AudioPacket {
        var reader = BinaryReader(payload)
        let sequence = try reader.readUInt64()
        let captureNanos = try reader.readUInt64()
        let frameCount = try reader.readUInt16()
        return AudioPacket(sequence: sequence, captureNanos: captureNanos, frameCount: frameCount, data: reader.readRemaining())
    }
}

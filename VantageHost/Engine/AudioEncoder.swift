import AVFAudio
import AudioToolbox
import Foundation
import VantageCore
import os

/// Opus through AudioToolbox (`AVAudioConverter`): one 480-frame block in, one packet out.
///
/// `mFramesPerPacket` is set explicitly: the encoder otherwise picks 2.5 ms packets. The encoder
/// primes with 312 frames (6.5 ms), so the first call or so returns nothing. Not thread-safe; one
/// caller at a time.
nonisolated final class OpusEncoder {
    static let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(AudioBlock.sampleRate),
                                           channels: AVAudioChannelCount(AudioBlock.channels), interleaved: true)!

    let outputFormat: AVAudioFormat
    let bitrate: Int
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioCompressedBuffer

    init?(bitrate: Int = 128_000, framesPerPacket: Int = AudioBlock.frames) {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(AudioBlock.sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(AudioBlock.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let outputFormat = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: Self.inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: Self.inputFormat, frameCapacity: AVAudioFrameCount(framesPerPacket)) else { return nil }
        converter.bitRate = bitrate
        let maxPacket = max(converter.maximumOutputPacketSize, 1_500)
        self.outputFormat = outputFormat
        self.bitrate = converter.bitRate
        self.converter = converter
        self.input = input
        self.output = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 4, maximumPacketSize: maxPacket)
    }

    /// Encodes one block of interleaved stereo samples. Returns the packets the encoder finished
    /// (usually one, none while it primes).
    func encode(_ samples: [Float]) -> [Data] {
        let frames = samples.count / AudioBlock.channels
        guard frames > 0, frames <= Int(input.frameCapacity) else { return [] }
        samples.withUnsafeBufferPointer { source in
            _ = memcpy(input.floatChannelData![0], source.baseAddress!, samples.count * MemoryLayout<Float>.size)
        }
        input.frameLength = AVAudioFrameCount(frames)
        output.packetCount = 0
        output.byteLength = 0
        var supplied = false
        var error: NSError?
        let block = input
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return block
        }
        guard status != .error, output.packetCount > 0, let descriptions = output.packetDescriptions else { return [] }
        var packets: [Data] = []
        for index in 0..<Int(output.packetCount) {
            let description = descriptions[index]
            packets.append(Data(bytes: output.data + Int(description.mStartOffset), count: Int(description.mDataByteSize)))
        }
        return packets
    }
}

/// Encodes a source's blocks on a dedicated serial queue and hands out numbered `AudioPacket`s
/// (the host sends them with `sendDetached`). Logs throughput every ~10 s, never per packet.
nonisolated final class AudioEncoder: @unchecked Sendable {
    let config: AudioConfig
    private let queue = DispatchQueue(label: "vantage.audio.encode", qos: .userInteractive)
    private let encoder: OpusEncoder
    private let onPacket: @Sendable (AudioPacket) -> Void
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "audio")
    // Queue-confined.
    private var sequence: UInt64 = 0
    private var pendingTimes: [UInt64] = []
    private var windowPackets = 0
    private var windowBytes = 0
    private var windowStart: UInt64 = 0
    private var totalPackets: UInt64 = 0

    init?(bitrate: Int = 128_000, onPacket: @escaping @Sendable (AudioPacket) -> Void) {
        guard let encoder = OpusEncoder(bitrate: bitrate) else { return nil }
        self.encoder = encoder
        self.onPacket = onPacket
        self.config = AudioConfig(codec: AudioConfig.opus, sampleRate: AudioBlock.sampleRate, channels: AudioBlock.channels,
                                  framesPerPacket: AudioBlock.frames, bitrate: encoder.bitrate)
    }

    /// Queues one block. Safe from any thread.
    func encode(_ block: AudioBlock) {
        queue.async { self.encodeNow(block) }
    }

    /// Packets sent so far.
    var packetCount: UInt64 { queue.sync { totalPackets } }

    private func encodeNow(_ block: AudioBlock) {
        // The encoder runs ~312 frames behind, so a packet belongs to an earlier block's time;
        // pairing packets with block times in order keeps `captureNanos` honest to ±10 ms.
        pendingTimes.append(block.captureNanos)
        for data in encoder.encode(block.samples) {
            let captureNanos = pendingTimes.isEmpty ? block.captureNanos : pendingTimes.removeFirst()
            onPacket(AudioPacket(sequence: sequence, captureNanos: captureNanos, frameCount: UInt16(AudioBlock.frames), data: data))
            sequence &+= 1
            totalPackets &+= 1
            windowPackets += 1
            windowBytes += data.count
        }
        if pendingTimes.count > 8 { pendingTimes.removeFirst(pendingTimes.count - 8) }
        let now = MonotonicClock.nanos()
        if windowStart == 0 { windowStart = now }
        if now - windowStart >= 10_000_000_000 {
            let seconds = Double(now - windowStart) / 1e9
            log.info("audio: \(self.totalPackets, privacy: .public) packets sent, \(Int(Double(self.windowPackets) / seconds), privacy: .public)/s, \(Int(Double(self.windowBytes) * 8 / seconds / 1000), privacy: .public) kbps")
            windowStart = now
            windowPackets = 0
            windowBytes = 0
        }
    }
}

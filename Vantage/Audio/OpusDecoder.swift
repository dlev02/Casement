import AVFAudio
import AudioToolbox
import Foundation
import VantageCore

/// Decodes the host's Opus packets (`AudioConfig`) into interleaved Float32 PCM with
/// `AVAudioConverter`. AudioToolbox's Opus needs no magic cookie, only the stream description.
/// Not thread-safe; `MacAudioPlayer` uses it from its decode queue only.
nonisolated final class OpusDecoder {
    let config: AudioConfig
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let input: AVAudioCompressedBuffer
    private let output: AVAudioPCMBuffer

    /// Nil for a codec or layout this build can't play.
    init?(config: AudioConfig) {
        guard config.codec == AudioConfig.opus, config.unavailable == nil, (1...2).contains(config.channels),
              config.framesPerPacket > 0, config.sampleRate > 0 else { return nil }
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(config.sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(config.framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(config.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let inputFormat = AVAudioFormat(streamDescription: &description),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(config.sampleRate),
                                               channels: AVAudioChannelCount(config.channels), interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(config.framesPerPacket * 4)) else { return nil }
        self.config = config
        self.outputFormat = outputFormat
        self.converter = converter
        self.input = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: 4_000)
        self.output = output
    }

    /// Decodes one packet. The result is interleaved (`channels` samples per frame) and only valid
    /// until the next call. Nil if the packet didn't decode.
    func decode(_ packet: Data) -> UnsafeBufferPointer<Float>? {
        guard !packet.isEmpty, packet.count <= Int(input.maximumPacketSize) else { return nil }
        packet.withUnsafeBytes { raw in _ = memcpy(input.data, raw.baseAddress!, packet.count) }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                    mDataByteSize: UInt32(packet.count))
        output.frameLength = 0
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
        guard status != .error, output.frameLength > 0, let samples = output.floatChannelData?[0] else { return nil }
        return UnsafeBufferPointer(start: samples, count: Int(output.frameLength) * config.channels)
    }

    /// Drops the decoder's state (after a gap in the stream).
    func reset() {
        converter.reset()
    }
}

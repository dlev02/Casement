import AVFAudio
import Foundation

/// One `AVAudioConverter` for a stream of buffers, with an explicit end.
///
/// A converter that changes the sample rate keeps a few dozen milliseconds of input inside its
/// filter (measured: ~30 ms for 48 kHz → 16 kHz, ~56 ms for 22.05 kHz) and only hands them out
/// once it's told the input has ended. Dictation must call `finish()` after the last buffer or
/// the end of the last word never reaches the transcriber.
///
/// Not thread-safe: one caller at a time (`MicrophoneCapture` serializes it with a lock).
nonisolated final class AudioResampler {
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var finished = false

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    /// Converts one buffer. Nil when the converter has nothing to hand out yet.
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard !finished else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// Ends the stream and returns the samples still held in the converter (nil if none).
    /// Later `convert` calls return nil.
    func finish() -> AVAudioPCMBuffer? {
        guard !finished else { return nil }
        finished = true
        var collected: AVAudioPCMBuffer?
        // Bounded: a converter holds well under a second, so a few passes always empty it.
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if output.frameLength > 0 { collected = Self.appending(output, to: collected) }
            if status != .haveData || output.frameLength == 0 { break }
        }
        return collected
    }

    private static func appending(_ tail: AVAudioPCMBuffer, to head: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        guard let head else { return tail }
        guard let joined = AVAudioPCMBuffer(pcmFormat: head.format, frameCapacity: head.frameLength + tail.frameLength) else { return head }
        let bytesPerFrame = Int(head.format.streamDescription.pointee.mBytesPerFrame)
        let headBytes = Int(head.frameLength) * bytesPerFrame
        let tailBytes = Int(tail.frameLength) * bytesPerFrame
        let destination = joined.audioBufferList.pointee.mBuffers.mData!
        memcpy(destination, head.audioBufferList.pointee.mBuffers.mData!, headBytes)
        memcpy(destination + headBytes, tail.audioBufferList.pointee.mBuffers.mData!, tailBytes)
        joined.frameLength = head.frameLength + tail.frameLength
        return joined
    }
}

/// 16 kHz mono PCM16 ↔ `Data`, the uplink representation.
nonisolated enum PCM16 {
    /// 16 kHz mono PCM16: MacWhisper's input rate and the Speech models' native format.
    static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    static func data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let samples = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return nil }
        return Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }

    static func buffer(from data: Data) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let destination = buffer.int16ChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            _ = memcpy(destination, raw.baseAddress!, Int(frames) * MemoryLayout<Int16>.size)
        }
        buffer.frameLength = frames
        return buffer
    }

    /// True when a buffer in `format` can go to `other` without conversion.
    static func matches(_ other: AVAudioFormat) -> Bool {
        other.commonFormat == format.commonFormat && other.sampleRate == format.sampleRate
            && other.channelCount == format.channelCount
    }
}

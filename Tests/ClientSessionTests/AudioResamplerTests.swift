import AVFAudio
import Foundation
import Testing
@testable import VantageClientLogic

/// The dictation resampler must hand out every sample it was given once the stream ends:
/// a sample-rate converter otherwise keeps the end of the last word.
struct AudioResamplerTests {
    private func tone(rate: Double, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = 0.5 * sin(Float(index) * 0.05) }
        return buffer
    }

    @Test(arguments: [48_000.0, 44_100.0, 22_050.0])
    func finishFlushesWhatTheConverterHeldBack(rate: Double) throws {
        let chunk: AVAudioFrameCount = 4_800
        let chunks = 20
        let resampler = try #require(AudioResampler(from: tone(rate: rate, frames: 1).format, to: PCM16.format))
        var streamed = 0
        for _ in 0..<chunks {
            streamed += Int(resampler.convert(tone(rate: rate, frames: chunk))?.frameLength ?? 0)
        }
        let expected = Double(Int(chunk) * chunks) * 16_000 / rate
        // Without the end-of-stream pass tens of milliseconds are missing (~30 ms at 48 kHz).
        #expect(expected - Double(streamed) > 16 * 10)
        let tail = try #require(resampler.finish())
        #expect(abs(Double(streamed + Int(tail.frameLength)) - expected) <= 2)
        #expect(resampler.finish() == nil)
        #expect(resampler.convert(tone(rate: rate, frames: chunk)) == nil)
    }

    @Test func pcm16RoundTripsThroughData() throws {
        let samples: [Int16] = [0, 1, -1, .max, .min, 1234]
        let data = samples.withUnsafeBytes { Data($0) }
        let buffer = try #require(PCM16.buffer(from: data))
        #expect(buffer.frameLength == 6)
        #expect(PCM16.data(from: buffer) == data)
        #expect(PCM16.buffer(from: Data()) == nil)
        #expect(PCM16.matches(PCM16.format))
        #expect(!PCM16.matches(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!))
    }
}

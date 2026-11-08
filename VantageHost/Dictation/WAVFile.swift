import Foundation
import VantageCore

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

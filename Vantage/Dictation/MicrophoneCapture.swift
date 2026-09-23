import AVFAudio
import Foundation
import os

/// Microphone capture for dictation: one `AVAudioEngine` input tap, converted on the audio thread
/// into the formats the consumers want: the on-device analyzer's format, 16 kHz mono PCM16 for
/// the Mac, and a 0–1 level for the meter.
///
/// Everything here runs on the tap's real-time thread, so the class is nonisolated and hands
/// results out through `@Sendable` callbacks.
nonisolated final class MicrophoneCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInput
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .noInput: "This iPad has no microphone input available."
            case .converterUnavailable: "Vantage couldn't read the microphone's audio format."
            }
        }
    }

    /// 16 kHz mono PCM16: MacWhisper's input rate and the Speech models' native format.
    static let uplinkFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "dictation")
    private let engine = AVAudioEngine()
    private let analyzerFormat: AVAudioFormat?
    private let wantsUplink: Bool
    private let onAnalyzerBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onUplink: @Sendable (Data) -> Void
    private let onLevel: @Sendable (Float) -> Void
    private var analyzerConverter: AVAudioConverter?
    private var uplinkConverter: AVAudioConverter?
    private var isRunning = false

    init(analyzerFormat: AVAudioFormat?, wantsUplink: Bool,
         onAnalyzerBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
         onUplink: @escaping @Sendable (Data) -> Void,
         onLevel: @escaping @Sendable (Float) -> Void) {
        self.analyzerFormat = analyzerFormat
        self.wantsUplink = wantsUplink
        self.onAnalyzerBuffer = onAnalyzerBuffer
        self.onUplink = onUplink
        self.onLevel = onLevel
    }

    /// Activates a record-capable audio session and starts the tap.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // playAndRecord (not record) so a later Mac-audio stream can share the session; other
        // apps' audio ducks while the mic is live.
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noInput }
        if let analyzerFormat {
            guard let converter = AVAudioConverter(from: inputFormat, to: analyzerFormat) else { throw CaptureError.converterUnavailable }
            analyzerConverter = converter
        }
        if wantsUplink {
            guard let converter = AVAudioConverter(from: inputFormat, to: Self.uplinkFormat) else { throw CaptureError.converterUnavailable }
            uplinkConverter = converter
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        isRunning = true
        log.info("microphone started at \(inputFormat.sampleRate, privacy: .public) Hz")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        onLevel(Self.level(of: buffer))
        if let analyzerConverter, let analyzerFormat, let converted = Self.convert(buffer, with: analyzerConverter, to: analyzerFormat) {
            onAnalyzerBuffer(converted)
        }
        if let uplinkConverter, let converted = Self.convert(buffer, with: uplinkConverter, to: Self.uplinkFormat),
           let samples = converted.int16ChannelData?[0] {
            onUplink(Data(bytes: samples, count: Int(converted.frameLength) * MemoryLayout<Int16>.size))
        }
    }

    static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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

    /// RMS of the first channel mapped from −50…0 dBFS onto 0…1.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(1, max(0, (decibels + 50) / 50))
    }
}

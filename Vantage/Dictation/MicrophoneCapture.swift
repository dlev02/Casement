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
            case .noInput: "This \(LocalDevice.noun) has no microphone input available."
            case .converterUnavailable: "Porthole couldn't read the microphone's audio format."
            }
        }
    }

    /// 16 kHz mono PCM16: MacWhisper's input rate and the Speech models' native format.
    static var uplinkFormat: AVAudioFormat { PCM16.format }

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "dictation")
    /// Posts `AVAudioEngineConfigurationChange` on the Mac when the input device changes.
    let engine = AVAudioEngine()
    private let analyzerFormat: AVAudioFormat?
    private let wantsUplink: Bool
    private let onAnalyzerBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onUplink: @Sendable (Data) -> Void
    private let onLevel: @Sendable (Float) -> Void
    /// Guards the resamplers and `isRunning`: the tap thread converts while `stop()` drains.
    private let lock = NSLock()
    private var analyzerResampler: AudioResampler?
    private var uplinkResampler: AudioResampler?
    private var isRunning = false
    private var loggedTapSize = false

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
        #if !os(macOS) // macOS has no audio session; the engine talks to the device directly
        let session = AVAudioSession.sharedInstance()
        // playAndRecord (not record) so a later Mac-audio stream can share the session; other
        // apps' audio ducks while the mic is live.
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw CaptureError.noInput }
        if let analyzerFormat {
            guard let resampler = AudioResampler(from: inputFormat, to: analyzerFormat) else { throw CaptureError.converterUnavailable }
            analyzerResampler = resampler
        }
        if wantsUplink {
            guard let resampler = AudioResampler(from: inputFormat, to: Self.uplinkFormat) else { throw CaptureError.converterUnavailable }
            uplinkResampler = resampler
        }

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        lock.withLock { isRunning = true }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            lock.withLock { isRunning = false }
            input.removeTap(onBus: 0)
            throw error
        }
        log.info("microphone started at \(inputFormat.sampleRate, privacy: .public) Hz")
    }

    /// Stops the tap, then hands out what the resamplers still hold (the last ~30 ms), so the
    /// callbacks have delivered every captured sample by the time this returns.
    func stop() {
        let wasRunning = lock.withLock {
            defer { isRunning = false }
            return isRunning
        }
        guard wasRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // A tap callback already in flight finishes under the lock before the drain runs, and
        // any later one sees `isRunning == false`.
        lock.withLock {
            if let tail = analyzerResampler?.finish() { onAnalyzerBuffer(tail) }
            if let tail = uplinkResampler?.finish(), let data = PCM16.data(from: tail) { onUplink(data) }
        }
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        if !loggedTapSize {
            // What a stop can lose at most: the tap buffer that was still filling.
            loggedTapSize = true
            log.info("microphone tap delivers \(buffer.frameLength, privacy: .public) frames per buffer")
        }
        onLevel(Self.level(of: buffer))
        if let converted = analyzerResampler?.convert(buffer) {
            onAnalyzerBuffer(converted)
        }
        if let converted = uplinkResampler?.convert(buffer), let data = PCM16.data(from: converted) {
            onUplink(data)
        }
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

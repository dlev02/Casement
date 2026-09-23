import AVFAudio
import Foundation
import Speech
import os

/// On-device transcription with the iOS 26 Speech framework: `SpeechTranscriber` where the
/// hardware supports it, otherwise the older `DictationTranscriber`. Audio arrives from
/// `MicrophoneCapture` already converted to `audioFormat` and is fed through an `AsyncStream`.
@MainActor
final class LiveTranscriber {
    enum Failure: Error, Equatable {
        case unsupportedLocale(String)
        case assetsUnavailable
        case needsDownload
    }

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "dictation")
    private let module: any SpeechModule
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let inputStream: AsyncStream<AnalyzerInput>
    private var resultsTask: Task<Void, Never>?
    let audioFormat: AVAudioFormat

    /// Called on the main actor with each result: the text and whether it is final.
    var onResult: ((String, Bool) -> Void)?

    private init(module: any SpeechModule, audioFormat: AVAudioFormat) {
        self.module = module
        self.audioFormat = audioFormat
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        analyzer = SpeechAnalyzer(modules: [module], options: options)
        (inputStream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Builds a transcriber for the current locale. When the model isn't installed yet it is
    /// downloaded (reporting 0–1 progress) if `allowDownload`, else this throws `.needsDownload`,
    /// which the Mac engine uses to skip the live preview rather than start a download.
    static func make(locale: Locale = .current, allowDownload: Bool, progress: @escaping (Double) -> Void) async throws -> LiveTranscriber {
        let module: any SpeechModule
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let transcriber = DictationTranscriber(locale: supported, preset: .progressiveLongDictation)
            module = transcriber
        } else {
            throw Failure.unsupportedLocale(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }

        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            break
        case .unsupported:
            throw Failure.assetsUnavailable
        default:
            guard allowDownload else { throw Failure.needsDownload }
            try await install(module, progress: progress)
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw Failure.assetsUnavailable
        }
        let transcriber = LiveTranscriber(module: module, audioFormat: format)
        try await transcriber.analyzer.prepareToAnalyze(in: format)
        return transcriber
    }

    private static func install(_ module: any SpeechModule, progress: @escaping (Double) -> Void) async throws {
        if let locale = (module as? SpeechTranscriber)?.selectedLocales.first ?? (module as? DictationTranscriber)?.selectedLocales.first {
            _ = try? await AssetInventory.reserve(locale: locale)
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    func start() async throws {
        let stream = inputStream
        resultsTask = Task { [weak self] in
            await self?.consumeResults()
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Safe from the audio thread: the continuation is thread-safe.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ends input and waits for the last final result.
    func finish() async {
        input.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            log.error("finalizing transcription failed: \(error.localizedDescription, privacy: .public)")
            await analyzer.cancelAndFinishNow()
        }
        await resultsTask?.value
    }

    func cancel() async {
        input.finish()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }

    private func consumeResults() async {
        do {
            if let transcriber = module as? SpeechTranscriber {
                for try await result in transcriber.results {
                    onResult?(String(result.text.characters), result.isFinal)
                }
            } else if let transcriber = module as? DictationTranscriber {
                for try await result in transcriber.results {
                    onResult?(String(result.text.characters), result.isFinal)
                }
            }
        } catch {
            log.error("transcription results ended: \(error.localizedDescription, privacy: .public)")
        }
    }
}

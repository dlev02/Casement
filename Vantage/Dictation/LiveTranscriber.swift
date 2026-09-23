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
    private let localeKey: String
    private var hasStarted = false
    /// Converts 16 kHz PCM16 uplink audio when the analyzer wants another format.
    private var uplinkResampler: AudioResampler?
    let audioFormat: AVAudioFormat

    /// Called on the main actor with each result: the text and whether it is final.
    var onResult: ((String, Bool) -> Void)?

    private init(module: any SpeechModule, audioFormat: AVAudioFormat, localeKey: String) {
        self.module = module
        self.audioFormat = audioFormat
        self.localeKey = localeKey
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        analyzer = SpeechAnalyzer(modules: [module], options: options)
        (inputStream, input) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
    }

    /// What `make` learned about a locale: which module serves it and in what format. Looked up
    /// once per launch; the first lookup can take seconds on a device (Speech's daemons and the
    /// asset catalog start cold), later ones are instant.
    private struct Plan {
        var locale: Locale
        var usesSpeechTranscriber: Bool
        var format: AVAudioFormat

        func module() -> any SpeechModule {
            usesSpeechTranscriber ? SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                : DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        }
    }

    private static let staticLog = Logger(subsystem: "com.benjaminlevinson.vantage", category: "dictation")
    static let signposter = OSSignposter(logger: staticLog)
    private static var plans: [String: Plan] = [:]
    /// A prepared, never-started transcriber per locale, left by an attempt that was cancelled
    /// (or finished preparing after the user stopped). The next attempt takes it.
    private static var spares: [String: LiveTranscriber] = [:]
    /// The one preparation running per locale. Unstructured, so cancelling the dictation that
    /// started it doesn't throw the work away: the next attempt waits for it instead of queueing
    /// a second cold start behind it.
    private static var building: [String: Task<Void, any Error>] = [:]

    /// Builds a transcriber for the current locale. When the model isn't installed yet it is
    /// downloaded (reporting 0–1 progress) if `allowDownload`, else this throws `.needsDownload`,
    /// which the Mac engine uses to skip the live preview rather than start a download.
    ///
    /// Only one preparation per locale runs at a time; a caller that is cancelled while waiting
    /// leaves the result for the next one (`spares`).
    static func make(locale: Locale = .current, allowDownload: Bool, progress: @escaping (Double) -> Void) async throws -> LiveTranscriber {
        let key = locale.identifier
        let started = ContinuousClock.now
        var retriedWithDownload = false
        while true {
            if let ready = spares.removeValue(forKey: key) {
                staticLog.info("speech transcriber ready: \(Self.milliseconds(since: started), privacy: .public) ms")
                return ready
            }
            if let running = building[key] {
                do {
                    try await running.value
                } catch Failure.needsDownload where allowDownload && !retriedWithDownload {
                    retriedWithDownload = true // That attempt wouldn't download; this one may.
                }
                try Task.checkCancellation()
                continue // Take its result, or build again if someone else got there first.
            }
            let download = allowDownload
            let task = Task<Void, any Error> { @MainActor in
                do {
                    let transcriber = try await build(locale: locale, allowDownload: download, progress: progress)
                    spares[key] = transcriber
                    building[key] = nil
                } catch {
                    building[key] = nil
                    throw error
                }
            }
            building[key] = task
        }
    }

    /// Hands back a transcriber that was made but never started, for the next dictation.
    static func recycle(_ transcriber: LiveTranscriber) {
        guard !transcriber.hasStarted else { return }
        spares[transcriber.localeKey] = spares[transcriber.localeKey] ?? transcriber
    }

    private static func build(locale: Locale, allowDownload: Bool, progress: @escaping (Double) -> Void) async throws -> LiveTranscriber {
        let key = locale.identifier
        let interval = signposter.beginInterval("prepare speech transcriber")
        defer { signposter.endInterval("prepare speech transcriber", interval) }
        var stage = ContinuousClock.now
        func lap(_ name: String) {
            staticLog.info("speech transcriber \(name, privacy: .public): \(Self.milliseconds(since: stage), privacy: .public) ms")
            stage = .now
        }

        let plan: Plan
        if let cached = plans[key] {
            plan = cached
        } else {
            let module: any SpeechModule
            let usesSpeechTranscriber: Bool
            let supportedLocale: Locale
            if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                module = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
                usesSpeechTranscriber = true
                supportedLocale = supported
            } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                module = DictationTranscriber(locale: supported, preset: .progressiveLongDictation)
                usesSpeechTranscriber = false
                supportedLocale = supported
            } else {
                throw Failure.unsupportedLocale(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
            }
            lap("locale lookup")

            switch await AssetInventory.status(forModules: [module]) {
            case .installed:
                lap("asset status")
            case .unsupported:
                throw Failure.assetsUnavailable
            default:
                lap("asset status")
                guard allowDownload else { throw Failure.needsDownload }
                try await install(module, progress: progress)
                lap("model download")
            }

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw Failure.assetsUnavailable
            }
            lap("audio format")
            plan = Plan(locale: supportedLocale, usesSpeechTranscriber: usesSpeechTranscriber, format: format)
        }

        let transcriber = LiveTranscriber(module: plan.module(), audioFormat: plan.format, localeKey: key)
        do {
            try await transcriber.analyzer.prepareToAnalyze(in: plan.format)
        } catch {
            plans[key] = nil // Look everything up again next time.
            throw error
        }
        lap("analyzer prepare")
        plans[key] = plan
        return transcriber
    }

    nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
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
        hasStarted = true
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

    /// Feeds 16 kHz mono PCM16 (the Mac uplink audio), converting if the analyzer wants
    /// something else.
    func feed(pcm16 data: Data) {
        guard let buffer = PCM16.buffer(from: data) else { return }
        if PCM16.matches(audioFormat) {
            feed(buffer)
            return
        }
        if uplinkResampler == nil { uplinkResampler = AudioResampler(from: PCM16.format, to: audioFormat) }
        if let converted = uplinkResampler?.convert(buffer) { feed(converted) }
    }

    /// Ends input and waits for the last final result.
    func finish() async {
        if let tail = uplinkResampler?.finish() { feed(tail) }
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

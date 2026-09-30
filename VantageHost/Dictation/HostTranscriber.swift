import AVFAudio
import Foundation
import Speech
import VantageCore
import os

/// Turns a finished dictation clip into text on the Mac.
///
/// The engine the client asked for goes first; after that MacWhisper (its `mw` CLI transcribes a
/// file through the running app with whatever model Drew selected there), then the optional
/// built-in Parakeet model, then macOS SpeechAnalyzer. MacWhisper and Apple read a private temp
/// WAV that exists only for the length of the run; Parakeet takes the samples directly. Nothing is
/// logged but sizes and timings, and `--persist` is never passed, so dictations stay out of
/// MacWhisper's history.
nonisolated struct HostTranscriber: Sendable {
    struct Output: Sendable, Equatable {
        var text: String
        var engine: DictationEngineID
    }

    struct Failure: Error, Sendable, Equatable {
        var message: String
    }

    private static let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "dictation")

    /// Fallback order when the client didn't ask for a specific engine (or asked for one this Mac
    /// doesn't have).
    static let preferenceOrder: [DictationEngineID] = [.macWhisper, .parakeet, .apple]

    var macWhisper: MacWhisperCLI?
    var parakeet: (any BuiltInSpeechEngine)?
    var appleEnabled: Bool
    var directory: URL

    init(macWhisper: MacWhisperCLI?, parakeet: (any BuiltInSpeechEngine)? = nil, appleEnabled: Bool,
         directory: URL = HostTranscriber.defaultDirectory) {
        self.macWhisper = macWhisper
        self.parakeet = parakeet
        self.appleEnabled = appleEnabled
        self.directory = directory
    }

    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("VantageDictation", isDirectory: true)
    }

    /// Engines this Mac can run right now, best first. `mw` is probed with `mw version`, which
    /// answers in ~20 ms without launching MacWhisper; the answer is cached for a minute so every
    /// connect doesn't pay for a subprocess. Parakeet is read live: it's listed only while the
    /// user has it turned on and the model is on disk.
    static func availableEngines() async -> [DictationEngineID] {
        let probed: [DictationEngineID]
        if let cached = EngineCache.shared.value() {
            probed = cached
        } else {
            var engines: [DictationEngineID] = []
            if let cli = MacWhisperCLI.locate(), await cli.version() != nil { engines.append(.macWhisper) }
            if SpeechTranscriber.isAvailable { engines.append(.apple) }
            EngineCache.shared.store(engines)
            probed = engines
        }
        let builtIn: [DictationEngineID] = BuiltInSpeechEngines.shared.parakeet != nil ? [.parakeet] : []
        return preferenceOrder.filter { (probed + builtIn).contains($0) }
    }

    /// The transcriber matching what `availableEngines()` found.
    static func live() async -> HostTranscriber {
        let engines = await availableEngines()
        return HostTranscriber(macWhisper: engines.contains(.macWhisper) ? MacWhisperCLI.locate() : nil,
                               parakeet: engines.contains(.parakeet) ? BuiltInSpeechEngines.shared.parakeet : nil,
                               appleEnabled: engines.contains(.apple))
    }

    /// The requested engine first (when it's one this build knows), then `preferenceOrder`.
    static func order(requested: DictationEngineID?) -> [DictationEngineID] {
        guard let requested, preferenceOrder.contains(requested) else { return preferenceOrder }
        return [requested] + preferenceOrder.filter { $0 != requested }
    }

    private func isUsable(_ engine: DictationEngineID) -> Bool {
        switch engine {
        case .macWhisper: macWhisper != nil
        case .parakeet: parakeet != nil
        case .apple: appleEnabled
        default: false
        }
    }

    /// Silence appended to every clip before any engine sees it. Whisper-family models (and
    /// Parakeet) tend to drop the final word when speech runs right up to the end of the audio,
    /// which is exactly how a push-to-talk clip ends.
    static let trailingSilence: Duration = .milliseconds(500)

    /// `samples` (16 kHz mono PCM16) followed by `trailingSilence`.
    static func paddedForTranscription(_ samples: Data) -> Data {
        let silenceBytes = Int(trailingSilence / .seconds(1) * MicAudioFormat.pcm16LE16k.sampleRate) * 2
        return samples + Data(count: silenceBytes)
    }

    /// Transcribes 16 kHz mono PCM16. Tries the requested engine, then the others in
    /// `preferenceOrder`; the output names the engine that answered.
    func transcribe(samples recorded: Data, requested: DictationEngineID?, language: String?) async throws(Failure) -> Output {
        guard !recorded.isEmpty else { return Output(text: "", engine: requested ?? .macWhisper) }
        let seconds = Double(recorded.count) / (MicAudioFormat.pcm16LE16k.sampleRate * 2)
        let samples = Self.paddedForTranscription(recorded)
        let usable = Self.order(requested: requested).filter(isUsable)
        guard !usable.isEmpty else {
            throw Failure(message: "This Mac has no speech engine. Install MacWhisper or turn on built-in transcription in Porthole Host, or transcribe on the iPad.")
        }

        // Written only when a file-based engine runs, and always deleted afterwards.
        var clipURL: URL?
        defer { if let clipURL { try? FileManager.default.removeItem(at: clipURL) } }
        func clipFile() throws -> URL {
            if let clipURL { return clipURL }
            do {
                let url = try writeClip(samples)
                clipURL = url
                return url
            } catch {
                Self.log.error("couldn't write dictation clip: \(error.localizedDescription, privacy: .public)")
                throw Failure(message: "The Mac couldn't save the recording for transcription.")
            }
        }

        var lastFailure = Failure(message: "Transcription failed on the Mac.")
        for engine in usable {
            let started = ContinuousClock.now
            do {
                let text: String
                switch engine {
                case .macWhisper:
                    // Cold MacWhisper loads its model first (~11 s measured); long clips scale.
                    text = try await macWhisper!.transcribe(try clipFile(), language: language, timeout: .seconds(30 + seconds))
                case .parakeet:
                    text = try await parakeet!.transcribe(samples: samples, language: language)
                default:
                    text = try await Self.transcribeWithApple(try clipFile(), language: language)
                }
                Self.log.info("transcribed \(String(format: "%.1f", seconds), privacy: .public) s with \(engine.rawValue, privacy: .public) in \((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])), privacy: .public); \(text.count, privacy: .public) characters")
                return Output(text: text, engine: engine)
            } catch let failure as Failure {
                Self.log.error("\(engine.rawValue, privacy: .public) failed: \(failure.message, privacy: .public)")
                lastFailure = failure
            } catch {
                Self.log.error("\(engine.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                let message: String = switch engine {
                case .macWhisper: "MacWhisper couldn't transcribe the recording."
                case .parakeet: "Parakeet couldn't transcribe the recording."
                default: "The Mac couldn't transcribe the recording."
                }
                lastFailure = Failure(message: message)
            }
        }
        throw lastFailure
    }

    private func writeClip(_ samples: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
        guard FileManager.default.createFile(atPath: url.path, contents: WAVFile.pcm16Mono(samples, sampleRate: 16_000),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// macOS SpeechAnalyzer over the WAV (the same model the iPad uses, so this is a fallback, not
    /// an upgrade). Downloads the locale's model on first use.
    static func transcribeWithApple(_ url: URL, language: String?) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw Failure(message: "Apple speech recognition isn't available on this Mac.") }
        let wanted = language.map { Locale(identifier: $0) } ?? Locale.current
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw Failure(message: "Apple speech recognition doesn't support that language on this Mac.")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if await AssetInventory.status(forModules: [transcriber]) < .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let collected = transcriber.results.reduce(into: "") { text, result in
            if result.isFinal { text += String(result.text.characters) }
        }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A speech engine that runs inside Vantage Host on 16 kHz mono PCM16: the optional built-in
/// Parakeet model (`ParakeetRuntime`). Behind a protocol so the dictation tests don't need
/// FluidAudio or a downloaded model.
nonisolated protocol BuiltInSpeechEngine: Sendable {
    /// Transcribes one clip. A model that is still loading is waited for briefly; past that it
    /// throws `HostTranscriber.Failure` so the caller falls back to the next engine.
    func transcribe(samples: Data, language: String?) async throws -> String
}

/// The built-in engines the user has turned on and installed, published by the host app
/// (`ParakeetModel`) and read by sessions when they advertise and transcribe.
nonisolated final class BuiltInSpeechEngines: @unchecked Sendable {
    static let shared = BuiltInSpeechEngines()
    private let lock = NSLock()
    private var storedParakeet: (any BuiltInSpeechEngine)?

    var parakeet: (any BuiltInSpeechEngine)? {
        get { lock.withLock { storedParakeet } }
        set { lock.withLock { storedParakeet = newValue } }
    }
}

/// MacWhisper's command-line tool. It ships inside the app bundle and talks to the running app
/// over a local socket, launching it if needed.
nonisolated struct MacWhisperCLI: Sendable {
    var executableURL: URL

    static let candidatePaths = [
        "/Applications/MacWhisper.app/Contents/MacOS/mw",
        NSHomeDirectory() + "/Applications/MacWhisper.app/Contents/MacOS/mw",
        "/usr/local/bin/mw",
        "/opt/homebrew/bin/mw",
    ]

    static func locate() -> MacWhisperCLI? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { MacWhisperCLI(executableURL: URL(fileURLWithPath: $0)) }
    }

    /// `mw version`, e.g. "MacWhisper 14.8.1 (1481)", or nil when the CLI doesn't answer.
    func version() async -> String? {
        guard let output = try? await ProcessRunner.run(executableURL, ["version"], timeout: .seconds(3)),
              output.status == 0 else { return nil }
        let text = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// `mw transcribe --language <code> <wav>`; plain text arrives on stdout.
    func transcribe(_ url: URL, language: String?, timeout: Duration) async throws -> String {
        var arguments = ["transcribe", "--format", "txt", "--no-timestamps"]
        if let language = Self.sanitizedLanguage(language) { arguments += ["--language", language] }
        arguments.append(url.path)
        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(executableURL, arguments, timeout: timeout)
        } catch ProcessRunner.RunError.timedOut {
            throw HostTranscriber.Failure(message: "MacWhisper took too long to transcribe.")
        }
        guard output.status == 0 else {
            throw HostTranscriber.Failure(message: "MacWhisper couldn't transcribe the recording. Check that MacWhisper opens on the Mac.")
        }
        return String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only an ISO 639 code or "auto" reaches the command line.
    static func sanitizedLanguage(_ language: String?) -> String? {
        guard let language = language?.lowercased(),
              language == "auto" || (2...3).contains(language.count) && language.allSatisfy({ $0 >= "a" && $0 <= "z" }) else { return nil }
        return language
    }
}

/// Runs a subprocess off the cooperative pool with a watchdog, collecting stdout.
nonisolated enum ProcessRunner {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
    }

    enum RunError: Error {
        case timedOut
    }

    static func run(_ executable: URL, _ arguments: [String], timeout: Duration) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // `waitUntilExit()` can miss an exit and block forever (seen with `mw` after a few dozen
        // runs: the child was reaped, the waiter never woke), so wait for the termination handler.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        let box = ProcessBox(process)
        let watchdog = Task.detached {
            try await Task.sleep(for: timeout)
            box.terminate()
        }
        defer { watchdog.cancel() }
        let output: Output = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // EOF arrives when the process exits (or is terminated by the watchdog).
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                exited.wait()
                continuation.resume(returning: Output(status: box.process.terminationStatus, stdout: data))
            }
        }
        if box.didTimeOut { throw RunError.timedOut }
        return output
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        private let lock = NSLock()
        private var timedOut = false

        init(_ process: Process) { self.process = process }

        var didTimeOut: Bool { lock.withLock { timedOut } }

        func terminate() {
            lock.withLock {
                guard process.isRunning else { return }
                timedOut = true
                process.terminate()
            }
        }
    }
}

/// One-minute cache of `HostTranscriber.availableEngines()`.
private nonisolated final class EngineCache: @unchecked Sendable {
    static let shared = EngineCache()
    private let lock = NSLock()
    private var engines: [DictationEngineID]?
    private var storedAt = ContinuousClock.now

    func value() -> [DictationEngineID]? {
        lock.withLock { engines != nil && ContinuousClock.now - storedAt < .seconds(60) ? engines : nil }
    }

    func store(_ value: [DictationEngineID]) {
        lock.withLock {
            engines = value
            storedAt = .now
        }
    }
}

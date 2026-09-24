import AVFAudio
import Foundation
import Observation
import Speech
#if canImport(UIKit)
import UIKit
#endif
import VantageCore
import os

/// One dictation at a time for a session: records the mic, transcribes on this device or streams
/// the audio to the Mac (MacWhisper or the host's built-in Parakeet), and holds the text for
/// review until Send or Cancel.
///
/// The Mac path only ever runs when the host advertised a Mac engine (`DictationRoute.resolve`),
/// so an older host never sees `dictationControl` or `micAudio`. Transcript text is never
/// logged except as `.private`.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        /// Permissions, model download (0–1 when known), or engine warm-up.
        case preparing(progress: Double?)
        case listening
        /// Audio sent; waiting for the Mac's transcript.
        case transcribing
        case review
        case failed(Failure)
    }

    struct Failure: Equatable {
        var title: String
        var message: String
        /// Offer a button to this privacy setting (a permission was denied).
        var settings: PrivacySetting?

        var opensSettings: Bool { settings != nil }
    }

    /// The permission a failure's Open Settings button leads to.
    enum PrivacySetting: Equatable {
        case microphone
        case speechRecognition

        /// iOS has one page per app; the Mac's System Settings has one pane per permission.
        var url: URL? {
            #if os(macOS)
            let anchor = self == .microphone ? "Privacy_Microphone" : "Privacy_SpeechRecognition"
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
            #elseif canImport(UIKit)
            return URL(string: UIApplication.openSettingsURLString)
            #else
            return nil
            #endif
        }
    }

    /// What to do once listening stops and the final text is known.
    enum Completion: Equatable {
        case review
        case send(pressReturn: Bool)
    }

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "dictation")

    private(set) var phase: Phase = .idle
    private(set) var route: DictationRoute = .iPad
    private(set) var transcript = DictationTranscript()
    /// Editable text in review.
    var text = ""
    private(set) var level: Float = 0
    private(set) var startedAt: Date?
    /// The engine that produced the text under review (the Mac may fall back to Apple's).
    private(set) var resultEngine: DictationEngineID?
    /// A live on-iPad transcript shown while the Mac engine records, when the model is installed.
    private(set) var hasLivePreview = false

    var isActive: Bool { phase != .idle }
    var isListening: Bool { phase == .listening }

    /// Sends a protocol message to the host (dictation control and audio).
    var send: ((Message) -> Void)?
    /// Types final text on the Mac through the normal text path, optionally pressing Return.
    var deliver: ((String, Bool) -> Void)?
    /// True right before the microphone takes the audio session (`.playAndRecord`), false right
    /// after it has released it, so Mac audio can step aside instead of fighting over the category.
    var onMicrophoneActive: ((Bool) -> Void)?

    private var clipID: UUID?
    private var packetizer: MicPacketizer?
    private var capture: MicrophoneCapture?
    /// Mic audio for the Mac, in capture order, drained on the main actor.
    private var uplink: AsyncStream<Data>.Continuation?
    private var uplinkTask: Task<Void, Never>?
    private var transcriber: LiveTranscriber?
    private var completion: Completion = .review
    private var startTask: Task<Void, Never>?
    private var resultTimeout: Task<Void, Never>?
    private var interruptionObserver: (any NSObjectProtocol)?
    /// Bumped by every reset, so work that outlives its dictation (a preview that finished
    /// preparing late, the tail after release) can tell it no longer applies.
    private var attempt = 0
    /// When the current dictation was requested, for the startup timing log.
    private var requestedAt = ContinuousClock.now
    /// Mac engine: the on-iPad preview transcriber still being prepared.
    private var previewTask: Task<Void, Never>?
    /// Mac engine: uplink audio recorded while the preview is getting ready, replayed into it
    /// when it attaches so it doesn't miss the first words.
    private var previewBacklog = Data()
    /// The press that is down began this dictation (hold to talk vs tap to toggle).
    private var pressStartedDictation = false

    /// How long the microphone stays open after the user stops: push-to-talk fingers lift while
    /// the last word is still sounding.
    static let captureTail: Duration = .milliseconds(400)
    /// Uplink audio held for a preview that isn't ready yet (60 s of 16 kHz PCM16); past this
    /// the preview is skipped.
    static let previewBacklogLimit = 60 * 16_000 * 2

    // MARK: Control-strip gesture

    /// Finger down on the mic button. Starts dictation if nothing is running.
    func pressBegan(route: DictationRoute) {
        switch phase {
        case .idle, .review, .failed:
            pressStartedDictation = true
            start(route: route)
        default:
            pressStartedDictation = false
        }
    }

    /// Finger up. A hold of ~0.3 s or more is push-to-talk and stops on release; a quick tap
    /// leaves dictation running (toggle), and the next tap stops it.
    func pressEnded(held: Bool) {
        defer { pressStartedDictation = false }
        if pressStartedDictation {
            if held { stop(then: .review) }
        } else if phase == .listening || isPreparing {
            stop(then: .review)
        }
    }

    /// The press turned into a drag of the control strip: drop the dictation it started.
    func pressCancelled() {
        if pressStartedDictation { cancel() }
        pressStartedDictation = false
    }

    /// VoiceOver and keyboard: one action that starts or stops.
    func toggle(route: DictationRoute) {
        if phase == .listening || isPreparing { stop(then: .review) } else { start(route: route) }
    }

    private var isPreparing: Bool {
        if case .preparing = phase { true } else { false }
    }

    // MARK: Lifecycle

    /// Starts listening. Text already under review is kept and the new speech is appended.
    func start(route: DictationRoute) {
        let keep = phase == .review ? text : ""
        reset(keepingPhase: true)
        self.route = route
        transcript = DictationTranscript(prefix: keep)
        text = keep
        completion = .review
        phase = .preparing(progress: nil)
        requestedAt = .now
        startTask = Task { await begin() }
    }

    /// Stops listening and either shows the text for review or sends it.
    func stop(then completion: Completion) {
        self.completion = completion
        switch phase {
        case .preparing:
            cancel()
        case .listening:
            Task { await finishListening() }
        case .review:
            if case .send(let pressReturn) = completion { sendText(pressReturn: pressReturn) }
        default:
            break
        }
    }

    func cancel() {
        if let clipID, case .mac = route {
            send?(.dictationControl(DictationControl(action: .cancel, id: clipID)))
        }
        reset(keepingPhase: false)
    }

    /// Types the reviewed text on the Mac and closes the panel.
    func sendText(pressReturn: Bool) {
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !final.isEmpty else { return }
        deliver?(final, pressReturn)
        reset(keepingPhase: false)
    }

    /// The session dropped. Audio in flight to the Mac is lost; text under review is kept.
    func connectionLost() {
        switch phase {
        case .listening, .preparing, .transcribing:
            if case .mac = route {
                let preview = transcript.display
                reset(keepingPhase: false)
                phase = .failed(Failure(title: "Connection Lost",
                                        message: preview.isEmpty ? "The connection to the Mac dropped before it could transcribe the recording." :
                                            "The connection to the Mac dropped before \(route.label) finished. The on-\(LocalDevice.noun) preview is below."))
                if !preview.isEmpty { text = preview }
            } else {
                stop(then: .review)
            }
        default:
            break
        }
    }

    /// The Mac's answer to a committed clip.
    func handle(_ result: DictationResult) {
        guard result.id == clipID, phase == .transcribing else { return }
        resultTimeout?.cancel()
        if let error = result.error {
            let preview = transcript.display
            phase = .failed(Failure(title: "Transcription Failed", message: error))
            if !preview.isEmpty { text = preview }
            return
        }
        resultEngine = result.engine
        log.debug("mac transcript: \(result.text, privacy: .private)")
        text = DictationTranscript.join(transcript.prefix, result.text)
        clipID = nil
        complete()
    }

    // MARK: Private

    private func begin() async {
        let attempt = self.attempt
        let signpost = LiveTranscriber.signposter.beginInterval("dictation start")
        defer { LiveTranscriber.signposter.endInterval("dictation start", signpost) }
        guard await ensureMicrophonePermission() else { return }
        logStage("microphone permission")
        guard attempt == self.attempt, !Task.isCancelled else { return }
        do {
            switch route {
            case .iPad:
                guard await ensureSpeechPermission() else { return }
                let transcriber = try await LiveTranscriber.make(allowDownload: true) { [weak self] fraction in
                    guard let self, self.attempt == attempt, self.isPreparing else { return }
                    self.phase = .preparing(progress: fraction)
                }
                guard attempt == self.attempt, !Task.isCancelled else {
                    LiveTranscriber.recycle(transcriber)
                    return
                }
                logStage("speech transcriber")
                try await startCapture(transcriber: transcriber, uplink: false)
            case .mac(let engine):
                // Nothing to wait for: the Mac transcribes after the fact, so the mic opens and
                // the clip begins right away. The on-iPad preview is a bonus that joins when its
                // model is ready (the first preparation after launch can take many seconds).
                let id = UUID()
                clipID = id
                packetizer = MicPacketizer(dictationID: id)
                send?(.dictationControl(DictationControl(action: .begin, id: id, engine: engine,
                                                         language: DictationLanguage.code(), format: .pcm16LE16k)))
                try await startCapture(transcriber: nil, uplink: true)
                if SFSpeechRecognizer.authorizationStatus() == .authorized { attachPreview() }
            }
            logStage("listening")
        } catch is CancellationError {
            return
        } catch let failure as LiveTranscriber.Failure {
            fail(failure)
        } catch {
            log.error("dictation couldn't start: \(error.localizedDescription, privacy: .public)")
            fail(Failure(title: "Dictation Unavailable", message: error.localizedDescription))
        }
    }

    /// Startup timing, measured from the tap (no transcript content).
    private func logStage(_ stage: String) {
        let route = switch route {
        case .iPad: LocalDevice.noun
        case .mac(let engine): engine.rawValue
        }
        log.info("dictation start (\(route, privacy: .public)): \(stage, privacy: .public) after \(LiveTranscriber.milliseconds(since: self.requestedAt), privacy: .public) ms")
    }

    /// Mac engine: prepares the on-iPad preview alongside the recording and attaches it when
    /// ready, replaying what was already said. Never delays the recording itself.
    private func attachPreview() {
        let attempt = self.attempt
        previewBacklog = Data()
        previewTask = Task { [weak self] in
            let transcriber: LiveTranscriber
            do {
                transcriber = try await LiveTranscriber.make(allowDownload: false) { _ in }
            } catch {
                // No model on this device (or not now): record without a preview.
                self?.dropPreview(attempt: attempt)
                return
            }
            guard let self, attempt == self.attempt, self.phase == .listening, self.previewTask != nil else {
                LiveTranscriber.recycle(transcriber)
                return
            }
            transcriber.onResult = { [weak self] text, isFinal in
                self?.transcript.apply(text, isFinal: isFinal)
            }
            do {
                try await transcriber.start()
            } catch {
                self.log.error("dictation preview couldn't start: \(error.localizedDescription, privacy: .public)")
                await transcriber.cancel()
                self.dropPreview(attempt: attempt)
                return
            }
            guard attempt == self.attempt, self.previewTask != nil else {
                await transcriber.cancel()
                return
            }
            // Synchronous from here on: nothing else can reach `upload` until the preview owns the feed.
            transcriber.feed(pcm16: self.previewBacklog)
            self.log.info("dictation preview attached after \(LiveTranscriber.milliseconds(since: self.requestedAt), privacy: .public) ms, replaying \(self.previewBacklog.count, privacy: .public) bytes")
            self.previewBacklog = Data()
            self.previewTask = nil
            self.transcriber = transcriber
            self.hasLivePreview = true
        }
    }

    private func dropPreview(attempt: Int) {
        guard attempt == self.attempt else { return }
        previewTask?.cancel()
        previewTask = nil
        previewBacklog = Data()
    }

    private func startCapture(transcriber: LiveTranscriber?, uplink: Bool) async throws {
        self.transcriber = transcriber
        hasLivePreview = transcriber != nil
        transcriber?.onResult = { [weak self] text, isFinal in
            self?.transcript.apply(text, isFinal: isFinal)
        }
        try await transcriber?.start()
        let (samples, continuation) = AsyncStream<Data>.makeStream()
        if uplink {
            self.uplink = continuation
            uplinkTask = Task { [weak self] in
                for await chunk in samples { self?.upload(chunk) }
            }
        }
        let capture = MicrophoneCapture(
            analyzerFormat: uplink ? nil : transcriber?.audioFormat,
            wantsUplink: uplink,
            onAnalyzerBuffer: { [transcriber] buffer in transcriber?.feed(buffer) },
            onUplink: { chunk in continuation.yield(chunk) },
            onLevel: { [weak self] level in Task { @MainActor in self?.level = level } })
        onMicrophoneActive?(true)
        do {
            try capture.start()
        } catch {
            onMicrophoneActive?(false)
            throw error
        }
        self.capture = capture
        logStage("microphone started")
        observeInterruptions(of: capture)
        startedAt = .now
        phase = .listening
    }

    private func upload(_ samples: Data) {
        guard var packetizer else { return }
        for packet in packetizer.push(samples) { send?(.micAudio(packet)) }
        self.packetizer = packetizer
        // The Mac route's preview listens to the same 16 kHz audio the Mac gets.
        if let transcriber {
            transcriber.feed(pcm16: samples)
        } else if previewTask != nil {
            previewBacklog.append(samples)
            if previewBacklog.count > Self.previewBacklogLimit { dropPreview(attempt: attempt) }
        }
    }

    private func finishListening() async {
        let attempt = self.attempt
        // Say so at once, but keep recording a moment: the finger lifts while the last word is
        // still sounding.
        phase = .transcribing
        level = 0
        if capture != nil { try? await Task.sleep(for: Self.captureTail) }
        guard attempt == self.attempt else { return } // Cancelled during the tail.
        // Stopping flushes the resamplers, so every captured sample has been handed out after this.
        releaseMicrophone()
        switch route {
        case .iPad:
            await transcriber?.finish()
            guard attempt == self.attempt else { return }
            transcriber = nil
            text = transcript.committed
            complete()
        case .mac:
            // A preview that never got ready is no longer wanted; it stays prepared for next time.
            previewTask?.cancel()
            previewTask = nil
            previewBacklog = Data()
            // Drain audio still queued behind the tap so the commit follows the last packet.
            uplink?.finish()
            uplink = nil
            await uplinkTask?.value
            uplinkTask = nil
            guard attempt == self.attempt else { return }
            if var packetizer, let tail = packetizer.flush() {
                send?(.micAudio(tail))
                self.packetizer = packetizer
            }
            guard let clipID else { return }
            log.info("dictation clip sent: \(self.packetizer?.sequence ?? 0, privacy: .public) packets")
            send?(.dictationControl(DictationControl(action: .commit, id: clipID)))
            resultTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled, let self, self.phase == .transcribing else { return }
                let preview = self.transcript.display
                self.phase = .failed(Failure(title: "No Answer from the Mac", message: "\(self.route.label) didn't return a transcript in time."))
                if !preview.isEmpty { self.text = preview }
            }
            // Keep the preview's last words on screen while the Mac works.
            if let transcriber {
                await transcriber.finish()
                if attempt == self.attempt { self.transcriber = nil }
            }
        }
    }

    private func complete() {
        stopObservingInterruptions()
        switch completion {
        case .review:
            phase = .review
        case .send(let pressReturn):
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                phase = .review // Nothing recognized; say so instead of sending nothing.
            } else {
                sendText(pressReturn: pressReturn)
            }
        }
    }

    private func fail(_ failure: LiveTranscriber.Failure) {
        switch failure {
        case .unsupportedLocale(let name):
            fail(Failure(title: "Language Not Supported", message: "Dictation on \(LocalDevice.this) doesn't support \(name). Choose On the Mac (MacWhisper) in Settings → Controls to transcribe on your Mac."))
        case .assetsUnavailable, .needsDownload:
            fail(Failure(title: "Speech Model Unavailable", message: "This \(LocalDevice.noun) couldn't get the speech model. Check your internet connection and try again, or transcribe on the Mac."))
        }
    }

    private func fail(_ failure: Failure) {
        let keep = transcript.display
        // The Mac already opened a clip for this attempt; don't leave it waiting.
        if let clipID, case .mac = route { send?(.dictationControl(DictationControl(action: .cancel, id: clipID))) }
        reset(keepingPhase: false)
        phase = .failed(failure)
        text = keep
    }

    private func reset(keepingPhase: Bool) {
        attempt += 1
        startTask?.cancel()
        startTask = nil
        previewTask?.cancel()
        previewTask = nil
        previewBacklog = Data()
        resultTimeout?.cancel()
        resultTimeout = nil
        releaseMicrophone()
        uplink?.finish()
        uplink = nil
        uplinkTask?.cancel()
        uplinkTask = nil
        if let transcriber { Task { await transcriber.cancel() } }
        transcriber = nil
        stopObservingInterruptions()
        clipID = nil
        packetizer = nil
        level = 0
        startedAt = nil
        resultEngine = nil
        hasLivePreview = false
        if !keepingPhase {
            phase = .idle
            text = ""
            transcript = DictationTranscript()
        }
    }

    /// Stops the microphone (which deactivates the audio session) and says so.
    private func releaseMicrophone() {
        guard let capture else { return }
        capture.stop()
        self.capture = nil
        onMicrophoneActive?(false)
    }

    // MARK: Permissions

    private func ensureMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            if await AVAudioApplication.requestRecordPermission() { return true }
        default:
            break
        }
        fail(Failure(title: "Microphone Access Is Off",
                     message: "Allow Vantage to use the microphone in \(LocalDevice.settingsApp) to dictate to your Mac.", settings: .microphone))
        return false
    }

    private func ensureSpeechPermission() async -> Bool {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined { status = await Self.requestSpeechAuthorization() }
        guard status == .authorized else {
            fail(Failure(title: "Speech Recognition Is Off",
                         message: "Allow Speech Recognition for Vantage in \(LocalDevice.settingsApp), or choose On the Mac (MacWhisper) in Settings → Controls.",
                         settings: .speechRecognition))
            return false
        }
        return true
    }

    /// Nonisolated so the completion handler, which runs on an arbitrary queue, isn't
    /// main-actor-isolated.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    // MARK: Interruptions

    /// A phone call or Siri takes the mic (iOS), or the Mac's input device changes under the
    /// engine, which stops it (macOS has no audio session to interrupt): stop and keep what was
    /// heard.
    private func observeInterruptions(of capture: MicrophoneCapture) {
        guard interruptionObserver == nil else { return }
        #if os(macOS)
        let name = Notification.Name.AVAudioEngineConfigurationChange
        let object: AnyObject? = capture.engine
        #else
        let name = AVAudioSession.interruptionNotification
        let object: AnyObject? = nil
        #endif
        interruptionObserver = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .listening else { return }
                self.log.info("dictation interrupted; stopping with what was heard")
                self.stop(then: .review)
            }
        }
    }

    private func stopObservingInterruptions() {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
    }

    // MARK: Debug fixtures

    #if DEBUG
    /// Runs the Mac engine end to end on synthesized speech instead of the microphone, so the
    /// whole upload → MacWhisper → review path can be tested in the simulator without recording
    /// anything real (`-VantageDictationSpeak "text"`).
    func speakForTesting(_ phrase: String, route: DictationRoute) {
        reset(keepingPhase: false)
        guard case .mac(let engine) = route else {
            phase = .failed(Failure(title: "No Mac Engine", message: "The Mac didn't advertise MacWhisper or Parakeet, so there is nothing to test."))
            return
        }
        self.route = route
        completion = .review
        let id = UUID()
        clipID = id
        packetizer = MicPacketizer(dictationID: id)
        send?(.dictationControl(DictationControl(action: .begin, id: id, engine: engine,
                                                 language: DictationLanguage.code(), format: .pcm16LE16k)))
        requestedAt = .now
        startedAt = .now
        phase = .listening
        // Exercises the preview's cold start too (its stage timings land in the log), without
        // the speech-permission gate the simulator can't grant.
        attachPreview()
        Task {
            let samples = await SyntheticSpeech.render(phrase)
            log.info("synthetic dictation: \(samples.count, privacy: .public) bytes of speech")
            upload(samples)
            await finishListening()
        }
    }

    /// Shows the panel in a given state without touching the microphone (screenshots).
    func showFixture(_ fixture: String) {
        reset(keepingPhase: false)
        route = fixture.hasPrefix("mac") ? .mac(.macWhisper) : .iPad
        transcript = DictationTranscript(finalized: "Please move the design review to Thursday at three and send the updated", volatile: "agenda to the team")
        switch fixture {
        case "macTranscribing":
            startedAt = .now.addingTimeInterval(-7)
            phase = .transcribing
        case "review", "macReview":
            text = "Please move the design review to Thursday at three and send the updated agenda to the team."
            resultEngine = route == .iPad ? nil : .macWhisper
            phase = .review
        case "failed":
            phase = .failed(Failure(title: "Microphone Access Is Off",
                                    message: "Allow Vantage to use the microphone in \(LocalDevice.settingsApp) to dictate to your Mac.", settings: .microphone))
        case "download":
            transcript = DictationTranscript()
            phase = .preparing(progress: 0.42)
        default:
            startedAt = .now.addingTimeInterval(-7)
            level = 0.6
            hasLivePreview = true
            phase = .listening
        }
    }
    #endif
}

#if DEBUG
/// Text-to-speech rendered straight to 16 kHz PCM16 for `speakForTesting`.
private nonisolated enum SyntheticSpeech {
    static func render(_ text: String) async -> Data {
        await withCheckedContinuation { continuation in
            let collector = Collector()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            collector.synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    // The synthesizer can signal the end more than once; resume only the first time.
                    if let data = collector.finish() { continuation.resume(returning: data) }
                } else {
                    collector.append(pcm)
                }
            }
        }
    }

    private final class Collector: @unchecked Sendable {
        let synthesizer = AVSpeechSynthesizer()
        private var resampler: AudioResampler?
        private var data = Data()
        private let lock = NSLock()

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.withLock {
                if resampler == nil { resampler = AudioResampler(from: buffer.format, to: PCM16.format) }
                guard let converted = resampler?.convert(buffer), let samples = PCM16.data(from: converted) else { return }
                data.append(samples)
            }
        }

        private var finished = false

        func finish() -> Data? {
            lock.withLock {
                guard !finished else { return nil }
                finished = true
                // The resampler holds the last ~55 ms of speech until told the input ended.
                if let tail = resampler?.finish(), let samples = PCM16.data(from: tail) { data.append(samples) }
                return data
            }
        }
    }
}
#endif

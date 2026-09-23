import Foundation
import Testing
import VantageCore
@testable import VantageHostDictation

/// A throwaway directory with a fake `mw` that records its arguments and the WAV it was given.
private struct StubMacWhisper {
    let directory: URL
    let cli: MacWhisperCLI

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mw-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mw")
        try ("#!/bin/sh\nSTUB_DIR='\(directory.path)'\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        cli = MacWhisperCLI(executableURL: url)
    }

    var clipsDirectory: URL { directory.appendingPathComponent("clips") }

    func read(_ name: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }
}

/// Saves the arguments and a copy of the WAV (the last argument), then prints a transcript.
private let echoScript = """
echo "$@" > "$STUB_DIR/args"
for last; do :; done
cp "$last" "$STUB_DIR/seen.wav"
echo "Transcribing $last..." >&2
printf 'Open the pull request.\\n\\n'
"""

/// Stands in for the built-in Parakeet engine: records what it was given, then answers or fails.
private final class StubBuiltInEngine: BuiltInSpeechEngine, @unchecked Sendable {
    private let lock = NSLock()
    private let answer: Result<String, HostTranscriber.Failure>
    private var received: [(samples: Data, language: String?)] = []

    init(_ answer: Result<String, HostTranscriber.Failure>) { self.answer = answer }

    var calls: [(samples: Data, language: String?)] { lock.withLock { received } }

    func transcribe(samples: Data, language: String?) async throws -> String {
        lock.withLock { received.append((samples, language)) }
        return try answer.get()
    }
}

private func silence(seconds: Double) -> Data {
    Data(count: Int(seconds * 16_000) * 2)
}

@Suite(.timeLimit(.minutes(1)))
struct HostDictationTests {
    @Test func clipStoreOnlyAcceptsAudioForOpenClips() {
        var store = DictationClipStore()
        let id = UUID()
        #expect(store.append(MicAudio(dictationID: id, sequence: 0, samples: Data([1, 2]))) == .unknownClip)
        store.begin(DictationControl(action: .begin, id: id, engine: .macWhisper, language: "en", format: .pcm16LE16k))
        #expect(store.append(MicAudio(dictationID: id, sequence: 0, samples: Data([1, 2]))) == .appended)
        #expect(store.append(MicAudio(dictationID: id, sequence: 2, samples: Data([5, 6]))) == .appended)
        let clip = store.commit(id)
        #expect(clip?.samples == Data([1, 2, 5, 6]))
        #expect(clip?.droppedPackets == 1)
        #expect(clip?.engine == .macWhisper)
        #expect(store.commit(id) == nil)
        #expect(store.append(MicAudio(dictationID: id, sequence: 3, samples: Data([7]))) == .unknownClip)

        let cancelled = UUID()
        store.begin(DictationControl(action: .begin, id: cancelled))
        store.cancel(cancelled)
        #expect(store.clips.isEmpty)
    }

    @Test func clipStoreCapsLengthAndOpenClips() {
        var store = DictationClipStore()
        let id = UUID()
        store.begin(DictationControl(action: .begin, id: id))
        let chunk = Data(count: DictationClipStore.maxBytes / 2)
        #expect(store.append(MicAudio(dictationID: id, sequence: 0, samples: chunk)) == .appended)
        #expect(store.append(MicAudio(dictationID: id, sequence: 1, samples: chunk)) == .appended)
        #expect(store.append(MicAudio(dictationID: id, sequence: 2, samples: Data([1, 2]))) == .truncated)
        #expect(store.clips[id]?.isTruncated == true)
        #expect(store.clips[id]?.samples.count == DictationClipStore.maxBytes)

        for _ in 0..<5 { store.begin(DictationControl(action: .begin, id: UUID())) }
        #expect(store.clips.count == DictationClipStore.maxOpenClips)
    }

    @Test func wavHeaderDescribes16kMonoPCM() throws {
        let wav = WAVFile.pcm16Mono(Data([1, 0, 2, 0]), sampleRate: 16_000)
        #expect(wav.count == 48)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        var reader = BinaryReader(wav.subdata(in: 20..<44))
        #expect(try reader.readUInt16() == 1)       // PCM
        #expect(try reader.readUInt16() == 1)       // mono
        #expect(try reader.readUInt32() == 16_000)
        #expect(try reader.readUInt32() == 32_000)
        #expect(try reader.readUInt16() == 2)
        #expect(try reader.readUInt16() == 16)
        #expect(String(decoding: reader.readRemaining().prefix(4), as: UTF8.self) == "data")
    }

    @Test func macWhisperRunsOnATempWAVAndDeletesIt() async throws {
        let stub = try StubMacWhisper(script: echoScript)
        let transcriber = HostTranscriber(macWhisper: stub.cli, appleEnabled: false, directory: stub.clipsDirectory)
        let output = try await transcriber.transcribe(samples: silence(seconds: 0.5), requested: .macWhisper, language: "en")
        #expect(output == .init(text: "Open the pull request.", engine: .macWhisper))

        let args = try #require(stub.read("args"))
        #expect(args.hasPrefix("transcribe --format txt --no-timestamps --language en "))
        #expect(!args.contains("--persist"))
        let seen = try Data(contentsOf: stub.directory.appendingPathComponent("seen.wav"))
        #expect(seen.count == 44 + 16_000 + 16_000) // 0.5 s of speech + 0.5 s of trailing silence
        #expect(String(decoding: seen.prefix(4), as: UTF8.self) == "RIFF")
        // The clip never outlives the run.
        #expect(try FileManager.default.contentsOfDirectory(atPath: stub.clipsDirectory.path).isEmpty)
    }

    @Test func clipsEndWithHalfASecondOfSilence() {
        let speech = Data(repeating: 0x7F, count: 3_200)
        let padded = HostTranscriber.paddedForTranscription(speech)
        #expect(padded.count == speech.count + 16_000)
        #expect(padded.prefix(speech.count) == speech)
        #expect(padded.dropFirst(speech.count).allSatisfy { $0 == 0 })
    }

    @Test func languageIsSanitizedBeforeReachingTheCommandLine() {
        #expect(MacWhisperCLI.sanitizedLanguage("EN") == "en")
        #expect(MacWhisperCLI.sanitizedLanguage("auto") == "auto")
        #expect(MacWhisperCLI.sanitizedLanguage("--persist") == nil)
        #expect(MacWhisperCLI.sanitizedLanguage("en-US") == nil)
        #expect(MacWhisperCLI.sanitizedLanguage(nil) == nil)
    }

    @Test func failuresExplainThemselvesAndStillDeleteTheClip() async throws {
        let stub = try StubMacWhisper(script: "exit 3\n")
        let transcriber = HostTranscriber(macWhisper: stub.cli, appleEnabled: false, directory: stub.clipsDirectory)
        await #expect(throws: HostTranscriber.Failure.self) {
            try await transcriber.transcribe(samples: silence(seconds: 0.2), requested: .macWhisper, language: nil)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: stub.clipsDirectory.path).isEmpty)

        let none = HostTranscriber(macWhisper: nil, appleEnabled: false, directory: stub.clipsDirectory)
        do {
            _ = try await none.transcribe(samples: silence(seconds: 0.2), requested: .macWhisper, language: nil)
            Issue.record("expected a failure")
        } catch {
            #expect(error.message.contains("MacWhisper"))
        }
    }

    @Test func hungCLIIsTerminatedByTheWatchdog() async throws {
        let stub = try StubMacWhisper(script: "exec sleep 20\n")
        let started = ContinuousClock.now
        await #expect(throws: HostTranscriber.Failure(message: "MacWhisper took too long to transcribe.")) {
            try await stub.cli.transcribe(URL(fileURLWithPath: "/dev/null"), language: nil, timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func versionProbeRequiresASuccessfulAnswer() async throws {
        #expect(await (try StubMacWhisper(script: "echo 'MacWhisper 14.8.1 (1481)'\n")).cli.version() == "MacWhisper 14.8.1 (1481)")
        #expect(await (try StubMacWhisper(script: "exit 1\n")).cli.version() == nil)
    }

    @Test func engineOrderPutsTheClientsChoiceFirst() {
        #expect(HostTranscriber.order(requested: nil) == [.macWhisper, .parakeet, .apple])
        #expect(HostTranscriber.order(requested: .parakeet) == [.parakeet, .macWhisper, .apple])
        #expect(HostTranscriber.order(requested: .apple) == [.apple, .macWhisper, .parakeet])
        // An engine this build doesn't know (a newer client) means "the host's best".
        #expect(HostTranscriber.order(requested: DictationEngineID(rawValue: "future")) == [.macWhisper, .parakeet, .apple])
    }

    @Test func parakeetGetsTheSamplesDirectlyAndNoWAVIsWritten() async throws {
        let stub = try StubMacWhisper(script: echoScript)
        let parakeet = StubBuiltInEngine(.success("Open the pull request."))
        let transcriber = HostTranscriber(macWhisper: stub.cli, parakeet: parakeet, appleEnabled: false, directory: stub.clipsDirectory)
        let samples = silence(seconds: 0.5)
        let output = try await transcriber.transcribe(samples: samples, requested: .parakeet, language: "en")
        #expect(output == .init(text: "Open the pull request.", engine: .parakeet))
        #expect(parakeet.calls.count == 1)
        #expect(parakeet.calls.first?.samples == HostTranscriber.paddedForTranscription(samples))
        #expect(parakeet.calls.first?.language == "en")
        #expect(stub.read("args") == nil) // MacWhisper never ran
        #expect(!FileManager.default.fileExists(atPath: stub.clipsDirectory.path))
    }

    @Test func withoutARequestMacWhisperStillWinsAndParakeetIsNext() async throws {
        let stub = try StubMacWhisper(script: echoScript)
        let parakeet = StubBuiltInEngine(.success("from parakeet"))
        let both = HostTranscriber(macWhisper: stub.cli, parakeet: parakeet, appleEnabled: false, directory: stub.clipsDirectory)
        #expect(try await both.transcribe(samples: silence(seconds: 0.2), requested: nil, language: nil).engine == .macWhisper)
        #expect(try await both.transcribe(samples: silence(seconds: 0.2), requested: .macWhisper, language: nil).engine == .macWhisper)
        #expect(parakeet.calls.isEmpty)

        // A Mac without MacWhisper: an older client still asks for "macwhisper" and gets Parakeet.
        let parakeetOnly = HostTranscriber(macWhisper: nil, parakeet: parakeet, appleEnabled: false, directory: stub.clipsDirectory)
        #expect(try await parakeetOnly.transcribe(samples: silence(seconds: 0.2), requested: .macWhisper, language: nil)
                == .init(text: "from parakeet", engine: .parakeet))
    }

    @Test func parakeetThatIsntReadyFallsBackAndSaysWhichEngineAnswered() async throws {
        let stub = try StubMacWhisper(script: echoScript)
        let preparing = StubBuiltInEngine(.failure(.init(message: "Parakeet is still getting ready on the Mac.")))
        let transcriber = HostTranscriber(macWhisper: stub.cli, parakeet: preparing, appleEnabled: false, directory: stub.clipsDirectory)
        let output = try await transcriber.transcribe(samples: silence(seconds: 0.2), requested: .parakeet, language: "en")
        #expect(output == .init(text: "Open the pull request.", engine: .macWhisper))
        #expect(preparing.calls.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: stub.clipsDirectory.path).isEmpty)

        // Nothing to fall back to: the user sees why.
        let alone = HostTranscriber(macWhisper: nil, parakeet: preparing, appleEnabled: false, directory: stub.clipsDirectory)
        await #expect(throws: HostTranscriber.Failure(message: "Parakeet is still getting ready on the Mac.")) {
            try await alone.transcribe(samples: silence(seconds: 0.2), requested: .parakeet, language: nil)
        }
    }

    @Test func parakeetIsAdvertisedOnlyWhileRegistered() async {
        let previous = BuiltInSpeechEngines.shared.parakeet
        defer { BuiltInSpeechEngines.shared.parakeet = previous }
        BuiltInSpeechEngines.shared.parakeet = nil
        #expect(!(await HostTranscriber.availableEngines()).contains(.parakeet))
        BuiltInSpeechEngines.shared.parakeet = StubBuiltInEngine(.success(""))
        let engines = await HostTranscriber.availableEngines()
        #expect(engines.contains(.parakeet))
        #expect(engines == HostTranscriber.preferenceOrder.filter(engines.contains)) // best first
    }

    /// Real MacWhisper on synthetic speech from `say`. Opt-in: `VANTAGE_TEST_REAL_MW=1 swift test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VANTAGE_TEST_REAL_MW"] == "1"), .timeLimit(.minutes(1)))
    func realEnginesTranscribeSyntheticSpeech() async throws {
        let samples = try synthesizeSpeech("Please open the pull request for Vantage.")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mw-real-\(UUID().uuidString)")
        if let cli = MacWhisperCLI.locate(), await cli.version() != nil {
            let output = try await HostTranscriber(macWhisper: cli, appleEnabled: false, directory: directory)
                .transcribe(samples: samples, requested: .macWhisper, language: "en")
            print("macwhisper:", output.text)
            #expect(output.engine == .macWhisper)
            #expect(output.text.lowercased().contains("pull request"))
        }
        let apple = try await HostTranscriber(macWhisper: nil, appleEnabled: true, directory: directory)
            .transcribe(samples: samples, requested: .apple, language: "en")
        print("apple:", apple.text)
        #expect(apple.engine == .apple)
        #expect(apple.text.lowercased().contains("request"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty)
    }

    /// A clip that ends right on the last word (as a push-to-talk clip does) keeps that word.
    /// Prints the unpadded run for comparison: on `say` speech MacWhisper Large v3 Turbo kept the
    /// last word even with 30–150 ms of it cut and no padding, so the padding is insurance, not
    /// the fix. Opt-in: `VANTAGE_TEST_REAL_MW=1 swift test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VANTAGE_TEST_REAL_MW"] == "1"), .timeLimit(.minutes(2)))
    func realMacWhisperKeepsTheLastWordOfAClippedRecording() async throws {
        guard let cli = MacWhisperCLI.locate(), await cli.version() != nil else { return }
        let phrases = ["Please move the design review and invite Priyanka",
                       "Send the build to the team before lunch on Thursday",
                       "Open the pull request and assign it to Octavia"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mw-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for phrase in phrases {
            let clipped = trimmingTrailingSilence(try synthesizeSpeech(phrase))
            let lastWord = phrase.split(separator: " ").last!.lowercased()
            let raw = directory.appendingPathComponent("raw.wav")
            try WAVFile.pcm16Mono(clipped, sampleRate: 16_000).write(to: raw)
            let unpadded = try await cli.transcribe(raw, language: "en", timeout: .seconds(60))
            let padded = try await HostTranscriber(macWhisper: cli, appleEnabled: false, directory: directory)
                .transcribe(samples: clipped, requested: .macWhisper, language: "en")
            print("clip \(clipped.count / 32) ms | unpadded: \(unpadded) | padded: \(padded.text)")
            #expect(padded.text.lowercased().contains(lastWord))
        }
    }
}

/// Drops trailing samples quieter than about −40 dBFS, so the clip ends on the last word.
private func trimmingTrailingSilence(_ samples: Data) -> Data {
    var end = samples.count / 2
    samples.withUnsafeBytes { raw in
        let values = raw.bindMemory(to: Int16.self)
        while end > 0, abs(Int(values[end - 1])) < 330 { end -= 1 }
    }
    return samples.prefix(end * 2)
}

/// `say` → 16 kHz mono PCM16 samples (the WAV's data chunk).
private func synthesizeSpeech(_ text: String) throws -> Data {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("say-\(UUID().uuidString)")
    let aiff = base.appendingPathExtension("aiff"), wav = base.appendingPathExtension("wav")
    defer { try? FileManager.default.removeItem(at: aiff); try? FileManager.default.removeItem(at: wav) }
    for (tool, arguments) in [("/usr/bin/say", ["-o", aiff.path, text]),
                              ("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])] {
        let process = try Process.run(URL(fileURLWithPath: tool), arguments: arguments)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    let data = try Data(contentsOf: wav)
    var offset = 12
    while offset + 8 <= data.count {
        let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        var reader = BinaryReader(data.subdata(in: offset + 4..<offset + 8))
        let size = Int(try reader.readUInt32())
        if id == "data" { return data.subdata(in: offset + 8..<min(data.count, offset + 8 + size)) }
        offset += 8 + size + (size & 1)
    }
    throw CocoaError(.fileReadCorruptFile)
}

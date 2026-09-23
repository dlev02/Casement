import FluidAudio
import Foundation
import Observation
import VantageCore
import os

/// Vantage Host's optional built-in speech engine: NVIDIA Parakeet TDT 0.6B v3 on Core ML (Neural
/// Engine) through FluidAudio, for Macs without MacWhisper.
///
/// Off by default. Nothing is downloaded or loaded until the user turns it on in Settings →
/// Dictation; with the toggle off the host makes no network requests for it and doesn't advertise
/// `parakeet`. Turning it on downloads the model once into
/// `~/Library/Application Support/Vantage Host/Models`, then loads it and runs a silent clip so the
/// first real dictation doesn't pay the Core ML compile. Remove deletes the files.
@MainActor
@Observable
final class ParakeetModel {
    enum State: Equatable {
        case notInstalled
        /// Fraction 0–1 when known.
        case downloading(Double?)
        /// On disk, not loaded (the toggle is off).
        case installed
        /// Loading into Core ML and warming up.
        case preparing
        case ready
        case failed(String)
    }

    static let shared = ParakeetModel()
    static let enabledKey = "dictation.parakeetEnabled"
    /// Measured on disk after a v3 download (int8 encoder, decoder, joint, preprocessor, vocab):
    /// 491.5 MB. Core ML adds a ~40 MB compiled cache on first load.
    static let approximateDownloadSize = Measurement(value: 490, unit: UnitInformationStorage.megabytes)

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "dictation")

    private(set) var isEnabled: Bool
    private(set) var state: State
    /// Bytes the model occupies on disk, when installed.
    private(set) var installedBytes: Int64?
    /// How long the last load + warm-up took.
    private(set) var lastLoadTime: Duration?

    private let runtime: ParakeetRuntime
    private var downloadTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        runtime = ParakeetRuntime(directory: Self.modelDirectory)
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        state = Self.isInstalled ? .installed : .notInstalled
        if Self.hasFilesOnDisk { measureDiskUsage() }
    }

    // MARK: Paths

    /// `~/Library/Application Support/Vantage Host/Models`.
    static var modelsRoot: URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("Vantage Host", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// FluidAudio's folder for Parakeet v3 ("parakeet-tdt-0.6b-v3"), placed inside `modelsRoot`.
    static var modelDirectory: URL {
        modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent, isDirectory: true)
    }

    /// Written after a download finishes, so an interrupted download (which leaves partial
    /// `.mlmodelc` folders behind) never counts as installed.
    private static var completeMarker: URL {
        modelDirectory.appendingPathComponent(".vantage-complete")
    }

    /// Core ML's per-app compiled-model cache (only Parakeet uses Core ML in the host).
    private static var coreMLCache: URL? {
        Bundle.main.bundleIdentifier.map {
            URL.cachesDirectory.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
        }
    }

    /// Anything on disk, including what an interrupted download left behind (Remove clears it).
    static var hasFilesOnDisk: Bool {
        FileManager.default.fileExists(atPath: modelDirectory.path)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: completeMarker.path)
            && AsrModels.modelsExist(at: modelDirectory, version: .v3)
    }

    // MARK: Lifecycle

    /// App launch: if the user left it on, publish the engine and warm the model in the background
    /// (or finish a download the last run didn't complete).
    func start() {
        guard isEnabled else { return }
        if Self.isInstalled { warmUp() } else { download() }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            if Self.isInstalled { warmUp() } else { download() }
        } else {
            unpublish()
            downloadTask?.cancel()
            downloadTask = nil
            state = Self.isInstalled ? .installed : .notInstalled
        }
    }

    /// Downloads the model (only while enabled), then warms it.
    func download() {
        guard isEnabled, downloadTask == nil, !Self.isInstalled else { return }
        state = .downloading(nil)
        log.info("downloading Parakeet v3 model")
        let started = ContinuousClock.now
        downloadTask = Task { [weak self] in
            do {
                try await ParakeetRuntime.download(to: Self.modelDirectory) { fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(fraction)
                    }
                }
                try Task.checkCancellation()
                try Data().write(to: Self.completeMarker)
                guard let self else { return }
                self.log.info("Parakeet model downloaded in \((ContinuousClock.now - started).formatted(.units(allowed: [.seconds])), privacy: .public)")
                self.downloadTask = nil
                self.measureDiskUsage()
                if self.isEnabled { self.warmUp() } else { self.state = .installed }
            } catch {
                guard let self else { return }
                self.downloadTask = nil
                self.measureDiskUsage()
                if Task.isCancelled || error is CancellationError {
                    self.state = Self.isInstalled ? .installed : .notInstalled
                } else {
                    self.log.error("Parakeet download failed: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed("The download didn't finish. Check the internet connection and try again.")
                }
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = Self.isInstalled ? .installed : .notInstalled
    }

    /// Unloads and deletes the model, and turns the engine off so it isn't downloaded again.
    func remove() {
        downloadTask?.cancel()
        downloadTask = nil
        unpublish()
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        do {
            if FileManager.default.fileExists(atPath: Self.modelDirectory.path) {
                try FileManager.default.removeItem(at: Self.modelDirectory)
            }
            // Core ML's compiled Neural Engine cache for the model; rebuilt on the next load.
            if let cache = Self.coreMLCache { try? FileManager.default.removeItem(at: cache) }
            state = .notInstalled
            installedBytes = nil
            log.info("Parakeet model removed")
        } catch {
            log.error("couldn't remove Parakeet model: \(error.localizedDescription, privacy: .public)")
            state = .failed("Vantage Host couldn't delete the model: \(error.localizedDescription)")
        }
    }

    // MARK: Private

    /// Publishes the engine right away (a clip that arrives mid-warm-up waits briefly, then falls
    /// back with a label) and loads the model off the main actor.
    private func warmUp() {
        BuiltInSpeechEngines.shared.parakeet = runtime
        state = .preparing
        warmTask?.cancel()
        warmTask = Task { [runtime, weak self] in
            do {
                let elapsed = try await runtime.prepare()
                guard let self, self.isEnabled, !Task.isCancelled else { return }
                self.lastLoadTime = elapsed
                self.state = .ready
                self.log.info("Parakeet ready in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
            } catch {
                guard let self, self.isEnabled, !Task.isCancelled else { return }
                self.log.error("Parakeet failed to load: \(error.localizedDescription, privacy: .public)")
                self.unpublish()
                self.state = .failed("The model didn't load. Remove it and download it again.")
            }
        }
    }

    private func unpublish() {
        BuiltInSpeechEngines.shared.parakeet = nil
        warmTask?.cancel()
        warmTask = nil
        Task { [runtime] in await runtime.unload() }
    }

    private func measureDiskUsage() {
        let directory = Self.modelDirectory
        Task.detached(priority: .utility) {
            let bytes = Self.allocatedSize(of: directory)
            await MainActor.run { [weak self] in self?.installedBytes = bytes }
        }
    }

    private nonisolated static func allocatedSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Owns the loaded Parakeet model. An actor, so loading and inference never touch the main actor;
/// FluidAudio's `AsrManager` is itself an actor and serializes clips.
actor ParakeetRuntime: BuiltInSpeechEngine {
    /// How long a clip waits for a model that is still loading before the host falls back.
    static let readyTimeout: Duration = .seconds(20)

    private let directory: URL
    private var manager: AsrManager?
    private var loadTask: Task<Void, Never>?
    private var loadError: (any Error)?
    /// Bumped on unload so a load that finishes afterwards is discarded.
    private var generation = 0

    init(directory: URL) {
        self.directory = directory
    }

    /// Downloads Parakeet v3 into `directory` (FluidAudio fetches from Hugging Face).
    nonisolated static func download(to directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await AsrModels.download(to: directory, version: .v3) { update in
            progress(update.fractionCompleted)
        }
    }

    /// Loads (if needed) and warms the model; returns how long that took.
    func prepare() async throws -> Duration {
        let started = ContinuousClock.now
        startLoading()
        _ = try await loadedManager(timeout: .seconds(600))
        return ContinuousClock.now - started
    }

    func unload() async {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        loadError = nil
        if let manager { await manager.cleanup() }
        manager = nil
    }

    func transcribe(samples: Data, language: String?) async throws -> String {
        startLoading()
        let manager: AsrManager
        do {
            manager = try await loadedManager(timeout: Self.readyTimeout)
        } catch is TimeoutError {
            throw HostTranscriber.Failure(message: "Parakeet is still getting ready on the Mac. Try again in a moment.")
        } catch {
            throw HostTranscriber.Failure(message: "Parakeet couldn't load its model on the Mac.")
        }
        var floats = Self.floatSamples(samples)
        // FluidAudio rejects clips under 0.3 s; pad very short ones with silence.
        if floats.count < 16_000 { floats += [Float](repeating: 0, count: 16_000 - floats.count) }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(floats, decoderState: &decoderState,
                                                  language: language.flatMap { Language(rawValue: $0) })
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Loading

    private struct TimeoutError: Error {}

    private func startLoading() {
        guard manager == nil, loadTask == nil else { return }
        loadError = nil
        let generation = generation
        let directory = directory
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<AsrManager, any Error>
            do { result = .success(try await Self.makeManager(directory)) } catch { result = .failure(error) }
            await self?.finishLoading(result, generation: generation)
        }
    }

    private func finishLoading(_ result: Result<AsrManager, any Error>, generation: Int) {
        guard generation == self.generation else { return }
        loadTask = nil
        switch result {
        case .success(let manager): self.manager = manager
        case .failure(let error): loadError = error
        }
    }

    /// Waits for the in-flight load. Polls rather than awaiting the task, so a clip can give up
    /// after `timeout` while the load carries on for the next one.
    private func loadedManager(timeout: Duration) async throws -> AsrManager {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let manager { return manager }
            if let loadError { throw loadError }
            if loadTask == nil { startLoading() }
            guard ContinuousClock.now < deadline else { throw TimeoutError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Local files only (`loadLocal` never touches the network), then one silent clip so Core ML
    /// finishes compiling for the Neural Engine before the first real dictation.
    private nonisolated static func makeManager(_ directory: URL) async throws -> AsrManager {
        let models = try AsrModels.loadLocal(from: directory, version: .v3)
        let manager = AsrManager(config: .default, models: models)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        _ = try await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &decoderState)
        return manager
    }

    /// 16-bit little-endian PCM → Float in -1...1.
    nonisolated static func floatSamples(_ pcm: Data) -> [Float] {
        pcm.withUnsafeBytes { raw in
            let count = raw.count / 2
            var floats = [Float](repeating: 0, count: count)
            for index in 0..<count {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                floats[index] = Float(value) / 32_768
            }
            return floats
        }
    }
}

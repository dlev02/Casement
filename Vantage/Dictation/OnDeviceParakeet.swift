#if canImport(FluidAudio)
import FluidAudio
import Foundation
import Network
import Observation
import os
#if canImport(UIKit)
import UIKit
#endif

/// Parakeet on this device: NVIDIA's Parakeet TDT 0.6B v3 on Core ML through FluidAudio, so a
/// dictation that stays here (to a PC, or to a Mac without MacWhisper or its own Parakeet) gets
/// the same model Casement Host offers.
///
/// Optional and off until asked for. Nothing is downloaded, loaded or sent anywhere until the
/// person chooses Download in Settings → Controls → Dictation; that fetches the model once from
/// Hugging Face into Application Support (left out of backups), and Remove deletes it. The model
/// is loaded when a dictation starts and let go two minutes after the last one, so it costs no
/// memory the rest of the time.
///
/// Built only where FluidAudio is linked: iOS, iPadOS and macOS. Its bundled text-normalization
/// binary has no visionOS slice, so the visionOS app leaves the package out and this file with it
/// (the project file filters the dependency by platform).
@MainActor
@Observable
final class OnDeviceParakeet {
    enum State: Equatable {
        case notInstalled
        /// Fraction 0–1 when known.
        case downloading(Double?)
        /// Downloaded; loading once so Core ML compiles it before the first dictation.
        case preparing
        case installed
        case failed(String)
    }

    static let shared = OnDeviceParakeet()
    static let enabledKey = "vantage.onDeviceParakeet"
    /// Measured on disk after a v3 download: 491.5 MB.
    static let approximateDownloadSize = Measurement(value: 490, unit: UnitInformationStorage.megabytes)

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "dictation")

    private(set) var state: State
    /// Use it for dictation on this device (only matters once it's installed).
    private(set) var isEnabled: Bool
    /// Bytes the model occupies on disk, when installed.
    private(set) var installedBytes: Int64?

    private let runtime = OnDeviceParakeetRuntime(directory: OnDeviceParakeet.modelDirectory)
    private var downloadTask: Task<Void, Never>?
    private var memoryObserver: (any NSObjectProtocol)?

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        state = Self.isInstalled ? .installed : .notInstalled
    }

    // MARK: Paths

    /// `Application Support/Vantage/Models/parakeet-tdt-0.6b-v3` (FluidAudio's folder name).
    static var modelDirectory: URL {
        modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent, isDirectory: true)
    }

    private static var modelsRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Vantage/Models", directoryHint: .isDirectory)
    }

    /// Written once a download finishes, so an interrupted one never counts as installed.
    private static var completeMarker: URL { modelDirectory.appendingPathComponent(".vantage-complete") }

    /// Core ML's compiled cache for this app (only Parakeet uses Core ML here).
    private static var coreMLCache: URL? {
        Bundle.main.bundleIdentifier.map {
            URL.cachesDirectory.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
        }
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: completeMarker.path)
            && AsrModels.modelsExist(at: modelDirectory, version: .v3)
    }

    /// Anything on disk, including what an interrupted download left (Remove clears it).
    var hasModelFiles: Bool {
        if case .downloading = state { return true }
        return FileManager.default.fileExists(atPath: Self.modelDirectory.path)
    }

    // MARK: Lifecycle

    /// App launch: offer the engine if it's installed and on. Reads the disk; loads nothing.
    func start() {
        publish()
        if state == .installed { measureDiskUsage() }
        #if canImport(UIKit)
        guard memoryObserver == nil else { return }
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [runtime] _ in
            Task { await runtime.unloadIfIdle() }
        }
        #endif
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        publish()
        if !enabled { Task { [runtime] in await runtime.unloadIfIdle() } }
    }

    /// Fetches the model from Hugging Face, then loads it once so the first dictation is quick.
    /// An interrupted download carries on from the bytes already on disk.
    func download() {
        guard downloadTask == nil, !Self.isInstalled else { return }
        state = .downloading(nil)
        log.info("downloading Parakeet v3 model")
        downloadTask = Task { [weak self, runtime] in
            do {
                let directory = Self.modelDirectory
                try FileManager.default.createDirectory(at: Self.modelsRoot, withIntermediateDirectories: true)
                Self.excludeFromBackup(Self.modelsRoot)
                try await AsrModels.download(to: directory, version: .v3) { update in
                    let fraction = update.fractionCompleted
                    Task { @MainActor in
                        guard let self, case .downloading = self.state else { return }
                        self.state = .downloading(fraction)
                    }
                }
                try Task.checkCancellation()
                try Data().write(to: Self.completeMarker)
                guard let self else { return }
                self.state = .preparing
                self.measureDiskUsage()
                try await runtime.warmUp()
                try Task.checkCancellation()
                self.downloadTask = nil
                self.state = .installed
                self.setEnabled(true)
                self.publish()
                self.log.info("Parakeet model downloaded and ready")
            } catch {
                guard let self else { return }
                self.downloadTask = nil
                if Task.isCancelled || error is CancellationError {
                    self.state = Self.isInstalled ? .installed : .notInstalled
                } else if Self.isInstalled {
                    self.log.error("Parakeet failed to load: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed("The model didn't load. Remove it and download it again.")
                } else {
                    self.log.error("Parakeet download failed: \(error.localizedDescription, privacy: .public)")
                    self.state = .failed("The download didn't finish. Check your internet connection and try again.")
                }
                self.publish()
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = Self.isInstalled ? .installed : .notInstalled
    }

    /// Unloads and deletes the model and Core ML's compiled copy of it.
    func remove() {
        downloadTask?.cancel()
        downloadTask = nil
        OnDeviceSpeechEngines.parakeet = nil
        Task { [runtime] in await runtime.unload() }
        do {
            if FileManager.default.fileExists(atPath: Self.modelDirectory.path) {
                try FileManager.default.removeItem(at: Self.modelDirectory)
            }
            if let cache = Self.coreMLCache { try? FileManager.default.removeItem(at: cache) }
            state = .notInstalled
            installedBytes = nil
            log.info("Parakeet model removed")
        } catch {
            log.error("couldn't remove Parakeet model: \(error.localizedDescription, privacy: .public)")
            state = .failed("Casement couldn't delete the model: \(error.localizedDescription)")
        }
    }

    // MARK: Private

    /// Dictation uses the engine only while it's installed and switched on.
    private func publish() {
        OnDeviceSpeechEngines.parakeet = isEnabled && state == .installed ? runtime : nil
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

    /// A model that can be downloaded again has no business in an iCloud or computer backup.
    private nonisolated static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Whether the connection in use right now is metered (cellular, a personal hotspot), so
    /// Settings can ask before spending half a gigabyte of it.
    nonisolated static func isOnExpensiveNetwork() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let answered = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                monitor.cancel()
                continuation.resume(returning: path.isExpensive)
            }
            monitor.start(queue: .global(qos: .userInitiated))
        }
    }
}

/// Owns the loaded model. An actor, so loading and inference stay off the main actor; FluidAudio's
/// `AsrManager` is an actor too and takes one clip at a time.
actor OnDeviceParakeetRuntime: OnDeviceSpeechEngine {
    /// How long a clip waits for a model that is still loading. After the first load Core ML has
    /// it compiled and this takes about a second; the wait covers a cold device.
    static let readyTimeout: Duration = .seconds(45)
    /// How long the model stays in memory after it was last wanted.
    static let idleUnload: Duration = .seconds(120)

    private let directory: URL
    private var manager: AsrManager?
    private var loadTask: Task<Void, Never>?
    private var loadError: (any Error)?
    private var idleTask: Task<Void, Never>?
    private var clipsInFlight = 0
    /// Bumped on unload so a load that finishes afterwards is discarded.
    private var generation = 0

    init(directory: URL) {
        self.directory = directory
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// A dictation is starting: load now, so the model is there when the clip ends.
    func prepare() async {
        startLoading()
        unloadWhenIdle()
    }

    /// The first load after a download, which is when Core ML compiles the model for the Neural
    /// Engine (the slow one). Leaves it loaded for the idle timer to let go.
    func warmUp() async throws {
        startLoading()
        _ = try await loadedManager(timeout: .seconds(600))
        unloadWhenIdle()
    }

    func transcribe(samples: Data, language: String?) async throws -> String {
        clipsInFlight += 1
        defer {
            clipsInFlight -= 1
            unloadWhenIdle()
        }
        idleTask?.cancel()
        startLoading()
        let manager: AsrManager
        do {
            manager = try await loadedManager(timeout: Self.readyTimeout)
        } catch is TimeoutError {
            throw Failure(errorDescription: "Parakeet was still loading.")
        }
        var floats = Self.floatSamples(samples)
        // FluidAudio rejects clips under 0.3 s; pad very short ones with silence.
        if floats.count < 16_000 { floats += [Float](repeating: 0, count: 16_000 - floats.count) }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(floats, decoderState: &decoderState,
                                                  language: language.flatMap { Language(rawValue: $0) })
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() async {
        generation += 1
        idleTask?.cancel()
        idleTask = nil
        loadTask?.cancel()
        loadTask = nil
        loadError = nil
        if let manager { await manager.cleanup() }
        manager = nil
    }

    /// Memory is tight, or the engine was switched off: let the model go unless a clip needs it.
    func unloadIfIdle() async {
        guard clipsInFlight == 0 else { return }
        await unload()
    }

    // MARK: Loading

    private struct TimeoutError: Error {}

    private func unloadWhenIdle() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.idleUnload) } catch { return }
            await self?.unloadIfIdle()
        }
    }

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

    /// Waits for the load in flight. Polls rather than awaiting the task, so a clip can give up
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
    /// has compiled the model before a real one arrives.
    private nonisolated static func makeManager(_ directory: URL) async throws -> AsrManager {
        let models = try AsrModels.loadLocal(from: directory, version: .v3)
        let manager = AsrManager(config: .default, models: models)
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        _ = try await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &decoderState)
        return manager
    }

    /// 16-bit little-endian PCM → Float in -1...1.
    private nonisolated static func floatSamples(_ pcm: Data) -> [Float] {
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
#endif

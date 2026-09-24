import Foundation
import Observation
import VantageCore
import os

/// The session's files, both ways: a queue of files to send to the Mac (one at a time), what
/// the Mac sends here, and the list the Transfers sheet shows.
///
/// It outlives connections. `ClientSession` attaches a `FileTransferEngine` each time the file
/// channel comes up and detaches it when it drops; queued files wait for the next one. A file cut
/// off by a dropped connection waits too, and carries on from where it stopped once the channel is
/// back: sends are offered again under the same id (the Mac kept the partial file), and the Mac
/// does the same with files it was sending here.
@MainActor
@Observable
final class FileTransferController {
    struct Transfer: Identifiable, Equatable {
        enum State: Equatable {
            case waiting
            case active
            case done
            case failed(String)
            case cancelled
        }

        let id: UUID
        var name: String
        var byteCount: UInt64
        let direction: FileTransferItem.Direction
        var state: State
        var bytesDone: UInt64 = 0
        /// Smoothed, for the rate and time-left labels.
        var bytesPerSecond: Double = 0
        /// Where a received file was saved.
        var savedURL: URL?
        /// The name the Mac saved a sent file under ("Report 2.pdf").
        var savedName: String?
        var finishedAt: Date?
        /// Set while a file the connection cut off waits to resume.
        var interruptedAt: Date?

        var isActive: Bool { state == .waiting || state == .active }
        var fraction: Double {
            guard byteCount > 0 else { return state == .done ? 1 : 0 }
            return min(1, Double(bytesDone) / Double(byteCount))
        }
        /// Seconds left at the current rate, once there is a rate to go on.
        var secondsRemaining: Double? {
            guard state == .active, bytesPerSecond > 1, byteCount > bytesDone else { return nil }
            return Double(byteCount - bytesDone) / bytesPerSecond
        }
    }

    private struct Source {
        var url: URL
        /// From the Files picker: access has to be started and stopped around the read.
        var securityScoped: Bool
        /// A copy Vantage made (a drop, a test file); deleted when the transfer ends.
        var temporary: Bool
        var interruptions = 0
    }

    /// How many times one file may be cut off and resumed before it counts as failed.
    static let maxInterruptions = 10
    /// How long a file the Mac was sending when the connection dropped waits for it to resume.
    static let resumeWindow: TimeInterval = 60 * 60

    private(set) var transfers: [Transfer] = []
    /// The file channel is up, so files can move right now.
    private(set) var isConnected = false
    /// Called once per file received here, for the "Received …" notice.
    var onReceived: ((Transfer) -> Void)?
    /// Called once per file sent (or that failed to send), for VoiceOver.
    var onSendFinished: ((Transfer) -> Void)?

    let receiveDirectory: URL
    private var engine: FileTransferEngine?
    private var sources: [UUID: Source] = [:]
    private var sending: UUID?
    private var rateSamples: [UUID: (time: ContinuousClock.Instant, bytes: UInt64)] = [:]
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "files")

    /// `Documents/Received`, which Files shows as On My iPad → Vantage → Received.
    static var defaultReceiveDirectory: URL {
        URL.documentsDirectory.appending(path: "Received", directoryHint: .isDirectory)
    }

    /// Copies of dropped files wait here until they've been sent.
    nonisolated static var outboxDirectory: URL {
        URL.temporaryDirectory.appending(path: "Outbox", directoryHint: .isDirectory)
    }

    init(receiveDirectory: URL = FileTransferController.defaultReceiveDirectory) {
        self.receiveDirectory = receiveDirectory
    }

    var configuration: FileTransferConfiguration {
        var configuration = FileTransferConfiguration(receiveDirectory: receiveDirectory)
        #if DEBUG
        configuration.chunkDelay = chunkDelayForTesting
        #endif
        return configuration
    }

    #if DEBUG
    /// `-VantageSlowFiles <ms>` in the app: a pause per 256 KiB chunk sent, so UI tests can act
    /// while a file is still moving.
    var chunkDelayForTesting: Duration = .zero
    #endif

    /// Something is still moving or waiting to.
    var hasActiveTransfers: Bool { transfers.contains { $0.isActive } }
    /// Anything happened this session (the session menu shows Transfers… from then on).
    var hasTransfers: Bool { !transfers.isEmpty }
    var activeCount: Int { transfers.filter(\.isActive).count }

    // MARK: Connection

    func attach(_ engine: FileTransferEngine) {
        self.engine = engine
        isConnected = true
        expireInterruptions()
        Task { [weak self] in
            for await event in engine.events {
                // A receive cut off by the connection waits for the Mac to offer it again.
                if case .finished(let id, .failed) = event, await engine.hasClosed, self?.interruptReceive(id) == true { continue }
                self?.handle(event)
            }
        }
        pumpIfNeeded()
    }

    func detach(_ engine: FileTransferEngine) {
        guard self.engine === engine else { return }
        self.engine = nil
        isConnected = false
    }

    // MARK: Queue

    /// Files chosen in the Files picker. Their access is security scoped until they're sent.
    func send(_ urls: [URL], securityScoped: Bool) {
        for url in urls {
            let scoped = securityScoped && url.startAccessingSecurityScopedResource()
            enqueue(url, name: url.lastPathComponent, source: Source(url: url, securityScoped: scoped, temporary: false))
        }
    }

    /// A file that only lives as long as a callback: copies it to the outbox first.
    func sendCopy(of url: URL, name: String? = nil) throws {
        sendOutboxCopy(try Self.copyToOutbox(url, name: name))
    }

    /// Copies a file into a folder of its own in the outbox. Safe off the main actor, so an
    /// `NSItemProvider` callback can copy before its temporary file goes away.
    nonisolated static func copyToOutbox(_ url: URL, name: String? = nil) throws -> URL {
        let folder = outboxDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: FileNames.sanitize(name ?? url.lastPathComponent), directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    /// Queues a file `copyToOutbox` made; it's deleted once the transfer ends.
    func sendOutboxCopy(_ copy: URL) {
        enqueue(copy, name: copy.lastPathComponent, source: Source(url: copy, securityScoped: false, temporary: true))
    }

    private func enqueue(_ url: URL, name: String, source: Source) {
        let id = UUID()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64($0) } ?? 0
        sources[id] = source
        transfers.append(Transfer(id: id, name: name, byteCount: size, direction: .sending, state: .waiting))
        pumpIfNeeded()
    }

    func cancel(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].isActive else { return }
        if transfers[index].state == .waiting && sending != id {
            transfers[index].state = .cancelled
            transfers[index].finishedAt = .now
            release(id)
            return
        }
        if let engine { Task { await engine.cancel(id) } }
    }

    /// Fails every file still waiting to go (the Mac can't take files).
    func failWaiting(_ reason: String) {
        for index in transfers.indices where transfers[index].state == .waiting && transfers[index].id != sending {
            finish(index, .failed(reason))
            release(transfers[index].id)
        }
    }

    /// Removes finished rows from the list.
    func clearFinished() {
        transfers.removeAll { !$0.isActive }
    }

    private func pumpIfNeeded() {
        guard sending == nil, let engine,
              let next = transfers.first(where: { $0.direction == .sending && $0.state == .waiting }),
              let source = sources[next.id] else { return }
        sending = next.id
        Task {
            let outcome = await engine.send(fileAt: source.url, name: next.name, id: next.id)
            let lostConnection = await engine.hasClosed
            sending = nil
            settle(next.id, outcome, lostConnection: lostConnection)
            // After a drop the rest waits for the next `attach`, not this closed engine.
            if !lostConnection { pumpIfNeeded() }
        }
    }

    /// Records how a send ended. One cut off by the connection dropping goes back to the front of
    /// the queue and resumes from where it stopped when the file channel returns.
    private func settle(_ id: UUID, _ outcome: FileTransferOutcome, lostConnection: Bool) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        if lostConnection, case .failed = outcome, var source = sources[id], source.interruptions < Self.maxInterruptions,
           transfers[index].state != .cancelled {
            source.interruptions += 1
            sources[id] = source
            transfers[index].state = .waiting
            transfers[index].interruptedAt = .now
            transfers[index].bytesPerSecond = 0
            log.info("file send interrupted by the connection; it resumes when the channel is back")
            return
        }
        if transfers[index].isActive {
            finish(index, outcome)
            onSendFinished?(transfers[index])
        }
        release(id)
    }

    private func release(_ id: UUID) {
        guard let source = sources.removeValue(forKey: id) else { return }
        if source.securityScoped { source.url.stopAccessingSecurityScopedResource() }
        if source.temporary { try? FileManager.default.removeItem(at: source.url.deletingLastPathComponent()) }
    }

    /// A file the Mac was sending here when the connection dropped: it waits for the Mac to
    /// offer it again (the partial stays in Received, hidden). False if there's no such row.
    private func interruptReceive(_ id: UUID) -> Bool {
        guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].direction == .receiving,
              transfers[index].isActive else { return false }
        transfers[index].state = .waiting
        transfers[index].interruptedAt = .now
        transfers[index].bytesPerSecond = 0
        rateSamples[id] = nil
        return true
    }

    /// Interrupted receives the Mac never came back to within `resumeWindow` count as failed.
    func expireInterruptions(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Self.resumeWindow)
        for index in transfers.indices where transfers[index].direction == .receiving {
            guard let since = transfers[index].interruptedAt, since < cutoff else { continue }
            finish(index, .failed("The connection was lost."))
        }
    }

    // MARK: Events

    private func handle(_ event: FileTransferEvent) {
        switch event {
        case .started(let item):
            rateSamples[item.id] = (.now, 0)
            if let index = transfers.firstIndex(where: { $0.id == item.id }) {
                transfers[index].state = .active
                transfers[index].byteCount = item.byteCount
                transfers[index].interruptedAt = nil
            } else {
                transfers.append(Transfer(id: item.id, name: item.name, byteCount: item.byteCount, direction: item.direction, state: .active))
            }
        case .progress(let id, let bytes):
            guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
            let now = ContinuousClock.now
            // A resume reports where it picked up first: the rate starts from there.
            if let sample = rateSamples[id], sample.bytes == 0, bytes > 0, transfers[index].bytesPerSecond == 0 {
                rateSamples[id] = (now, bytes)
            } else if let sample = rateSamples[id] {
                let elapsed = now - sample.time
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                if seconds >= 0.05, bytes >= sample.bytes {
                    let instant = Double(bytes - sample.bytes) / seconds
                    let old = transfers[index].bytesPerSecond
                    transfers[index].bytesPerSecond = old == 0 ? instant : old * 0.7 + instant * 0.3
                    rateSamples[id] = (now, bytes)
                }
            }
            transfers[index].bytesDone = bytes
        case .finished(let id, let outcome):
            rateSamples[id] = nil
            // Sends are settled by `pumpIfNeeded`, which knows whether to retry.
            guard let index = transfers.firstIndex(where: { $0.id == id }), transfers[index].direction == .receiving else { return }
            finish(index, outcome)
            if case .received = outcome { onReceived?(transfers[index]) }
        }
    }

    private func finish(_ index: Int, _ outcome: FileTransferOutcome) {
        transfers[index].finishedAt = .now
        transfers[index].interruptedAt = nil
        transfers[index].bytesPerSecond = 0
        switch outcome {
        case .sent(let savedName):
            transfers[index].state = .done
            transfers[index].bytesDone = transfers[index].byteCount
            transfers[index].savedName = savedName
        case .received(let url):
            transfers[index].state = .done
            transfers[index].bytesDone = transfers[index].byteCount
            transfers[index].savedURL = url
            transfers[index].name = url.lastPathComponent
        case .failed(let reason):
            transfers[index].state = .failed(reason)
        case .cancelled:
            transfers[index].state = .cancelled
        }
    }

    #if DEBUG
    /// `-VantageSendTestFile <bytes>`: queues a file of random bytes, as if picked in Files.
    func queueTestFile(bytes: Int, name: String = "Vantage Test.bin") {
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            for offset in stride(from: 0, to: bytes - 7, by: 8) {
                raw.storeBytes(of: generator.next() as UInt64, toByteOffset: offset, as: UInt64.self)
            }
        }
        let url = URL.temporaryDirectory.appending(path: name)
        do {
            try data.write(to: url)
            try sendCopy(of: url)
            try? FileManager.default.removeItem(at: url)
        } catch {
            log.error("couldn't make the test file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rows for `-VantageOpenScreen transfers`: one of each state, nothing on the network.
    static func fixture() -> FileTransferController {
        let controller = FileTransferController(receiveDirectory: URL.temporaryDirectory.appending(path: "FixtureReceived"))
        controller.transfers = [
            Transfer(id: UUID(), name: "Quarterly Report.pdf", byteCount: 48_300_000, direction: .sending, state: .active,
                     bytesDone: 31_400_000, bytesPerSecond: 11_800_000),
            Transfer(id: UUID(), name: "Screen Recording 2026-09-23.mov", byteCount: 412_000_000, direction: .receiving, state: .active,
                     bytesDone: 96_000_000, bytesPerSecond: 23_500_000),
            Transfer(id: UUID(), name: "Site Photos.zip", byteCount: 180_000_000, direction: .sending, state: .waiting),
            Transfer(id: UUID(), name: "Invoice 1042.pdf", byteCount: 212_000, direction: .receiving, state: .done,
                     bytesDone: 212_000, savedURL: URL.temporaryDirectory.appending(path: "Invoice 1042.pdf"), finishedAt: .now),
            Transfer(id: UUID(), name: "Keynote Draft.key", byteCount: 9_600_000, direction: .sending, state: .done,
                     bytesDone: 9_600_000, savedName: "Keynote Draft 2.key", finishedAt: .now),
            Transfer(id: UUID(), name: "Archive.dmg", byteCount: 2_100_000_000, direction: .sending,
                     state: .failed("There isn't enough free space for it."), finishedAt: .now),
        ]
        return controller
    }
    #endif
}

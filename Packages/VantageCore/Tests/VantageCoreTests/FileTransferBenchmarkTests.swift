import Darwin
import Foundation
import Network
import Testing
@testable import VantageCore

/// Throughput and memory for one large file over loopback, both engines in this process. Opt in:
/// `VANTAGE_BENCH_FILES=1 xcrun swift test --package-path Packages/VantageCore --filter FileTransferBenchmark`
/// (`VANTAGE_BENCH_BYTES` overrides the 2 GiB size). Needs twice the size free on disk.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VANTAGE_BENCH_FILES"] == "1"), .timeLimit(.minutes(10)))
struct FileTransferBenchmark {
    @Test func largeFileOverLoopback() async throws {
        let size = ProcessInfo.processInfo.environment["VANTAGE_BENCH_BYTES"].flatMap(Int.init) ?? 2 << 30
        let listener = try NWListener(using: VantageNetwork.tcpParameters(), on: .any)
        let accepted = AsyncStream<MessageChannel> { continuation in
            listener.newConnectionHandler = { connection in
                continuation.yield(MessageChannel(connection: connection, label: "bench.server", maxBufferedMessages: 64))
                continuation.finish()
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume() }
                else if case .failed(let error) = state { listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
            }
            listener.start(queue: .global())
        }
        defer { listener.cancel() }
        let clientChannel = MessageChannel(connection: NWConnection(host: .ipv4(.loopback), port: listener.port!, using: VantageNetwork.bulkParameters()),
                                           label: "bench.client", maxBufferedMessages: 64)
        try await clientChannel.start()
        var iterator = accepted.makeAsyncIterator()
        let serverChannel = try #require(await iterator.next())
        try await serverChannel.start()

        let root = FileManager.default.temporaryDirectory.appending(path: "vantage-bench-\(UUID().uuidString)")
        let sourceDir = root.appending(path: "source"), hostDir = root.appending(path: "host"), clientDir = root.appending(path: "client")
        for directory in [sourceDir, hostDir, clientDir] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sourceDir.appending(path: "Big.bin")
        try writePattern(bytes: size, to: source)

        let client = FileTransferEngine(channel: clientChannel, role: .client, configuration: .init(receiveDirectory: clientDir))
        let host = FileTransferEngine(channel: serverChannel, role: .host, configuration: .init(receiveDirectory: hostDir))
        let runs = [Task { await client.run() }, Task { await host.run() }]
        let sampler = FootprintSampler()
        sampler.start()
        let before = footprint()
        let started = ContinuousClock.now
        let outcome = await client.send(fileAt: source)
        let elapsed = ContinuousClock.now - started
        sampler.stop()
        #expect(outcome == .sent(savedName: "Big.bin"))
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let mib = Double(size) / 1_048_576
        print("benchmark: \(Int(mib)) MiB in \(String(format: "%.2f", seconds)) s = \(String(format: "%.0f", mib / seconds)) MiB/s; footprint \(before >> 20) MiB before, peak \(sampler.peak >> 20) MiB during")
        await client.close()
        for run in runs { await run.value }
    }

    /// A 64 MiB random block repeated, so writing the file isn't the slow part.
    private func writePattern(bytes: Int, to url: URL) throws {
        let blockSize = 64 << 20
        var generator = SystemRandomNumberGenerator()
        var block = Data(count: blockSize)
        block.withUnsafeMutableBytes { raw in
            for offset in stride(from: 0, to: blockSize, by: 8) {
                raw.storeBytes(of: generator.next() as UInt64, toByteOffset: offset, as: UInt64.self)
            }
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var written = 0
        while written < bytes {
            let piece = min(blockSize, bytes - written)
            try handle.write(contentsOf: piece == blockSize ? block : block.prefix(piece))
            written += piece
        }
    }
}

/// This process's physical footprint (what Xcode's memory gauge shows).
func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Samples `footprint()` every 50 ms on a background thread and keeps the highest.
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var highest: UInt64 = 0
    private var running = false

    var peak: UInt64 { lock.withLock { highest } }

    func start() {
        lock.withLock { running = true; highest = footprint() }
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let now = footprint()
                lock.withLock { highest = max(highest, now) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    func stop() { lock.withLock { running = false } }
}

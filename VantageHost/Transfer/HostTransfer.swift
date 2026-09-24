import Foundation
import VantageCore

/// One file in the host menu's transfer list.
struct HostTransfer: Identifiable, Equatable {
    enum State: Equatable {
        case waiting
        case active
        case done
        case failed(String)
        case cancelled
    }

    let id: UUID
    let name: String
    var byteCount: UInt64
    let direction: FileTransferItem.Direction
    let deviceName: String
    var state: State
    var bytesDone: UInt64 = 0
    /// Where a received file was saved.
    var savedURL: URL?
    var finishedAt: Date?
    /// The file being sent (sending only).
    var source: URL?
    /// Smoothed speed once there's enough to go on (about half a second of progress).
    var bytesPerSecond: Double?
    private var sampledAt: Date?
    private var sampledBytes: UInt64 = 0
    /// Which iPad it's moving to or from (`DeviceIdentity` fingerprint), so an interrupted file
    /// resumes when that iPad's next file channel opens.
    var clientKey: String?
    /// Set while the connection is gone mid-file: the row stays `.waiting` and the file carries on
    /// from where it stopped when the iPad reconnects (within `HostTransfer.resumeWindow`).
    var interruptedAt: Date?

    /// How long an interrupted file waits for its iPad before it counts as failed.
    static let resumeWindow: TimeInterval = 60 * 60

    init(id: UUID, name: String, byteCount: UInt64, direction: FileTransferItem.Direction, deviceName: String,
         state: State, source: URL? = nil, clientKey: String? = nil) {
        self.id = id
        self.name = name
        self.byteCount = byteCount
        self.direction = direction
        self.deviceName = deviceName
        self.state = state
        self.source = source
        self.clientKey = clientKey
    }

    var isActive: Bool { state == .waiting || state == .active }

    var fraction: Double {
        guard byteCount > 0 else { return state == .done ? 1 : 0 }
        return min(1, Double(bytesDone) / Double(byteCount))
    }

    /// Time left at the current speed, while it's moving.
    var secondsRemaining: TimeInterval? {
        guard state == .active, let bytesPerSecond, bytesPerSecond > 0, byteCount > bytesDone else { return nil }
        return Double(byteCount - bytesDone) / bytesPerSecond
    }

    /// Progress so far; updates the speed from the bytes since the last sample.
    mutating func record(bytes: UInt64, at now: Date = .now) {
        bytesDone = bytes
        guard let sampledAt else {
            self.sampledAt = now
            sampledBytes = bytes
            return
        }
        let elapsed = now.timeIntervalSince(sampledAt)
        guard elapsed >= 0.5, bytes >= sampledBytes else { return }
        let rate = Double(bytes - sampledBytes) / elapsed
        bytesPerSecond = bytesPerSecond.map { $0 * 0.6 + rate * 0.4 } ?? rate
        self.sampledAt = now
        sampledBytes = bytes
    }

    mutating func finish(_ outcome: FileTransferOutcome) {
        finishedAt = .now
        interruptedAt = nil
        switch outcome {
        case .sent:
            state = .done
            bytesDone = byteCount
        case .received(let url):
            state = .done
            bytesDone = byteCount
            savedURL = url
        case .failed(let reason):
            state = .failed(reason)
        case .cancelled:
            state = .cancelled
        }
    }
}

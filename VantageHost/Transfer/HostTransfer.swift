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

    init(id: UUID, name: String, byteCount: UInt64, direction: FileTransferItem.Direction, deviceName: String,
         state: State, source: URL? = nil) {
        self.id = id
        self.name = name
        self.byteCount = byteCount
        self.direction = direction
        self.deviceName = deviceName
        self.state = state
        self.source = source
    }

    var isActive: Bool { state == .waiting || state == .active }

    var fraction: Double {
        guard byteCount > 0 else { return state == .done ? 1 : 0 }
        return min(1, Double(bytesDone) / Double(byteCount))
    }

    mutating func finish(_ outcome: FileTransferOutcome) {
        finishedAt = .now
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

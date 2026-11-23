import Foundation
import VantageCore

/// What the Connection card shows that changes from second to second: measured here, from the
/// session's own 250 ms feedback windows (`VideoStreamController.snapshotStats` and the ping),
/// never asked of the host. The rest (the picture's size and codec, quality, route, address)
/// the card reads from the session as it is.
nonisolated struct ConnectionDetails: Equatable, Sendable {
    /// Round trip to the computer and back, the mean of the last second's pings; nil before the
    /// first answer.
    var roundTripMillis: Double?
    /// The last 30 seconds' round trips, oldest first, for the sparkline.
    var roundTripHistory: [Double] = []
    /// Frames that reached the screen over the last second. A still screen sends few: the host
    /// skips frames that would show nothing new.
    var framesPerSecond: Double = 0
    /// The picture's bits over the last second (video only, not sound or files).
    var megabitsPerSecond: Double = 0
    /// Frames this device couldn't use since the card opened.
    var droppedFrames: UInt64 = 0
    /// The decoded picture, in pixels; nil before the first stream.
    var pictureSize: CGSize?
}

/// Gathers the feedback windows into one `ConnectionDetails` a second. It runs only while the
/// card is open (`ScreenSessionModel.isShowingConnection`).
nonisolated struct ConnectionMeter: Sendable {
    /// Windows per published value: four 250 ms windows make a second.
    static let windowsPerUpdate = 4
    static let historyLength = 30

    private var windows: [QualityFeedback] = []
    private var history: [Double] = []
    private var dropped: UInt64 = 0

    /// Adds one window; every `windowsPerUpdate` windows, returns the second's figures.
    mutating func add(_ window: QualityFeedback) -> ConnectionDetails? {
        windows.append(window)
        dropped &+= window.framesDropped
        guard windows.count >= Self.windowsPerUpdate else { return nil }
        defer { windows.removeAll(keepingCapacity: true) }
        let seconds = windows.reduce(0) { $0 + $1.windowSeconds }
        guard seconds > 0 else { return nil }
        let pings = windows.map(\.rttMillis).filter { $0 > 0 }
        let roundTrip = pings.isEmpty ? nil : pings.reduce(0, +) / Double(pings.count)
        if let roundTrip {
            history.append(roundTrip)
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
        let frames = windows.reduce(UInt64(0)) { $0 &+ $1.framesReceived }
        let bytes = windows.reduce(UInt64(0)) { $0 &+ $1.bytesReceived }
        return ConnectionDetails(roundTripMillis: roundTrip, roundTripHistory: history,
                                 framesPerSecond: Double(frames) / seconds,
                                 megabitsPerSecond: Double(bytes) * 8 / seconds / 1_000_000,
                                 droppedFrames: dropped)
    }
}

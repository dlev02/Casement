import Foundation
import VantageCore

/// AIMD bitrate/fps controller driven by client feedback. Also decides text vs motion mode from
/// the capture dirty-area ratio. Pure logic, unit-testable, no I/O.
nonisolated struct AdaptiveController {
    struct Limits {
        var minBitrateKbps = 2_000
        var maxBitrateKbps = 60_000
        var textFPS = 30
        var motionFPS = 60
    }

    enum Mode: Equatable { case text, motion }

    var limits: Limits
    private(set) var bitrateKbps: Int
    private(set) var mode: Mode = .motion
    private var smoothedDirty: Double = 0
    private var lastAdjustment = Date.distantPast
    private var probeHoldUntil = Date.distantPast

    init(limits: Limits = Limits(), startBitrateKbps: Int = 20_000) {
        self.limits = limits
        self.bitrateKbps = startBitrateKbps
    }

    /// Smooths dirty ratio and returns the resulting mode + target fps.
    mutating func observe(dirtyRatio: Double) -> (mode: Mode, fps: Int) {
        smoothedDirty = smoothedDirty * 0.9 + dirtyRatio * 0.1
        mode = smoothedDirty < 0.02 ? .text : .motion
        return (mode, mode == .text ? limits.textFPS : limits.motionFPS)
    }

    /// Applies client feedback; returns a new bitrate if it changed.
    mutating func apply(feedback: QualityFeedback, now: Date = Date()) -> Int? {
        let loss = feedback.framesDropped > 0 || feedback.queueDepth > 1
        let previous = bitrateKbps
        if loss {
            bitrateKbps = max(limits.minBitrateKbps, Int(Double(bitrateKbps) * 0.7))
            probeHoldUntil = now.addingTimeInterval(2)
        } else if now > probeHoldUntil, now.timeIntervalSince(lastAdjustment) > 2 {
            bitrateKbps = min(limits.maxBitrateKbps, Int(Double(bitrateKbps) * 1.1))
        }
        if bitrateKbps != previous {
            lastAdjustment = now
            return bitrateKbps
        }
        return nil
    }

    /// Suggested max QP so text stays crisp under pressure.
    var maxQP: Int { mode == .text ? 32 : 44 }
}

import Foundation
import VantageCore

/// AIMD bitrate/fps controller driven by client feedback. Also decides text vs motion mode from
/// the capture dirty-area ratio. Pure logic, unit-testable, no I/O.
nonisolated struct AdaptiveController {
    /// What a quality preset asks of the stream. The Windows host's `AdaptiveController` uses the
    /// same numbers.
    struct Limits: Equatable {
        var minBitrateKbps = 2_000
        var maxBitrateKbps = 60_000
        var textFPS = 30
        var motionFPS = 60
        /// Quantiser ceilings: text mode keeps static text crisp, motion lets movement through.
        var textMaxQP = 32
        var motionMaxQP = 44
        /// The ceiling for the one re-encode of a still screen once motion stops; nil never sharpens.
        var idleMaxQP: Int? = 24

        /// Balanced (`auto`) adapts to the screen and sharpens it when it stops; Fluid (`motion`)
        /// holds 60 fps and never spends a burst on a still screen; Sharp Text (`text`) tightens
        /// every ceiling and keeps a higher bitrate floor.
        init(preset: QualityPreset = .auto) {
            switch preset {
            case .auto:
                break
            case .motion:
                textFPS = 60
                textMaxQP = 36
                idleMaxQP = nil
            case .text:
                minBitrateKbps = 6_000
                textMaxQP = 28
                motionMaxQP = 38
                idleMaxQP = 20
            case .maximum:
                minBitrateKbps = 10_000
                textMaxQP = 24
                motionMaxQP = 34
                idleMaxQP = 18
            }
        }
    }

    enum Mode: Equatable { case text, motion }

    private(set) var limits: Limits
    private(set) var bitrateKbps: Int
    private(set) var mode: Mode = .motion
    private var smoothedDirty: Double = 0
    private var lastAdjustment = Date.distantPast
    private var probeHoldUntil = Date.distantPast
    /// Input keeps the frame rate up for a moment: a moving pointer dirties too little of the screen
    /// to leave text mode, so it would otherwise update at 30 fps.
    private var inputHoldUntil = Date.distantPast

    init(limits: Limits = Limits(), startBitrateKbps: Int = 20_000) {
        self.limits = limits
        self.bitrateKbps = min(limits.maxBitrateKbps, max(limits.minBitrateKbps, startBitrateKbps))
    }

    /// The device picked another quality mid-stream: new limits, the bitrate kept within them.
    /// Returns the bitrate when that moved it.
    mutating func setPreset(_ preset: QualityPreset) -> Int? {
        limits = Limits(preset: preset)
        let previous = bitrateKbps
        bitrateKbps = min(limits.maxBitrateKbps, max(limits.minBitrateKbps, bitrateKbps))
        return bitrateKbps == previous ? nil : bitrateKbps
    }

    /// Smooths dirty ratio and returns the resulting mode + target fps. The mode (and so the QP
    /// ceiling) follows the screen alone; recent input only raises the fps.
    mutating func observe(dirtyRatio: Double, now: Date = Date()) -> (mode: Mode, fps: Int) {
        smoothedDirty = smoothedDirty * 0.9 + dirtyRatio * 0.1
        mode = smoothedDirty < 0.02 ? .text : .motion
        return (mode, fps(now: now))
    }

    /// The mode's frame rate, or the motion rate within a second of input.
    func fps(now: Date = Date()) -> Int {
        mode == .motion || now < inputHoldUntil ? limits.motionFPS : limits.textFPS
    }

    /// Pointer, scroll, or key input: hold the motion frame rate for the next second.
    mutating func noteInput(now: Date = Date()) {
        inputHoldUntil = now.addingTimeInterval(1)
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

    /// The QP ceiling for the current mode, so text stays crisp under pressure.
    var maxQP: Int { mode == .text ? limits.textMaxQP : limits.motionMaxQP }
}

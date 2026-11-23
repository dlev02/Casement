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
        /// Moving content runs at up to 120 fps on Balanced and Fluid, as fast as a ProMotion
        /// screen shows it; `AdaptiveController.fpsCap` holds it to the device and the display.
        var motionFPS = 120
        /// Quantiser ceilings: text mode keeps static text crisp, motion lets movement through.
        var textMaxQP = 32
        var motionMaxQP = 44
        /// The ceiling for the one re-encode of a still screen once motion stops; nil never sharpens.
        var idleMaxQP: Int? = 24

        /// Balanced (`auto`) adapts to the screen and sharpens it when it stops; Fluid (`motion`)
        /// never drops under 60 fps and never spends a burst on a still screen; Sharp Text (`text`)
        /// tightens every ceiling, keeps a higher bitrate floor and moves at 60 fps, so each frame
        /// keeps twice the bits.
        init(preset: QualityPreset = .auto) {
            switch preset {
            case .auto:
                break
            case .motion:
                textFPS = 60
                textMaxQP = 36
                idleMaxQP = nil
            case .text:
                motionFPS = 60
                minBitrateKbps = 6_000
                textMaxQP = 28
                motionMaxQP = 38
                idleMaxQP = 20
            case .maximum:
                motionFPS = 60
                minBitrateKbps = 10_000
                textMaxQP = 24
                motionMaxQP = 34
                idleMaxQP = 18
            }
        }
    }

    enum Mode: Equatable { case text, motion }

    /// The most frames a second wanted from this stream: the device's request, the display's
    /// refresh rate and `maxFPS`, whichever is lowest (`fpsCap(requested:displayRefresh:)`).
    let fpsCap: Int
    /// No device shows more than this; 240 would only double the cost.
    static let maxFPS = 120

    /// The frame-rate ceiling for a stream: what the device asked for, no faster than the display
    /// refreshes (a 60 Hz display can't give 120 different frames) and never over `maxFPS`.
    static func fpsCap(requested: Int, displayRefresh: Double) -> Int {
        let refresh = displayRefresh >= 1 ? Int(displayRefresh.rounded()) : 60
        return max(1, min(requested, refresh, maxFPS))
    }

    private(set) var limits: Limits
    private(set) var bitrateKbps: Int
    private(set) var mode: Mode = .motion
    private var smoothedDirty: Double = 0
    private var lastAdjustment = Date.distantPast
    private var probeHoldUntil = Date.distantPast
    /// Input keeps the frame rate up for a moment: a moving pointer dirties too little of the screen
    /// to leave text mode, so it would otherwise update at 30 fps.
    private var inputHoldUntil = Date.distantPast

    init(limits: Limits = Limits(), startBitrateKbps: Int = 20_000, fpsCap: Int = AdaptiveController.maxFPS) {
        self.limits = limits
        self.fpsCap = max(1, fpsCap)
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
        min(fpsCap, mode == .motion || now < inputHoldUntil ? limits.motionFPS : limits.textFPS)
    }

    /// Pointer, scroll, or key input: hold the motion frame rate for the next second.
    mutating func noteInput(now: Date = Date()) {
        inputHoldUntil = now.addingTimeInterval(1)
    }

    /// Applies client feedback; returns a new bitrate if it changed. `backlogged` is the host's
    /// own sign of a full link: video it sent that the network stack hasn't taken yet (the
    /// device's report can't show it over TCP, where overload is delay, not loss).
    mutating func apply(feedback: QualityFeedback, backlogged: Bool = false, now: Date = Date()) -> Int? {
        let loss = backlogged || feedback.framesDropped > 0 || feedback.queueDepth > 1
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

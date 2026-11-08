import Foundation
import VantageCore

/// Keeps a picture coming for one screen session: what the device asked to stream, one capture
/// start at a time (a request made meanwhile takes over afterwards), the display sleeping and
/// waking, which input a sleeping display admits, the watchdog that brings a missing picture
/// back (0.5 s doubling to 5 s, a "capture started but sent no frames" rule at 5 s, the
/// "screen unavailable" notice at 3 s), and what `HostStatus` the device hears, once per change.
///
/// Pure: events in, decisions out, and the caller's clock (`now`) on every event, so a test
/// drives it with a fake clock and a fake frame source. `HostSession` executes the decisions.
/// The Windows host's session runs the same machine.
nonisolated struct CaptureLifecycle: Sendable {
    /// What a capture start should do: try these targets in order, and first wake the display
    /// when it's asleep (a fresh request) or a panel that's dark (a watchdog retry).
    struct StartRequest: Equatable, Sendable {
        var targets: [SelectDisplay]
        var reason: String
        var wakesSleepingDisplay = false
        var wakesDarkPanel = false
    }

    enum Event: Sendable {
        /// The device asked to stream this.
        case selectionRequested(SelectDisplay)
        /// A start the lifecycle asked for came up on this display with this codec.
        case captureStarted(display: DisplayInfo, codec: VideoCodec)
        /// Every target of a start the lifecycle asked for failed.
        case captureFailed(reason: String)
        /// The running capture stopped by itself (ScreenCaptureKit lost the display).
        case captureStopped(reason: String)
        case frameArrived
        /// Lock, secure input, or display sleep, as the status monitor reports it.
        case statusChanged(HostStatus)
        /// The device's Wake command (also Retry while the picture is missing).
        case wakeRequested
        /// The device's Sleep Display command.
        case sleepRequested
        /// The displays woke or changed, as the controller saw it.
        case displaysChanged
        /// 250 ms passed while `wantsTicks`.
        case tick
    }

    enum Decision: Equatable, Sendable {
        /// Start capture (stopping any running one first); report `captureStarted` or `captureFailed`.
        case startCapture(StartRequest)
        /// Stop the running capture and encoder; the lifecycle has already written it off.
        case stopCapture(reason: String)
        /// Tell the device (only sent when it differs from the last one).
        case sendStatus(HostStatus)
        case wakeDisplay(reason: String)
        case sleepDisplay
        /// Read lock, secure input and display sleep again now, rather than at the next poll.
        case refreshStatus
        /// Start the session-long pieces: keep-awake and the status monitor, then report its status.
        case beginMonitoring
        /// The next frame should be a keyframe (a wake with capture still running).
        case requestKeyframe
        /// Something worth a line in the log.
        case note(String)
    }

    enum InputVerdict: Equatable, Sendable {
        case deliver
        case drop
        /// Drop it, and wake the display (the input path rate-limits the wake to once a second).
        case wakeThenDrop
    }

    /// Timings, in one place for the tests.
    struct Timing: Sendable {
        /// A started capture with no frame for this long counts as failed.
        var noFrameLimit: Duration = .seconds(5)
        /// The device hears `isScreenUnavailable` after this long without a picture.
        var unavailableNotice: Duration = .seconds(3)
        var firstRetry: Duration = .milliseconds(500)
        var maxRetry: Duration = .seconds(5)
        /// Input in this moment after Sleep Display doesn't wake the display (the hand that chose it).
        var sleepGrace: Duration = .seconds(2)
        /// A restart within this long of a start is the same wake, not a second one.
        var restartDebounce: Duration = .seconds(2)
    }

    private struct Running: Sendable {
        var display: DisplayInfo
        var codec: VideoCodec
        var startedAt: ContinuousClock.Instant
        var hasFramed = false
    }

    let timing: Timing
    /// Whether a display chosen by id can be asked for again after a restart (`HostScreen.canRestartByDisplayID`).
    let restartsByDisplayID: Bool

    private(set) var wanted: SelectDisplay?
    private var starting = false
    private var pendingStart: SelectDisplay?
    private var running: Running?
    /// The display and codec of the last capture, which a restart goes back to.
    private var lastDisplay: DisplayInfo?
    private var lastCodec: VideoCodec?
    private var lostAt: ContinuousClock.Instant?
    private var lossReason = ""
    private var nextRetry: ContinuousClock.Instant?
    private var retryDelay: Duration
    private var screenUnavailable = false
    private var monitoring = false
    private var displayAsleep = false
    private var sleptAt: ContinuousClock.Instant?
    /// The monitor's last word, and the last status the device was told.
    private var baseStatus: HostStatus?
    private var lastSent: HostStatus?

    init(restartsByDisplayID: Bool, timing: Timing = Timing()) {
        self.restartsByDisplayID = restartsByDisplayID
        self.timing = timing
        self.retryDelay = timing.firstRetry
    }

    /// A capture is running (started and not stopped since).
    var isCapturing: Bool { running != nil }
    /// A start is under way.
    var isStarting: Bool { starting }
    /// The display being (or last) streamed.
    var display: DisplayInfo? { lastDisplay }
    var isDisplayAsleep: Bool { displayAsleep }
    /// Whether the watchdog needs `tick`s: a capture that hasn't framed yet, or a picture that's
    /// missing while the display is awake.
    var wantsTicks: Bool {
        guard wanted != nil, !displayAsleep else { return false }
        if let running, !running.hasFramed { return true }
        return lostAt != nil
    }

    /// Lock, secure input and display sleep, plus whether the picture is missing while awake.
    var currentStatus: HostStatus {
        var status = baseStatus ?? HostStatus(isScreenLocked: false, isSecureInputActive: false, inputPath: .native)
        status.isScreenUnavailable = screenUnavailable && status.isDisplayAsleep != true
        return status
    }

    /// Whether input may reach the screen now.
    func admitsInput(isRelease: Bool, now: ContinuousClock.Instant) -> InputVerdict {
        guard displayAsleep else { return .deliver }
        if isRelease { return .deliver }
        if let sleptAt, now - sleptAt < timing.sleepGrace { return .drop }
        return .wakeThenDrop
    }

    mutating func handle(_ event: Event, now: ContinuousClock.Instant) -> [Decision] {
        switch event {
        case .selectionRequested(let select):
            wanted = select
            var decisions: [Decision] = []
            if !monitoring {
                monitoring = true
                decisions.append(.beginMonitoring)
            }
            decisions += start(targets: [select], reason: "device asked for a display", wakesSleepingDisplay: true, pendingIfBusy: select)
            return decisions

        case .captureStarted(let display, let codec):
            starting = false
            running = Running(display: display, codec: codec, startedAt: now)
            lastDisplay = display
            lastCodec = codec
            return startPendingIfAny()

        case .captureFailed(let reason):
            starting = false
            lossReason = reason
            let pending = startPendingIfAny()
            return pending.isEmpty ? unavailable(now: now) : pending

        case .captureStopped(let reason):
            guard running != nil else { return [] }
            running = nil
            lossReason = reason
            return [.refreshStatus] + unavailable(now: now)

        case .frameArrived:
            running?.hasFramed = true
            return recovered(now: now)

        case .statusChanged(let status):
            baseStatus = status
            var decisions = sendStatusIfChanged()
            let asleep = status.isDisplayAsleep == true
            guard asleep != displayAsleep else {
                // Capture waiting on something else (a lock screen lists no displays either): try
                // again now that the Mac changed, rather than at the next backoff step.
                if !asleep, running == nil, wanted != nil, !starting {
                    decisions += start(targets: restartTargets(), reason: "Mac state changed")
                }
                return decisions
            }
            displayAsleep = asleep
            if asleep {
                decisions.append(.note("display went to sleep; the session stays up"))
                // The asleep state explains the missing picture; the clock restarts on wake.
                lostAt = nil
                nextRetry = nil
                screenUnavailable = false
                // ScreenCaptureKit stops its stream by itself a moment later; stopping it now means
                // nothing encoded before the sleep arrives after the wake, and the wake restarts cleanly.
                if running != nil {
                    running = nil
                    decisions.append(.stopCapture(reason: "display asleep"))
                }
                decisions += sendStatusIfChanged()
            } else {
                decisions.append(.note("display woke"))
                sleptAt = nil
                if running == nil, wanted != nil {
                    decisions += start(targets: restartTargets(), reason: "display woke")
                } else if running != nil {
                    decisions.append(.requestKeyframe)
                }
            }
            return decisions

        case .wakeRequested:
            sleptAt = nil
            var decisions: [Decision] = [.wakeDisplay(reason: "Wake command"), .refreshStatus]
            // Wake doubles as Retry while the picture is missing: try again now, from a short backoff.
            if lostAt != nil, running == nil {
                retryDelay = timing.firstRetry
                nextRetry = now + retryDelay
                decisions.append(.note("capture retry asked for by the client"))
                decisions += start(targets: restartTargets(), reason: "client asked to retry")
            }
            return decisions

        case .sleepRequested:
            sleptAt = now
            return [.sleepDisplay, .refreshStatus]

        case .displaysChanged:
            guard wanted != nil, !displayAsleep else { return [] }
            // The wake notice just restarted it; don't do it twice.
            if let running, now - running.startedAt < timing.restartDebounce { return [] }
            return start(targets: restartTargets(), reason: "displays changed")

        case .tick:
            return tick(now: now)
        }
    }

    // MARK: Starting

    /// Asks for a start unless one is under way; a request that must not be dropped waits as
    /// `pendingIfBusy` and goes out once the current start reports back.
    private mutating func start(targets: [SelectDisplay], reason: String, wakesSleepingDisplay: Bool = false,
                                wakesDarkPanel: Bool = false, pendingIfBusy: SelectDisplay? = nil) -> [Decision] {
        guard wanted != nil else { return [] }
        if starting {
            if let pendingIfBusy { pendingStart = pendingIfBusy }
            return []
        }
        starting = true
        return [.startCapture(StartRequest(targets: targets, reason: reason, wakesSleepingDisplay: wakesSleepingDisplay,
                                           wakesDarkPanel: wakesDarkPanel))]
    }

    private mutating func startPendingIfAny() -> [Decision] {
        guard let pending = pendingStart else { return [] }
        pendingStart = nil
        return start(targets: [pending], reason: "device asked for a display", wakesSleepingDisplay: true)
    }

    /// The display capture was on (if displays persist), then the device's original choice.
    private func restartTargets() -> [SelectDisplay] {
        guard let wanted else { return [] }
        var targets: [SelectDisplay] = []
        // Synthetic displays are made to the viewport, so only the original request rebuilds one.
        if let lastDisplay, restartsByDisplayID {
            targets.append(SelectDisplay(selection: .display(lastDisplay.id), targetFPS: wanted.targetFPS, quality: wanted.quality,
                                         preferredCodec: lastCodec ?? wanted.preferredCodec))
        }
        targets.append(wanted)
        return targets
    }

    // MARK: Awake but no picture

    /// Capture is down while the device waits. A sleeping display comes back through the wake
    /// notice; anything else gets the watchdog.
    private mutating func unavailable(now: ContinuousClock.Instant) -> [Decision] {
        guard wanted != nil, running == nil else { return [] }
        let decisions = sendStatusIfChanged()
        guard !displayAsleep else { return decisions }
        if lostAt == nil {
            lostAt = now
            retryDelay = timing.firstRetry
            nextRetry = now + retryDelay
        }
        return decisions
    }

    private mutating func tick(now: ContinuousClock.Instant) -> [Decision] {
        guard wanted != nil, !displayAsleep else { return [] }
        var decisions: [Decision] = []
        // A capture that started but never sent a frame counts as failed.
        if let running, !running.hasFramed, now - running.startedAt > timing.noFrameLimit {
            self.running = nil
            lossReason = "capture started but sent no frames"
            decisions.append(.stopCapture(reason: lossReason))
            decisions += unavailable(now: now)
        }
        guard let lostAt else { return decisions }
        let seconds = Int((now - lostAt).components.seconds)
        if now - lostAt >= timing.unavailableNotice, !screenUnavailable {
            screenUnavailable = true
            decisions.append(.note("capture unavailable for \(seconds) s: \(lossReason); telling the client"))
            decisions += sendStatusIfChanged()
        }
        guard running == nil, !starting, let nextRetry, now >= nextRetry else { return decisions }
        decisions.append(.note("capture unavailable for \(seconds) s: \(lossReason); trying again"))
        decisions += start(targets: restartTargets(), reason: "capture unavailable for \(seconds) s", wakesDarkPanel: true)
        retryDelay = min(retryDelay * 2, timing.maxRetry)
        self.nextRetry = now + retryDelay
        return decisions
    }

    /// Frames are flowing again: clear the unavailable state at once.
    private mutating func recovered(now: ContinuousClock.Instant) -> [Decision] {
        guard let lostAt else { return [] }
        self.lostAt = nil
        nextRetry = nil
        var decisions: [Decision] = [.note("capture back after \((now - lostAt).formatted(.units(allowed: [.seconds, .milliseconds])))")]
        if screenUnavailable {
            screenUnavailable = false
            decisions += sendStatusIfChanged()
        }
        return decisions
    }

    /// The device hears a status only when it differs from the last one it was told.
    private mutating func sendStatusIfChanged() -> [Decision] {
        let status = currentStatus
        guard status != lastSent else { return [] }
        lastSent = status
        return [.sendStatus(status)]
    }
}

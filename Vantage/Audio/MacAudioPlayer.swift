import AVFAudio
import Foundation
import Observation
import Synchronization
import VantageCore
import os

/// Plays the Mac's audio: Opus packets from the session are decoded on a queue of their own into
/// `AudioJitterBuffer`, and an `AVAudioEngine` source node pulls from it on the render thread.
///
/// Audio session: `.playback` with `.mixWithOthers` while only playing (the user's music keeps
/// going; the silent switch doesn't mute an explicit Mac Audio toggle). Dictation owns the session
/// while it listens: `DictationController` reports the microphone opening before it switches the
/// category to `.playAndRecord`, output stops (the iPad's speaker would otherwise feed the Mac's
/// sound into the transcript), and once the microphone has let the session go this takes it back.
/// No background audio mode: playback ends with the session when the app leaves the foreground.
@MainActor
@Observable
final class MacAudioPlayer {
    enum Status: Equatable {
        case off
        /// Asked for; waiting for the host's `audioConfig`.
        case starting
        case playing
        /// Dictation has the audio session.
        case paused
        /// The host (or this iPad) can't play audio right now; the text says why.
        case unavailable(String)
    }

    private(set) var status: Status = .off

    private let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "audio")
    @ObservationIgnored private let pipeline = MacAudioPipeline()
    @ObservationIgnored private var engine: AVAudioEngine?
    #if DEBUG && targetEnvironment(simulator)
    /// Some simulators can't reach an audio device at all (CoreAudio: "there is no system
    /// object"); this pulls from the buffer on a timer instead, so the rest of the path can
    /// still be tested there.
    @ObservationIgnored private var nullOutput: NullAudioOutput?
    #endif
    private var isOutputRunning: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if nullOutput != nil { return true }
        #endif
        return engine != nil
    }
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var microphoneActive = false
    @ObservationIgnored private var interrupted = false

    var stats: AudioJitterBuffer.Stats { pipeline.buffer.stats }

    init() {}

    // MARK: Control

    /// The user turned Mac audio on or off (or the session connected with it on). Off stops
    /// output and releases the audio session.
    func setWanted(_ on: Bool) {
        guard on != wanted else { return }
        wanted = on
        if on {
            status = .starting
            observeSession()
            startStatsLog()
        } else {
            stopOutput()
            pipeline.stop()
            stopObserving()
            statsTask?.cancel()
            statsTask = nil
            status = .off
        }
    }

    /// The connection dropped or the app went to the background: the host's stream is gone, and
    /// the next connection starts a new one (with a new `audioConfig`).
    func connectionLost() {
        stopOutput()
        pipeline.stop()
        if wanted { status = .starting }
    }

    /// Called by `DictationController` right before the microphone takes the audio session and
    /// right after it has given it back.
    func setMicrophoneActive(_ active: Bool) {
        guard active != microphoneActive else { return }
        microphoneActive = active
        if active {
            if isOutputRunning {
                stopOutput(releaseSession: false) // the microphone is about to reconfigure it
                status = .paused
            }
        } else if status == .paused {
            startOutput()
        }
    }

    /// `audioConfig` and `audioPacket` from `ClientSession.onAudio`.
    func handle(_ message: Message) {
        switch message {
        case .audioConfig(let config):
            guard wanted else { return }
            if let reason = config.unavailable {
                log.info("Mac audio unavailable: \(reason, privacy: .public)")
                stopOutput()
                pipeline.stop()
                status = .unavailable(reason)
                return
            }
            guard pipeline.configure(config) else {
                stopOutput()
                status = .unavailable("This version of Vantage can't play the Mac's audio (\(config.codec)). Update Vantage.")
                return
            }
            log.info("Mac audio: \(config.codec, privacy: .public) \(config.sampleRate, privacy: .public) Hz, \(config.channels, privacy: .public) ch, \(config.framesPerPacket, privacy: .public) frames/packet, \(config.bitrate / 1000, privacy: .public) kbps")
            if microphoneActive { status = .paused } else { startOutput() }
        case .audioPacket(let packet):
            pipeline.enqueue(packet, playing: isOutputRunning)
        default:
            break
        }
    }

    // MARK: Output

    private func startOutput() {
        guard wanted, !microphoneActive, !interrupted, !isOutputRunning, pipeline.isConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        var step = "session"
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
            step = "engine"
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let engine = AVAudioEngine()
            let node = Self.makeSourceNode(buffer: pipeline.buffer, format: format)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.prepare()
            pipeline.buffer.reset()
            step = "start"
            try engine.start()
            self.engine = engine
            status = .playing
            log.info("Mac audio playing: IO buffer \(Int(session.ioBufferDuration * 1000), privacy: .public) ms, output latency \(Int(session.outputLatency * 1000), privacy: .public) ms, route \(session.currentRoute.outputs.first?.portType.rawValue ?? "none", privacy: .public)")
        } catch {
            log.error("Mac audio couldn't start (\(step, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            engine?.stop()
            engine = nil
            #if DEBUG && targetEnvironment(simulator)
            log.info("Mac audio: no audio device in this simulator; playing into a null output")
            pipeline.buffer.reset()
            nullOutput = NullAudioOutput(buffer: pipeline.buffer)
            status = .playing
            return
            #else
            status = .unavailable("This iPad couldn't start playing the Mac's sound.")
            #endif
        }
    }

    private func stopOutput(releaseSession: Bool = true) {
        #if DEBUG && targetEnvironment(simulator)
        nullOutput?.stop()
        nullOutput = nil
        #endif
        guard let engine else { return }
        engine.stop()
        self.engine = nil
        pipeline.buffer.reset()
        if releaseSession, !microphoneActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Renders on the audio thread. Nonisolated so the block doesn't inherit the main actor.
    private nonisolated static func makeSourceNode(buffer: AudioJitterBuffer, format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { isSilence, _, frameCount, outputData in
            let list = UnsafeMutableAudioBufferListPointer(outputData)
            guard list.count >= 2,
                  let left = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = list[1].mData?.assumingMemoryBound(to: Float.self) else {
                isSilence.pointee = true
                return noErr
            }
            buffer.render(left: left, right: right, frames: Int(frameCount))
            return noErr
        }
    }

    // MARK: Session events

    private func observeSession() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            MainActor.assumeIsolated { self?.handleInterruption(began: type == .began, shouldResume: options.contains(.shouldResume)) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { self?.handleRouteChange(reason) }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            let changed = note.object as? AVAudioEngine
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine, changed === engine else { return }
                // The hardware format changed under the engine (a new route); it has stopped.
                self.log.info("Mac audio: engine configuration changed; restarting")
                self.stopOutput(releaseSession: false)
                self.startOutput()
            }
        })
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        // Dictation's own session changes aren't interruptions of ours to handle.
        guard !microphoneActive else { return }
        if began {
            interrupted = true
            log.info("Mac audio interrupted")
            stopOutput(releaseSession: false)
            if wanted, pipeline.isConfigured { status = .paused }
        } else {
            interrupted = false
            log.info("Mac audio interruption ended (resume: \(shouldResume, privacy: .public))")
            if shouldResume, status == .paused { startOutput() }
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason?) {
        guard engine != nil else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
            // AirPods in or out: the new route has its own latency, so rebuild the cushion.
            log.info("Mac audio: route changed to \(AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "none", privacy: .public); resetting the jitter buffer")
            pipeline.buffer.reset()
        default:
            break
        }
    }

    // MARK: Stats

    private func startStatsLog() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, self.isOutputRunning else { continue }
                self.logStats()
            }
        }
    }

    private func logStats() {
        let stats = pipeline.buffer.stats
        let transit = pipeline.transitSnapshot()
        let session = AVAudioSession.sharedInstance()
        let outputMs = (session.outputLatency + session.ioBufferDuration) * 1000
        log.info("Mac audio stats: packets \(transit.packets, privacy: .public), depth \(Int(stats.milliseconds(stats.depthFrames)), privacy: .public) ms, target \(Int(stats.milliseconds(stats.targetFrames)), privacy: .public) ms, underruns \(stats.underruns, privacy: .public), idle gaps \(stats.idleGaps, privacy: .public), drops \(stats.drops, privacy: .public), repeats \(stats.duplicates, privacy: .public), skips \(stats.skips, privacy: .public), overflows \(stats.overflows, privacy: .public), frames in/out \(stats.framesPushed, privacy: .public)/\(stats.framesPlayed, privacy: .public), arrival jitter p95 \(String(format: "%.1f", transit.jitterP95Ms), privacy: .public) ms, output \(Int(outputMs), privacy: .public) ms")
        #if DEBUG
        // Host and client share a clock only on loopback (the simulator on the host's Mac).
        log.info("Mac audio transit (loopback clock): p50 \(String(format: "%.1f", transit.p50Ms), privacy: .public) ms, p95 \(String(format: "%.1f", transit.p95Ms), privacy: .public) ms; capture → speaker ≈ \(Int(transit.p50Ms + stats.milliseconds(stats.depthFrames) + outputMs), privacy: .public) ms")
        #endif
    }
}

/// The decode side of `MacAudioPlayer`: its own serial queue, the Opus decoder, and the jitter
/// buffer's producer end. Safe to call from any thread.
nonisolated final class MacAudioPipeline: @unchecked Sendable {
    struct Transit: Sendable {
        var packets = 0
        var p50Ms = 0.0
        var p95Ms = 0.0
        /// p95 minus the fastest packet: how uneven arrivals are, whatever the clocks.
        var jitterP95Ms = 0.0
    }

    let buffer = AudioJitterBuffer()
    private let queue = DispatchQueue(label: "vantage.audio.decode", qos: .userInteractive)
    // Queue-confined.
    private var decoder: OpusDecoder?
    private var channels = 2
    private var lastSequence: UInt64?
    private var packets = 0
    private var transit: [Double] = []
    private let configured = Atomic(false)

    var isConfigured: Bool { configured.load(ordering: .acquiring) }

    /// Nil-safe: returns false for a format this build can't decode.
    func configure(_ config: AudioConfig) -> Bool {
        guard let decoder = OpusDecoder(config: config) else { return false }
        queue.sync {
            self.decoder = decoder
            channels = config.channels
            lastSequence = nil
        }
        configured.store(true, ordering: .releasing)
        return true
    }

    func stop() {
        configured.store(false, ordering: .releasing)
        queue.async {
            self.decoder = nil
            self.lastSequence = nil
        }
    }

    /// Decodes on the queue. While output is stopped the packet is still decoded (keeping the
    /// decoder's state continuous) but not buffered.
    func enqueue(_ packet: AudioPacket, playing: Bool) {
        let arrival = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            guard let decoder else { return }
            if let last = lastSequence, packet.sequence != last &+ 1 {
                decoder.reset() // a gap (shouldn't happen over TCP): don't blend unrelated audio
            }
            lastSequence = packet.sequence
            packets += 1
            transit.append(Double(Int64(bitPattern: arrival &- packet.captureNanos)) / 1e6)
            if transit.count > 1_000 { transit.removeFirst(transit.count - 1_000) }
            guard let pcm = decoder.decode(packet.data), playing else { return }
            buffer.push(pcm, channels: channels, captureNanos: packet.captureNanos)
        }
    }

    func transitSnapshot() -> Transit {
        queue.sync {
            guard !transit.isEmpty else { return Transit(packets: packets) }
            let sorted = transit.sorted()
            let p50 = sorted[sorted.count / 2], p95 = sorted[sorted.count * 95 / 100]
            return Transit(packets: packets, p50Ms: p50, p95Ms: p95, jitterP95Ms: p95 - sorted[0])
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Pulls 5 ms at a time from the jitter buffer on a timer, paced by the clock like a sound card.
nonisolated final class NullAudioOutput: @unchecked Sendable {
    private let timer: DispatchSourceTimer
    private let buffer: AudioJitterBuffer
    private let started = DispatchTime.now().uptimeNanoseconds
    private var pulled = 0
    private var left = [Float](repeating: 0, count: 240)
    private var right = [Float](repeating: 0, count: 240)

    init(buffer: AudioJitterBuffer) {
        self.buffer = buffer
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "vantage.audio.null", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    func stop() { timer.cancel() }

    private func tick() {
        let due = Int((DispatchTime.now().uptimeNanoseconds - started) * 48 / 1_000_000)
        while due - pulled >= 240 {
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in buffer.render(left: l.baseAddress!, right: r.baseAddress!, frames: 240) }
            }
            pulled += 240
        }
    }
}
#endif

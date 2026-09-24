import AVFAudio
import Foundation
import Network
import Testing
import VantageCore
@testable import VantageClientLogic
@testable import VantageSynthetic

// MARK: Helpers

private func rms(_ samples: ArraySlice<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

/// Interleaved stereo sine blocks.
private func sineBlocks(count: Int, frequency: Double = 1_000, amplitude: Float = 0.125_9) -> [AudioBlock] {
    (0..<count).map { block in
        var samples = [Float](repeating: 0, count: AudioBlock.frames * 2)
        for frame in 0..<AudioBlock.frames {
            let n = Double(block * AudioBlock.frames + frame)
            let value = amplitude * Float(sin(2 * .pi * frequency * n / 48_000))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        return AudioBlock(samples: samples, captureNanos: UInt64(block) * AudioBlock.nanosPerBlock)
    }
}

/// Runs a jitter buffer against a producer whose clock runs `ratio` times the consumer's, in
/// 5 ms render steps, and returns the rendered left channel.
private func simulate(_ buffer: AudioJitterBuffer, seconds: Double, ratio: Double = 1, renderFrames: Int = 240,
                      jitterEvery: Int = 0, frequency: Double = 440) -> [Float] {
    var output: [Float] = []
    var left = [Float](repeating: 0, count: renderFrames)
    var right = [Float](repeating: 0, count: renderFrames)
    var produced = 0
    var consumed = 0
    var packet = [Float](repeating: 0, count: 960)
    var held: [(Int, [Float])] = []
    let steps = Int(seconds * 48_000) / renderFrames
    for step in 0..<steps {
        consumed += renderFrames
        // Producer: packets become available on its (slightly different) clock.
        while Double(produced + 480) <= Double(consumed) * ratio + 2_400 {
            for frame in 0..<480 {
                let value = 0.5 * Float(sin(2 * .pi * frequency * Double(produced + frame) / 48_000))
                packet[frame * 2] = value
                packet[frame * 2 + 1] = value
            }
            held.append((produced, packet))
            produced += 480
        }
        // Optional network jitter: hold packets back for a few renders now and then.
        let holding = jitterEvery > 0 && step % jitterEvery < 6
        if !holding {
            for (start, samples) in held {
                samples.withUnsafeBufferPointer {
                    buffer.push($0, channels: 2, captureNanos: UInt64(Double(start) / 48_000 * 1e9))
                }
            }
            held.removeAll()
        }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                buffer.render(left: l.baseAddress!, right: r.baseAddress!, frames: renderFrames)
            }
        }
        output += left
    }
    return output
}

/// Largest sample-to-sample step: a click shows up as a step far above the signal's own slope.
private func largestStep(_ samples: [Float]) -> Float {
    zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
}

// MARK: Codec and repacketizer

@Suite(.timeLimit(.minutes(1)))
struct MacAudioCodecTests {
    @Test func opusRoundTripKeepsTheToneLevel() throws {
        let encoder = try #require(OpusEncoder(bitrate: 128_000))
        let decoder = try #require(OpusDecoder(config: AudioConfig()))
        let blocks = sineBlocks(count: 100) // 1 s at −18 dBFS
        var input: [Float] = []
        var decoded: [Float] = []
        var packets = 0
        var largest = 0
        for block in blocks {
            input += block.samples
            for packet in encoder.encode(block.samples) {
                packets += 1
                largest = max(largest, packet.count)
                let pcm = try #require(decoder.decode(packet))
                // The decoder trims its own start-up (the first packet comes out 120 frames short).
                if packets > 1 { #expect(pcm.count == 960, "packet \(packets) decoded to \(pcm.count / 2) frames") }
                decoded += Array(pcm)
            }
        }
        // One packet per 10 ms block (a couple fewer while the encoder primes), 128 kbps ≈ 160 B.
        #expect(packets >= 97 && packets <= 100)
        #expect(largest < 400)
        // Skip the priming and compare levels over the steady part.
        let inputLevel = rms(input[9_600...])
        let outputLevel = rms(decoded[9_600...])
        let decibels = 20 * log10(outputLevel / inputLevel)
        #expect(abs(decibels) < 0.5, "decoded level off by \(decibels) dB")
        #expect(abs(inputLevel - 0.089) < 0.001) // −18 dBFS peak sine → −21 dBFS RMS
    }

    @Test func decoderRejectsWhatItCannotPlay() {
        #expect(OpusDecoder(config: AudioConfig(codec: "lyra")) == nil)
        #expect(OpusDecoder(config: .unavailable("No permission")) == nil)
        #expect(OpusDecoder(config: AudioConfig(channels: 6)) == nil)
        let decoder = OpusDecoder(config: AudioConfig())
        #expect(decoder?.decode(Data()) == nil)
    }

    @Test func repacketizerMakesFixedTenMillisecondBlocks() {
        var repacketizer = AudioRepacketizer()
        var blocks: [AudioBlock] = []
        var frame = 0
        // Odd callback sizes, planar like ScreenCaptureKit.
        for size in [100, 1_024, 7, 960, 441, 2_000, 333] {
            let left = (0..<size).map { Float(frame + $0) }
            let right = left.map { -$0 }
            let nanos = UInt64(frame) * 1_000_000_000 / 48_000
            left.withUnsafeBufferPointer { l in
                right.withUnsafeBufferPointer { r in
                    blocks += repacketizer.append(planar: [l, r], startNanos: 1_000_000 + nanos)
                }
            }
            frame += size
        }
        #expect(blocks.count == frame / 480)
        #expect(blocks.allSatisfy { $0.samples.count == 960 })
        for (index, block) in blocks.enumerated() {
            #expect(block.captureNanos == 1_000_000 + UInt64(index) * 10_000_000)
            #expect(block.samples[0] == Float(index * 480))  // left, interleaved
            #expect(block.samples[1] == -Float(index * 480)) // right
            #expect(block.samples[958] == Float(index * 480 + 479))
        }

        // A jump in time finishes the partial block with silence and starts a new timeline.
        var fresh = AudioRepacketizer()
        let chunk = [Float](repeating: 0.5, count: 300 * 2)
        chunk.withUnsafeBufferPointer { #expect(fresh.append(interleaved: $0, startNanos: 0).isEmpty) }
        let resumed = chunk.withUnsafeBufferPointer { fresh.append(interleaved: $0, startNanos: 500_000_000) }
        #expect(resumed.count == 1)
        #expect(resumed.first?.captureNanos == 0)
        #expect(resumed.first?.samples[599] == 0.5 && resumed.first?.samples[600] == 0)
        let next = chunk.withUnsafeBufferPointer { fresh.append(interleaved: $0, startNanos: 506_250_000) }
        #expect(next.first?.captureNanos == 500_000_000)
    }

    @Test func chimeIsQuietAndPeriodic() {
        var synth = ChimeSynth()
        var samples = [Float](repeating: 0, count: 96_000 * 2)
        samples.withUnsafeMutableBufferPointer { synth.render(into: $0, frames: 96_000) }
        let peak = samples.map(abs).max() ?? 0
        #expect(peak <= ChimeSynth.peak + 0.000_1)
        #expect(peak > ChimeSynth.peak * 0.8)
        #expect(rms(samples[0..<4_800]) > 0.02)            // the first note rings…
        #expect(rms(samples[(90_000 * 2)..<(96_000 * 2)]) < 0.000_1) // …and it's silent before the next chime
        #expect(largestStep(Array(samples.enumerated().filter { $0.offset % 2 == 0 }.map(\.element))) < 0.03)
    }
}

// MARK: Jitter buffer

@Suite(.timeLimit(.minutes(1)))
struct AudioJitterBufferTests {
    @Test func startsOnlyOnceTheTargetIsBuffered() {
        let buffer = AudioJitterBuffer()
        var left = [Float](repeating: 1, count: 240), right = left
        let packet = [Float](repeating: 0.25, count: 960)
        for index in 0..<4 { // 40 ms < 50 ms target
            packet.withUnsafeBufferPointer { buffer.push($0, channels: 2, captureNanos: UInt64(index) * 10_000_000) }
        }
        buffer.render(left: &left, right: &right, frames: 240)
        #expect(left.allSatisfy { $0 == 0 })
        #expect(!buffer.stats.isPlaying)
        packet.withUnsafeBufferPointer { buffer.push($0, channels: 2, captureNanos: 40_000_000) }
        buffer.render(left: &left, right: &right, frames: 240)
        #expect(buffer.stats.isPlaying)
        #expect(left[0] < 0.01)          // fades in…
        #expect(left[239] == 0.25)       // …within 5 ms
        #expect(buffer.stats.depthFrames == 2_400 - 240)
    }

    @Test func steadyStreamPlaysWithoutUnderrunsOrCorrections() {
        let buffer = AudioJitterBuffer()
        let output = simulate(buffer, seconds: 20)
        let stats = buffer.stats
        #expect(stats.underruns == 0)
        #expect(stats.idleGaps == 0)
        #expect(stats.skips == 0)
        #expect(stats.drops + stats.duplicates <= 2)
        #expect(largestStep(Array(output[4_800...])) < 0.03) // 440 Hz at 0.5 moves ≤ 0.029 per sample
    }

    @Test func lateUnderrunFadesAndRaisesTheTarget() {
        let buffer = AudioJitterBuffer()
        var output: [Float] = []
        var left = [Float](repeating: 0, count: 240), right = left
        var produced = 0
        func push(_ packets: Int) {
            for _ in 0..<packets {
                var packet = [Float](repeating: 0, count: 960)
                for frame in 0..<480 {
                    let value = 0.5 * Float(sin(2 * .pi * 440 * Double(produced + frame) / 48_000))
                    packet[frame * 2] = value; packet[frame * 2 + 1] = value
                }
                packet.withUnsafeBufferPointer { buffer.push($0, channels: 2, captureNanos: UInt64(produced) * 1_000_000_000 / 48_000) }
                produced += 480
            }
        }
        func render(_ count: Int) {
            for _ in 0..<count {
                buffer.render(left: &left, right: &right, frames: 240)
                output += left
            }
        }
        push(6)       // 60 ms
        render(20)    // 100 ms: plays out and runs dry
        #expect(!buffer.stats.isPlaying)
        #expect(largestStep(output) < 0.03)       // faded, no click
        #expect(output.suffix(240).allSatisfy { $0 == 0 })
        push(10)      // the late packets continue the timeline: the network's fault
        #expect(buffer.stats.underruns == 1)
        render(1)
        #expect(buffer.stats.targetFrames == 2_400 + 480) // 50 → 60 ms

        // A pause on the host (its timeline jumps) is not the network's fault.
        render(40)
        #expect(!buffer.stats.isPlaying)
        produced += 48_000 // one second later
        push(8)
        #expect(buffer.stats.underruns == 1)
        #expect(buffer.stats.idleGaps == 1)
    }

    @Test(arguments: [1.001, 0.999])
    func clockDriftIsAbsorbedWithoutUnderruns(ratio: Double) {
        let buffer = AudioJitterBuffer()
        let output = simulate(buffer, seconds: 60, ratio: ratio)
        let stats = buffer.stats
        #expect(stats.underruns == 0)
        #expect(stats.skips == 0)
        // 0.1% of 48 kHz is 48 frames/s: corrections must keep pace.
        if ratio > 1 { #expect(stats.drops > 1_500) } else { #expect(stats.duplicates > 1_500) }
        let depthMs = stats.milliseconds(stats.depthFrames)
        #expect(abs(depthMs - stats.milliseconds(stats.targetFrames)) < 30, "depth \(depthMs) ms")
        #expect(largestStep(Array(output[4_800...])) < 0.03)
    }

    @Test func burstAfterAStallIsCutBackToTheTarget() {
        let buffer = AudioJitterBuffer()
        _ = simulate(buffer, seconds: 1)
        // 300 ms arrive at once (queued behind a video keyframe).
        let packet = [Float](repeating: 0.1, count: 960)
        for index in 0..<30 {
            packet.withUnsafeBufferPointer { buffer.push($0, channels: 2, captureNanos: UInt64(2_000 + index) * 10_000_000) }
        }
        var left = [Float](repeating: 0, count: 240), right = left
        buffer.render(left: &left, right: &right, frames: 240)
        let stats = buffer.stats
        #expect(stats.skips == 1)
        #expect(stats.milliseconds(stats.depthFrames) <= stats.milliseconds(stats.targetFrames) + 1)
        #expect(largestStep(left) < 0.05)
    }

    @Test func backlogBeforePlaybackStartsAtTheTargetWithoutASkip() {
        // 300 ms buffered before anything plays: playback starts `target` behind the newest
        // audio, fading in from silence, and carries on from there without a jump.
        let buffer = AudioJitterBuffer()
        var packet = [Float](repeating: 0, count: 960)
        func value(_ frame: Int) -> Float { Float(frame) / 100_000 } // a ramp: each sample says where it's from
        for index in 0..<30 {
            for frame in 0..<480 {
                packet[frame * 2] = value(index * 480 + frame)
                packet[frame * 2 + 1] = value(index * 480 + frame)
            }
            packet.withUnsafeBufferPointer { buffer.push($0, channels: 2, captureNanos: UInt64(index) * 10_000_000) }
        }
        var left = [Float](repeating: 0, count: 240), right = left
        buffer.render(left: &left, right: &right, frames: 240)
        let stats = buffer.stats
        #expect(stats.isPlaying)
        #expect(stats.skips == 0)
        #expect(stats.startTrims == 1)
        #expect(stats.depthFrames == stats.targetFrames)
        let first = 14_400 - stats.targetFrames - 240
        #expect(left[0] < value(first) * 0.01)   // fades in…
        #expect(left[239] == value(first + 239)) // …from where it starts
        buffer.render(left: &left, right: &right, frames: 240)
        #expect(left[0] == value(first + 240))   // and goes straight on
        #expect(buffer.stats.skips == 0)
    }

    @Test func jitteryNetworkSettlesWithinTheBand() {
        // Packets held back 30 ms every half second: the target grows until they stop underrunning.
        let buffer = AudioJitterBuffer()
        _ = simulate(buffer, seconds: 30, jitterEvery: 100)
        let stats = buffer.stats
        #expect(stats.milliseconds(stats.targetFrames) <= 80)
        #expect(stats.underruns <= 3)
    }

    @Test func resetEmptiesAndRebuffers() {
        let buffer = AudioJitterBuffer()
        _ = simulate(buffer, seconds: 1)
        #expect(buffer.stats.isPlaying)
        buffer.reset()
        var left = [Float](repeating: 1, count: 240), right = left
        buffer.render(left: &left, right: &right, frames: 240)
        #expect(!buffer.stats.isPlaying)
        #expect(left.allSatisfy { $0 == 0 })
        #expect(buffer.stats.depthFrames == 0)
    }
}

// MARK: Loopback

private enum AudioTestFailure: Error { case unexpectedMessage, timedOut }

/// A one-connection loopback host with the given capabilities that answers `audioRequest` the
/// way `HostSession` does: `audioConfig`, then the synthetic chime through the real encoder.
private func audioHost(capabilities: HostCapabilities,
                       then body: @escaping @Sendable (MessageChannel, Hello) async throws -> Void) async throws -> (NWListener, Task<Void, any Error>) {
    let listener = try NWListener(using: VantageNetwork.tcpParameters(), on: .any)
    let channels = AsyncStream<MessageChannel> { continuation in
        listener.newConnectionHandler = { continuation.yield(MessageChannel(connection: $0)) }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        listener.stateUpdateHandler = { state in
            if case .ready = state { listener.stateUpdateHandler = nil; continuation.resume() }
            else if case .failed(let error) = state { listener.stateUpdateHandler = nil; continuation.resume(throwing: error) }
        }
        listener.start(queue: .global())
    }
    let server = Task {
        var iterator = channels.makeAsyncIterator()
        guard let channel = await iterator.next() else { throw AudioTestFailure.unexpectedMessage }
        try await channel.start()
        guard case .hello(let hello)? = try await channel.receive() else { throw AudioTestFailure.unexpectedMessage }
        try await channel.send(.challenge(Challenge(hostName: "Test Mac", hostVersion: "1.0", hostPublicKey: DeviceIdentity().publicKeyData,
                                                    nonce: AuthTranscript.randomNonce(), isPaired: true)))
        guard case .authenticate? = try await channel.receive() else { throw AudioTestFailure.unexpectedMessage }
        try await channel.send(.authResult(AuthResult(status: .ok, displays: [], capabilities: capabilities)))
        guard case .selectDisplay? = try await channel.receive() else { throw AudioTestFailure.unexpectedMessage }
        try await body(channel, hello)
        await channel.close()
    }
    return (listener, server)
}

@MainActor
private func waitUntil(seconds: Double = 10, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw AudioTestFailure.timedOut }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct MacAudioSessionTests {
    @Test @MainActor func requestedAudioArrivesAsConfigThenOrderedPackets() async throws {
        let capabilities = HostCapabilities(codecs: [.hevc], canManageVirtualDisplay: false, clipboard: true, maxFPS: 60, audio: true)
        let (listener, server) = try await audioHost(capabilities: capabilities) { channel, hello in
            #expect(hello.features?.macAudio == true)
            guard case .audioRequest(let request)? = try await channel.receive() else { throw AudioTestFailure.unexpectedMessage }
            #expect(request.enabled)
            let source = SyntheticAudioSource()
            let encoder = try #require(AudioEncoder { packet in channel.sendDetached(.audioPacket(packet)) })
            try await channel.send(.audioConfig(encoder.config))
            try await source.start(onBlock: { encoder.encode($0) }, onStop: { _ in })
            guard case .audioRequest(let stop)? = try await channel.receive() else { throw AudioTestFailure.unexpectedMessage }
            #expect(!stop.enabled)
            await source.stop()
            let next = try await channel.receive()
            #expect(next == nil)
        }
        defer { listener.cancel() }

        let session = ClientSession(identity: DeviceIdentity())
        defer { session.disconnect() }
        var config: AudioConfig?
        var packets: [AudioPacket] = []
        var arrivals: [UInt64] = []
        session.onAudio = { message in
            switch message {
            case .audioConfig(let value):
                #expect(packets.isEmpty, "config must come first")
                config = value
            case .audioPacket(let packet):
                packets.append(packet)
                arrivals.append(DispatchTime.now().uptimeNanoseconds)
            default: break
            }
        }
        session.setMacAudio(true) // asked for before connecting: sent once the host says it can
        session.connect(to: SavedDevice(name: "Test Mac", host: "127.0.0.1", port: listener.port!.rawValue),
                        viewport: Viewport(widthPoints: 800, heightPoints: 600, scale: 2))
        try await waitUntil { session.state == .connected }
        #expect(session.hostOffersAudio)
        try await waitUntil { packets.count >= 250 } // 2.5 s: one full chime period and more
        session.setMacAudio(false)

        let received = try #require(config)
        #expect(received.codec == "opus" && received.framesPerPacket == 480 && received.sampleRate == 48_000 && received.channels == 2)
        #expect(packets.map(\.sequence) == Array(0..<UInt64(packets.count)))
        #expect(packets.allSatisfy { $0.frameCount == 480 && !$0.data.isEmpty })
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $1.captureNanos > $0.captureNanos })

        // Decode and play it through the jitter buffer: the chime comes out at its level.
        let decoder = try #require(OpusDecoder(config: received))
        let buffer = AudioJitterBuffer()
        var played: [Float] = []
        var left = [Float](repeating: 0, count: 240), right = left
        for packet in packets {
            let pcm = try #require(decoder.decode(packet.data))
            buffer.push(pcm, channels: 2, captureNanos: packet.captureNanos)
            for _ in 0..<2 {
                buffer.render(left: &left, right: &right, frames: 240)
                played += left
            }
        }
        #expect(buffer.stats.underruns == 0)
        let peak = played.map(abs).max() ?? 0
        #expect(peak > 0.08 && peak < 0.16, "peak \(peak)")

        // Same clock on loopback: how long a packet took from capture to the client.
        let transit = zip(packets, arrivals).map { Double($1 &- $0.captureNanos) / 1e6 }.sorted()
        print("loopback audio transit (capture → client): p50 \(transit[transit.count / 2]) ms, p95 \(transit[transit.count * 95 / 100]) ms, max \(transit.last!) ms")
        session.disconnect()
        try await server.value
    }

    @Test @MainActor func olderHostNeverSeesAudioRequest() async throws {
        let old = HostCapabilities(codecs: [.hevc], canManageVirtualDisplay: false, clipboard: true, maxFPS: 60)
        let (listener, server) = try await audioHost(capabilities: old) { channel, _ in
            // The client must not send anything the older host can't decode.
            let next = try await channel.receive()
            #expect(next == nil)
        }
        defer { listener.cancel() }
        let session = ClientSession(identity: DeviceIdentity())
        session.setMacAudio(true)
        session.connect(to: SavedDevice(name: "Old Mac", host: "127.0.0.1", port: listener.port!.rawValue),
                        viewport: Viewport(widthPoints: 800, heightPoints: 600, scale: 2))
        try await waitUntil { session.state == .connected }
        #expect(!session.hostOffersAudio)
        session.setMacAudio(true)
        try await Task.sleep(for: .milliseconds(200))
        session.disconnect()
        try await server.value
    }
}

import CoreVideo
import Testing
@testable import VantageSynthetic

/// Exercise simultaneous clocks/frames without AppKit's shared string-drawing state.
@Test(.timeLimit(.minutes(1))) func concurrentSyntheticStreamsKeepRendering() async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
            group.addTask {
                let source = SyntheticFrameSource(pixelWidth: 320, pixelHeight: 240, fps: 240)
                let (frames, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
                try await source.start(onFrame: { frame in
                    continuation.yield(CVPixelBufferGetWidth(frame.pixelBuffer) == 320 &&
                                       CVPixelBufferGetHeight(frame.pixelBuffer) == 240)
                }, onStop: { _ in continuation.finish() })
                var count = 0
                for await validSize in frames {
                    #expect(validSize)
                    count += 1
                    if count == 500 { break }
                }
                await source.stop()
                continuation.finish()
                #expect(count == 500)
            }
        }
        try await group.waitForAll()
    }
}

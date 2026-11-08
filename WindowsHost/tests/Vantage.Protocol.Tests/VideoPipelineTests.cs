using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Time.Testing;
using Vantage.Protocol.Adaptive;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Transport;
using Vantage.SyntheticHost;

namespace Vantage.Protocol.Tests;

/// <summary>The frame → wire pipeline on a fake encoder and clock; the listener and HEVC session tests cover it end to end.</summary>
public class VideoPipelineTests
{
    private static readonly byte[] s_sps = [0x67, 0x64, 0x00, 0x28], s_pps = [0x68, 0xEE, 0x3C], s_idr = [0x65, 0x88, 0x84, 0x00, 0x21], s_slice = [0x41, 0x9A, 0x02];

    private static byte[] AnnexB(params byte[][] units) => [.. units.SelectMany(unit => (byte[])[0, 0, 0, 1, .. unit])];

    /// <summary>Lets everything the last call posted (and what that posted) run.</summary>
    private static async Task DrainAsync(SerialQueue queue)
    {
        for (var i = 0; i < 3; i++) await queue.RunAsync(() => Task.CompletedTask);
    }

    [Fact]
    public async Task AnEncodeThatNeverReportsBackIsGivenUpOnAndAKeyframeForced()
    {
        var clock = new FakeTimeProvider();
        var queue = new SerialQueue(NullLogger.Instance);
        var encoder = new LosingEncoder { LoseEncode = 1 };
        var lane = new RecordingLane();
        var pipeline = new VideoPipeline(encoder, new FakeCapture(), VideoCodec.H264, targetFps: 60, new AdaptiveController(20_000, clock), lane, queue, clock,
                                         firstSequence: 7, _ => Task.CompletedTask, NullLogger.Instance);
        pipeline.Start();
        try
        {
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(1)));
            await DrainAsync(queue);
            Assert.Equal([true], encoder.Forced);
            Assert.IsType<VideoConfig>(lane.Posted[0]);
            var first = Assert.IsType<VideoFrame>(lane.Posted[1]);
            Assert.True(first.IsKeyframe);
            Assert.Equal(7UL, first.Sequence);

            // The second encode is lost inside the encoder; the third frame waits behind it.
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(2)));
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(3)));
            await DrainAsync(queue);
            Assert.Equal([true, false], encoder.Forced);
            Assert.Equal(2, lane.Posted.Count); // without the stall rule this would be the picture's last frame

            clock.Advance(VideoPipeline.EncodeStallLimit);
            await DrainAsync(queue);
            Assert.Equal([true, false, true], encoder.Forced); // given up on, and the latest frame re-encoded as an IDR
            var recovered = Assert.IsType<VideoFrame>(lane.Posted[^1]);
            Assert.True(recovered.IsKeyframe);
            Assert.Equal(8UL, recovered.Sequence);
            Assert.Equal(3, lane.Posted.Count); // the same parameter sets: no second videoConfig

            // One in flight again, so the next frame encodes at once.
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(4)));
            await DrainAsync(queue);
            Assert.Equal([true, false, true, false], encoder.Forced);
            Assert.False(Assert.IsType<VideoFrame>(lane.Posted[^1]).IsKeyframe);
        }
        finally
        {
            await queue.RunAsync(() => pipeline.DisposeAsync().AsTask());
            queue.Complete();
        }
    }

    /// <summary>Reports every encode at once, except the one at <see cref="LoseEncode"/>, which it never reports.</summary>
    private sealed class LosingEncoder : IVideoEncoder
    {
        private IEncodedFrameSink? _sink;
        public readonly List<bool> Forced = [];
        public int LoseEncode = -1;

        public void Start(IEncodedFrameSink sink) => _sink = sink;

        public ValueTask EncodeAsync(ICapturedFrame frame, bool forceKeyframe, CancellationToken cancellationToken)
        {
            var index = Forced.Count;
            Forced.Add(forceKeyframe);
            if (index == LoseEncode) return ValueTask.CompletedTask;
            _sink!.OnFrame(new EncodedFrame
            {
                Data = forceKeyframe ? AnnexB(s_sps, s_pps, s_idr) : AnnexB(s_slice),
                Format = NalFormat.AnnexB,
                IsKeyframe = forceKeyframe,
                CaptureNanos = frame.TimestampNanos,
                Width = 64,
                Height = 64,
            });
            return ValueTask.CompletedTask;
        }

        public void SetBitrate(int kbps)
        {
        }

        public void SetFrameRate(int fps)
        {
        }

        public void SetMaxQP(int maxQP)
        {
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class RecordingLane : IVideoLane
    {
        public readonly List<IMessage> Posted = [];
        public bool IsVideoBacklogged => false;

        public bool PostVideo(IMessage message, bool droppable)
        {
            Posted.Add(message);
            return true;
        }
    }

    private sealed class FakeCapture : ICaptureStream
    {
        public DisplayInfo Display => FakeDisplay.Info;
        public int FrameWidth => 64;
        public int FrameHeight => 64;

        public void SetFrameRate(int fps)
        {
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private sealed class Frame(ulong nanos) : ICapturedFrame
    {
        public ulong TimestampNanos => nanos;
        public double DirtyRatio => 1;
        public int Width => 64;
        public int Height => 64;

        public void Dispose()
        {
        }
    }
}

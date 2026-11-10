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

    private static (VideoPipeline Pipeline, ScriptedEncoder Encoder, RecordingLane Lane, SerialQueue Queue, FakeTimeProvider Clock) Started()
    {
        var clock = new FakeTimeProvider();
        var queue = new SerialQueue(NullLogger.Instance);
        var encoder = new ScriptedEncoder();
        var lane = new RecordingLane();
        var pipeline = new VideoPipeline(encoder, new FakeCapture(), VideoCodec.H264, targetFps: 60, new AdaptiveController(20_000, clock), lane, queue, clock,
                                         firstSequence: 7, _ => Task.CompletedTask, NullLogger.Instance);
        pipeline.Start();
        return (pipeline, encoder, lane, queue, clock);
    }

    private static async Task StopAsync(VideoPipeline pipeline, SerialQueue queue)
    {
        await queue.RunAsync(() => pipeline.DisposeAsync().AsTask());
        queue.Complete();
    }

    [Fact]
    public async Task AnEncodeThatNeverReportsBackIsGivenUpOnAndAKeyframeForced()
    {
        var (pipeline, encoder, lane, queue, clock) = Started();
        encoder.Hold.Add(1);
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
            await StopAsync(pipeline, queue);
        }
    }

    [Fact]
    public async Task ALateAnswerFromAnEncodeGivenUpOnLeavesItsReplacementAlone()
    {
        var (pipeline, encoder, lane, queue, clock) = Started();
        encoder.Hold.Add(1); // A, which the encoder sits on
        encoder.Hold.Add(2); // B, its replacement, still in flight when A answers late
        try
        {
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(1)));
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(2)));
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(3)));
            await DrainAsync(queue);
            clock.Advance(VideoPipeline.EncodeStallLimit);
            await DrainAsync(queue);
            Assert.Equal([true, false, true], encoder.Forced); // A given up on, B started as an IDR
            Assert.Equal(2, lane.Posted.Count);

            // A answers after all (Media Foundation reports an abandoned input about a second later): nothing moves.
            encoder.Answer(1);
            await DrainAsync(queue);
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(4)));
            await DrainAsync(queue);
            Assert.Equal(3, encoder.Forced.Count); // no third encode beside B
            Assert.Equal(2, lane.Posted.Count); // A's late frame never reaches the wire

            // B is still watched: with no answer of its own it is given up on in turn.
            clock.Advance(VideoPipeline.EncodeStallLimit);
            await DrainAsync(queue);
            Assert.Equal([true, false, true, true], encoder.Forced);
            Assert.Equal(3, lane.Posted.Count);
            Assert.True(Assert.IsType<VideoFrame>(lane.Posted[^1]).IsKeyframe);
        }
        finally
        {
            await StopAsync(pipeline, queue);
        }
    }

    [Fact]
    public async Task AnEncodeThatNeverAnswersCostsOneStallAndNothingAfter()
    {
        var (pipeline, encoder, lane, queue, clock) = Started();
        encoder.Hold.Add(1);
        try
        {
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(1)));
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(2)));
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(3)));
            await DrainAsync(queue);
            clock.Advance(VideoPipeline.EncodeStallLimit);
            await DrainAsync(queue);
            Assert.Equal([true, false, true], encoder.Forced);
            Assert.Equal(3, lane.Posted.Count);

            // Ten frames over several stall limits: each is encoded as it comes, none forced, no stall.
            for (var i = 0; i < 10; i++)
            {
                clock.Advance(TimeSpan.FromMilliseconds(400));
                await queue.RunAsync(() => pipeline.IngestAsync(new Frame(10 + (ulong)i)));
                await DrainAsync(queue);
                Assert.Equal(4 + i, encoder.Forced.Count);
                Assert.False(encoder.Forced[^1]);
                Assert.Equal(4 + i, lane.Posted.Count);
            }
        }
        finally
        {
            await StopAsync(pipeline, queue);
        }
    }

    [Fact]
    public async Task AStallTimeoutQueuedBehindTheAnswerDoesNotAbandonTheNextEncode()
    {
        var (pipeline, encoder, lane, queue, clock) = Started();
        encoder.Hold.Add(1); // A
        encoder.Hold.Add(2); // B
        try
        {
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(1)));
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(2)));
            await queue.RunAsync(() => pipeline.IngestAsync(new Frame(3)));
            await DrainAsync(queue);
            Assert.Equal([true, false], encoder.Forced);

            // The session queue is busy: A's answer and then A's stall timeout line up behind it.
            var busy = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            queue.Post(() => busy.Task);
            clock.Advance(TimeSpan.FromMilliseconds(900));
            encoder.Answer(1);
            clock.Advance(TimeSpan.FromMilliseconds(100)); // A's timer fires at the limit, after the answer was already queued
            busy.SetResult();
            await DrainAsync(queue);

            // A's frame went out and B started; the stale timeout left B alone.
            Assert.Equal([true, false, false], encoder.Forced);
            Assert.Equal(3, lane.Posted.Count);
            clock.Advance(TimeSpan.FromMilliseconds(500));
            await DrainAsync(queue);
            Assert.Equal(3, encoder.Forced.Count);

            // B keeps its own full limit, counted from when it started.
            clock.Advance(TimeSpan.FromMilliseconds(500));
            await DrainAsync(queue);
            Assert.Equal([true, false, false, true], encoder.Forced);
        }
        finally
        {
            await StopAsync(pipeline, queue);
        }
    }

    /// <summary>Answers every encode at once, except those whose index is in <see cref="Hold"/>, which wait for <see cref="Answer"/>.</summary>
    private sealed class ScriptedEncoder : IVideoEncoder
    {
        private IEncodedFrameSink? _sink;
        private readonly List<(long Id, EncodedFrame Output)> _encodes = [];
        public readonly List<bool> Forced = [];
        public readonly HashSet<int> Hold = [];

        public void Start(IEncodedFrameSink sink) => _sink = sink;

        public ValueTask EncodeAsync(ICapturedFrame frame, bool forceKeyframe, long encodeId, CancellationToken cancellationToken)
        {
            var index = Forced.Count;
            Forced.Add(forceKeyframe);
            var output = new EncodedFrame
            {
                Data = forceKeyframe ? AnnexB(s_sps, s_pps, s_idr) : AnnexB(s_slice),
                Format = NalFormat.AnnexB,
                IsKeyframe = forceKeyframe,
                CaptureNanos = frame.TimestampNanos,
                Width = 64,
                Height = 64,
            };
            _encodes.Add((encodeId, output));
            if (!Hold.Contains(index)) Answer(index);
            return ValueTask.CompletedTask;
        }

        /// <summary>Delivers the output of the encode at <paramref name="index"/> (in the order encodes were asked for).</summary>
        public void Answer(int index) => _sink!.OnFrame(_encodes[index].Id, _encodes[index].Output);

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

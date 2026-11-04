using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Video;
using Vantage.SyntheticHost;

namespace Vantage.Protocol.Tests;

/// <summary>Hand-made HEVC NAL units: a two-byte header with the type in bits 1–6, then a payload byte or two.</summary>
internal static class HevcSamples
{
    public static byte[] Unit(int type, params byte[] payload) => [(byte)(type << 1), 0x01, .. payload];

    public static readonly byte[] Vps = Unit(HevcNalType.Vps, 0x0C, 0x01);
    public static readonly byte[] Sps = Unit(HevcNalType.Sps, 0x01, 0x01, 0x60);
    public static readonly byte[] Pps = Unit(HevcNalType.Pps, 0xC1, 0x72);
    public static readonly byte[] Aud = Unit(HevcNalType.AccessUnitDelimiter, 0x50);
    public static readonly byte[] PrefixSei = Unit(HevcNalType.PrefixSei, 0x05, 0x10);
    public static readonly byte[] SuffixSei = Unit(HevcNalType.SuffixSei, 0x81);
    /// <summary>An IDR_W_RADL slice with <c>first_slice_segment_in_pic_flag</c> set.</summary>
    public static readonly byte[] Idr = Unit(HevcNalType.IdrWRadl, 0xAF, 0x08, 0x40);
    /// <summary>A TRAIL_R slice (type 1) starting a picture.</summary>
    public static readonly byte[] Trail = Unit(1, 0xD0, 0x22);
    /// <summary>A second slice segment of the same picture (flag clear).</summary>
    public static readonly byte[] TrailMore = Unit(1, 0x40, 0x23);

    public static byte[] AnnexB(params byte[][] units)
    {
        var data = new List<byte>();
        foreach (var unit in units) data.AddRange([0, 0, 0, 1, .. unit]);
        return [.. data];
    }
}

public class HevcVideoTests
{
    [Fact]
    public void HevcTypesComeFromBitsOneToSix()
    {
        Assert.Equal(32, HevcNalType.Of(HevcSamples.Vps));
        Assert.Equal(33, HevcNalType.Of(HevcSamples.Sps));
        Assert.Equal(34, HevcNalType.Of(HevcSamples.Pps));
        Assert.Equal(19, HevcNalType.Of(HevcSamples.Idr));
        Assert.Equal(20, HevcNalType.Of([0x28, 0x01]));
        Assert.Equal(21, HevcNalType.Of([0x2A, 0x01]));
        Assert.Equal(-1, HevcNalType.Of([]));
        Assert.Equal(33, NalType.Of(HevcSamples.Sps, VideoCodec.Hevc));
        Assert.Equal(HevcSamples.Sps[0] & 0x1F, NalType.Of(HevcSamples.Sps, VideoCodec.H264));
        Assert.True(HevcNalType.IsRandomAccess(HevcNalType.IdrWRadl));
        Assert.True(HevcNalType.IsRandomAccess(HevcNalType.IdrNLp));
        Assert.True(HevcNalType.IsRandomAccess(HevcNalType.Cra));
        Assert.False(HevcNalType.IsRandomAccess(1));
        Assert.False(HevcNalType.IsRandomAccess(HevcNalType.Vps));
    }

    [Fact]
    public void HevcKeyframeLosesVpsSpsPpsAudAndSeiAndBecomesHvcc()
    {
        var annexB = HevcSamples.AnnexB(HevcSamples.Aud, HevcSamples.Vps, HevcSamples.Sps, HevcSamples.Pps, HevcSamples.PrefixSei,
                                        HevcSamples.Idr, HevcSamples.SuffixSei);
        var au = AnnexB.ToAccessUnit(annexB, VideoCodec.Hevc);
        Assert.True(au.IsKeyframe);
        Assert.Equal(HevcSamples.Vps, au.Vps);
        Assert.Equal(HevcSamples.Sps, au.Sps);
        Assert.Equal(HevcSamples.Pps, au.Pps);
        Assert.Equal([0, 0, 0, (byte)HevcSamples.Idr.Length, .. HevcSamples.Idr], au.Avcc);
        Assert.Equal([HevcSamples.Vps, HevcSamples.Sps, HevcSamples.Pps], au.ParameterSets(VideoCodec.Hevc));
        Assert.True(AnnexB.AvccHasIdr(au.Avcc, VideoCodec.Hevc));

        var kept = AnnexB.ToAccessUnit(annexB, VideoCodec.Hevc, keepSei: true);
        Assert.Equal(3, AnnexB.SplitAvcc(kept.Avcc).Count);
    }

    [Fact]
    public void HevcPFrameIsNoKeyframeAndAnIncompleteSetIsNoConfig()
    {
        var p = AnnexB.ToAccessUnit(HevcSamples.AnnexB(HevcSamples.Trail, HevcSamples.TrailMore), VideoCodec.Hevc);
        Assert.False(p.IsKeyframe);
        Assert.Null(p.ParameterSets(VideoCodec.Hevc));
        Assert.False(AnnexB.AvccHasIdr(p.Avcc, VideoCodec.Hevc));
        Assert.Equal(2, AnnexB.SplitAvcc(p.Avcc).Count);

        var noVps = AnnexB.ToAccessUnit(HevcSamples.AnnexB(HevcSamples.Sps, HevcSamples.Pps, HevcSamples.Idr), VideoCodec.Hevc);
        Assert.True(noVps.IsKeyframe);
        Assert.Null(noVps.ParameterSets(VideoCodec.Hevc)); // HEVC needs all three
        Assert.NotNull(noVps.ParameterSets(VideoCodec.H264));
    }

    [Fact]
    public void HevcCraCountsAsAKeyframe()
    {
        var cra = HevcSamples.Unit(HevcNalType.Cra, 0xAF, 0x01);
        var au = AnnexB.FromUnits([HevcSamples.Vps, HevcSamples.Sps, HevcSamples.Pps, cra], VideoCodec.Hevc);
        Assert.True(au.IsKeyframe);
        Assert.Equal(3, au.ParameterSets(VideoCodec.Hevc)!.Length);
    }

    [Fact]
    public void HevcStreamSplitsIntoAccessUnitsAtParameterSetsAndFirstSlices()
    {
        var stream = HevcSamples.AnnexB(HevcSamples.Vps, HevcSamples.Sps, HevcSamples.Pps, HevcSamples.Idr,
                                        HevcSamples.Trail, HevcSamples.TrailMore,
                                        HevcSamples.Trail,
                                        HevcSamples.Aud, HevcSamples.Trail);
        var units = AnnexB.SplitAccessUnits(stream, VideoCodec.Hevc);
        Assert.Equal(4, units.Count);
        Assert.True(AnnexB.ToAccessUnit(units[0], VideoCodec.Hevc).IsKeyframe);
        Assert.Equal(2, AnnexB.SplitNalUnits(units[1]).Count);
        Assert.Single(AnnexB.SplitNalUnits(units[2]));
        Assert.Equal(2, AnnexB.SplitNalUnits(units[3]).Count); // AUD + slice
    }

    [Fact]
    public void TheH264OverloadsStayH264()
    {
        // The same bytes read as H.264: no IDR (type 5) in sight, so no keyframe and nothing pulled out.
        var annexB = HevcSamples.AnnexB(HevcSamples.Vps, HevcSamples.Sps, HevcSamples.Pps, HevcSamples.Idr);
        var plain = AnnexB.ToAccessUnit(annexB);
        var named = AnnexB.ToAccessUnit(annexB, VideoCodec.H264);
        Assert.False(plain.IsKeyframe);
        Assert.Null(plain.Vps);
        Assert.Equal(plain.Avcc, named.Avcc);
        Assert.Equal(plain.IsKeyframe, named.IsKeyframe);
        Assert.Equal(AnnexB.SplitAccessUnits(annexB).Count, AnnexB.SplitAccessUnits(annexB, VideoCodec.H264).Count);
    }

    [Theory]
    [InlineData(VideoCodec.Hevc, new[] { VideoCodec.Hevc, VideoCodec.H264 }, VideoCodec.Hevc)]
    [InlineData(VideoCodec.H264, new[] { VideoCodec.Hevc, VideoCodec.H264 }, VideoCodec.H264)]
    [InlineData(null, new[] { VideoCodec.Hevc, VideoCodec.H264 }, VideoCodec.Hevc)] // the Mac's preferredCodec ?? .hevc
    [InlineData(VideoCodec.Hevc, new[] { VideoCodec.H264 }, VideoCodec.H264)]
    [InlineData(null, new[] { VideoCodec.H264 }, VideoCodec.H264)]
    [InlineData(VideoCodec.H264, new[] { VideoCodec.Hevc }, VideoCodec.Hevc)] // --codec hevc
    public void CodecChoiceHonoursThePreferenceWhenTheHostHasIt(VideoCodec? preferred, VideoCodec[] host, VideoCodec expected) =>
        Assert.Equal(expected, HostSessionCore.ChooseCodec(preferred, host, [VideoCodec.Hevc, VideoCodec.H264]));

    [Fact]
    public void CodecChoiceNeverPicksWhatTheClientCantDecode()
    {
        Assert.Equal(VideoCodec.H264, HostSessionCore.ChooseCodec(VideoCodec.Hevc, [VideoCodec.Hevc, VideoCodec.H264], [VideoCodec.H264]));
        Assert.Equal(VideoCodec.H264, HostSessionCore.ChooseCodec(null, [VideoCodec.Hevc, VideoCodec.H264], [VideoCodec.H264]));
        Assert.Equal(VideoCodec.Hevc, HostSessionCore.ChooseCodec(null, [VideoCodec.Hevc, VideoCodec.H264], []));
    }
}

/// <summary>
/// A host that offers <c>[hevc, h264]</c>: HEVC frames are hand-made (an IDR with VPS/SPS/PPS, then
/// TRAIL_R slices), H.264 comes from the test clip, and HEVC can be made to fail like a GPU without one.
/// </summary>
internal sealed class HevcEncoderFactory(Clip clip, bool hevcFails = false) : IVideoEncoderFactory
{
    private readonly ClipEncoderFactory _h264 = new(clip);
    public readonly List<VideoCodec> Created = [];

    public IReadOnlyList<VideoCodec> SupportedCodecs { get; } = [VideoCodec.Hevc, VideoCodec.H264];

    public IVideoEncoder Create(ICaptureStream source, VideoEncoderSettings settings)
    {
        lock (Created) Created.Add(settings.Codec);
        if (settings.Codec == VideoCodec.H264) return _h264.Create(source, settings);
        if (hevcFails) throw new CaptureUnavailableException("no HEVC encoder on Test GPU");
        return new Encoder(settings);
    }

    private sealed class Encoder(VideoEncoderSettings settings) : IVideoEncoder
    {
        private IEncodedFrameSink? _sink;
        private bool _started;

        public void Start(IEncodedFrameSink sink) => _sink = sink;

        public ValueTask EncodeAsync(ICapturedFrame frame, bool forceKeyframe, CancellationToken cancellationToken)
        {
            var keyframe = forceKeyframe || !_started;
            _started = true;
            var output = new EncodedFrame
            {
                Data = keyframe
                    ? HevcSamples.AnnexB(HevcSamples.Aud, HevcSamples.Vps, HevcSamples.Sps, HevcSamples.Pps, HevcSamples.PrefixSei, HevcSamples.Idr)
                    : HevcSamples.AnnexB(HevcSamples.Aud, HevcSamples.Trail),
                Format = NalFormat.AnnexB,
                IsKeyframe = keyframe,
                CaptureNanos = frame.TimestampNanos,
                Width = settings.Width,
                Height = settings.Height,
            };
            var sink = _sink;
            _ = Task.Run(() => sink?.OnFrame(output), cancellationToken);
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
}

public class HevcSessionTests
{
    private static SelectDisplay Select(VideoCodec? preferred) => new()
    {
        Selection = new DisplaySelection.FitViewport(new Viewport { WidthPoints = 1210, HeightPoints = 834, Scale = 2 }),
        TargetFPS = 60, Quality = QualityPreset.Auto, PreferredCodec = preferred, UseVirtualDisplay = false,
    };

    private static async Task<(StreamConfig Stream, VideoConfig Video, VideoFrame First, AuthResult Result)> StartAsync(TestHost host, VideoCodec? preferred)
    {
        var (connection, _, result) = await new TestClient().ConnectAsync(host.Port, "246810");
        await connection.SendAsync(Select(preferred));
        var stream = await Loopback.Next<StreamConfig>(connection);
        var video = await Loopback.Next<VideoConfig>(connection);
        var first = await Loopback.Next<VideoFrame>(connection);
        return (stream, video, first, result);
    }

    [Fact]
    public async Task AnHevcHostStreamsHevcWithVpsSpsPpsWhenTheClientPrefersIt()
    {
        await using var host = new TestHost(encoders: new HevcEncoderFactory(new Clip(VideoTests.ClipPath())));
        var (stream, video, first, result) = await StartAsync(host, VideoCodec.Hevc);
        Assert.Equal([VideoCodec.Hevc, VideoCodec.H264], result.Capabilities!.Codecs);
        Assert.Equal(VideoCodec.Hevc, stream.Codec);
        Assert.Equal(VideoCodec.Hevc, video.Codec);
        Assert.Equal(4, video.NalLengthSize);
        Assert.Equal([HevcSamples.Vps, HevcSamples.Sps, HevcSamples.Pps], video.ParameterSets);
        Assert.True(first.IsKeyframe);
        var units = AnnexB.SplitAvcc(first.Data);
        Assert.Equal([HevcNalType.IdrWRadl], units.Select(u => HevcNalType.Of(u.Span)));
    }

    [Fact]
    public async Task AnHevcHostStreamsHevcWhenTheClientStatesNoPreference()
    {
        await using var host = new TestHost(encoders: new HevcEncoderFactory(new Clip(VideoTests.ClipPath())));
        var (stream, video, _, _) = await StartAsync(host, preferred: null);
        Assert.Equal(VideoCodec.Hevc, stream.Codec);
        Assert.Equal(VideoCodec.Hevc, video.Codec);
    }

    [Fact]
    public async Task AClientThatPrefersH264GetsH264()
    {
        await using var host = new TestHost(encoders: new HevcEncoderFactory(new Clip(VideoTests.ClipPath())));
        var (stream, video, first, _) = await StartAsync(host, VideoCodec.H264);
        Assert.Equal(VideoCodec.H264, stream.Codec);
        Assert.Equal(VideoCodec.H264, video.Codec);
        Assert.Equal(2, video.ParameterSets.Count);
        Assert.True(AnnexB.AvccHasIdr(first.Data));
    }

    [Fact]
    public async Task AnHevcEncoderThatCantBeMadeFallsBackToH264()
    {
        var encoders = new HevcEncoderFactory(new Clip(VideoTests.ClipPath()), hevcFails: true);
        await using var host = new TestHost(encoders: encoders);
        var (stream, video, first, _) = await StartAsync(host, VideoCodec.Hevc);
        Assert.Equal(VideoCodec.H264, stream.Codec);
        Assert.Equal(VideoCodec.H264, video.Codec);
        Assert.True(first.IsKeyframe);
        lock (encoders.Created) Assert.Equal([VideoCodec.Hevc, VideoCodec.H264], encoders.Created);
    }
}

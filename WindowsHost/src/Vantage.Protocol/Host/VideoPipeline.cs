using Microsoft.Extensions.Logging;
using Vantage.Protocol.Adaptive;
using Vantage.Protocol.Messages;
using Vantage.Protocol.Transport;
using Vantage.Protocol.Video;

namespace Vantage.Protocol.Host;

/// <summary>
/// Captured frame → <c>videoConfig</c>/<c>videoFrame</c> on the wire, for one capture of one screen
/// session: idle suppression, adaptive frame rate and max QP, latest frame wins with one encode in
/// flight, a keyframe when one is due (stream start, <c>requestKeyframe</c>, a dropped frame, bad
/// output) and only once the lane has drained, Annex-B → AVCC/HVCC with the parameter sets pulled
/// out, <c>videoConfig</c> before an IDR whose sets changed, waiting for an IDR before any frame,
/// and P-frames dropped under backpressure.
/// </summary>
/// <remarks>
/// Everything runs on the session's <see cref="SerialQueue"/>; encoder callbacks only post onto it.
/// The encoder's contract is that every accepted encode ends in one sink call, but the pipeline
/// doesn't depend on it: an encode with no word back within <see cref="EncodeStallLimit"/> is given
/// up on and a keyframe forced, so a lost callback can never leave the picture frozen with one
/// frame "in flight" for good (which happened on the Mac). Every encode gets a number, and the sink
/// call that answers it carries that number back, so an answer from an encode already given up on
/// is recognised and dropped: it never clears the encode that replaced it, its stall timer or its
/// keyframe, and a lost answer never shifts the accounting of the answers after it. A stall timeout
/// acts only when it was armed for the encode still in flight and that encode's deadline has passed;
/// one that was already queued when the encode finished does nothing.
/// </remarks>
internal sealed class VideoPipeline : IAsyncDisposable
{
    /// <summary>An encode with no sink call within this long is treated as lost.</summary>
    public static readonly TimeSpan EncodeStallLimit = TimeSpan.FromSeconds(1);

    private readonly IVideoEncoder _encoder;
    private readonly ICaptureStream _capture;
    private readonly int _targetFps;
    private readonly AdaptiveController _adaptive;
    private readonly IVideoLane _lane;
    private readonly SerialQueue _queue;
    private readonly TimeProvider _time;
    private readonly Func<Exception, Task> _onEncoderFailed;
    private readonly ILogger _log;
    private readonly ITimer _stall;
    private ICapturedFrame? _latest;
    private bool _pendingEncode;
    private long _lastEncodeId;
    private long? _inFlight;
    private DateTimeOffset _inFlightDeadline;
    private long _stallArmedFor;
    private bool _needsKeyframe = true;
    private bool _configSent;
    private byte[][]? _lastParameterSets;
    private ulong _sequence;
    private ulong _framesSent;
    private ulong _idleSkipped;
    private int _stalls;
    private EncodingMode _loggedMode = EncodingMode.Motion;
    private int _currentFps;
    private int _currentMaxQP;
    private bool _disposed;

    /// <param name="encoder">Made for <paramref name="capture"/> and not yet started; the pipeline starts and disposes it.</param>
    /// <param name="capture">The capture the frames come from (its frame rate follows the adaptive controller).</param>
    /// <param name="codec">What <paramref name="encoder"/> produces.</param>
    /// <param name="targetFps">The device's <c>targetFPS</c>: the adaptive rate never exceeds it.</param>
    /// <param name="adaptive">The controller made for this stream, already at its starting bitrate.</param>
    /// <param name="lane">Where frames go.</param>
    /// <param name="queue">The session's queue; every method here runs on it.</param>
    /// <param name="time">Clock for the stall limit.</param>
    /// <param name="firstSequence">The next <c>videoFrame.sequence</c>; numbering continues across captures.</param>
    /// <param name="onEncoderFailed">Called on the queue when the encoder reports an error (the session restarts capture).</param>
    /// <param name="log">The session's logger.</param>
    public VideoPipeline(IVideoEncoder encoder, ICaptureStream capture, VideoCodec codec, int targetFps, AdaptiveController adaptive, IVideoLane lane,
                         SerialQueue queue, TimeProvider time, ulong firstSequence, Func<Exception, Task> onEncoderFailed, ILogger log)
    {
        _encoder = encoder;
        _capture = capture;
        Codec = codec;
        _targetFps = targetFps;
        _adaptive = adaptive;
        _lane = lane;
        _queue = queue;
        _time = time;
        _sequence = firstSequence;
        _onEncoderFailed = onEncoderFailed;
        _log = log;
        _currentFps = targetFps;
        _currentMaxQP = adaptive.MaxQP;
        _stall = time.CreateTimer(_ =>
        {
            var encodeId = Volatile.Read(ref _stallArmedFor);
            _queue.Post(() => StallAsync(encodeId));
        }, null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <summary>The codec on the wire.</summary>
    public VideoCodec Codec { get; }

    /// <summary>The adaptive controller's current target.</summary>
    public int BitrateKbps => _adaptive.BitrateKbps;

    /// <summary>The <c>videoFrame.sequence</c> the next frame gets; the next pipeline starts here.</summary>
    public ulong NextSequence => _sequence;

    /// <summary>Starts the encoder; its output comes back through this pipeline.</summary>
    public void Start() => _encoder.Start(new Sink(this));

    /// <summary>A frame from the capture (ownership passes here). Encodes it, or keeps it as the latest for when the encoder is free.</summary>
    public async Task IngestAsync(ICapturedFrame frame)
    {
        if (_disposed)
        {
            frame.Dispose();
            return;
        }
        var fps = Math.Min(_adaptive.Observe(frame.DirtyRatio), _targetFps);
        if (_adaptive.Mode != _loggedMode)
        {
            _loggedMode = _adaptive.Mode;
            _log.LogInformation("video mode {Mode} (max QP {QP}); {Skipped} unchanged frames skipped so far",
                                _loggedMode == EncodingMode.Text ? "text" : "motion", _adaptive.MaxQP, _idleSkipped);
        }
        if (fps != _currentFps)
        {
            _currentFps = fps;
            _capture.SetFrameRate(fps);
            _encoder.SetFrameRate(fps);
        }
        if (_adaptive.MaxQP != _currentMaxQP)
        {
            _currentMaxQP = _adaptive.MaxQP;
            _encoder.SetMaxQP(_currentMaxQP);
        }
        var previous = _latest;
        _latest = frame;
        previous?.Dispose();

        // Idle suppression: skip a static frame, but always honour a pending keyframe.
        if (frame.DirtyRatio <= HostSessionCore.IdleDirtyRatio && !_needsKeyframe && _framesSent > 0)
        {
            _idleSkipped++;
            return;
        }
        if (_inFlight is not null)
        {
            _pendingEncode = true;
            return;
        }
        await EncodeLatestAsync().ConfigureAwait(false);
    }

    /// <summary>The client (or the session) needs an IDR. A static screen sends no new frames, so the last one is re-encoded now.</summary>
    public async Task RequestKeyframeAsync()
    {
        _needsKeyframe = true;
        if (_inFlight is null) await EncodeLatestAsync().ConfigureAwait(false);
    }

    /// <summary>The video lane emptied after refusing a frame: a due IDR can go now.</summary>
    public async Task LaneDrainedAsync()
    {
        if (_needsKeyframe && _inFlight is null) await EncodeLatestAsync().ConfigureAwait(false);
    }

    /// <summary>Input arrived: the adaptive controller holds motion rate for a moment.</summary>
    public void NoteInput() => _adaptive.NoteInput();

    /// <summary>The client's <c>qualityFeedback</c>: a bitrate change goes to the encoder at once.</summary>
    public void ApplyFeedback(QualityFeedback feedback)
    {
        if (_adaptive.Apply(feedback) is { } bitrate) _encoder.SetBitrate(bitrate);
    }

    /// <summary>Stops: no more output is taken, the latest frame and the encoder are released.</summary>
    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        _stall.Dispose();
        _latest?.Dispose();
        _latest = null;
        try
        {
            await _encoder.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception error)
        {
            _log.LogError("stopping {Type} failed: {Error}", _encoder.GetType().Name, error.Message);
        }
    }

    /// <summary>Encodes the newest frame (forcing an IDR when one is due). A due IDR waits while the video lane is backed up.</summary>
    private async Task EncodeLatestAsync()
    {
        if (_disposed || _latest is not { } frame || _inFlight is not null) return;
        if (_needsKeyframe && _lane.IsVideoBacklogged)
        {
            _pendingEncode = true; // LaneDrainedAsync brings it back
            return;
        }
        _pendingEncode = false;
        var force = _needsKeyframe;
        _needsKeyframe = false;
        var encodeId = ++_lastEncodeId;
        _inFlight = encodeId;
        _inFlightDeadline = _time.GetUtcNow() + EncodeStallLimit;
        Volatile.Write(ref _stallArmedFor, encodeId);
        _stall.Change(EncodeStallLimit, Timeout.InfiniteTimeSpan);
        try
        {
            await _encoder.EncodeAsync(frame, force, encodeId, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            if (_inFlight == encodeId) Returned();
            if (force) _needsKeyframe = true;
            _log.LogError("encode failed: {Error}", error.Message);
        }
    }

    /// <summary>The encode in flight is done with (output, skipped, failed to queue, or given up on).</summary>
    private void Returned()
    {
        _inFlight = null;
        _stall.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    /// <summary>The encoder answered encode <paramref name="encodeId"/>; only the encode in flight is listened to.</summary>
    private async Task EmitAsync(long encodeId, EncodedFrame? output)
    {
        if (_disposed) return;
        if (_inFlight != encodeId)
        {
            // An encode given up on (or one whose EncodeAsync threw) answered after all: the picture has
            // moved on to a keyframe, so this frame is dropped and the current encode's state left alone.
            _log.LogInformation("encode {Id} answered after it was given up on; {What} dropped", encodeId, output is null ? "the skip" : "its frame");
            return;
        }
        Returned();
        if (output is not null) Send(output);
        if (_pendingEncode || (_needsKeyframe && _latest is not null)) await EncodeLatestAsync().ConfigureAwait(false);
    }

    /// <summary>
    /// The stall timer fired for encode <paramref name="encodeId"/>. When that encode is still in flight
    /// and its <see cref="EncodeStallLimit"/> has really passed, it is given up on and the latest frame
    /// re-encoded as a keyframe. A timeout queued behind the answer that finished its encode finds a
    /// newer encode (or none) in flight and does nothing; one that ran early is armed again for the rest.
    /// </summary>
    private async Task StallAsync(long encodeId)
    {
        if (_disposed || _inFlight != encodeId) return;
        var remaining = _inFlightDeadline - _time.GetUtcNow();
        if (remaining > TimeSpan.Zero)
        {
            _stall.Change(remaining, Timeout.InfiniteTimeSpan);
            return;
        }
        _stalls++;
        _log.LogWarning("encode {Id} returned nothing for {Ms} ms ({Count} stalls so far); giving up on it and forcing a keyframe",
                        encodeId, (int)EncodeStallLimit.TotalMilliseconds, _stalls);
        Returned();
        _needsKeyframe = true;
        await EncodeLatestAsync().ConfigureAwait(false);
    }

    private void Send(EncodedFrame output)
    {
        AccessUnit unit;
        try
        {
            unit = output.Format == NalFormat.AnnexB ? AnnexB.ToAccessUnit(output.Data, Codec) : AnnexB.FromUnits(AnnexB.SplitAvcc(output.Data), Codec);
        }
        catch (FormatException error)
        {
            _log.LogError("encoder output didn't parse: {Error}", error.Message);
            _needsKeyframe = true;
            return;
        }
        if (unit.Avcc.Length == 0) return;
        if (unit.IsKeyframe && WireParameterSets(unit, output.ParameterSets) is { } sets
            && (!_configSent || _lastParameterSets is null || !SameSets(sets, _lastParameterSets)))
        {
            _lane.PostVideo(new VideoConfig
            {
                Codec = Codec,
                Width = output.Width,
                Height = output.Height,
                ParameterSets = sets,
                NalLengthSize = 4,
                Fps = _currentFps,
            }, droppable: false);
            _lastParameterSets = sets;
            _configSent = true;
        }
        if (!_configSent)
        {
            // The client can't decode anything before a videoConfig: wait for an IDR.
            _needsKeyframe = true;
            return;
        }
        var frame = new VideoFrame
        {
            Sequence = _sequence++,
            CaptureNanos = output.CaptureNanos,
            IsKeyframe = unit.IsKeyframe,
            Width = (uint)output.Width,
            Height = (uint)output.Height,
            Data = unit.Avcc,
        };
        if (_lane.PostVideo(frame, droppable: !unit.IsKeyframe))
        {
            _framesSent++;
            return;
        }
        // The link is behind: this P-frame is gone, so the picture needs an IDR once it catches up.
        _needsKeyframe = true;
        if (_adaptive.NoteBacklog() is { } bitrate) _encoder.SetBitrate(bitrate);
    }

    /// <summary>
    /// The keyframe's parameter sets in wire order for the codec (H.264 <c>[SPS, PPS]</c>, HEVC
    /// <c>[VPS, SPS, PPS]</c>), each from the AU or else from what the encoder handed over beside
    /// it; null while any is missing.
    /// </summary>
    private byte[][]? WireParameterSets(AccessUnit unit, IReadOnlyList<byte[]>? side)
    {
        byte[]? Side(int type) => side?.FirstOrDefault(p => NalType.Of(p, Codec) == type);
        if (Codec == VideoCodec.Hevc)
        {
            var vps = unit.Vps ?? Side(HevcNalType.Vps);
            var hevcSps = unit.Sps ?? Side(HevcNalType.Sps);
            var hevcPps = unit.Pps ?? Side(HevcNalType.Pps);
            return vps is not null && hevcSps is not null && hevcPps is not null ? [vps, hevcSps, hevcPps] : null;
        }
        var sps = unit.Sps ?? Side(NalType.Sps);
        var pps = unit.Pps ?? Side(NalType.Pps);
        return sps is not null && pps is not null ? [sps, pps] : null;
    }

    private static bool SameSets(byte[][] a, byte[][] b) =>
        a.Length == b.Length && a.Zip(b).All(pair => pair.First.AsSpan().SequenceEqual(pair.Second));

    /// <summary>Forwards encoder output onto the session queue; a replaced pipeline's late output is ignored there.</summary>
    private sealed class Sink(VideoPipeline pipeline) : IEncodedFrameSink
    {
        public void OnFrame(long encodeId, EncodedFrame frame) => pipeline._queue.Post(() => pipeline.EmitAsync(encodeId, frame));

        public void OnFrameSkipped(long encodeId) => pipeline._queue.Post(() => pipeline.EmitAsync(encodeId, null));

        public void OnError(Exception error) => pipeline._queue.Post(async () =>
        {
            if (pipeline._disposed) return;
            pipeline._log.LogError("encoder failed: {Error}", error.Message);
            await pipeline._onEncoderFailed(error).ConfigureAwait(false);
        });
    }
}

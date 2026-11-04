namespace Vantage.Protocol.Audio;

/// <summary>
/// Turns capture buffers of any size into fixed 480-frame blocks (the Mac's
/// <c>AudioRepacketizer</c>, same rules).
/// </summary>
/// <remarks>
/// WASAPI hands out whatever its period holds (usually 10 ms, but 3 ms on some drivers and
/// several periods after a stall), so nothing downstream may assume a size. Timestamps follow the
/// samples: each block's time is the time of its first frame. When a buffer's timestamp disagrees
/// with where the samples say it should be by more than <see cref="DiscontinuityNanos"/>
/// (loopback delivered nothing while the PC was silent, the device changed, a glitch), or the
/// caller says the data is discontinuous (<c>AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY</c>), the
/// partial block is finished with silence and a new timeline starts at the new time, so the client
/// can tell a pause from late packets. Smaller jitter is ignored: the sample count is the clock.
/// Not thread-safe; one capture thread at a time.
/// </remarks>
public sealed class AudioRepacketizer
{
    /// <summary>How far a buffer's timestamp may disagree with the running sample clock before it counts as a new timeline.</summary>
    public const ulong DiscontinuityNanos = 15_000_000;

    private readonly float[] _pending = new float[AudioFormat.SamplesPerBlock];
    private int _pendingSamples;
    /// <summary>Time of the pending block's first frame, or of the next frame when nothing is pending.</summary>
    private ulong? _pendingStartNanos;

    /// <summary>New timelines started after the first (pauses, device changes, glitches).</summary>
    public int TimelineRestarts { get; private set; }

    /// <summary>For the log: how far the last restart's timestamp was from the sample clock (positive: later), 0 for a flagged discontinuity on time.</summary>
    public long LastRestartDriftNanos { get; private set; }

    /// <summary>
    /// Appends interleaved stereo samples whose first frame was captured at
    /// <paramref name="startNanos"/>, adding every block completed to <paramref name="blocks"/>.
    /// </summary>
    /// <param name="samples">Interleaved L R pairs; a trailing odd sample is ignored.</param>
    /// <param name="startNanos">Capture time of the first frame (<see cref="Host.HostClock"/> nanoseconds).</param>
    /// <param name="blocks">Receives the finished blocks, in order.</param>
    /// <param name="discontinuity">The source says these samples don't follow the previous ones.</param>
    public void Append(ReadOnlySpan<float> samples, ulong startNanos, List<AudioBlock> blocks, bool discontinuity = false)
    {
        var usable = samples.Length - samples.Length % AudioFormat.Channels;
        if (usable <= 0) return;
        BeginChunk(startNanos, blocks, discontinuity);
        var source = samples[..usable];
        while (!source.IsEmpty)
        {
            var take = Math.Min(source.Length, _pending.Length - _pendingSamples);
            source[..take].CopyTo(_pending.AsSpan(_pendingSamples));
            _pendingSamples += take;
            source = source[take..];
            if (_pendingSamples == _pending.Length) EmitPending(blocks);
        }
    }

    /// <summary>Drops the partial block and the timeline (the next buffer starts a fresh one, not counted as a restart).</summary>
    public void Reset()
    {
        _pendingSamples = 0;
        _pendingStartNanos = null;
    }

    /// <summary>Where the next frame would land on the current timeline.</summary>
    private ulong? ExpectedNanos =>
        _pendingStartNanos is { } start ? start + AudioFormat.NanosFor(_pendingSamples / AudioFormat.Channels) : null;

    private void BeginChunk(ulong startNanos, List<AudioBlock> blocks, bool discontinuity)
    {
        if (ExpectedNanos is not { } expected)
        {
            _pendingStartNanos = startNanos;
            return;
        }
        var drift = startNanos > expected ? startNanos - expected : expected - startNanos;
        if (drift <= DiscontinuityNanos && !discontinuity) return;
        // New timeline: finish the partial block with silence so it isn't glued to later audio.
        if (_pendingSamples > 0)
        {
            _pending.AsSpan(_pendingSamples).Clear();
            _pendingSamples = _pending.Length;
            EmitPending(blocks);
        }
        _pendingStartNanos = startNanos;
        TimelineRestarts++;
        LastRestartDriftNanos = (long)startNanos - (long)expected;
    }

    private void EmitPending(List<AudioBlock> blocks)
    {
        var start = _pendingStartNanos ?? 0;
        blocks.Add(new AudioBlock(_pending.ToArray(), start));
        _pendingSamples = 0;
        _pendingStartNanos = start + AudioFormat.NanosPerBlock;
    }
}

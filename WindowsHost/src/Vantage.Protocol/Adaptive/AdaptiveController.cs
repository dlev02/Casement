using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Adaptive;

/// <summary>Text (static, crisp) or motion (smooth) encoding.</summary>
public enum EncodingMode
{
    Text,
    Motion,
}

/// <summary>
/// AIMD bitrate and text/motion frame rate (Mac <c>AdaptiveController</c>, spec §9.1). Pure logic;
/// not thread-safe (the session calls it from its own queue).
/// </summary>
public sealed class AdaptiveController
{
    public const int MinBitrateKbps = 2_000;
    public const int MaxBitrateKbps = 60_000;
    public const int TextFps = 30;
    public const int MotionFps = 60;

    private readonly TimeProvider _time;
    private double _smoothedDirty;
    private DateTimeOffset _lastAdjustment = DateTimeOffset.MinValue;
    private DateTimeOffset _probeHoldUntil = DateTimeOffset.MinValue;

    public AdaptiveController(int startBitrateKbps, TimeProvider? time = null)
    {
        BitrateKbps = startBitrateKbps;
        _time = time ?? TimeProvider.System;
    }

    public int BitrateKbps { get; private set; }
    public EncodingMode Mode { get; private set; } = EncodingMode.Motion;

    /// <summary>Quantiser ceiling: 32 keeps text crisp, 44 lets motion through.</summary>
    public int MaxQP => Mode == EncodingMode.Text ? 32 : 44;

    /// <summary>Frame rate for the current mode.</summary>
    public int Fps => Mode == EncodingMode.Text ? TextFps : MotionFps;

    /// <summary>The Mac's starting bitrate: <c>clamp(pixels × fps × 0.08 / 1000, 4 000, 60 000)</c> kbps.</summary>
    public static int StartBitrate(int pixels, int fps) =>
        (int)Math.Min(MaxBitrateKbps, Math.Max(4_000, pixels * (double)fps * 0.08 / 1000));

    /// <summary>Smooths the capture's dirty ratio (0.9/0.1) and picks the mode; returns the mode's frame rate.</summary>
    public int Observe(double dirtyRatio)
    {
        _smoothedDirty = _smoothedDirty * 0.9 + dirtyRatio * 0.1;
        Mode = _smoothedDirty < 0.02 ? EncodingMode.Text : EncodingMode.Motion;
        return Fps;
    }

    /// <summary>Client feedback: loss (dropped frames or queue depth over 1) cuts 30 % and holds probing for 2 s; otherwise +10 % every 2 s. Returns the new bitrate if it changed.</summary>
    public int? Apply(QualityFeedback feedback) =>
        Adjust(loss: feedback.FramesDropped > 0 || feedback.QueueDepth > 1);

    /// <summary>The host's own send backlog made it drop a frame: treated as loss (spec §9.1).</summary>
    public int? NoteBacklog() => Adjust(loss: true);

    private int? Adjust(bool loss)
    {
        var now = _time.GetUtcNow();
        var previous = BitrateKbps;
        if (loss)
        {
            BitrateKbps = Math.Max(MinBitrateKbps, (int)(BitrateKbps * 0.7));
            _probeHoldUntil = now.AddSeconds(2);
        }
        else if (now > _probeHoldUntil && now - _lastAdjustment > TimeSpan.FromSeconds(2))
        {
            BitrateKbps = Math.Min(MaxBitrateKbps, (int)(BitrateKbps * 1.1));
        }
        if (BitrateKbps == previous) return null;
        _lastAdjustment = now;
        return BitrateKbps;
    }
}

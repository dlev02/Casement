using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Adaptive;

/// <summary>Text (static, crisp) or motion (smooth) encoding.</summary>
public enum EncodingMode
{
    Text,
    Motion,
}

/// <summary>
/// What a <see cref="QualityPreset"/> asks of the stream (the Mac's <c>AdaptiveController.Profile</c>,
/// same numbers): frame rate and quantiser ceiling for text and motion, the ceiling of the one
/// re-encode a still picture gets (null: none), and the bitrate floor.
/// </summary>
public readonly record struct QualityProfile(int TextFps, int MotionFps, int TextMaxQP, int MotionMaxQP, int? IdleMaxQP, int MinBitrateKbps)
{
    /// <summary>Balanced (<c>auto</c>), Fluid (<c>motion</c>), Sharp Text (<c>text</c>), and <c>maximum</c> (not offered in Casement).</summary>
    public static QualityProfile For(QualityPreset preset) => preset switch
    {
        QualityPreset.Motion => new(TextFps: 60, MotionFps: 60, TextMaxQP: 36, MotionMaxQP: 44, IdleMaxQP: null, MinBitrateKbps: 2_000),
        QualityPreset.Text => new(TextFps: 30, MotionFps: 60, TextMaxQP: 28, MotionMaxQP: 38, IdleMaxQP: 20, MinBitrateKbps: 6_000),
        QualityPreset.Maximum => new(TextFps: 30, MotionFps: 60, TextMaxQP: 24, MotionMaxQP: 34, IdleMaxQP: 18, MinBitrateKbps: 10_000),
        _ => new(TextFps: 30, MotionFps: 60, TextMaxQP: 32, MotionMaxQP: 44, IdleMaxQP: 24, MinBitrateKbps: 2_000),
    };
}

/// <summary>
/// AIMD bitrate and text/motion frame rate (Mac <c>AdaptiveController</c>, spec §9.1), shaped by the
/// device's <see cref="QualityPreset"/>. Pure logic; not thread-safe (the session calls it from its
/// own queue).
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
    // Input keeps the frame rate up for a moment: a moving pointer dirties too little of the
    // screen to leave text mode, so it would otherwise update at 30 fps.
    private DateTimeOffset _inputHoldUntil = DateTimeOffset.MinValue;

    /// <param name="startBitrateKbps">Where AIMD starts; raised to the preset's floor.</param>
    /// <param name="time">The session's clock.</param>
    /// <param name="preset">The device's <c>selectDisplay.quality</c>.</param>
    public AdaptiveController(int startBitrateKbps, TimeProvider? time = null, QualityPreset preset = QualityPreset.Auto)
    {
        _time = time ?? TimeProvider.System;
        Preset = preset;
        Profile = QualityProfile.For(preset);
        BitrateKbps = Math.Max(startBitrateKbps, Profile.MinBitrateKbps);
    }

    public int BitrateKbps { get; private set; }
    public EncodingMode Mode { get; private set; } = EncodingMode.Motion;

    /// <summary>The device's quality preset.</summary>
    public QualityPreset Preset { get; private set; }

    /// <summary>What <see cref="Preset"/> asks of the stream.</summary>
    public QualityProfile Profile { get; private set; }

    /// <summary>Quantiser ceiling for the mode (Balanced: 32 keeps text crisp, 44 lets motion through).</summary>
    public int MaxQP => Mode == EncodingMode.Text ? Profile.TextMaxQP : Profile.MotionMaxQP;

    /// <summary>The ceiling for the one re-encode a still picture gets; null when the preset has none (Fluid).</summary>
    public int? IdleMaxQP => Profile.IdleMaxQP;

    /// <summary>Frame rate for the current mode, or the motion rate within a second of input.</summary>
    public int Fps => Mode == EncodingMode.Motion || _time.GetUtcNow() < _inputHoldUntil ? Profile.MotionFps : Profile.TextFps;

    /// <summary>The device picked another preset mid-stream: the ceilings, rates and floor follow (a bitrate under the new floor is raised; returns it then).</summary>
    public int? SetPreset(QualityPreset preset)
    {
        Preset = preset;
        Profile = QualityProfile.For(preset);
        if (BitrateKbps >= Profile.MinBitrateKbps) return null;
        BitrateKbps = Profile.MinBitrateKbps;
        return BitrateKbps;
    }

    /// <summary>Pointer, scroll, or key input: hold the motion frame rate for the next second. The mode (and so the QP ceiling) still follows the screen.</summary>
    public void NoteInput() => _inputHoldUntil = _time.GetUtcNow().AddSeconds(1);

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

    /// <summary>Client feedback: loss (dropped frames or queue depth over 1) cuts 30 % (never under the preset's floor) and holds probing for 2 s; otherwise +10 % every 2 s. Returns the new bitrate if it changed.</summary>
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
            BitrateKbps = Math.Max(Profile.MinBitrateKbps, (int)(BitrateKbps * 0.7));
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

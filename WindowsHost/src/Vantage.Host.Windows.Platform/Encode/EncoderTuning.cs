namespace Vantage.Host.Windows.Encode;

/// <summary>Rate control for the H.264 MFT (<c>CODECAPI_AVEncCommonRateControlMode</c>).</summary>
public enum RateControl
{
    /// <summary>Constant bitrate (the default; what NVENC's low-latency preset is tuned for).</summary>
    Cbr,
    /// <summary>Low-delay VBR (lets a static desktop use fewer bits; try if CBR pulses).</summary>
    LowDelayVbr,
}

/// <summary>Which encoder to use.</summary>
public enum EncoderPreference
{
    /// <summary>The hardware MFT on the capture GPU, else Microsoft's software encoder.</summary>
    Auto,
    /// <summary>Hardware only (fail rather than fall back; for bring-up).</summary>
    HardwareOnly,
    /// <summary>Microsoft's software encoder only.</summary>
    SoftwareOnly,
}

/// <summary>Knobs for bring-up (Cli flags); the defaults are the plan's settings.</summary>
/// <param name="Preference">Hardware, software, or either.</param>
/// <param name="RateControl">CBR or low-delay VBR.</param>
/// <param name="BufferFrames">VBV buffer (<c>AVEncCommonBufferSize</c>) in frames at the current bitrate and frame rate.</param>
public sealed record EncoderTuning(EncoderPreference Preference = EncoderPreference.Auto, RateControl RateControl = RateControl.Cbr,
                                   double BufferFrames = 2)
{
    /// <summary>GOP length: effectively infinite (IDRs only on request; spec §7.2).</summary>
    public const uint GopSize = 216_000;

    /// <summary><c>AVEncCommonBufferSize</c> in bits for a bitrate and frame rate.</summary>
    public static uint BufferBits(int kbps, int fps, double frames) =>
        (uint)Math.Clamp(kbps * 1000.0 / Math.Max(1, fps) * Math.Max(0.5, frames), 64_000, int.MaxValue);
}

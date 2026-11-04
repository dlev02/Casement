namespace Vantage.Protocol.Audio;

/// <summary>
/// The one format everything after capture works in (Swift <c>AudioBlock</c>): 48 kHz stereo,
/// interleaved float32, cut into 10 ms blocks of 480 frames, which is also the Opus packet size.
/// </summary>
public static class AudioFormat
{
    public const int SampleRate = 48_000;
    public const int Channels = 2;
    /// <summary>10 ms: Opus's packet size here, and the unit everything downstream counts in.</summary>
    public const int FramesPerBlock = 480;
    public const int SamplesPerBlock = FramesPerBlock * Channels;
    public const ulong NanosPerBlock = 10_000_000;

    /// <summary>Nanoseconds that <paramref name="frames"/> frames last at 48 kHz.</summary>
    public static ulong NanosFor(long frames) => (ulong)frames * 1_000_000_000UL / SampleRate;
}

/// <summary>10 ms of 48 kHz stereo audio, interleaved (L R L R …), ready for the Opus encoder.</summary>
/// <param name="Samples"><see cref="AudioFormat.SamplesPerBlock"/> samples, −1…1. Owned by the block.</param>
/// <param name="CaptureNanos">Host capture time of the first frame, on <see cref="Host.HostClock"/>.</param>
public readonly record struct AudioBlock(float[] Samples, ulong CaptureNanos);

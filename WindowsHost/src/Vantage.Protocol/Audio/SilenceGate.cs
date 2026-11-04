namespace Vantage.Protocol.Audio;

/// <summary>
/// Stops the stream while the PC is silent, the way ScreenCaptureKit does on the Mac.
/// </summary>
/// <remarks>
/// Endpoint loopback delivers nothing while no app plays, but process loopback (and some drivers)
/// keep delivering digital silence. Sent as packets, that silence looks to the client like
/// audio that never stops, so its buffer never sees the Mac-style pause that lets it settle (a
/// pause isn't counted against the network; late packets are). After <see cref="Hangover"/> of
/// silent blocks in a row the gate closes and drops blocks; the first block with sound opens it
/// again, and since its <c>captureNanos</c> jumped, the client starts a new timeline. The hangover
/// keeps short gaps (between words, between notes) on one timeline. A block counts as silent when
/// no sample reaches <see cref="Threshold"/> (−90 dBFS, under a 16-bit step, so dither and true
/// zeros both count). Not thread-safe; one caller at a time.
/// </remarks>
public sealed class SilenceGate
{
    /// <summary>Peak level below which a block is silence: 1/32768, −90 dBFS.</summary>
    public const float Threshold = 1f / 32_768;

    /// <summary>How long silence is still sent before the gate closes.</summary>
    public static readonly TimeSpan Hangover = TimeSpan.FromMilliseconds(500);

    private static readonly int s_hangoverBlocks = (int)(Hangover.TotalMilliseconds / 10);
    private int _silentBlocks = int.MaxValue / 2; // closed until the first sound

    /// <summary>Whether the gate is closed (dropping silence) right now.</summary>
    public bool IsClosed => _silentBlocks > s_hangoverBlocks;

    /// <summary>Times the gate closed: pauses the client sees.</summary>
    public int Pauses { get; private set; }

    /// <summary>Whether <paramref name="block"/> should be sent.</summary>
    public bool Admit(in AudioBlock block)
    {
        if (!IsSilent(block.Samples))
        {
            _silentBlocks = 0;
            return true;
        }
        if (_silentBlocks <= s_hangoverBlocks && ++_silentBlocks > s_hangoverBlocks) Pauses++;
        return !IsClosed;
    }

    /// <summary>Closes the gate (a new capture starts closed, so it never opens on silence).</summary>
    public void Reset() => _silentBlocks = int.MaxValue / 2;

    /// <summary>No sample at or above <see cref="Threshold"/>.</summary>
    public static bool IsSilent(ReadOnlySpan<float> samples)
    {
        foreach (var sample in samples)
        {
            if (sample >= Threshold || sample <= -Threshold) return false;
        }
        return true;
    }
}

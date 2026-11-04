using System.Buffers.Binary;

namespace Vantage.Protocol.Audio;

/// <summary>A PCM layout a capture buffer may arrive in (WASAPI's <c>WAVEFORMATEX</c>/<c>WAVEFORMATEXTENSIBLE</c>).</summary>
/// <param name="SampleRate">Frames per second.</param>
/// <param name="Channels">Interleaved channels per frame.</param>
/// <param name="BitsPerSample">Container size: 16, 24 or 32 (float or integer).</param>
/// <param name="IsFloat">IEEE float samples (32-bit) rather than signed integers.</param>
/// <param name="ChannelMask">
/// <c>dwChannelMask</c> (SPEAKER_FRONT_LEFT = 0x1, …) when known; 0 means the usual order for
/// the channel count (FL FR FC LFE BL BR SL SR).
/// </param>
public sealed record PcmFormat(int SampleRate, int Channels, int BitsPerSample, bool IsFloat, uint ChannelMask = 0)
{
    /// <summary>What the encoder wants: 48 kHz stereo float.</summary>
    public static readonly PcmFormat Target = new(AudioFormat.SampleRate, AudioFormat.Channels, 32, IsFloat: true, ChannelMask: 0x3);

    /// <summary>Bytes per interleaved frame.</summary>
    public int BytesPerFrame => Channels * BitsPerSample / 8;

    /// <summary>Whether <see cref="PcmConverter"/> can read it.</summary>
    public bool IsSupported => Channels >= 1 && SampleRate >= 8_000 && SampleRate <= 384_000 &&
                               (IsFloat ? BitsPerSample == 32 : BitsPerSample is 16 or 24 or 32);

    public override string ToString() =>
        $"{SampleRate} Hz, {Channels} ch, {BitsPerSample}-bit {(IsFloat ? "float" : "integer")}";
}

/// <summary>
/// Turns capture buffers in any <see cref="PcmFormat"/> into 48 kHz interleaved stereo float, the
/// encoder's format.
/// </summary>
/// <remarks>
/// Mostly a fallback: the capture first asks Windows for 48 kHz stereo float
/// (<c>AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM</c>, the audio engine's own converter), and process
/// loopback takes whatever format it is given; when the engine refuses, the mix format arrives as
/// is. Channels: mono goes to both sides; more than two are folded down with the usual −3 dB
/// weights for the centre and surround channels (LFE dropped), then clipped to ±1. Rate: linear
/// interpolation, carried across buffers. That costs a little treble near 20 kHz and leaves faint
/// images (roughly −40 dB under loud high notes) that a windowed-sinc resampler wouldn't, which is
/// fine for a remote-desktop monitor stream already squeezed into 128 kbps Opus, and far cheaper.
/// The first output frame of a buffer lands within one input frame (≤ 23 µs at 44.1 kHz) of the
/// buffer's timestamp, well under the repacketizer's 15 ms tolerance, so timestamps pass through
/// unchanged. Not thread-safe.
/// </remarks>
public sealed class PcmConverter
{
    private const float Minus3dB = 0.70710678f;
    private const uint FrontLeft = 0x1, FrontRight = 0x2, FrontCenter = 0x4, LowFrequency = 0x8, BackLeft = 0x10, BackRight = 0x20,
        FrontLeftOfCenter = 0x40, FrontRightOfCenter = 0x80, BackCenter = 0x100, SideLeft = 0x200, SideRight = 0x400;

    private readonly PcmFormat _format;
    private readonly (float Left, float Right)[] _weights;
    private readonly double _step;
    private float[] _stereo = new float[AudioFormat.SamplesPerBlock * 4];
    private float[] _output = new float[AudioFormat.SamplesPerBlock * 4];
    private bool _primed;
    private float _prevLeft, _prevRight;
    /// <summary>Position of the next output frame in input frames; −1 is the previous buffer's last frame.</summary>
    private double _position;

    public PcmConverter(PcmFormat format)
    {
        if (!format.IsSupported) throw new ArgumentException($"Unsupported audio format: {format}", nameof(format));
        _format = format;
        _weights = Weights(format.Channels, format.ChannelMask);
        _step = (double)format.SampleRate / AudioFormat.SampleRate;
    }

    /// <summary>The format being read.</summary>
    public PcmFormat Format => _format;

    /// <summary>Whether buffers are already 48 kHz stereo float (copied, never resampled).</summary>
    public bool IsPassthrough => _format.SampleRate == AudioFormat.SampleRate && _format.Channels == 2 && _format.IsFloat;

    /// <summary>
    /// Converts <paramref name="frames"/> frames from <paramref name="data"/>. The result stays
    /// valid until the next call. <paramref name="silent"/> (WASAPI's <c>AUDCLNT_BUFFERFLAGS_SILENT</c>)
    /// treats the data as zeros, as WASAPI requires.
    /// </summary>
    public ReadOnlySpan<float> Convert(ReadOnlySpan<byte> data, int frames, bool silent = false)
    {
        if (!silent) frames = Math.Min(frames, data.Length / _format.BytesPerFrame);
        if (frames <= 0) return [];
        var stereo = ToStereo(data, frames, silent);
        return _format.SampleRate == AudioFormat.SampleRate ? stereo : Resample(stereo, frames);
    }

    /// <summary>Forgets the resampler's history (a new timeline starts with the next buffer).</summary>
    public void Reset()
    {
        _primed = false;
        _position = 0;
    }

    private Span<float> ToStereo(ReadOnlySpan<byte> data, int frames, bool silent)
    {
        var count = frames * 2;
        if (_stereo.Length < count) _stereo = new float[count * 2];
        var stereo = _stereo.AsSpan(0, count);
        if (silent)
        {
            stereo.Clear();
            return stereo;
        }
        var channels = _format.Channels;
        var bytesPerSample = _format.BitsPerSample / 8;
        for (var frame = 0; frame < frames; frame++)
        {
            float left = 0, right = 0;
            var offset = frame * _format.BytesPerFrame;
            for (var channel = 0; channel < channels; channel++)
            {
                var (wl, wr) = _weights[channel];
                if (wl == 0 && wr == 0) continue;
                var sample = Read(data.Slice(offset + channel * bytesPerSample, bytesPerSample));
                left += sample * wl;
                right += sample * wr;
            }
            stereo[frame * 2] = Math.Clamp(left, -1f, 1f);
            stereo[frame * 2 + 1] = Math.Clamp(right, -1f, 1f);
        }
        return stereo;
    }

    private float Read(ReadOnlySpan<byte> sample) => _format.BitsPerSample switch
    {
        32 when _format.IsFloat => BinaryPrimitives.ReadSingleLittleEndian(sample),
        16 => BinaryPrimitives.ReadInt16LittleEndian(sample) / 32_768f,
        24 => ((sample[0] | (sample[1] << 8) | (sample[2] << 16)) << 8 >> 8) / 8_388_608f,
        _ => BinaryPrimitives.ReadInt32LittleEndian(sample) / 2_147_483_648f,
    };

    private ReadOnlySpan<float> Resample(ReadOnlySpan<float> stereo, int frames)
    {
        if (!_primed)
        {
            // Start exactly on the first frame.
            _position = 0;
            _primed = true;
        }
        var capacity = (int)(frames / _step) + 4;
        if (_output.Length < capacity * 2) _output = new float[capacity * 4];
        var produced = 0;
        // Input index −1 is the previous buffer's last frame, 0…frames−1 this buffer's.
        while (_position < frames - 1)
        {
            var index = (int)Math.Floor(_position);
            var fraction = (float)(_position - index);
            float l0, r0;
            if (index < 0)
            {
                l0 = _prevLeft;
                r0 = _prevRight;
            }
            else
            {
                l0 = stereo[index * 2];
                r0 = stereo[index * 2 + 1];
            }
            var l1 = stereo[(index + 1) * 2];
            var r1 = stereo[(index + 1) * 2 + 1];
            _output[produced * 2] = l0 + (l1 - l0) * fraction;
            _output[produced * 2 + 1] = r0 + (r1 - r0) * fraction;
            produced++;
            _position += _step;
        }
        _prevLeft = stereo[(frames - 1) * 2];
        _prevRight = stereo[(frames - 1) * 2 + 1];
        _position -= frames;
        return _output.AsSpan(0, produced * 2);
    }

    /// <summary>Per-channel (left, right) gains for folding <paramref name="channels"/> down to stereo.</summary>
    internal static (float Left, float Right)[] Weights(int channels, uint mask)
    {
        var weights = new (float, float)[channels];
        if (channels == 1)
        {
            weights[0] = (1, 1);
            return weights;
        }
        if (mask == 0)
        {
            mask = channels switch
            {
                3 => FrontLeft | FrontRight | FrontCenter,
                4 => FrontLeft | FrontRight | BackLeft | BackRight,
                6 => FrontLeft | FrontRight | FrontCenter | LowFrequency | BackLeft | BackRight,
                8 => FrontLeft | FrontRight | FrontCenter | LowFrequency | BackLeft | BackRight | SideLeft | SideRight,
                _ => FrontLeft | FrontRight,
            };
        }
        // Channels appear in mask-bit order; channels past the mask's bits stay silent.
        var channel = 0;
        for (var bit = 0; bit < 32 && channel < channels; bit++)
        {
            var speaker = 1u << bit;
            if ((mask & speaker) == 0) continue;
            weights[channel++] = speaker switch
            {
                FrontLeft => (1, 0),
                FrontRight => (0, 1),
                FrontCenter or BackCenter => (Minus3dB, Minus3dB),
                FrontLeftOfCenter or BackLeft or SideLeft => (Minus3dB, 0),
                FrontRightOfCenter or BackRight or SideRight => (0, Minus3dB),
                _ => (0, 0), // LFE and the height channels
            };
        }
        return weights;
    }
}

using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>Makes an encoder for one capture stream (Windows: the Media Foundation H.264 MFT on the capture's GPU).</summary>
public interface IVideoEncoderFactory
{
    /// <summary>
    /// Codecs this host can encode, best first. Windows v1: <c>[H264]</c> only, whatever the client
    /// prefers; it is what <c>HostCapabilities.codecs</c> advertises.
    /// </summary>
    IReadOnlyList<VideoCodec> SupportedCodecs { get; }

    /// <summary>
    /// Creates (but doesn't start) an encoder for frames from <paramref name="source"/>. Called at
    /// every capture (re)start; the previous encoder is disposed first. Throw
    /// <see cref="CaptureUnavailableException"/> if no encoder can be made right now.
    /// </summary>
    /// <param name="source">The capture whose frames will be encoded (share its GPU device).</param>
    /// <param name="settings">Initial settings. The output must be exactly <see cref="VideoEncoderSettings.Width"/> × <see cref="VideoEncoderSettings.Height"/>.</param>
    IVideoEncoder Create(ICaptureStream source, VideoEncoderSettings settings);
}

/// <summary>Initial encoder settings.</summary>
/// <param name="Codec">Always <see cref="VideoCodec.H264"/> on Windows v1.</param>
/// <param name="Width">
/// Encoded width: even, and within the client's <c>maxDecodeWidth</c> × <c>maxDecodeHeight</c>
/// (the core computes it with <see cref="VideoGeometry.EncodedSize"/>; a larger capture is
/// downscaled by the encoder's colour converter).
/// </param>
/// <param name="Height">Encoded height (even).</param>
/// <param name="Fps">Expected frame rate.</param>
/// <param name="BitrateKbps">Target bitrate (CBR or low-delay VBR), changed live with <see cref="IVideoEncoder.SetBitrate"/>.</param>
/// <param name="MaxQP">Quantiser ceiling from the adaptive controller (32 text, 44 motion); may be ignored.</param>
public sealed record VideoEncoderSettings(VideoCodec Codec, int Width, int Height, int Fps, int BitrateKbps, int MaxQP);

/// <summary>
/// A hardware or software H.264 encoder (spec §7.3): progressive 4:2:0 8-bit, High (or Main)
/// profile, no B-frames or reordering, low-latency rate control, no periodic IDRs, VUI BT.709
/// primaries / sRGB (or BT.709) transfer / BT.709 matrix / video range.
/// </summary>
/// <remarks>
/// Every <see cref="EncodeAsync"/> the encoder accepts ends in exactly one call to the sink:
/// <see cref="IEncodedFrameSink.OnFrame"/> or <see cref="IEncodedFrameSink.OnFrameSkipped"/>. The
/// core keeps one frame in flight and relies on that to send the next.
/// </remarks>
public interface IVideoEncoder : IAsyncDisposable
{
    /// <summary>Starts the encoder. Output and errors go to <paramref name="sink"/>, from any thread, one call at a time.</summary>
    void Start(IEncodedFrameSink sink);

    /// <summary>
    /// Queues one frame. The encoder must be done reading <paramref name="frame"/> (converted or
    /// copied into its own surface) when the returned task completes; the core may dispose the
    /// frame after that or keep it to re-encode later.
    /// </summary>
    /// <param name="frame">A frame from the capture stream this encoder was created for.</param>
    /// <param name="forceKeyframe">The output must be an IDR carrying SPS and PPS (stream start, <c>requestKeyframe</c>, after dropped frames).</param>
    /// <param name="cancellationToken">Cancels waiting for the encoder to take the frame.</param>
    ValueTask EncodeAsync(ICapturedFrame frame, bool forceKeyframe, CancellationToken cancellationToken);

    /// <summary>New target bitrate in kbps (2 000…60 000), applied without a keyframe.</summary>
    void SetBitrate(int kbps);

    /// <summary>New expected frame rate (rate control only).</summary>
    void SetFrameRate(int fps);

    /// <summary>New quantiser ceiling; may be ignored.</summary>
    void SetMaxQP(int maxQP);
}

/// <summary>Where an encoder delivers its output.</summary>
public interface IEncodedFrameSink
{
    /// <summary>One access unit for one input frame, in decode order.</summary>
    void OnFrame(EncodedFrame frame);

    /// <summary>The encoder took a frame and produced nothing for it (rate control dropped it).</summary>
    void OnFrameSkipped();

    /// <summary>The encoder failed; the core logs it and restarts capture and encoding.</summary>
    void OnError(Exception error);
}

/// <summary>How NAL units are delimited in <see cref="EncodedFrame.Data"/>.</summary>
public enum NalFormat
{
    /// <summary>Start codes (00 00 01 / 00 00 00 01), as Media Foundation emits. The core converts.</summary>
    AnnexB,

    /// <summary>4-byte big-endian length prefixes, as on the wire.</summary>
    Avcc,
}

/// <summary>One encoded access unit.</summary>
public sealed class EncodedFrame
{
    /// <summary>
    /// The access unit. For <see cref="NalFormat.AnnexB"/> it may include SPS/PPS/AUD/SEI: the core
    /// pulls SPS and PPS out for <c>videoConfig</c>, drops AUD, and sends the slices as AVCC.
    /// </summary>
    public required ReadOnlyMemory<byte> Data { get; init; }

    /// <summary>How <see cref="Data"/> is delimited.</summary>
    public required NalFormat Format { get; init; }

    /// <summary>
    /// SPS and PPS as raw NAL units (no start code or length) when they aren't inside
    /// <see cref="Data"/>; needed on every IDR when <see cref="Format"/> is <see cref="NalFormat.Avcc"/>.
    /// </summary>
    public IReadOnlyList<byte[]>? ParameterSets { get; init; }

    /// <summary>A hint; the core decides from the NAL types (an IDR slice, type 5).</summary>
    public bool IsKeyframe { get; init; }

    /// <summary>The source frame's <see cref="ICapturedFrame.TimestampNanos"/>.</summary>
    public ulong CaptureNanos { get; init; }

    /// <summary>Encoded width.</summary>
    public required int Width { get; init; }

    /// <summary>Encoded height.</summary>
    public required int Height { get; init; }
}

/// <summary>Pure sizing rules for the encoded picture.</summary>
public static class VideoGeometry
{
    /// <summary>
    /// The largest even size with the capture's aspect ratio that fits in the client's decode
    /// limits (4096 × 2304 today); the capture size itself (rounded down to even) when it fits.
    /// A limit of 0 or less means no limit.
    /// </summary>
    public static (int Width, int Height) EncodedSize(int pixelWidth, int pixelHeight, int maxWidth, int maxHeight)
    {
        if (pixelWidth <= 0 || pixelHeight <= 0) throw new ArgumentOutOfRangeException(nameof(pixelWidth), "Capture size must be positive.");
        double scale = 1;
        if (maxWidth > 0 && pixelWidth > maxWidth) scale = Math.Min(scale, (double)maxWidth / pixelWidth);
        if (maxHeight > 0 && pixelHeight > maxHeight) scale = Math.Min(scale, (double)maxHeight / pixelHeight);
        var width = (int)Math.Floor(pixelWidth * scale) & ~1;
        var height = (int)Math.Floor(pixelHeight * scale) & ~1;
        return (Math.Max(2, width), Math.Max(2, height));
    }
}

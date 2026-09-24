using Microsoft.Extensions.Logging;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;

namespace Vantage.Host.Windows.Encode;

/// <summary>
/// <c>--dump-h264 PATH</c>: wraps an encoder factory and appends every encoded access unit, as
/// Annex-B, to one file, so the raw stream can be copied to the Mac and checked with
/// <c>ffprobe -show_frames</c> / <c>ffplay</c> / a VideoToolbox decode. Each capture restart appends
/// (the stream restarts with an IDR carrying SPS/PPS, so the file stays decodable).
/// </summary>
public sealed class DumpingEncoderFactory(IVideoEncoderFactory inner, string path, ILogger log) : IVideoEncoderFactory
{
    private readonly Lock _fileLock = new();

    /// <inheritdoc />
    public IReadOnlyList<VideoCodec> SupportedCodecs => inner.SupportedCodecs;

    /// <inheritdoc />
    public IVideoEncoder Create(ICaptureStream source, VideoEncoderSettings settings)
    {
        log.LogInformation("dumping the H.264 stream to {Path}", path);
        return new DumpingEncoder(inner.Create(source, settings), this);
    }

    private void Append(EncodedFrame frame)
    {
        var bytes = frame.Format == NalFormat.AnnexB
            ? frame.Data.ToArray()
            : NalUnits.AvccToAnnexB(frame.Data.Span, frame.IsKeyframe ? frame.ParameterSets : null);
        lock (_fileLock)
        {
            using var file = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
            file.Write(bytes);
        }
    }

    private sealed class DumpingEncoder(IVideoEncoder inner, DumpingEncoderFactory owner) : IVideoEncoder, IEncodedFrameSink
    {
        private IEncodedFrameSink? _sink;

        public void Start(IEncodedFrameSink sink)
        {
            _sink = sink;
            inner.Start(this);
        }

        public ValueTask EncodeAsync(ICapturedFrame frame, bool forceKeyframe, CancellationToken cancellationToken) =>
            inner.EncodeAsync(frame, forceKeyframe, cancellationToken);

        public void SetBitrate(int kbps) => inner.SetBitrate(kbps);

        public void SetFrameRate(int fps) => inner.SetFrameRate(fps);

        public void SetMaxQP(int maxQP) => inner.SetMaxQP(maxQP);

        public ValueTask DisposeAsync() => inner.DisposeAsync();

        public void OnFrame(EncodedFrame frame)
        {
            try { owner.Append(frame); }
            catch (IOException) { }
            _sink?.OnFrame(frame);
        }

        public void OnFrameSkipped() => _sink?.OnFrameSkipped();

        public void OnError(Exception error) => _sink?.OnError(error);
    }
}

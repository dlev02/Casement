using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Capture;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;

namespace Vantage.Host.Windows.Encode;

/// <summary>
/// <see cref="IVideoEncoderFactory"/> for Windows: the hardware H.264 MFT on the capture's GPU,
/// falling back to Microsoft's software MFT (unless <see cref="EncoderPreference.HardwareOnly"/>).
/// Once hardware has failed for a GPU it isn't retried until the host restarts, so a broken driver
/// doesn't cost every capture restart a second of retries.
/// </summary>
public sealed class MediaFoundationEncoderFactory : IVideoEncoderFactory
{
    private readonly ILogger _log;
    private readonly EncoderTuning _tuning;
    private readonly HashSet<long> _hardwareFailedOn = [];
    private readonly Lock _lock = new();

    /// <param name="logging">Loggers (category <c>Vantage.Encode</c>).</param>
    /// <param name="tuning">Bring-up overrides; null for the defaults.</param>
    public MediaFoundationEncoderFactory(ILoggerFactory logging, EncoderTuning? tuning = null)
    {
        _log = logging.CreateLogger("Vantage.Encode");
        _tuning = tuning ?? new EncoderTuning();
    }

    /// <summary>The encoder most recently made ("NVIDIA H.264 Encoder MFT"), for the UI and logs.</summary>
    public string? CurrentEncoderName { get; private set; }

    /// <inheritdoc />
    public IReadOnlyList<VideoCodec> SupportedCodecs { get; } = [VideoCodec.H264];

    /// <inheritdoc />
    public IVideoEncoder Create(ICaptureStream source, VideoEncoderSettings settings)
    {
        if (source is not WgcCaptureStream capture)
            throw new CaptureUnavailableException("The Media Foundation encoder needs a Windows.Graphics.Capture stream.");
        if (settings.Codec != VideoCodec.H264)
            throw new CaptureUnavailableException($"Only H.264 is supported on Windows (asked for {settings.Codec}).");

        bool tryHardware;
        lock (_lock) tryHardware = _tuning.Preference != EncoderPreference.SoftwareOnly && !_hardwareFailedOn.Contains(capture.Gpu.AdapterLuid);

        if (tryHardware)
        {
            try
            {
                var encoder = MfH264Encoder.CreateHardware(capture, settings, _tuning, _log);
                CurrentEncoderName = encoder.Name;
                return encoder;
            }
            catch (Exception ex)
            {
                if (_tuning.Preference == EncoderPreference.HardwareOnly)
                    throw new CaptureUnavailableException($"hardware H.264 encoding failed: {ex.Message}", ex);
                lock (_lock) _hardwareFailedOn.Add(capture.Gpu.AdapterLuid);
                _log.LogWarning(ex, "hardware H.264 encoding unavailable on {Adapter}; using the software encoder", capture.Gpu.AdapterName);
            }
        }

        try
        {
            var encoder = MfH264Encoder.CreateSoftware(capture, settings, _tuning, _log);
            CurrentEncoderName = encoder.Name;
            return encoder;
        }
        catch (Exception ex)
        {
            throw new CaptureUnavailableException($"no H.264 encoder could be made: {ex.Message}", ex);
        }
    }
}

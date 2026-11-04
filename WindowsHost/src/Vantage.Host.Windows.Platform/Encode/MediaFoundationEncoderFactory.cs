using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Capture;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;

namespace Vantage.Host.Windows.Encode;

/// <summary>
/// <see cref="IVideoEncoderFactory"/> for Windows: the hardware HEVC or H.264 MFT on the capture's
/// GPU, falling back to a software MFT (unless <see cref="EncoderPreference.HardwareOnly"/>):
/// Microsoft's for H.264; for HEVC only if one is registered, since Windows ships none. Once
/// hardware has failed for a codec on a GPU it isn't retried until the host restarts, so a broken
/// driver doesn't cost every capture restart a second of retries.
/// </summary>
public sealed class MediaFoundationEncoderFactory : IVideoEncoderFactory
{
    private readonly ILogger _log;
    private readonly EncoderTuning _tuning;
    private readonly HashSet<(VideoCodec, long)> _hardwareFailedOn = [];
    private readonly Lock _lock = new();
    private readonly Lazy<bool> _hevcAvailable;
    private volatile bool _hevcRefused;

    /// <param name="logging">Loggers (category <c>Vantage.Encode</c>).</param>
    /// <param name="tuning">Bring-up overrides; null for the defaults.</param>
    public MediaFoundationEncoderFactory(ILoggerFactory logging, EncoderTuning? tuning = null)
    {
        _log = logging.CreateLogger("Vantage.Encode");
        _tuning = tuning ?? new EncoderTuning();
        _hevcAvailable = new Lazy<bool>(ProbeHevc, LazyThreadSafetyMode.ExecutionAndPublication);
    }

    /// <summary>
    /// The encoder most recently made, with its codec and kind ("NVIDIA HEVC Encoder MFT (hardware)"),
    /// for the UI and logs.
    /// </summary>
    public string? CurrentEncoderName { get; private set; }

    /// <summary>
    /// <c>[Hevc, H264]</c> (the Mac's order) while the PC has an HEVC encoder MFT the preference
    /// allows, else <c>[H264]</c>; just the <c>--codec</c> one when forced. Probed once, on first use
    /// (the first session), and HEVC is dropped after it fails on the capture GPU, so later sessions
    /// don't ask for it again.
    /// </summary>
    public IReadOnlyList<VideoCodec> SupportedCodecs => _tuning.Codec is { } forced
        ? [forced]
        : !_hevcRefused && _hevcAvailable.Value ? [VideoCodec.Hevc, VideoCodec.H264] : [VideoCodec.H264];

    /// <inheritdoc />
    public IVideoEncoder Create(ICaptureStream source, VideoEncoderSettings settings)
    {
        if (source is not WgcCaptureStream capture)
            throw new CaptureUnavailableException("The Media Foundation encoder needs a Windows.Graphics.Capture stream.");
        if (settings.Codec is not (VideoCodec.H264 or VideoCodec.Hevc))
            throw new CaptureUnavailableException($"{settings.Codec} isn't supported on Windows.");
        var codec = MfVideoEncoder.CodecName(settings.Codec);
        var key = (settings.Codec, capture.Gpu.AdapterLuid);

        bool tryHardware;
        lock (_lock) tryHardware = _tuning.Preference != EncoderPreference.SoftwareOnly && !_hardwareFailedOn.Contains(key);

        Exception? hardwareError = null;
        if (tryHardware)
        {
            try
            {
                return Made(MfVideoEncoder.CreateHardware(capture, settings, _tuning, _log));
            }
            catch (Exception ex)
            {
                if (_tuning.Preference == EncoderPreference.HardwareOnly)
                    throw new CaptureUnavailableException($"hardware {codec} encoding failed: {ex.Message}", ex);
                lock (_lock) _hardwareFailedOn.Add(key);
                hardwareError = ex;
            }
        }

        if (settings.Codec == VideoCodec.Hevc && !MfVideoEncoder.HasSoftwareEncoder(VideoCodec.Hevc))
        {
            // Windows has no software HEVC encoder: the session falls back to H.264.
            _hevcRefused = true;
            _log.LogWarning(hardwareError, "HEVC encoding unavailable on {Adapter}; not offering HEVC any more", capture.Gpu.AdapterName);
            throw new CaptureUnavailableException($"no HEVC encoder on {capture.Gpu.AdapterName}"
                                                  + (hardwareError is null ? "" : $": {hardwareError.Message}"), hardwareError);
        }
        if (hardwareError is not null)
            _log.LogWarning(hardwareError, "hardware {Codec} encoding unavailable on {Adapter}; using the software encoder", codec, capture.Gpu.AdapterName);

        try
        {
            return Made(MfVideoEncoder.CreateSoftware(capture, settings, _tuning, _log));
        }
        catch (Exception ex)
        {
            if (settings.Codec == VideoCodec.Hevc) _hevcRefused = true;
            throw new CaptureUnavailableException($"no {codec} encoder could be made: {ex.Message}", ex);
        }
    }

    /// <summary>
    /// The name shown in About: the MFT's friendly name, the codec when that name doesn't say it,
    /// and whether it runs on the graphics card.
    /// </summary>
    public static string DisplayName(string friendlyName, VideoCodec codec, bool isHardware)
    {
        string[] spellings = codec == VideoCodec.Hevc ? ["HEVC", "H.265", "H265"] : ["H.264", "H264", "AVC"];
        var namesCodec = spellings.Any(s => friendlyName.Contains(s, StringComparison.OrdinalIgnoreCase));
        var kind = isHardware ? "hardware" : "software";
        return namesCodec ? $"{friendlyName} ({kind})" : $"{friendlyName} ({MfVideoEncoder.CodecName(codec)}, {kind})";
    }

    private MfVideoEncoder Made(MfVideoEncoder encoder)
    {
        CurrentEncoderName = DisplayName(encoder.Name, encoder.Codec, encoder.IsHardware);
        return encoder;
    }

    private bool ProbeHevc()
    {
        try
        {
            var hardware = _tuning.Preference != EncoderPreference.SoftwareOnly && MfVideoEncoder.HasHardwareEncoder(VideoCodec.Hevc);
            var available = hardware || (_tuning.Preference != EncoderPreference.HardwareOnly && MfVideoEncoder.HasSoftwareEncoder(VideoCodec.Hevc));
            _log.LogInformation("HEVC encoder {Found}", available ? hardware ? "found (hardware)" : "found (software)" : "not found; offering H.264 only");
            return available;
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "couldn't look for an HEVC encoder; offering H.264 only");
            return false;
        }
    }
}

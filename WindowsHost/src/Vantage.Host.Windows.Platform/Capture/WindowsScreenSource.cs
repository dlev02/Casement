using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Gpu;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using AppCapabilityAccessStatus = global::Windows.Security.Authorization.AppCapabilityAccess.AppCapabilityAccessStatus;
using GraphicsCaptureAccess = global::Windows.Graphics.Capture.GraphicsCaptureAccess;
using GraphicsCaptureAccessKind = global::Windows.Graphics.Capture.GraphicsCaptureAccessKind;
using GraphicsCaptureSession = global::Windows.Graphics.Capture.GraphicsCaptureSession;

namespace Vantage.Host.Windows.Capture;

/// <summary>
/// <see cref="IScreenSource"/> over <see cref="DisplayEnumerator"/> and Windows.Graphics.Capture.
/// Each capture start makes a fresh <see cref="GpuDevice"/> on the monitor's adapter (after a mode
/// change or driver reset the old one may be gone), which the encoder then shares.
/// </summary>
public sealed class WindowsScreenSource : IScreenSource
{
    private readonly ILogger _log;
    private readonly SemaphoreSlim _accessGate = new(1, 1);
    private bool? _borderless;

    /// <param name="logging">Loggers (category <c>Vantage.Capture</c>).</param>
    public WindowsScreenSource(ILoggerFactory logging) => _log = logging.CreateLogger("Vantage.Capture");

    /// <inheritdoc />
    public bool IsCaptureSupported
    {
        get
        {
            try { return GraphicsCaptureSession.IsSupported(); }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "GraphicsCaptureSession.IsSupported failed");
                return false;
            }
        }
    }

    /// <inheritdoc />
    public string CaptureUnsupportedMessage => "This PC can't share its screen: Windows screen capture isn't available.";

    /// <inheritdoc />
    public Task<IReadOnlyList<DisplayInfo>> GetDisplaysAsync(CancellationToken cancellationToken)
    {
        try
        {
            IReadOnlyList<DisplayInfo> displays = [.. DisplayEnumerator.Enumerate(_log).Select(e => e.Info)];
            return Task.FromResult(displays);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "listing displays failed");
            return Task.FromResult<IReadOnlyList<DisplayInfo>>([]);
        }
    }

    /// <inheritdoc />
    public async Task<ICaptureStream> StartAsync(CaptureRequest request, Action<ICapturedFrame> onFrame, Action<string> onStopped,
                                                 CancellationToken cancellationToken)
    {
        var monitors = DisplayEnumerator.Enumerate(_log);
        var monitor = monitors.FirstOrDefault(m => m.Info.Id == request.Display.Id)
            ?? throw new CaptureUnavailableException(monitors.Count == 0
                ? "no displays are active (the monitor may be asleep or switched off)"
                : $"display {request.Display.Id} ({request.Display.Name}) isn't connected");

        var borderless = await EnsureBorderlessAccessAsync().ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();

        GpuDevice gpu;
        try
        {
            gpu = GpuDevice.CreateForMonitor(monitor.Monitor, _log);
        }
        catch (Exception ex) when (ex is not CaptureUnavailableException)
        {
            throw new CaptureUnavailableException($"couldn't open the graphics adapter: {ex.Message}", ex);
        }

        try
        {
            return WgcCaptureStream.Start(monitor, gpu, request.Fps, borderless, onFrame, onStopped, _log);
        }
        catch (CaptureUnavailableException)
        {
            gpu.Dispose();
            throw;
        }
        catch (Exception ex)
        {
            gpu.Dispose();
            throw new CaptureUnavailableException($"capture couldn't start: {ex.Message}", ex);
        }
    }

    /// <summary>
    /// Asks once per process for borderless capture (no yellow frame around the screen). Windows
    /// grants it to unpackaged desktop apps without a prompt on 11; anything else keeps the border.
    /// </summary>
    private async Task<bool> EnsureBorderlessAccessAsync()
    {
        if (_borderless is { } known) return known;
        await _accessGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_borderless is { } again) return again;
            var granted = false;
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348))
            {
                try
                {
                    var status = await GraphicsCaptureAccess.RequestAccessAsync(GraphicsCaptureAccessKind.Borderless);
                    granted = status == AppCapabilityAccessStatus.Allowed;
                    _log.LogInformation("borderless capture: {Status}", status);
                }
                catch (Exception ex)
                {
                    _log.LogInformation("borderless capture not available: {Message}", ex.Message);
                }
            }
            _borderless = granted;
            return granted;
        }
        finally
        {
            _accessGate.Release();
        }
    }
}

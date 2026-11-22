using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.DesktopHelper;
using Vantage.Host.Windows.Gpu;
using Vantage.Protocol.DesktopHelper;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Vantage.Host.Windows.Capture;

/// <summary>
/// A capture of the secure desktop (lock screen, administrator prompt, Ctrl+Alt+Del) through the
/// SYSTEM desktop helper, used while that desktop has the input; Windows.Graphics.Capture can't see
/// it. The helper sends the areas that changed; they're painted onto a canvas texture on the
/// monitor's GPU, and each complete frame is copied into a pooled texture for the encoder, as WGC
/// frames are. The stream ends itself when the desktop switches back (the session then starts WGC).
/// </summary>
internal sealed class HelperCaptureStream : IGpuCaptureStream
{
    private readonly Lock _gate = new();
    private readonly ILogger _log;
    private readonly Action<ICapturedFrame> _onFrame;
    private readonly Action<string> _onStopped;
    private readonly TexturePool _textures;
    private readonly ID3D11Texture2D _canvas;
    private readonly IDisposable _lease;
    private long _changedPixels;
    private bool _stopped;
    private bool _disposed;

    private HelperCaptureStream(MonitorEntry monitor, GpuDevice gpu, HelperClient helper, int fps, Action<ICapturedFrame> onFrame,
                                Action<string> onStopped, ILogger log)
    {
        Gpu = gpu;
        Display = monitor.Info;
        FrameWidth = monitor.Info.PixelWidth;
        FrameHeight = monitor.Info.PixelHeight;
        _onFrame = onFrame;
        _onStopped = onStopped;
        _log = log;
        _textures = new TexturePool(gpu, FrameWidth, FrameHeight);
        _canvas = gpu.Device.CreateTexture2D(new Texture2DDescription(Format.B8G8R8A8_UNorm, (uint)FrameWidth, (uint)FrameHeight, 1, 1,
                                                                      BindFlags.ShaderResource, ResourceUsage.Default, CpuAccessFlags.None,
                                                                      1, 0, ResourceOptionFlags.None));
        _lease = helper.StartCapture(monitor.GdiName, fps, OnFrame, reason => Stop($"the desktop helper stopped capturing: {reason}"));
        log.LogInformation("capturing {Name} ({Gdi}) on the secure desktop through the desktop helper", monitor.Info.Name, monitor.GdiName);
    }

    public GpuDevice Gpu { get; }

    public DisplayInfo Display { get; }

    public int FrameWidth { get; }

    public int FrameHeight { get; }

    /// <summary>Starts capturing <paramref name="monitor"/> through <paramref name="helper"/>; owns <paramref name="gpu"/>.</summary>
    public static HelperCaptureStream Start(MonitorEntry monitor, GpuDevice gpu, HelperClient helper, int fps,
                                            Action<ICapturedFrame> onFrame, Action<string> onStopped, ILogger log) =>
        new(monitor, gpu, helper, fps, onFrame, onStopped, log);

    // The helper throttles to the rate it was started at; a change only matters for WGC.
    public void SetFrameRate(int fps)
    {
    }

    /// <summary>Ends the stream (the core restarts capture): the secure desktop went away.</summary>
    public void Stop(string reason)
    {
        lock (_gate)
        {
            if (_stopped) return;
            _stopped = true;
        }
        _log.LogInformation("secure desktop capture of {Name} stopped: {Reason}", Display.Name, reason);
        ThreadPool.QueueUserWorkItem(_ =>
        {
            bool notify;
            lock (_gate) notify = !_disposed;
            if (notify) _onStopped(reason);
        });
    }

    private void OnFrame(HelperFrame frame)
    {
        lock (_gate)
        {
            if (_stopped) return;
            if (frame.Width != FrameWidth || frame.Height != FrameHeight)
            {
                ThreadPool.QueueUserWorkItem(_ => Stop($"the secure desktop is {frame.Width}×{frame.Height}, the display {FrameWidth}×{FrameHeight}"));
                return;
            }
            try
            {
                using (Gpu.LockContext())
                {
                    foreach (var strip in frame.Strips)
                    {
                        var box = new Vortice.Mathematics.Box(strip.X, strip.Y, 0, strip.X + strip.Width, strip.Y + strip.Height, 1);
                        Gpu.Context.UpdateSubresource(strip.Pixels, _canvas, 0, (uint)(strip.Width * 4), 0, box);
                        _changedPixels += (long)strip.Width * strip.Height;
                    }
                    if (!frame.IsLastPart) return;

                    var target = _textures.Rent();
                    Gpu.Context.CopyResource(target, _canvas);
                    // Something changed: at least the core's floor, so a caret blink is still sent.
                    var ratio = Math.Clamp((double)_changedPixels / ((long)FrameWidth * FrameHeight), 0.0005, 1.0);
                    _changedPixels = 0;
                    _onFrame(new CapturedTexture(Gpu, target, _textures, frame.TimestampNanos, ratio));
                }
            }
            catch (Exception ex)
            {
                if (Gpu.IsLost) ThreadPool.QueueUserWorkItem(_ => Stop($"the GPU device was lost ({Gpu.Device.DeviceRemovedReason})"));
                else _log.LogWarning(ex, "dropping a secure desktop frame");
            }
        }
    }

    public ValueTask DisposeAsync()
    {
        lock (_gate)
        {
            if (_disposed) return ValueTask.CompletedTask;
            _disposed = true;
            _stopped = true;
        }
        _lease.Dispose();
        lock (_gate)
        {
            _canvas.Dispose();
            _textures.Dispose();
        }
        Gpu.Dispose();
        return ValueTask.CompletedTask;
    }
}

/// <summary>A capture whose frames are textures on <see cref="Gpu"/>, which the Media Foundation encoder shares.</summary>
internal interface IGpuCaptureStream : ICaptureStream
{
    /// <summary>The capture's device.</summary>
    GpuDevice Gpu { get; }
}

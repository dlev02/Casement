using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Gpu;
using Vantage.Host.Windows.Interop;
using Vantage.Protocol.Host;
using Vantage.Protocol.Messages;
using WinRT;
using Direct3D11CaptureFramePool = global::Windows.Graphics.Capture.Direct3D11CaptureFramePool;
using DirectXPixelFormat = global::Windows.Graphics.DirectX.DirectXPixelFormat;
using GraphicsCaptureDirtyRegionMode = global::Windows.Graphics.Capture.GraphicsCaptureDirtyRegionMode;
using GraphicsCaptureItem = global::Windows.Graphics.Capture.GraphicsCaptureItem;
using GraphicsCaptureSession = global::Windows.Graphics.Capture.GraphicsCaptureSession;
using SizeInt32 = global::Windows.Graphics.SizeInt32;

namespace Vantage.Host.Windows.Capture;

/// <summary>
/// One Windows.Graphics.Capture session on one monitor (spec §7.2; plan §1 "Capture"): a
/// free-threaded frame pool of 3 buffers on the monitor's GPU, cursor in the frames, no yellow
/// border when borderless access was granted, <c>MinUpdateInterval</c> (24H2+) plus a throttle,
/// and <c>DirtyRegionMode.ReportOnly</c> (24H2+) for the dirty ratio. Each frame is copied into a
/// pooled texture so WGC's buffer is returned at once. The item closing (display unplugged or
/// asleep, exclusive fullscreen, mode change), a size change or a lost device end the stream
/// through <c>onStopped</c>; the core restarts capture.
/// </summary>
internal sealed class WgcCaptureStream : ICaptureStream
{
    private const int PoolBuffers = 3;
    private static readonly long s_throttleSlackTicks = TimeSpan.FromMilliseconds(2).Ticks;

    private readonly Lock _gate = new();
    private readonly ILogger _log;
    private readonly Action<ICapturedFrame> _onFrame;
    private readonly Action<string> _onStopped;
    private readonly GraphicsCaptureItem _item;
    private readonly Direct3D11CaptureFramePool _pool;
    private readonly GraphicsCaptureSession _session;
    private readonly TexturePool _textures;
    private readonly SizeInt32 _size;
    private readonly bool _hasMinUpdateInterval;
    private readonly bool _reportsDirtyRegions;
    private long _minIntervalTicks;
    private long _lastDeliveredTicks = long.MinValue;
    private bool _stopped;
    private bool _disposed;
    private int _framesSinceLog;

    private WgcCaptureStream(MonitorEntry monitor, GpuDevice gpu, GraphicsCaptureItem item, int fps, bool borderless,
                             Action<ICapturedFrame> onFrame, Action<string> onStopped, ILogger log)
    {
        Gpu = gpu;
        Display = monitor.Info;
        _item = item;
        _log = log;
        _onFrame = onFrame;
        _onStopped = onStopped;
        _size = item.Size;
        FrameWidth = _size.Width;
        FrameHeight = _size.Height;
        _textures = new TexturePool(gpu, _size.Width, _size.Height);
        _minIntervalTicks = IntervalTicks(fps);

        _pool = Direct3D11CaptureFramePool.CreateFreeThreaded(gpu.WinRtDevice, DirectXPixelFormat.B8G8R8A8UIntNormalized, PoolBuffers, _size);
        _session = _pool.CreateCaptureSession(item);
        _session.IsCursorCaptureEnabled = true;
        if (borderless && OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348))
        {
            try { _session.IsBorderRequired = false; }
            catch (Exception ex) { log.LogDebug("IsBorderRequired = false refused: {Message}", ex.Message); }
        }
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 26100))
        {
            try
            {
                _session.DirtyRegionMode = GraphicsCaptureDirtyRegionMode.ReportOnly;
                _reportsDirtyRegions = true;
            }
            catch (Exception ex) { log.LogDebug("DirtyRegionMode unavailable: {Message}", ex.Message); }
            try
            {
                _session.MinUpdateInterval = TimeSpan.FromTicks(_minIntervalTicks);
                _hasMinUpdateInterval = true;
            }
            catch (Exception ex) { log.LogDebug("MinUpdateInterval unavailable: {Message}", ex.Message); }
        }

        _item.Closed += OnItemClosed;
        _pool.FrameArrived += OnFrameArrived;
    }

    public GpuDevice Gpu { get; }

    public DisplayInfo Display { get; }

    public int FrameWidth { get; }

    public int FrameHeight { get; }

    /// <summary>Creates the item for <paramref name="monitor"/> and starts capturing.</summary>
    public static WgcCaptureStream Start(MonitorEntry monitor, GpuDevice gpu, int fps, bool borderless,
                                         Action<ICapturedFrame> onFrame, Action<string> onStopped, ILogger log)
    {
        var item = CreateItemForMonitor(monitor.Monitor);
        var stream = new WgcCaptureStream(monitor, gpu, item, fps, borderless, onFrame, onStopped, log);
        stream._session.StartCapture();
        log.LogInformation("capturing {Name} ({Gdi}) at {Width}×{Height} on {Adapter}; dirty regions {Dirty}, min interval {Min}",
                           monitor.Info.Name, monitor.GdiName, stream.FrameWidth, stream.FrameHeight, gpu.AdapterName,
                           stream._reportsDirtyRegions, stream._hasMinUpdateInterval);
        return stream;
    }

    public void SetFrameRate(int fps)
    {
        var ticks = IntervalTicks(fps);
        Interlocked.Exchange(ref _minIntervalTicks, ticks);
        if (!_hasMinUpdateInterval || !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 26100)) return;
        lock (_gate)
        {
            if (_stopped || _disposed) return;
            try { _session.MinUpdateInterval = TimeSpan.FromTicks(ticks); }
            catch (Exception ex) { _log.LogDebug("MinUpdateInterval change failed: {Message}", ex.Message); }
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
        Teardown();
        return ValueTask.CompletedTask;
    }

    private static GraphicsCaptureItem CreateItemForMonitor(nint monitor)
    {
        using var factory = ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem");
        var iid = ComCalls.IID_IGraphicsCaptureItemInterop;
        ComCalls.Check(Marshal.QueryInterface(factory.ThisPtr, in iid, out var interop), "QueryInterface(IGraphicsCaptureItemInterop)");
        try
        {
            var hr = ComCalls.CreateForMonitor(interop, monitor, ComCalls.IID_IGraphicsCaptureItem, out var itemPointer);
            if (hr < 0 || itemPointer == 0)
                throw new CaptureUnavailableException($"The display can't be captured right now (CreateForMonitor 0x{hr:X8}).");
            try
            {
                return GraphicsCaptureItem.FromAbi(itemPointer);
            }
            finally
            {
                Marshal.Release(itemPointer);
            }
        }
        finally
        {
            Marshal.Release(interop);
        }
    }

    private static long IntervalTicks(int fps) => TimeSpan.TicksPerSecond / Math.Clamp(fps, 1, 240);

    private void OnFrameArrived(Direct3D11CaptureFramePool sender, object args)
    {
        lock (_gate)
        {
            if (_stopped) return;
            try
            {
                using var frame = sender.TryGetNextFrame();
                if (frame is null) return;

                var contentSize = frame.ContentSize;
                if (contentSize.Width != _size.Width || contentSize.Height != _size.Height)
                {
                    StopLocked($"the display changed size from {_size.Width}×{_size.Height} to {contentSize.Width}×{contentSize.Height}");
                    return;
                }

                var time = frame.SystemRelativeTime.Ticks; // QPC-based, the same clock as HostClock
                var interval = Interlocked.Read(ref _minIntervalTicks);
                if (_lastDeliveredTicks != long.MinValue && time - _lastDeliveredTicks < interval - s_throttleSlackTicks) return;

                var dirty = 1.0;
                if (_reportsDirtyRegions && OperatingSystem.IsWindowsVersionAtLeast(10, 0, 26100)
                    && frame.DirtyRegionMode == GraphicsCaptureDirtyRegionMode.ReportOnly)
                {
                    var regions = frame.DirtyRegions;
                    var rects = new PixelRect[regions.Count];
                    for (var i = 0; i < rects.Length; i++)
                    {
                        var r = regions[i];
                        rects[i] = new PixelRect(r.X, r.Y, r.Width, r.Height);
                    }
                    dirty = DirtyRegionMath.Ratio(rects, _size.Width, _size.Height);
                }

                var target = _textures.Rent();
                try
                {
                    using var source = GpuDevice.TextureFromSurface(frame.Surface);
                    Gpu.Context.CopyResource(target, source);
                }
                catch
                {
                    _textures.Return(target);
                    throw;
                }
                _lastDeliveredTicks = time;
                var captured = new CapturedTexture(Gpu, target, _textures, (ulong)time * 100, dirty);
                if (++_framesSinceLog == 1) _log.LogDebug("first frame from {Name}", Display.Name);
                _onFrame(captured);
            }
            catch (Exception ex)
            {
                if (Gpu.IsLost) StopLocked($"the GPU device was lost ({Gpu.Device.DeviceRemovedReason})");
                else _log.LogWarning(ex, "dropping a captured frame");
            }
        }
    }

    private void OnItemClosed(GraphicsCaptureItem sender, object args)
    {
        lock (_gate) StopLocked("the capture item closed (display removed, asleep, or changed mode)");
    }

    private void StopLocked(string reason)
    {
        if (_stopped) return;
        _stopped = true;
        _log.LogInformation("capture of {Name} stopped: {Reason}", Display.Name, reason);
        // Callbacks and teardown off the WGC thread: disposing the pool from its own event deadlocks.
        ThreadPool.QueueUserWorkItem(_ =>
        {
            bool notify;
            lock (_gate) notify = !_disposed;
            if (notify) _onStopped(reason);
        });
    }

    private void Teardown()
    {
        try
        {
            _pool.FrameArrived -= OnFrameArrived;
            _item.Closed -= OnItemClosed;
            _session.Dispose();
            _pool.Dispose();
        }
        catch (Exception ex)
        {
            _log.LogDebug("capture teardown: {Message}", ex.Message);
        }
        _textures.Dispose();
        Gpu.Dispose();
    }
}

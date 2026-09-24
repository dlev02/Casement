using Vantage.Protocol.Messages;

namespace Vantage.Protocol.Host;

/// <summary>
/// The displays and their capture (Windows: DXGI/DisplayConfig enumeration +
/// Windows.Graphics.Capture). Frames are opaque to the protocol library: they go from here to the
/// <see cref="IVideoEncoder"/> created for the same stream, never through graphics types here.
/// </summary>
/// <remarks>
/// <see cref="HostSessionCore"/> owns the pipeline logic (spec §7.2): which display, when to force
/// an IDR, idle suppression, at most one frame in the encoder, the capture watchdog. The platform
/// only captures and encodes.
/// </remarks>
public interface IScreenSource
{
    /// <summary>
    /// Whether this machine can capture at all (Windows: <c>GraphicsCaptureSession.IsSupported()</c>).
    /// When false a screen session is refused with <c>authResult{denied, message: <see cref="CaptureUnsupportedMessage"/>}</c>.
    /// Probes and files-only sessions never ask.
    /// </summary>
    bool IsCaptureSupported { get; }

    /// <summary>User-facing reason shown on the iPad when <see cref="IsCaptureSupported"/> is false.</summary>
    string CaptureUnsupportedMessage { get; }

    /// <summary>
    /// The displays right now (spec §9.2), primary first is not required: the core picks the one
    /// with <see cref="DisplayInfo.IsMain"/>. Called when a screen session authenticates, on
    /// <c>refreshDisplays</c>, and at each capture (re)start. Return an empty list, don't throw, when
    /// the topology is empty (a DisplayPort monitor asleep).
    /// </summary>
    /// <remarks>
    /// Windows fields: <c>id</c> = n of <c>\\.\DISPLAYn</c>; <c>scale</c> = effective DPI / 96;
    /// <c>pointWidth</c> = round(pixelWidth / scale); <c>originX/Y</c> = the monitor's top-left in
    /// virtual-desktop pixels; <c>isBuiltIn</c> = internal output technology; <c>isVirtual</c> = false;
    /// <c>refreshRate</c> = dmDisplayFrequency.
    /// </remarks>
    Task<IReadOnlyList<DisplayInfo>> GetDisplaysAsync(CancellationToken cancellationToken);

    /// <summary>
    /// Starts capturing <see cref="CaptureRequest.Display"/> at up to <see cref="CaptureRequest.Fps"/>
    /// frames per second, with the cursor drawn into the frames (the Mac does the same; the client
    /// never draws one). Throws <see cref="CaptureUnavailableException"/> when capture can't start
    /// (display gone or asleep, secure desktop, access revoked); the core then retries with backoff
    /// for the whole session and never ends it over this.
    /// </summary>
    /// <param name="request">What to capture.</param>
    /// <param name="onFrame">
    /// Called for each new frame, one call at a time (never concurrently), from any thread. The
    /// core takes ownership and disposes the frame. It keeps the latest frame alive until a newer
    /// one arrives so it can re-encode it as an IDR on a static screen: size the frame pool for
    /// that (Windows: at least 3 buffers) or hand out copies. Deliver frames even when nothing
    /// changed if the platform does so cheaply; the core skips encoding when
    /// <see cref="ICapturedFrame.DirtyRatio"/> is ~0 and no keyframe is pending.
    /// </param>
    /// <param name="onStopped">
    /// Called at most once if capture stops on its own (Windows: <c>GraphicsCaptureItem.Closed</c>,
    /// device lost, a size or DPI change, the monitor leaving the topology). The reason is logged.
    /// Not called after the stream is disposed.
    /// </param>
    /// <param name="cancellationToken">Cancels a start still in progress.</param>
    Task<ICaptureStream> StartAsync(CaptureRequest request, Action<ICapturedFrame> onFrame, Action<string> onStopped,
                                    CancellationToken cancellationToken);
}

/// <summary>What to capture.</summary>
/// <param name="Display">The display, as last returned by <see cref="IScreenSource.GetDisplaysAsync"/>.</param>
/// <param name="Fps">Frames per second to aim for (≤ 60). May change later through <see cref="ICaptureStream.SetFrameRate"/>.</param>
public sealed record CaptureRequest(DisplayInfo Display, int Fps);

/// <summary>A running capture. Disposing stops it (no <c>onStopped</c> callback follows).</summary>
public interface ICaptureStream : IAsyncDisposable
{
    /// <summary>The display being captured, with the geometry capture actually uses.</summary>
    DisplayInfo Display { get; }

    /// <summary>Pixel size of the frames delivered (normally the display's pixel size).</summary>
    int FrameWidth { get; }

    /// <summary>Pixel size of the frames delivered.</summary>
    int FrameHeight { get; }

    /// <summary>
    /// The adaptive controller's frame-rate choice (30 for text, 60 for motion). Windows:
    /// <c>MinUpdateInterval</c> where available, else throttle delivery.
    /// </summary>
    void SetFrameRate(int fps);
}

/// <summary>
/// One captured frame, opaque to the protocol library (Windows: an <c>ID3D11Texture2D</c> on the
/// capture device). Only the <see cref="IVideoEncoder"/> made for the same <see cref="ICaptureStream"/>
/// looks inside.
/// </summary>
public interface ICapturedFrame : IDisposable
{
    /// <summary>Capture time on the host's monotonic clock, in nanoseconds (<see cref="HostClock.Nanos"/>).</summary>
    ulong TimestampNanos { get; }

    /// <summary>
    /// Fraction of the frame area that changed since the previous frame, 0…1 (Windows 24H2+:
    /// <c>DirtyRegionMode.ReportOnly</c> rects). Report 1 when unknown; 0 only when the platform
    /// knows nothing changed (the core then skips encoding it unless a keyframe is pending).
    /// </summary>
    double DirtyRatio { get; }

    /// <summary>Pixel width.</summary>
    int Width { get; }

    /// <summary>Pixel height.</summary>
    int Height { get; }
}

/// <summary>Capture can't start or run right now; the message is logged and capture is retried.</summary>
public sealed class CaptureUnavailableException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>The host's monotonic clock in nanoseconds, shared by capture timestamps and the core.</summary>
public static class HostClock
{
    private static readonly double s_nanosPerTick = 1_000_000_000.0 / System.Diagnostics.Stopwatch.Frequency;

    /// <summary>Nanoseconds on <see cref="System.Diagnostics.Stopwatch"/>'s clock.</summary>
    public static ulong Nanos => (ulong)(System.Diagnostics.Stopwatch.GetTimestamp() * s_nanosPerTick);
}

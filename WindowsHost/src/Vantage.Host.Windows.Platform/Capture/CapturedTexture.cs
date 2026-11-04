using Vantage.Host.Windows.Gpu;
using Vantage.Protocol.Host;
using Vortice.Direct3D11;

namespace Vantage.Host.Windows.Capture;

/// <summary>A captured frame: a BGRA texture on the capture's GPU device, returned to its pool on dispose.</summary>
internal sealed class CapturedTexture : ICapturedFrame
{
    private readonly TexturePool _pool;
    private readonly FrameEstimate? _estimate;
    private readonly double _dirtyRatio;
    private ID3D11Texture2D? _texture;

    /// <param name="gpu">The capture's device.</param>
    /// <param name="texture">The pooled copy of the frame.</param>
    /// <param name="pool">Where the texture goes back on dispose.</param>
    /// <param name="timestampNanos">Capture time.</param>
    /// <param name="dirtyRatio">The ratio when there's no <paramref name="estimate"/> (native dirty regions, or 1).</param>
    /// <param name="estimate">The GPU compare's pending answer, read when the core first asks.</param>
    public CapturedTexture(GpuDevice gpu, ID3D11Texture2D texture, TexturePool pool, ulong timestampNanos, double dirtyRatio,
                           FrameEstimate? estimate = null)
    {
        Gpu = gpu;
        _texture = texture;
        _pool = pool;
        TimestampNanos = timestampNanos;
        _dirtyRatio = dirtyRatio;
        _estimate = estimate;
        Width = pool.Width;
        Height = pool.Height;
    }

    public GpuDevice Gpu { get; }

    /// <summary>The pixels (B8G8R8A8_UNorm). Throws after dispose.</summary>
    public ID3D11Texture2D Texture => _texture ?? throw new ObjectDisposedException(nameof(CapturedTexture));

    public ulong TimestampNanos { get; }

    public double DirtyRatio => _estimate?.Ratio ?? _dirtyRatio;

    public int Width { get; }

    public int Height { get; }

    public void Dispose()
    {
        var texture = Interlocked.Exchange(ref _texture, null);
        if (texture is not null) _pool.Return(texture);
    }
}

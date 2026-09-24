using Vantage.Host.Windows.Gpu;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Vantage.Host.Windows.Capture;

/// <summary>
/// Reusable BGRA textures the size of the capture. Each WGC frame is copied into one on the GPU and
/// the WGC buffer goes straight back to its pool, so the core can keep the latest frame for as long
/// as it likes (to re-encode it as an IDR on a static screen) without starving capture.
/// </summary>
internal sealed class TexturePool : IDisposable
{
    private const int MaxIdle = 4;

    private readonly GpuDevice _gpu;
    private readonly Texture2DDescription _description;
    private readonly Stack<ID3D11Texture2D> _idle = new();
    private readonly Lock _lock = new();
    private bool _disposed;

    public TexturePool(GpuDevice gpu, int width, int height)
    {
        _gpu = gpu;
        Width = width;
        Height = height;
        _description = new Texture2DDescription(Format.B8G8R8A8_UNorm, (uint)width, (uint)height, 1, 1,
                                                BindFlags.ShaderResource | BindFlags.RenderTarget,
                                                ResourceUsage.Default, CpuAccessFlags.None, 1, 0, ResourceOptionFlags.None);
    }

    public int Width { get; }

    public int Height { get; }

    public ID3D11Texture2D Rent()
    {
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_idle.TryPop(out var texture)) return texture;
        }
        return _gpu.Device.CreateTexture2D(_description);
    }

    public void Return(ID3D11Texture2D texture)
    {
        lock (_lock)
        {
            if (!_disposed && _idle.Count < MaxIdle)
            {
                _idle.Push(texture);
                return;
            }
        }
        texture.Dispose();
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _disposed = true;
            while (_idle.TryPop(out var texture)) texture.Dispose();
        }
    }
}

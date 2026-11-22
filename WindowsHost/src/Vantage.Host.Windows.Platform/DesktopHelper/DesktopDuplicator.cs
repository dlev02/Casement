using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.DesktopHelper;
using Vantage.Protocol.Host;
using Vortice;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Vantage.Host.Windows.DesktopHelper;

/// <summary>
/// The SYSTEM helper's view of one monitor through DXGI desktop duplication, which (unlike
/// Windows.Graphics.Capture) works on the secure desktop when the caller runs as SYSTEM on a thread
/// attached to it. Each frame comes back as the rectangles that changed (the whole screen after a
/// start or a desktop switch), copied off the GPU through one staging texture. The pointer isn't
/// in the frames (duplication leaves it out); devices that draw their own pointer still show it.
/// </summary>
/// <remarks>Not thread-safe: one capture thread owns it. Dispose and make a new one after <see cref="DuplicationLostException"/>.</remarks>
internal sealed class DesktopDuplicator : IDisposable
{
    private readonly ID3D11Device _device;
    private readonly ID3D11DeviceContext _context;
    private readonly IDXGIOutputDuplication _duplication;
    private readonly ID3D11Texture2D _staging;
    private RawRect[] _dirty = new RawRect[16];
    private OutduplMoveRect[] _moves = new OutduplMoveRect[8];
    private bool _sentWhole;

    private DesktopDuplicator(ID3D11Device device, ID3D11DeviceContext context, IDXGIOutputDuplication duplication, int width, int height)
    {
        _device = device;
        _context = context;
        _duplication = duplication;
        Width = width;
        Height = height;
        _staging = device.CreateTexture2D(new Texture2DDescription(Format.B8G8R8A8_UNorm, (uint)width, (uint)height, 1, 1, BindFlags.None,
                                                                   ResourceUsage.Staging, CpuAccessFlags.Read, 1, 0, ResourceOptionFlags.None));
    }

    public int Width { get; }

    public int Height { get; }

    /// <summary>Duplicates the output whose GDI name is <paramref name="monitorDevice"/> (<c>\\.\DISPLAY1</c>).</summary>
    /// <exception cref="DuplicationLostException">The output isn't there, or the desktop can't be duplicated right now.</exception>
    public static DesktopDuplicator Open(string monitorDevice, ILogger log)
    {
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        for (uint index = 0; factory.EnumAdapters1(index, out var adapter).Success; index++)
        {
            using (adapter)
            {
                for (uint outputIndex = 0; adapter.EnumOutputs(outputIndex, out var output).Success; outputIndex++)
                {
                    using (output)
                    {
                        var description = output.Description;
                        if (!string.Equals(description.DeviceName.TrimEnd('\0'), monitorDevice, StringComparison.OrdinalIgnoreCase)) continue;
                        var bounds = description.DesktopCoordinates;
                        var width = bounds.Right - bounds.Left;
                        var height = bounds.Bottom - bounds.Top;
                        if (description.Rotation is not (ModeRotation.Identity or ModeRotation.Unspecified))
                            log.LogWarning("{Monitor} is rotated; the secure desktop may look turned", monitorDevice);

                        D3D11.D3D11CreateDevice(adapter, DriverType.Unknown, DeviceCreationFlags.BgraSupport,
                                                [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0],
                                                out ID3D11Device device, out ID3D11DeviceContext context).CheckError();
                        try
                        {
                            using var output1 = output.QueryInterface<IDXGIOutput1>();
                            var duplication = output1.DuplicateOutput(device);
                            return new DesktopDuplicator(device, context, duplication, width, height);
                        }
                        catch (SharpGen.Runtime.SharpGenException ex)
                        {
                            context.Dispose();
                            device.Dispose();
                            throw new DuplicationLostException($"duplicating {monitorDevice} failed (0x{ex.HResult:X8})", ex);
                        }
                    }
                }
            }
        }
        throw new DuplicationLostException($"no output named {monitorDevice}");
    }

    /// <summary>
    /// The next frame, or null when nothing changed within <paramref name="timeoutMs"/> (or only
    /// the pointer moved).
    /// </summary>
    /// <exception cref="DuplicationLostException">The desktop switched, the mode changed, or the device went away.</exception>
    public HelperFrame? Next(uint timeoutMs)
    {
        var result = _duplication.AcquireNextFrame(timeoutMs, out var info, out var resource);
        if (result.Code == Vortice.DXGI.ResultCode.WaitTimeout.Code) return null;
        if (result.Failure) throw new DuplicationLostException($"AcquireNextFrame failed (0x{result.Code:X8})");

        var timestamp = HostClock.Nanos;
        List<RawRect> rects;
        try
        {
            using (resource)
            {
                if (info.LastPresentTime == 0) return null; // only the pointer moved
                rects = _sentWhole ? ChangedRects(info.TotalMetadataBufferSize) : [new RawRect(0, 0, Width, Height)];
                if (rects.Count == 0) return null;
                using var texture = resource.QueryInterface<ID3D11Texture2D>();
                _context.CopyResource(_staging, texture);
            }
        }
        finally
        {
            _duplication.ReleaseFrame();
        }

        var map = _context.Map(_staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
        try
        {
            var strips = new HelperFrameStrip[rects.Count];
            for (var i = 0; i < rects.Count; i++)
            {
                var r = rects[i];
                int w = r.Right - r.Left, h = r.Bottom - r.Top;
                var pixels = new byte[w * h * 4];
                for (var row = 0; row < h; row++)
                {
                    var source = map.DataPointer + (nint)((r.Top + row) * (long)map.RowPitch + r.Left * 4L);
                    Marshal.Copy(source, pixels, row * w * 4, w * 4);
                }
                strips[i] = new HelperFrameStrip(r.Left, r.Top, w, h, pixels);
            }
            _sentWhole = true;
            return new HelperFrame(Width, Height, timestamp, strips);
        }
        finally
        {
            _context.Unmap(_staging, 0);
        }
    }

    /// <summary>Dirty rectangles plus where moved areas landed, clipped to the screen.</summary>
    private List<RawRect> ChangedRects(uint metadataSize)
    {
        var rects = new List<RawRect>();
        if (metadataSize == 0) return rects;

        uint needed;
        while (_duplication.GetFrameMoveRects((uint)(_moves.Length * Marshal.SizeOf<OutduplMoveRect>()), _moves, out needed).Code == Vortice.DXGI.ResultCode.MoreData.Code)
            _moves = new OutduplMoveRect[needed / Marshal.SizeOf<OutduplMoveRect>() + 1];
        var moveCount = (int)(needed / Marshal.SizeOf<OutduplMoveRect>());
        for (var i = 0; i < moveCount; i++) Add(rects, _moves[i].DestinationRect);

        while (_duplication.GetFrameDirtyRects((uint)(_dirty.Length * Marshal.SizeOf<RawRect>()), _dirty, out needed).Code == Vortice.DXGI.ResultCode.MoreData.Code)
            _dirty = new RawRect[needed / Marshal.SizeOf<RawRect>() + 1];
        var dirtyCount = (int)(needed / Marshal.SizeOf<RawRect>());
        for (var i = 0; i < dirtyCount; i++) Add(rects, _dirty[i]);
        return rects;

        void Add(List<RawRect> list, RawRect r)
        {
            var clipped = new RawRect(Math.Max(0, r.Left), Math.Max(0, r.Top), Math.Min(Width, r.Right), Math.Min(Height, r.Bottom));
            if (clipped.Right > clipped.Left && clipped.Bottom > clipped.Top) list.Add(clipped);
        }
    }

    public void Dispose()
    {
        _staging.Dispose();
        _duplication.Dispose();
        _context.Dispose();
        _device.Dispose();
    }
}

/// <summary>Duplication ended (desktop switch, mode change, device lost) or couldn't start; open a new one.</summary>
internal sealed class DuplicationLostException(string message, Exception? inner = null) : Exception(message, inner);

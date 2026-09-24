using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Interop;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using WinRT;
using IDirect3DDevice = global::Windows.Graphics.DirectX.Direct3D11.IDirect3DDevice;
using IDirect3DSurface = global::Windows.Graphics.DirectX.Direct3D11.IDirect3DSurface;

namespace Vantage.Host.Windows.Gpu;

/// <summary>
/// One D3D11 device on the adapter that drives a given monitor, shared by capture (the WGC frame
/// pool and texture copies), colour conversion (<c>ID3D11VideoProcessor</c>) and the Media
/// Foundation encoder (through an <c>IMFDXGIDeviceManager</c>). Created with
/// <c>VIDEO_SUPPORT | BGRA_SUPPORT</c> and multithread-protected, since MF drives it from its own threads.
/// </summary>
/// <remarks>
/// drew-pc has an NVIDIA RTX 5070 Ti and an AMD iGPU: the adapter is found by the output whose
/// <c>HMONITOR</c> is the captured monitor, never "the first adapter", so capture never crosses
/// adapters and the encoder is the GPU the monitor is plugged into.
/// </remarks>
public sealed class GpuDevice : IDisposable
{
    private int _references = 1;

    private GpuDevice(ID3D11Device device, ID3D11DeviceContext context, ID3D11VideoDevice videoDevice,
                      ID3D11VideoContext videoContext, IDirect3DDevice winRtDevice, AdapterDescription1 adapter)
    {
        Device = device;
        Context = context;
        VideoDevice = videoDevice;
        VideoContext = videoContext;
        WinRtDevice = winRtDevice;
        AdapterName = adapter.Description;
        AdapterLuid = ((long)adapter.Luid.HighPart << 32) | adapter.Luid.LowPart;
        VendorId = adapter.VendorId;
    }

    /// <summary>The D3D11 device.</summary>
    public ID3D11Device Device { get; }

    /// <summary>Its immediate context (thread-safe: the device is multithread-protected).</summary>
    public ID3D11DeviceContext Context { get; }

    /// <summary>For the colour converter.</summary>
    public ID3D11VideoDevice VideoDevice { get; }

    /// <summary>For the colour converter.</summary>
    public ID3D11VideoContext VideoContext { get; }

    /// <summary>The same device as a WinRT <c>IDirect3DDevice</c>, for the capture frame pool.</summary>
    public IDirect3DDevice WinRtDevice { get; }

    /// <summary>"NVIDIA GeForce RTX 5070 Ti".</summary>
    public string AdapterName { get; }

    /// <summary>The adapter LUID (for <c>MFT_ENUM_ADAPTER_LUID</c>), high part in the top 32 bits.</summary>
    public long AdapterLuid { get; }

    /// <summary>PCI vendor id (0x10DE NVIDIA, 0x1002 AMD, 0x8086 Intel).</summary>
    public uint VendorId { get; }

    /// <summary>True once the device was removed or reset (driver update, TDR); make a new one.</summary>
    public bool IsLost => Device.DeviceRemovedReason.Failure;

    /// <summary>
    /// Creates a device on the adapter whose output is <paramref name="monitor"/>. Falls back to the
    /// first hardware adapter with a warning only if no output matches (e.g. a monitor that just left).
    /// </summary>
    public static GpuDevice CreateForMonitor(nint monitor, ILogger log)
    {
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>();
        IDXGIAdapter1? chosen = null;
        IDXGIAdapter1? firstHardware = null;
        for (uint index = 0; factory.EnumAdapters1(index, out var adapter).Success; index++)
        {
            var description = adapter.Description1;
            var isSoftware = (description.Flags & AdapterFlags.Software) != 0;
            var drivesMonitor = false;
            for (uint outputIndex = 0; adapter.EnumOutputs(outputIndex, out var output).Success; outputIndex++)
            {
                using (output)
                {
                    if (output.Description.Monitor == monitor) drivesMonitor = true;
                }
            }
            if (drivesMonitor && chosen is null)
            {
                chosen = adapter;
                continue;
            }
            if (!isSoftware && firstHardware is null)
            {
                firstHardware = adapter;
                continue;
            }
            adapter.Dispose();
        }

        if (chosen is null)
        {
            if (firstHardware is null) throw new InvalidOperationException("No hardware graphics adapter.");
            log.LogWarning("no adapter lists the captured monitor as an output; using {Adapter}", firstHardware.Description1.Description);
            chosen = firstHardware;
            firstHardware = null;
        }
        firstHardware?.Dispose();

        using (chosen)
        {
            return Create(chosen, log);
        }
    }

    private static GpuDevice Create(IDXGIAdapter1 adapter, ILogger log)
    {
        var description = adapter.Description1;
        FeatureLevel[] levels = [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0];
        var result = D3D11.D3D11CreateDevice(adapter, DriverType.Unknown,
                                             DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport,
                                             levels, out ID3D11Device device, out ID3D11DeviceContext context);
        result.CheckError();

        using (var multithread = device.QueryInterface<ID3D11Multithread>())
        {
            multithread.SetMultithreadProtected(true);
        }

        var videoDevice = device.QueryInterface<ID3D11VideoDevice>();
        var videoContext = context.QueryInterface<ID3D11VideoContext>();

        IDirect3DDevice winRtDevice;
        using (var dxgiDevice = device.QueryInterface<IDXGIDevice>())
        {
            ComCalls.Check(ComCalls.CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice.NativePointer, out var inspectable),
                           "CreateDirect3D11DeviceFromDXGIDevice");
            try
            {
                winRtDevice = MarshalInterface<IDirect3DDevice>.FromAbi(inspectable);
            }
            finally
            {
                Marshal.Release(inspectable);
            }
        }

        log.LogInformation("GPU: {Adapter} (vendor 0x{Vendor:X4}, LUID {Luid:X}), feature level {Level}",
                           description.Description, description.VendorId,
                           ((long)description.Luid.HighPart << 32) | description.Luid.LowPart, device.FeatureLevel);
        return new GpuDevice(device, context, videoDevice, videoContext, winRtDevice, description);
    }

    /// <summary>
    /// The <c>ID3D11Texture2D</c> behind a WinRT capture surface (via <c>IDirect3DDxgiInterfaceAccess</c>).
    /// The caller owns the returned reference.
    /// </summary>
    public static ID3D11Texture2D TextureFromSurface(IDirect3DSurface surface)
    {
        var abi = MarshalInterface<IDirect3DSurface>.FromManaged(surface);
        try
        {
            var iid = ComCalls.IID_IDirect3DDxgiInterfaceAccess;
            ComCalls.Check(Marshal.QueryInterface(abi, in iid, out var access), "QueryInterface(IDirect3DDxgiInterfaceAccess)");
            try
            {
                ComCalls.Check(ComCalls.GetDxgiInterface(access, ComCalls.IID_ID3D11Texture2D, out var texture), "IDirect3DDxgiInterfaceAccess.GetInterface");
                return new ID3D11Texture2D(texture);
            }
            finally
            {
                Marshal.Release(access);
            }
        }
        finally
        {
            Marshal.Release(abi);
        }
    }

    /// <summary>Takes another reference (capture and the encoder each hold one).</summary>
    public GpuDevice AddReference()
    {
        Interlocked.Increment(ref _references);
        return this;
    }

    /// <summary>Drops a reference; the device goes when the last one does.</summary>
    public void Dispose()
    {
        if (Interlocked.Decrement(ref _references) != 0) return;
        (WinRtDevice as IDisposable)?.Dispose();
        VideoContext.Dispose();
        VideoDevice.Dispose();
        Context.Dispose();
        Device.Dispose();
    }
}

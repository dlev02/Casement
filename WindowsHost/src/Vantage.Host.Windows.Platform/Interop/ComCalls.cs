using System.Runtime.InteropServices;

namespace Vantage.Host.Windows.Interop;

/// <summary>
/// Direct vtable calls for the few COM interfaces neither Vortice nor the WinRT projection covers.
/// Slot numbers are from the Win32 metadata (Windows.Win32.winmd 71.0.14): IUnknown takes 0–2.
/// </summary>
internal static unsafe class ComCalls
{
    /// <summary><c>IGraphicsCaptureItemInterop</c> (windows.graphics.capture.interop.h).</summary>
    public static readonly Guid IID_IGraphicsCaptureItemInterop = new("3628e81b-3cac-4c60-b7f4-23ce0e0c3356");

    /// <summary>The ABI <c>IGraphicsCaptureItem</c> interface (what <c>CreateForMonitor</c> is asked for).</summary>
    public static readonly Guid IID_IGraphicsCaptureItem = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");

    /// <summary><c>IDirect3DDxgiInterfaceAccess</c> (windows.graphics.directx.direct3d11.interop.h).</summary>
    public static readonly Guid IID_IDirect3DDxgiInterfaceAccess = new("a9b3d012-3df2-4ee3-b8d1-8695f457d3c1");

    /// <summary><c>ID3D11Texture2D</c>.</summary>
    public static readonly Guid IID_ID3D11Texture2D = new("6f15aaf2-d208-4e89-9ab4-489535d34f9c");

    /// <summary>Throws for a failed HRESULT.</summary>
    public static void Check(int hr, string what)
    {
        if (hr < 0) throw new COMException($"{what} failed (0x{hr:X8})", hr);
    }

    /// <summary><c>IGraphicsCaptureItemInterop::CreateForMonitor</c> (slot 4, after CreateForWindow).</summary>
    public static int CreateForMonitor(nint interop, nint monitor, in Guid riid, out nint item)
    {
        var fn = (delegate* unmanaged[Stdcall]<nint, nint, Guid*, nint*, int>)(*(void***)interop)[4];
        nint result = 0;
        int hr;
        fixed (Guid* iid = &riid) hr = fn(interop, monitor, iid, &result);
        item = result;
        return hr;
    }

    /// <summary><c>IDirect3DDxgiInterfaceAccess::GetInterface</c> (slot 3).</summary>
    public static int GetDxgiInterface(nint access, in Guid riid, out nint result)
    {
        var fn = (delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)(*(void***)access)[3];
        nint value = 0;
        int hr;
        fixed (Guid* iid = &riid) hr = fn(access, iid, &value);
        result = value;
        return hr;
    }

    [DllImport("d3d11.dll", ExactSpelling = true)]
    public static extern int CreateDirect3D11DeviceFromDXGIDevice(nint dxgiDevice, out nint graphicsDevice);
}

/// <summary>
/// A <c>VARIANT</c> holding the integer types <c>ICodecAPI</c> uses (VT_UI4, VT_UI8, VT_BOOL). 24 bytes,
/// the x64/ARM64 layout (the host ships for win-x64 only).
/// </summary>
[StructLayout(LayoutKind.Explicit, Size = 24)]
internal struct CodecVariant
{
    public const ushort VT_EMPTY = 0;
    public const ushort VT_BOOL = 11;
    public const ushort VT_UI4 = 19;
    public const ushort VT_UI8 = 21;

    [FieldOffset(0)] public ushort Type;
    [FieldOffset(8)] public uint UInt32;
    [FieldOffset(8)] public ulong UInt64;
    [FieldOffset(8)] public short Bool;

    public static CodecVariant FromUInt32(uint value) => new() { Type = VT_UI4, UInt32 = value };
    public static CodecVariant FromUInt64(ulong value) => new() { Type = VT_UI8, UInt64 = value };
    public static CodecVariant FromBool(bool value) => new() { Type = VT_BOOL, Bool = value ? (short)-1 : (short)0 };

    public override readonly string ToString() => Type switch
    {
        VT_UI4 => UInt32.ToString(global::System.Globalization.CultureInfo.InvariantCulture),
        VT_UI8 => UInt64.ToString(global::System.Globalization.CultureInfo.InvariantCulture),
        VT_BOOL => Bool != 0 ? "true" : "false",
        _ => $"vt {Type}",
    };
}

/// <summary>
/// <c>ICodecAPI</c> (codecapi.h / strmif.h) on an encoder MFT, called through its vtable. Slots from
/// the Win32 metadata: IsSupported 3, IsModifiable 4, GetParameterRange 5, GetParameterValues 6,
/// GetDefaultValue 7, GetValue 8, SetValue 9.
/// </summary>
internal sealed unsafe class CodecApi : IDisposable
{
    public static readonly Guid IID_ICodecAPI = new("901db4c7-31ce-41a2-85dc-8fa0bf41b8da");

    private nint _pointer;

    private CodecApi(nint pointer) => _pointer = pointer;

    /// <summary>Queries <paramref name="unknown"/> (an MFT) for ICodecAPI; null if it has none.</summary>
    public static CodecApi? From(nint unknown)
    {
        var iid = IID_ICodecAPI;
        return Marshal.QueryInterface(unknown, in iid, out var pointer) >= 0 && pointer != 0 ? new CodecApi(pointer) : null;
    }

    public bool IsSupported(Guid api)
    {
        var fn = (delegate* unmanaged[Stdcall]<nint, Guid*, int>)(*(void***)_pointer)[3];
        return fn(_pointer, &api) == 0;
    }

    public bool IsModifiable(Guid api)
    {
        var fn = (delegate* unmanaged[Stdcall]<nint, Guid*, int>)(*(void***)_pointer)[4];
        return fn(_pointer, &api) == 0;
    }

    public int GetValue(Guid api, out CodecVariant value)
    {
        var fn = (delegate* unmanaged[Stdcall]<nint, Guid*, CodecVariant*, int>)(*(void***)_pointer)[8];
        CodecVariant result = default;
        var hr = fn(_pointer, &api, &result);
        value = result;
        return hr;
    }

    public int SetValue(Guid api, CodecVariant value)
    {
        var fn = (delegate* unmanaged[Stdcall]<nint, Guid*, CodecVariant*, int>)(*(void***)_pointer)[9];
        return fn(_pointer, &api, &value);
    }

    public void Dispose()
    {
        var pointer = Interlocked.Exchange(ref _pointer, 0);
        if (pointer != 0) Marshal.Release(pointer);
    }
}

/// <summary><c>CODECAPI_*</c> property GUIDs (codecapi.h), checked against the Win32 metadata.</summary>
internal static class CodecApiKeys
{
    public static readonly Guid AVLowLatencyMode = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");
    public static readonly Guid AVEncCommonRateControlMode = new("1c0608e9-370c-4710-8a58-cb6181c42423");
    public static readonly Guid AVEncCommonMeanBitRate = new("f7222374-2144-4815-b550-a37f8e12ee52");
    public static readonly Guid AVEncCommonMaxBitRate = new("9651eae4-39b9-4ebf-85ef-d7f444ec7465");
    public static readonly Guid AVEncCommonBufferSize = new("0db96574-b6a4-4c8b-8106-3773de0310cd");
    public static readonly Guid AVEncCommonQualityVsSpeed = new("98332df8-03cd-476b-89fa-3f9e442dec9f");
    public static readonly Guid AVEncMPVDefaultBPictureCount = new("8d390aac-dc5c-4200-b57f-814d04babab2");
    public static readonly Guid AVEncMPVGOPSize = new("95f31b26-95a4-41aa-9303-246a7fc6eef1");
    public static readonly Guid AVEncMPVProfile = new("dabb534a-1d99-4284-975a-d90e2239baa1");
    public static readonly Guid AVEncVideoForceKeyFrame = new("398c1b98-8353-475a-9ef2-8f265d260345");
    public static readonly Guid AVEncVideoMaxQP = new("3daf6f66-a6a7-45e0-a8e5-f2743f46a3a2");
    public static readonly Guid AVEncH264CABACEnable = new("ee6cad62-d305-4248-a50e-e1b255f7caf8");

    // eAVEncCommonRateControlMode
    public const uint RateControlCbr = 0;
    public const uint RateControlLowDelayVbr = 4;

    // eAVEncH264VProfile
    public const uint ProfileHigh = 100;
    public const uint ProfileMain = 77;
}

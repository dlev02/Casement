using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Vantage.Protocol.Audio;

namespace Vantage.Host.Windows.Audio;

/// <summary>
/// The WASAPI surface the loopback capture needs, called through vtables like
/// <see cref="Interop.ComCalls"/> (Vortice.MediaFoundation has <c>IMMDevice</c> but no
/// <c>IAudioClient</c>, and built-in COM interop would need marshalling the project turns off).
/// Slot numbers are from the Win32 metadata (audioclient.h, mmdeviceapi.h, propsys.h); IUnknown
/// takes 0–2. Everything here runs on an MTA thread the caller set up.
/// </summary>
internal static unsafe class Wasapi
{
    public static readonly Guid CLSID_MMDeviceEnumerator = new("bcde0395-e52f-467c-8e3d-c4579291692e");
    public static readonly Guid IID_IMMDeviceEnumerator = new("a95664d2-9614-4f35-a746-de8db63617e6");
    public static readonly Guid IID_IMMNotificationClient = new("7991eec9-7e89-4d85-8390-6c703cec60c0");
    public static readonly Guid IID_IAudioClient = new("1cb9ad4c-dbfa-4c32-b178-c2f568a703b2");
    public static readonly Guid IID_IAudioCaptureClient = new("c8adbd64-e71e-48a0-a4de-185c395cd317");
    public static readonly Guid IID_IActivateAudioInterfaceCompletionHandler = new("41d949ab-9862-444a-80f6-c261334da5eb");
    public static readonly Guid IID_IAgileObject = new("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");
    public static readonly Guid IID_IUnknown = new("00000000-0000-0000-c000-000000000046");
    public static readonly Guid KSDATAFORMAT_SUBTYPE_PCM = new("00000001-0000-0010-8000-00aa00389b71");
    public static readonly Guid KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = new("00000003-0000-0010-8000-00aa00389b71");

    /// <summary><c>VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK</c> (audioclientactivationparams.h).</summary>
    public const string ProcessLoopbackDevice = @"VAD\Process_Loopback";

    public const int eRender = 0;
    public const int eConsole = 0;
    public const uint CLSCTX_ALL = 0x17;
    public const int AUDCLNT_SHAREMODE_SHARED = 0;
    public const uint AUDCLNT_STREAMFLAGS_LOOPBACK = 0x0002_0000;
    public const uint AUDCLNT_STREAMFLAGS_EVENTCALLBACK = 0x0004_0000;
    public const uint AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY = 0x0800_0000;
    public const uint AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM = 0x8000_0000;
    public const uint AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY = 0x1;
    public const uint AUDCLNT_BUFFERFLAGS_SILENT = 0x2;
    public const uint AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR = 0x4;
    public const int AUDCLNT_S_BUFFER_EMPTY = 0x0889_0001;
    public const int AUDCLNT_E_DEVICE_INVALIDATED = unchecked((int)0x8889_0004);
    public const int AUDCLNT_E_UNSUPPORTED_FORMAT = unchecked((int)0x8889_0008);
    public const int AUDCLNT_E_SERVICE_NOT_RUNNING = unchecked((int)0x8889_0010);
    public const int AUDCLNT_E_RESOURCES_INVALIDATED = unchecked((int)0x8889_0026);
    public const int E_NOTFOUND = unchecked((int)0x8007_0490);
    public const int E_NOINTERFACE = unchecked((int)0x8000_4002);
    public const int E_ACCESSDENIED = unchecked((int)0x8007_0005);
    public const int AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK = 1;
    public const int PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE = 1;
    public const ushort WAVE_FORMAT_PCM = 1;
    public const ushort WAVE_FORMAT_IEEE_FLOAT = 3;
    public const ushort WAVE_FORMAT_EXTENSIBLE = 0xFFFE;
    public const ushort VT_LPWSTR = 31;
    public const ushort VT_BLOB = 65;

    /// <summary><c>PKEY_Device_FriendlyName</c> ("Speakers (Realtek(R) Audio)").</summary>
    public static readonly PropertyKey PKEY_Device_FriendlyName = new(new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), 14);

    [DllImport("ole32.dll", ExactSpelling = true)]
    public static extern int CoInitializeEx(nint reserved, uint coInit);

    [DllImport("ole32.dll", ExactSpelling = true)]
    public static extern void CoUninitialize();

    [DllImport("ole32.dll", ExactSpelling = true)]
    public static extern int CoCreateInstance(Guid* clsid, nint outer, uint context, Guid* iid, nint* result);

    [DllImport("ole32.dll", ExactSpelling = true)]
    public static extern int PropVariantClear(PropVariant* value);

    [DllImport("ole32.dll", ExactSpelling = true)]
    public static extern void CoTaskMemFree(nint memory);

    [DllImport("mmdevapi.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    public static extern int ActivateAudioInterfaceAsync(string deviceInterfacePath, Guid* riid, PropVariant* activationParams,
                                                         nint completionHandler, nint* activationOperation);

    /// <summary>Throws an <see cref="COMException"/> for a failed HRESULT.</summary>
    public static void Check(int hr, string what)
    {
        if (hr < 0) throw new COMException($"{what} failed (0x{hr:X8})", hr);
    }

    private static void** Vtbl(nint unknown) => *(void***)unknown;

    public static void Release(ref nint unknown)
    {
        var pointer = unknown;
        unknown = 0;
        if (pointer != 0) Marshal.Release(pointer);
    }

    // IMMDeviceEnumerator

    public static nint CreateEnumerator()
    {
        var clsid = CLSID_MMDeviceEnumerator;
        var iid = IID_IMMDeviceEnumerator;
        nint result = 0;
        Check(CoCreateInstance(&clsid, 0, CLSCTX_ALL, &iid, &result), "CoCreateInstance(MMDeviceEnumerator)");
        return result;
    }

    /// <summary>Slot 4. E_NOTFOUND when the PC has no output device.</summary>
    public static int GetDefaultAudioEndpoint(nint enumerator, int flow, int role, out nint device)
    {
        var fn = (delegate* unmanaged[Stdcall]<nint, int, int, nint*, int>)Vtbl(enumerator)[4];
        nint result = 0;
        var hr = fn(enumerator, flow, role, &result);
        device = result;
        return hr;
    }

    /// <summary>Slot 6.</summary>
    public static int RegisterEndpointNotificationCallback(nint enumerator, nint client) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, int>)Vtbl(enumerator)[6])(enumerator, client);

    /// <summary>Slot 7.</summary>
    public static int UnregisterEndpointNotificationCallback(nint enumerator, nint client) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, int>)Vtbl(enumerator)[7])(enumerator, client);

    // IMMDevice

    /// <summary>IMMDevice::Activate (slot 3) for an <c>IAudioClient</c>.</summary>
    public static int ActivateAudioClient(nint device, out nint client)
    {
        var fn = (delegate* unmanaged[Stdcall]<nint, Guid*, uint, PropVariant*, nint*, int>)Vtbl(device)[3];
        var iid = IID_IAudioClient;
        nint result = 0;
        var hr = fn(device, &iid, CLSCTX_ALL, null, &result);
        client = result;
        return hr;
    }

    /// <summary>The device's friendly name (OpenPropertyStore slot 4, IPropertyStore::GetValue slot 5), or null.</summary>
    public static string? FriendlyName(nint device)
    {
        var open = (delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)Vtbl(device)[4];
        nint store = 0;
        if (open(device, 0 /* STGM_READ */, &store) < 0 || store == 0) return null;
        try
        {
            var getValue = (delegate* unmanaged[Stdcall]<nint, PropertyKey*, PropVariant*, int>)Vtbl(store)[5];
            var key = PKEY_Device_FriendlyName;
            PropVariant value = default;
            if (getValue(store, &key, &value) < 0) return null;
            try
            {
                return value.Type == VT_LPWSTR && value.Pointer != 0 ? Marshal.PtrToStringUni(value.Pointer) : null;
            }
            finally
            {
                PropVariantClear(&value);
            }
        }
        finally
        {
            Release(ref store);
        }
    }

    // IAudioClient

    /// <summary>Slot 3.</summary>
    public static int Initialize(nint client, uint streamFlags, long bufferDuration, WaveFormatExtensible* format) =>
        ((delegate* unmanaged[Stdcall]<nint, int, uint, long, long, WaveFormatExtensible*, Guid*, int>)Vtbl(client)[3])(
            client, AUDCLNT_SHAREMODE_SHARED, streamFlags, bufferDuration, 0, format, null);

    /// <summary>Slot 8: the engine's mix format, freed with CoTaskMemFree. E_NOTIMPL on a process-loopback client.</summary>
    public static int GetMixFormat(nint client, out WaveFormatExtensible* format)
    {
        WaveFormatExtensible* result = null;
        var hr = ((delegate* unmanaged[Stdcall]<nint, WaveFormatExtensible**, int>)Vtbl(client)[8])(client, &result);
        format = result;
        return hr;
    }

    /// <summary>Slot 10.</summary>
    public static int Start(nint client) => ((delegate* unmanaged[Stdcall]<nint, int>)Vtbl(client)[10])(client);

    /// <summary>Slot 11.</summary>
    public static int Stop(nint client) => ((delegate* unmanaged[Stdcall]<nint, int>)Vtbl(client)[11])(client);

    /// <summary>Slot 13.</summary>
    public static int SetEventHandle(nint client, nint handle) =>
        ((delegate* unmanaged[Stdcall]<nint, nint, int>)Vtbl(client)[13])(client, handle);

    /// <summary>Slot 14, for the <c>IAudioCaptureClient</c>.</summary>
    public static int GetCaptureClient(nint client, out nint capture)
    {
        var iid = IID_IAudioCaptureClient;
        nint result = 0;
        var hr = ((delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)Vtbl(client)[14])(client, &iid, &result);
        capture = result;
        return hr;
    }

    // IAudioCaptureClient

    /// <summary>Slot 3. <paramref name="qpcPosition"/> is in 100 ns units of the performance counter.</summary>
    public static int GetBuffer(nint capture, out byte* data, out uint frames, out uint flags, out ulong qpcPosition)
    {
        byte* d = null;
        uint n = 0, f = 0;
        ulong device = 0, qpc = 0;
        var hr = ((delegate* unmanaged[Stdcall]<nint, byte**, uint*, uint*, ulong*, ulong*, int>)Vtbl(capture)[3])(capture, &d, &n, &f, &device, &qpc);
        data = d;
        frames = n;
        flags = f;
        qpcPosition = qpc;
        return hr;
    }

    /// <summary>Slot 4.</summary>
    public static int ReleaseBuffer(nint capture, uint frames) =>
        ((delegate* unmanaged[Stdcall]<nint, uint, int>)Vtbl(capture)[4])(capture, frames);

    /// <summary>Slot 5.</summary>
    public static int GetNextPacketSize(nint capture, out uint frames)
    {
        uint n = 0;
        var hr = ((delegate* unmanaged[Stdcall]<nint, uint*, int>)Vtbl(capture)[5])(capture, &n);
        frames = n;
        return hr;
    }

    // IActivateAudioInterfaceAsyncOperation

    /// <summary>Slot 3.</summary>
    public static int GetActivateResult(nint operation, out int activateResult, out nint activated)
    {
        int result = 0;
        nint unknown = 0;
        var hr = ((delegate* unmanaged[Stdcall]<nint, int*, nint*, int>)Vtbl(operation)[3])(operation, &result, &unknown);
        activateResult = result;
        activated = unknown;
        return hr;
    }

    /// <summary>The format the capture asks for: 48 kHz stereo, float32 or int16.</summary>
    public static WaveFormatExtensible Format(bool isFloat)
    {
        var bits = (ushort)(isFloat ? 32 : 16);
        var blockAlign = (ushort)(AudioFormat.Channels * bits / 8);
        return new WaveFormatExtensible
        {
            FormatTag = WAVE_FORMAT_EXTENSIBLE,
            Channels = AudioFormat.Channels,
            SamplesPerSec = AudioFormat.SampleRate,
            AvgBytesPerSec = (uint)(AudioFormat.SampleRate * blockAlign),
            BlockAlign = blockAlign,
            BitsPerSample = bits,
            ExtraSize = 22,
            ValidBitsPerSample = bits,
            ChannelMask = 0x3, // SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT
            SubFormat = isFloat ? KSDATAFORMAT_SUBTYPE_IEEE_FLOAT : KSDATAFORMAT_SUBTYPE_PCM,
        };
    }

    /// <summary>What <paramref name="format"/> means to <see cref="PcmConverter"/>.</summary>
    public static PcmFormat Describe(WaveFormatExtensible* format)
    {
        var tag = format->FormatTag;
        var isExtensible = tag == WAVE_FORMAT_EXTENSIBLE && format->ExtraSize >= 22;
        var isFloat = isExtensible ? format->SubFormat == KSDATAFORMAT_SUBTYPE_IEEE_FLOAT : tag == WAVE_FORMAT_IEEE_FLOAT;
        return new PcmFormat((int)format->SamplesPerSec, format->Channels, format->BitsPerSample, isFloat,
                             isExtensible ? format->ChannelMask : 0);
    }
}

/// <summary><c>PROPERTYKEY</c>.</summary>
[StructLayout(LayoutKind.Sequential)]
internal readonly struct PropertyKey(Guid formatId, uint propertyId)
{
    public readonly Guid FormatId = formatId;
    public readonly uint PropertyId = propertyId;
}

/// <summary><c>PROPVARIANT</c>, the x64/ARM64 layout (24 bytes), for VT_LPWSTR and VT_BLOB only.</summary>
[StructLayout(LayoutKind.Explicit, Size = 24)]
internal struct PropVariant
{
    [FieldOffset(0)] public ushort Type;
    /// <summary>VT_LPWSTR's string.</summary>
    [FieldOffset(8)] public nint Pointer;
    /// <summary>VT_BLOB's <c>cbSize</c>.</summary>
    [FieldOffset(8)] public uint BlobSize;
    /// <summary>VT_BLOB's <c>pBlobData</c>.</summary>
    [FieldOffset(16)] public nint BlobData;
}

/// <summary><c>WAVEFORMATEXTENSIBLE</c> (mmreg.h, packed to 1 byte: 40 bytes). The first 18 are <c>WAVEFORMATEX</c>.</summary>
[StructLayout(LayoutKind.Sequential, Pack = 1)]
internal struct WaveFormatExtensible
{
    public ushort FormatTag;
    public ushort Channels;
    public uint SamplesPerSec;
    public uint AvgBytesPerSec;
    public ushort BlockAlign;
    public ushort BitsPerSample;
    public ushort ExtraSize;
    public ushort ValidBitsPerSample;
    public uint ChannelMask;
    public Guid SubFormat;
}

/// <summary><c>AUDIOCLIENT_ACTIVATION_PARAMS</c> with its process-loopback member (12 bytes).</summary>
[StructLayout(LayoutKind.Sequential)]
internal struct AudioClientActivationParams
{
    public int ActivationType;
    public uint TargetProcessId;
    public int ProcessLoopbackMode;
}

/// <summary>
/// A COM object made of a native vtable and a GC handle to a managed target, for the two
/// callbacks WASAPI makes into us (<c>IMMNotificationClient</c>,
/// <c>IActivateAudioInterfaceCompletionHandler</c>). Reference-counted like any COM object: the
/// creator holds one reference and releases it with <see cref="Release"/>; the last release frees it.
/// Both callbacks are agile (they answer <c>IAgileObject</c>) since WASAPI calls them from its own threads.
/// </summary>
internal static unsafe class NativeCallbackObject
{
    [StructLayout(LayoutKind.Sequential)]
    private struct Layout
    {
        public void** Vtbl;
        public nint Target;
        public int References;
        public Guid Interface;
    }

    /// <summary>Allocates an object with <paramref name="vtbl"/> that answers <paramref name="iid"/>.</summary>
    public static nint Create(void** vtbl, Guid iid, object target)
    {
        var layout = (Layout*)NativeMemory.AllocZeroed((nuint)sizeof(Layout));
        layout->Vtbl = vtbl;
        layout->Target = GCHandle.ToIntPtr(GCHandle.Alloc(target));
        layout->References = 1;
        layout->Interface = iid;
        return (nint)layout;
    }

    /// <summary>The managed target behind <paramref name="self"/>.</summary>
    public static T? Target<T>(nint self) where T : class => GCHandle.FromIntPtr(((Layout*)self)->Target).Target as T;

    /// <summary>Drops the creator's reference.</summary>
    public static void Release(nint self) => Drop(self);

    /// <summary>Fills slots 0–2 of a vtable.</summary>
    public static void FillUnknown(void** vtbl)
    {
        vtbl[0] = (delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)&QueryInterface;
        vtbl[1] = (delegate* unmanaged[Stdcall]<nint, uint>)&AddRef;
        vtbl[2] = (delegate* unmanaged[Stdcall]<nint, uint>)&ReleaseImpl;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static int QueryInterface(nint self, Guid* iid, nint* result)
    {
        var layout = (Layout*)self;
        if (*iid == Wasapi.IID_IUnknown || *iid == Wasapi.IID_IAgileObject || *iid == layout->Interface)
        {
            Interlocked.Increment(ref layout->References);
            *result = self;
            return 0;
        }
        *result = 0;
        return Wasapi.E_NOINTERFACE;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static uint AddRef(nint self) => (uint)Interlocked.Increment(ref ((Layout*)self)->References);

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    private static uint ReleaseImpl(nint self) => (uint)Drop(self);

    private static int Drop(nint self)
    {
        var layout = (Layout*)self;
        var left = Interlocked.Decrement(ref layout->References);
        if (left == 0)
        {
            GCHandle.FromIntPtr(layout->Target).Free();
            NativeMemory.Free(layout);
        }
        return left;
    }
}

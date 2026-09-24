using System.Runtime.InteropServices;
using Vortice.MediaFoundation;

namespace Vantage.Host.Windows.Encode;

/// <summary>
/// Process-wide Media Foundation setup: <c>MFStartup</c> once, a multithreaded COM apartment kept
/// alive for the life of the process (so any thread that hasn't joined an apartment is implicitly
/// MTA and can activate MFTs), and <c>MFTEnum2</c>, which Vortice doesn't wrap.
/// </summary>
internal static unsafe class MediaFoundationRuntime
{
    // mftransform.h
    public const uint MFT_ENUM_FLAG_SYNCMFT = 0x1;
    public const uint MFT_ENUM_FLAG_ASYNCMFT = 0x2;
    public const uint MFT_ENUM_FLAG_HARDWARE = 0x4;
    public const uint MFT_ENUM_FLAG_SORTANDFILTER = 0x40;

    /// <summary><c>MFT_ENUM_ADAPTER_LUID</c> (blob: a LUID).</summary>
    public static readonly Guid MFT_ENUM_ADAPTER_LUID = new("1d39518c-e220-4da8-a07f-ba172552d6b1");

    /// <summary><c>MF_LOW_LATENCY</c> (UINT32) on the transform's attributes.</summary>
    public static readonly Guid MF_LOW_LATENCY = new("9c27891a-ed7a-40e1-88e8-b22727a024ee");

    /// <summary><c>MFSampleExtension_CleanPoint</c> (UINT32): the sample is a keyframe.</summary>
    public static readonly Guid MFSampleExtension_CleanPoint = new("9cdf01d8-a0f0-43ba-b077-eaa06cbd728a");

    /// <summary><c>CLSID_MSH264EncoderMFT</c>, Microsoft's software H.264 encoder.</summary>
    public static readonly Guid CLSID_MSH264EncoderMFT = new("6ca50344-051a-4ded-9779-a43305165e35");

    /// <summary><c>IMFShutdown</c>: Shutdown is slot 3.</summary>
    public static readonly Guid IID_IMFShutdown = new("97ec2ea4-0e42-4937-97ac-9d6d328824e1");

    // HRESULTs (mferror.h)
    public const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);
    public const int MF_E_TRANSFORM_STREAM_CHANGE = unchecked((int)0xC00D6D61);
    public const int MF_E_NOTACCEPTING = unchecked((int)0xC00D36B5);
    public const int MF_E_SHUTDOWN = unchecked((int)0xC00D3E85);

    private static readonly Lazy<bool> s_started = new(Start, LazyThreadSafetyMode.ExecutionAndPublication);

    /// <summary>Starts Media Foundation (once).</summary>
    public static void EnsureStarted() => _ = s_started.Value;

    private static bool Start()
    {
        using (var ready = new ManualResetEventSlim())
        {
            var keeper = new Thread(() =>
            {
                CoInitializeEx(0, 0 /* COINIT_MULTITHREADED */);
                ready.Set();
                Thread.Sleep(Timeout.Infinite);
            })
            { IsBackground = true, Name = "Vantage COM MTA" };
            keeper.Start();
            ready.Wait();
        }
        MediaFactory.MFStartup(useLightVersion: true).CheckError();
        return true;
    }

    /// <summary>
    /// <c>MFTEnum2</c>: the MFTs in <paramref name="category"/> converting <paramref name="input"/> to
    /// <paramref name="output"/>, limited to the adapter <paramref name="adapterLuid"/> when given. The
    /// caller disposes each activate.
    /// </summary>
    public static List<IMFActivate> Enumerate(Guid category, uint flags, RegisterTypeInfo input, RegisterTypeInfo output, long? adapterLuid)
    {
        IMFAttributes? attributes = null;
        try
        {
            if (adapterLuid is { } luid)
            {
                attributes = MediaFactory.MFCreateAttributes(1);
                var bytes = new byte[8];
                BitConverter.TryWriteBytes(bytes.AsSpan(0, 4), (uint)(luid & 0xFFFFFFFF));
                BitConverter.TryWriteBytes(bytes.AsSpan(4, 4), (int)(luid >> 32));
                attributes.SetBlob(MFT_ENUM_ADAPTER_LUID, bytes).CheckError();
            }
            nint array = 0;
            uint count = 0;
            var hr = MFTEnum2(category, flags, &input, &output, attributes?.NativePointer ?? 0, &array, &count);
            Marshal.ThrowExceptionForHR(hr);
            var result = new List<IMFActivate>((int)count);
            for (var i = 0; i < count; i++) result.Add(new IMFActivate(((nint*)array)[i]));
            if (array != 0) Marshal.FreeCoTaskMem(array);
            return result;
        }
        finally
        {
            attributes?.Dispose();
        }
    }

    /// <summary>Calls <c>IMFShutdown::Shutdown</c> if the object has it (unblocks a pending GetEvent).</summary>
    public static void Shutdown(nint unknown)
    {
        var iid = IID_IMFShutdown;
        if (Marshal.QueryInterface(unknown, in iid, out var shutdown) < 0 || shutdown == 0) return;
        try
        {
            var fn = (delegate* unmanaged[Stdcall]<nint, int>)(*(void***)shutdown)[3];
            fn(shutdown);
        }
        finally
        {
            Marshal.Release(shutdown);
        }
    }

    /// <summary>Creates Microsoft's software H.264 encoder MFT directly.</summary>
    public static IMFTransform CreateSoftwareH264Encoder()
    {
        var clsid = CLSID_MSH264EncoderMFT;
        var iid = typeof(IMFTransform).GUID;
        var hr = CoCreateInstance(&clsid, 0, 1 /* CLSCTX_INPROC_SERVER */, &iid, out var pointer);
        Marshal.ThrowExceptionForHR(hr);
        return new IMFTransform(pointer);
    }

    [DllImport("mfplat.dll", ExactSpelling = true)]
    private static extern int MFTEnum2(Guid guidCategory, uint flags, RegisterTypeInfo* inputType, RegisterTypeInfo* outputType,
                                       nint attributes, nint* activates, uint* count);

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoInitializeEx(nint reserved, uint coInit);

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoCreateInstance(Guid* clsid, nint outer, uint context, Guid* iid, out nint pointer);
}

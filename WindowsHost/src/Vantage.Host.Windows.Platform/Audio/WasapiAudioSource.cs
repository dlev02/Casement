using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Audio;
using Vantage.Protocol.Host;

namespace Vantage.Host.Windows.Audio;

/// <summary>How the PC's sound is captured (<c>--audio</c>).</summary>
public enum AudioLoopback
{
    /// <summary>Process loopback without the host's own process tree, else endpoint loopback.</summary>
    Auto,
    /// <summary>Process loopback only (Windows 10 2004+).</summary>
    Process,
    /// <summary>The default output device's loopback only (everything it plays, the host included).</summary>
    Endpoint,
    /// <summary>Never offer sound.</summary>
    Off,
}

/// <summary>
/// The PC's sound through WASAPI loopback (the Mac's <c>AudioCapture</c>): what the default output
/// device plays, as 10 ms blocks of 48 kHz stereo float.
/// </summary>
/// <remarks>
/// Process loopback (<c>ActivateAudioInterfaceAsync</c> on <c>VAD\Process_Loopback</c> with
/// <c>PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE</c> for this process) comes first: like
/// the Mac's <c>excludesCurrentProcessAudio</c>, it leaves the host's own sounds out, and it takes
/// the 48 kHz float format we ask for whatever the device runs at. Where it can't be activated
/// (before Windows 10 2004, or a driver that refuses it) the default render endpoint's loopback
/// is used instead, asking the engine to convert to 48 kHz stereo float and falling back to the
/// mix format through <see cref="PcmConverter"/>. Either way a change of default output device
/// (<c>IMMNotificationClient</c>) or an invalidated device restarts capture on a new timeline.
/// Whether capture works at all is probed once, the first time <see cref="UnavailableReason"/>
/// is read (the runtime reads it at startup); a failure is probed again at most every 30 s, so
/// plugging in a headset brings sound back without restarting the host.
/// </remarks>
[SupportedOSPlatform("windows10.0.19041.0")]
public sealed class WasapiAudioSource : IAudioSource
{
    private static readonly TimeSpan s_reprobeAfter = TimeSpan.FromSeconds(30);

    private readonly AudioLoopback _mode;
    private readonly ILogger _log;
    private readonly Lock _lock = new();
    private bool _probed;
    private string? _unavailable;
    private long _probedAt;

    /// <summary>Makes the source; nothing is opened until the first probe or start.</summary>
    public WasapiAudioSource(ILoggerFactory logging, AudioLoopback mode = AudioLoopback.Auto)
    {
        _mode = mode;
        _log = logging.CreateLogger("Vantage.Audio");
    }

    /// <inheritdoc />
    public string? UnavailableReason
    {
        get
        {
            if (_mode == AudioLoopback.Off) return "Sound is turned off on this PC (--audio off).";
            lock (_lock)
            {
                if (_probed && (_unavailable is null || Stopwatch.GetElapsedTime(_probedAt) < s_reprobeAfter)) return _unavailable;
                _unavailable = Probe();
                _probed = true;
                _probedAt = Stopwatch.GetTimestamp();
                return _unavailable;
            }
        }
    }

    /// <inheritdoc />
    public async Task<IAudioCapture> StartAsync(Action<AudioBlock> onBlock, Action<string> onStopped, CancellationToken cancellationToken)
    {
        if (_mode == AudioLoopback.Off) throw new AudioUnavailableException("Sound is turned off on this PC.");
        var capture = new WasapiLoopbackCapture(_mode, onBlock, onStopped, _log);
        try
        {
            await capture.Started.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            await capture.DisposeAsync().ConfigureAwait(false);
            throw;
        }
        lock (_lock)
        {
            _probed = true;
            _unavailable = null;
        }
        return capture;
    }

    /// <summary>Opens a loopback stream and closes it again; null when that worked, else why not.</summary>
    private string? Probe()
    {
        var watch = Stopwatch.StartNew();
        try
        {
            var description = Mta.Run(() =>
            {
                using var ready = new AutoResetEvent(false);
                using var stream = LoopbackStream.Open(_mode, ready, _log);
                return stream.Description;
            });
            _log.LogInformation("sound can be captured: {Description} (probed in {Ms} ms)", description, watch.ElapsedMilliseconds);
            return null;
        }
        catch (AudioUnavailableException error)
        {
            _log.LogWarning("sound can't be captured: {Reason}", error.Message);
            return error.Message;
        }
        catch (Exception error) when (error is COMException or DllNotFoundException or EntryPointNotFoundException)
        {
            _log.LogWarning("sound can't be captured: {Error}", error.Message);
            return $"Windows refused loopback capture: {error.Message}";
        }
    }
}

/// <summary>Runs COM work on a fresh MTA thread (WASAPI's objects are free-threaded; the thread pool's apartment isn't ours to set).</summary>
[SupportedOSPlatform("windows")]
internal static class Mta
{
    private const uint COINIT_MULTITHREADED = 0;

    public static T Run<T>(Func<T> work)
    {
        T result = default!;
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            var hr = Wasapi.CoInitializeEx(0, COINIT_MULTITHREADED);
            try
            {
                result = work();
            }
            catch (Exception error)
            {
                failure = error; // rethrown on the caller's thread below
            }
            finally
            {
                if (hr >= 0) Wasapi.CoUninitialize();
            }
        }) { IsBackground = true, Name = "Vantage audio probe" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        thread.Join();
        if (failure is not null) ExceptionDispatchInfoThrow(failure);
        return result;
    }

    private static void ExceptionDispatchInfoThrow(Exception error) =>
        System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(error).Throw();

    /// <summary>Calls CoInitializeEx(MTA) on the current thread; dispose to balance it.</summary>
    public static IDisposable Enter()
    {
        var hr = Wasapi.CoInitializeEx(0, COINIT_MULTITHREADED);
        return new Leave(hr >= 0);
    }

    private sealed class Leave(bool initialized) : IDisposable
    {
        public void Dispose()
        {
            if (initialized) Wasapi.CoUninitialize();
        }
    }
}

/// <summary>
/// One open loopback stream: an initialized, started <c>IAudioClient</c> and its
/// <c>IAudioCaptureClient</c>, signalling <c>ready</c> when a period's worth arrived. Opened and
/// used on one MTA thread.
/// </summary>
[SupportedOSPlatform("windows10.0.19041.0")]
internal sealed unsafe class LoopbackStream : IDisposable
{
    /// <summary>200 ms of buffer: room for the capture thread to be descheduled without losing sound.</summary>
    private const long BufferDuration = 2_000_000;

    private nint _client;
    private nint _capture;

    private LoopbackStream(nint client, PcmFormat format, string description)
    {
        _client = client;
        Converter = new PcmConverter(format);
        Description = description;
    }

    /// <summary>Converts what this stream delivers into 48 kHz stereo float.</summary>
    public PcmConverter Converter { get; }

    /// <summary>For the log.</summary>
    public string Description { get; }

    /// <summary>The <c>IAudioCaptureClient</c>.</summary>
    public nint CaptureClient => _capture;

    /// <summary>
    /// Opens a stream the way <paramref name="mode"/> says (auto: process loopback, else the
    /// endpoint's). Throws <see cref="AudioUnavailableException"/> with a user-facing reason.
    /// </summary>
    public static LoopbackStream Open(AudioLoopback mode, AutoResetEvent ready, ILogger log)
    {
        if (mode is AudioLoopback.Auto or AudioLoopback.Process)
        {
            try
            {
                return OpenProcessLoopback(ready);
            }
            catch (COMException error) when (mode == AudioLoopback.Auto)
            {
                log.LogInformation("process loopback unavailable ({Error}); capturing the output device instead", error.Message);
            }
            catch (COMException error)
            {
                throw Unavailable(error);
            }
        }
        try
        {
            return OpenEndpointLoopback(ready);
        }
        catch (COMException error)
        {
            throw Unavailable(error);
        }
    }

    /// <summary>The user-facing reason for a WASAPI failure.</summary>
    public static AudioUnavailableException Unavailable(COMException error) => new(error.HResult switch
    {
        Wasapi.E_NOTFOUND => "This PC has no sound output device.",
        Wasapi.AUDCLNT_E_SERVICE_NOT_RUNNING => "Windows Audio isn't running on this PC.",
        Wasapi.E_ACCESSDENIED => "Windows refused loopback capture: access denied.",
        _ => $"Windows refused loopback capture: {error.Message}",
    }, error);

    private static LoopbackStream OpenProcessLoopback(AutoResetEvent ready)
    {
        // Process loopback converts to whatever it is given; float first, 16-bit if a driver balks.
        COMException? last = null;
        foreach (var isFloat in new[] { true, false })
        {
            var client = ActivateProcessLoopback();
            var format = Wasapi.Format(isFloat);
            var hr = Wasapi.Initialize(client, Wasapi.AUDCLNT_STREAMFLAGS_LOOPBACK | Wasapi.AUDCLNT_STREAMFLAGS_EVENTCALLBACK | Wasapi.AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
                                       BufferDuration, &format);
            if (hr < 0)
            {
                Wasapi.Release(ref client);
                last = new COMException($"IAudioClient::Initialize (process loopback, {(isFloat ? "float" : "16-bit")}) failed (0x{hr:X8})", hr);
                continue;
            }
            var pcm = Wasapi.Describe(&format);
            return new LoopbackStream(client, pcm, $"process loopback, every app but this host, {pcm}").Start(ready);
        }
        throw last!;
    }

    private static nint ActivateProcessLoopback()
    {
        var parameters = new AudioClientActivationParams
        {
            ActivationType = Wasapi.AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK,
            TargetProcessId = (uint)Environment.ProcessId,
            ProcessLoopbackMode = Wasapi.PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE,
        };
        var variant = new PropVariant { Type = Wasapi.VT_BLOB, BlobSize = (uint)sizeof(AudioClientActivationParams), BlobData = (nint)(&parameters) };
        var iid = Wasapi.IID_IAudioClient;
        using var done = new ManualResetEventSlim(false);
        var handler = ActivationHandler.Create(done);
        nint operation = 0;
        try
        {
            int hr;
            try
            {
                hr = Wasapi.ActivateAudioInterfaceAsync(Wasapi.ProcessLoopbackDevice, &iid, &variant, handler, &operation);
            }
            catch (EntryPointNotFoundException error)
            {
                throw new COMException($"process loopback isn't available here ({error.Message})", unchecked((int)0x80004001));
            }
            Wasapi.Check(hr, "ActivateAudioInterfaceAsync(process loopback)");
            if (!done.Wait(TimeSpan.FromSeconds(5))) throw new COMException("process loopback activation didn't finish within 5 s", unchecked((int)0x800705B4));
            Wasapi.Check(Wasapi.GetActivateResult(operation, out var activated, out var unknown), "GetActivateResult");
            if (activated < 0)
            {
                Wasapi.Release(ref unknown);
                Wasapi.Check(activated, "process loopback activation");
            }
            return unknown;
        }
        finally
        {
            Wasapi.Release(ref operation);
            NativeCallbackObject.Release(handler);
        }
    }

    private static LoopbackStream OpenEndpointLoopback(AutoResetEvent ready)
    {
        var enumerator = Wasapi.CreateEnumerator();
        nint device = 0;
        try
        {
            Wasapi.Check(Wasapi.GetDefaultAudioEndpoint(enumerator, Wasapi.eRender, Wasapi.eConsole, out device), "GetDefaultAudioEndpoint");
            var name = Wasapi.FriendlyName(device) ?? "the default output device";
            // Ask the engine for 48 kHz stereo float (its own channel mixer and resampler) first.
            Wasapi.Check(Wasapi.ActivateAudioClient(device, out var client), "IMMDevice::Activate(IAudioClient)");
            var target = Wasapi.Format(isFloat: true);
            var hr = Wasapi.Initialize(client, Wasapi.AUDCLNT_STREAMFLAGS_LOOPBACK | Wasapi.AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                                               Wasapi.AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | Wasapi.AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                                       BufferDuration, &target);
            if (hr >= 0)
            {
                var pcm = Wasapi.Describe(&target);
                return new LoopbackStream(client, pcm, $"endpoint loopback on {name}, {pcm}").Start(ready);
            }
            // The device's own mix format, converted here.
            Wasapi.Release(ref client);
            Wasapi.Check(Wasapi.ActivateAudioClient(device, out client), "IMMDevice::Activate(IAudioClient)");
            try
            {
                Wasapi.Check(Wasapi.GetMixFormat(client, out var mix), "IAudioClient::GetMixFormat");
                try
                {
                    var pcm = Wasapi.Describe(mix);
                    if (!pcm.IsSupported) throw new COMException($"the output device's format ({pcm}) isn't one the host can read", Wasapi.AUDCLNT_E_UNSUPPORTED_FORMAT);
                    Wasapi.Check(Wasapi.Initialize(client, Wasapi.AUDCLNT_STREAMFLAGS_LOOPBACK | Wasapi.AUDCLNT_STREAMFLAGS_EVENTCALLBACK, BufferDuration, mix),
                                 "IAudioClient::Initialize (endpoint loopback)");
                    return new LoopbackStream(client, pcm, $"endpoint loopback on {name}, {pcm}, converted here").Start(ready);
                }
                finally
                {
                    Wasapi.CoTaskMemFree((nint)mix);
                }
            }
            catch
            {
                Wasapi.Release(ref client);
                throw;
            }
        }
        finally
        {
            Wasapi.Release(ref device);
            Wasapi.Release(ref enumerator);
        }
    }

    private LoopbackStream Start(AutoResetEvent ready)
    {
        try
        {
            Wasapi.Check(Wasapi.SetEventHandle(_client, ready.SafeWaitHandle.DangerousGetHandle()), "IAudioClient::SetEventHandle");
            Wasapi.Check(Wasapi.GetCaptureClient(_client, out _capture), "IAudioClient::GetService(IAudioCaptureClient)");
            Wasapi.Check(Wasapi.Start(_client), "IAudioClient::Start");
            return this;
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        if (_client != 0) Wasapi.Stop(_client);
        Wasapi.Release(ref _capture);
        Wasapi.Release(ref _client);
    }
}

/// <summary><c>IActivateAudioInterfaceCompletionHandler</c>: sets an event when activation finishes.</summary>
[SupportedOSPlatform("windows")]
internal static unsafe class ActivationHandler
{
    private static readonly nint s_vtbl = MakeVtbl();

    public static nint Create(ManualResetEventSlim done) =>
        NativeCallbackObject.Create((void**)s_vtbl, Wasapi.IID_IActivateAudioInterfaceCompletionHandler, done);

    private static nint MakeVtbl()
    {
        var vtbl = (void**)NativeMemory.AllocZeroed(4, (nuint)sizeof(nint)); // lives for the process
        NativeCallbackObject.FillUnknown(vtbl);
        vtbl[3] = (delegate* unmanaged[Stdcall]<nint, nint, int>)&ActivateCompleted;
        return (nint)vtbl;
    }

    [System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
    private static int ActivateCompleted(nint self, nint operation)
    {
        NativeCallbackObject.Target<ManualResetEventSlim>(self)?.Set();
        return 0;
    }
}

/// <summary><c>IMMNotificationClient</c>: calls back when the default output device changes. Never blocks WASAPI's thread.</summary>
[SupportedOSPlatform("windows")]
internal static unsafe class DefaultDeviceWatcher
{
    private static readonly nint s_vtbl = MakeVtbl();

    public static nint Create(Action onDefaultRenderChanged) =>
        NativeCallbackObject.Create((void**)s_vtbl, Wasapi.IID_IMMNotificationClient, onDefaultRenderChanged);

    private static nint MakeVtbl()
    {
        var vtbl = (void**)NativeMemory.AllocZeroed(8, (nuint)sizeof(nint)); // lives for the process
        NativeCallbackObject.FillUnknown(vtbl);
        vtbl[3] = (delegate* unmanaged[Stdcall]<nint, char*, uint, int>)&OnDeviceStateChanged;
        vtbl[4] = (delegate* unmanaged[Stdcall]<nint, char*, int>)&OnDeviceAddedOrRemoved;
        vtbl[5] = (delegate* unmanaged[Stdcall]<nint, char*, int>)&OnDeviceAddedOrRemoved;
        vtbl[6] = (delegate* unmanaged[Stdcall]<nint, int, int, char*, int>)&OnDefaultDeviceChanged;
        vtbl[7] = (delegate* unmanaged[Stdcall]<nint, char*, PropertyKey, int>)&OnPropertyValueChanged;
        return (nint)vtbl;
    }

    [System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
    private static int OnDeviceStateChanged(nint self, char* id, uint state) => 0;

    [System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
    private static int OnDeviceAddedOrRemoved(nint self, char* id) => 0;

    [System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
    private static int OnDefaultDeviceChanged(nint self, int flow, int role, char* id)
    {
        if (flow == Wasapi.eRender && role == Wasapi.eConsole) NativeCallbackObject.Target<Action>(self)?.Invoke();
        return 0;
    }

    [System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs = [typeof(System.Runtime.CompilerServices.CallConvStdcall)])]
    private static int OnPropertyValueChanged(nint self, char* id, PropertyKey key) => 0;
}

using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using SharpGen.Runtime;
using Vantage.Host.Windows.Capture;
using Vantage.Host.Windows.Gpu;
using Vantage.Host.Windows.Interop;
using Vantage.Protocol.Host;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.MediaFoundation;
using static Vantage.Host.Windows.Encode.MediaFoundationRuntime;

namespace Vantage.Host.Windows.Encode;

/// <summary>
/// H.264 through a Media Foundation encoder MFT (spec §7.3; plan §1 "Encode"):
/// <list type="bullet">
/// <item>Hardware: the vendor's MFT on the capture GPU (found with <c>MFTEnum2</c> by adapter LUID),
/// async (<c>MF_TRANSFORM_ASYNC_UNLOCK</c>, <c>METransformNeedInput</c>/<c>HaveOutput</c> on an event
/// thread), fed NV12 D3D11 textures through an <c>IMFDXGIDeviceManager</c>.</item>
/// <item>Software: Microsoft's H.264 MFT, synchronous, fed NV12 read back to system memory.</item>
/// </list>
/// Both get the same settings through <c>ICodecAPI</c>: low-latency mode, no B-frames, CBR (or
/// low-delay VBR), an effectively infinite GOP with <c>AVEncVideoForceKeyFrame</c> on request, a
/// two-frame VBV, High profile, and BT.709 / sRGB / BT.709 / video-range colour tags. Output is Annex-B.
/// </summary>
/// <remarks>
/// Every accepted <see cref="EncodeAsync"/> ends in one sink call. Outputs are matched to inputs by
/// sample time; an input the MFT never answers within <see cref="StallLimit"/> is reported skipped
/// and the next frame is forced to be an IDR (a lost P-frame would smear the client's picture).
/// </remarks>
internal sealed class MfH264Encoder : IVideoEncoder
{
    private static readonly TimeSpan StallLimit = TimeSpan.FromSeconds(1);
    private const int RingSize = 4;

    private readonly GpuDevice _gpu;
    private readonly Nv12Converter _converter;
    private readonly IMFTransform _transform;
    private readonly CodecApi? _codecApi;
    private readonly IMFDXGIDeviceManager? _deviceManager;
    private readonly IMFMediaEventGenerator? _events;
    private readonly bool _isAsync;
    private readonly bool _isHardware;
    private readonly ILogger _log;
    private readonly EncoderTuning _tuning;
    private readonly string _name;
    private readonly Lock _lock = new();
    private readonly Queue<Pending> _pending = new();
    private readonly SemaphoreSlim _needInput = new(0);
    private readonly Timer _stallTimer;
    private readonly int _width;
    private readonly int _height;
    private Thread? _eventThread;
    private BlockingWorker? _worker;
    private IEncodedFrameSink? _sink;
    private ID3D11Texture2D? _staging;
    private byte[]? _sequenceHeader;
    private bool _outputProvidesSamples;
    private int _outputBufferSize;
    private int _fps;
    private int _kbps;
    private ulong _baseNanos;
    private long _lastSampleTime = -1;
    private bool _forceNextKeyframe;
    private volatile bool _disposed;
    private long _framesOut;

    private sealed class Pending(long sampleTime, ulong captureNanos, long queuedAt)
    {
        public long SampleTime { get; } = sampleTime;
        public ulong CaptureNanos { get; } = captureNanos;
        public long QueuedAt { get; } = queuedAt;
        public bool Abandoned { get; set; }
    }

    private MfH264Encoder(GpuDevice gpu, Nv12Converter converter, IMFTransform transform, IMFDXGIDeviceManager? deviceManager,
                          bool isHardware, string name, VideoEncoderSettings settings, EncoderTuning tuning, ILogger log)
    {
        _gpu = gpu;
        _converter = converter;
        _transform = transform;
        _deviceManager = deviceManager;
        _isHardware = isHardware;
        _name = name;
        _log = log;
        _tuning = tuning;
        _width = settings.Width;
        _height = settings.Height;
        _fps = Math.Clamp(settings.Fps, 1, 240);
        _kbps = settings.BitrateKbps;
        _codecApi = CodecApi.From(transform.NativePointer);
        try
        {
            using var attributes = transform.Attributes;
            _isAsync = attributes is not null && attributes.GetUInt32(TransformAttributeKeys.TransformAsync, out var isAsync).Success && isAsync != 0;
            if (_isAsync)
            {
                attributes!.Set(TransformAttributeKeys.TransformAsyncUnlock, 1u).CheckError();
                _events = transform.QueryInterface<IMFMediaEventGenerator>();
            }
            attributes?.Set(MF_LOW_LATENCY, 1u);

            if (deviceManager is not null)
                transform.ProcessMessage(TMessageType.MessageSetD3DManager, (nuint)deviceManager.NativePointer);

            ApplyStaticSettings(settings);
            SetMediaTypes(settings);
            ApplyBitrate(_kbps);
            if (settings.MaxQP > 0) SetMaxQP(settings.MaxQP);

            var info = transform.GetOutputStreamInfo(0);
            _outputProvidesSamples = (info.Flags & 0x100) != 0 || (info.Flags & 0x200) != 0; // PROVIDES / CAN_PROVIDE
            _outputBufferSize = Math.Max(info.Size, _width * _height * 3 / 2);
        }
        catch
        {
            _events?.Dispose();
            _codecApi?.Dispose();
            throw;
        }
        _stallTimer = new Timer(_ => CheckForStall(), null, Timeout.Infinite, Timeout.Infinite);
        _log.LogInformation("encoder: {Name} ({Kind}, {Mode}) {Width}×{Height} @ {Fps} fps, {Kbps} kbps, {Rate}",
                            name, isHardware ? "hardware" : "software", _isAsync ? "async" : "sync", _width, _height, _fps, _kbps, tuning.RateControl);
    }

    /// <summary>The encoder's friendly name (for logs and the UI).</summary>
    public string Name => _name;

    /// <summary>Makes the hardware MFT on <paramref name="source"/>'s adapter.</summary>
    public static MfH264Encoder CreateHardware(WgcCaptureStream source, VideoEncoderSettings settings, EncoderTuning tuning, ILogger log)
    {
        EnsureStarted();
        var gpu = source.Gpu.AddReference();
        List<IMFActivate> activates;
        try
        {
            activates = Enumerate(TransformCategoryGuids.VideoEncoder, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
                                  new RegisterTypeInfo { GuidMajorType = MediaTypeGuids.Video, GuidSubtype = VideoFormatGuids.NV12 },
                                  new RegisterTypeInfo { GuidMajorType = MediaTypeGuids.Video, GuidSubtype = VideoFormatGuids.H264 },
                                  gpu.AdapterLuid);
        }
        catch
        {
            gpu.Dispose();
            throw;
        }
        Exception? lastError = null;
        try
        {
            if (activates.Count == 0) throw new NotSupportedException($"{gpu.AdapterName} has no hardware H.264 encoder MFT.");
            foreach (var activate in activates)
            {
                var name = FriendlyName(activate);
                IMFTransform? transform = null;
                IMFDXGIDeviceManager? manager = null;
                Nv12Converter? converter = null;
                try
                {
                    transform = activate.ActivateObject<IMFTransform>();
                    manager = MediaFactory.MFCreateDXGIDeviceManager();
                    manager.ResetDevice(gpu.Device).CheckError();
                    converter = new Nv12Converter(gpu, source.FrameWidth, source.FrameHeight, settings.Width, settings.Height, RingSize, log);
                    return new MfH264Encoder(gpu, converter, transform, manager, isHardware: true, name, settings, tuning, log);
                }
                catch (Exception ex)
                {
                    lastError = ex;
                    log.LogWarning("hardware encoder {Name} refused the setup: {Message}", name, ex.Message);
                    converter?.Dispose();
                    manager?.Dispose();
                    if (transform is not null) { activate.ShutdownObject(); transform.Dispose(); }
                }
            }
            throw new NotSupportedException($"no hardware H.264 encoder on {gpu.AdapterName} accepted the settings", lastError);
        }
        catch
        {
            gpu.Dispose();
            throw;
        }
        finally
        {
            foreach (var activate in activates) activate.Dispose();
        }
    }

    /// <summary>Makes Microsoft's software H.264 MFT.</summary>
    public static MfH264Encoder CreateSoftware(WgcCaptureStream source, VideoEncoderSettings settings, EncoderTuning tuning, ILogger log)
    {
        EnsureStarted();
        var gpu = source.Gpu.AddReference();
        Nv12Converter? converter = null;
        IMFTransform? transform = null;
        try
        {
            converter = new Nv12Converter(gpu, source.FrameWidth, source.FrameHeight, settings.Width, settings.Height, RingSize, log);
            transform = CreateSoftwareH264Encoder();
            return new MfH264Encoder(gpu, converter, transform, deviceManager: null, isHardware: false, "Microsoft H.264 software encoder",
                                     settings, tuning, log);
        }
        catch
        {
            converter?.Dispose();
            transform?.Dispose();
            gpu.Dispose();
            throw;
        }
    }

    public void Start(IEncodedFrameSink sink)
    {
        _sink = sink;
        _transform.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, 0);
        _transform.ProcessMessage(TMessageType.MessageNotifyStartOfStream, 0);
        if (_isAsync)
        {
            _eventThread = new Thread(EventLoop) { IsBackground = true, Name = "Vantage encoder events", Priority = ThreadPriority.AboveNormal };
            _eventThread.Start();
        }
        else
        {
            _worker = new BlockingWorker("Vantage software encoder");
        }
        _stallTimer.Change(TimeSpan.FromMilliseconds(250), TimeSpan.FromMilliseconds(250));
    }

    public async ValueTask EncodeAsync(ICapturedFrame frame, bool forceKeyframe, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_sink is null) throw new InvalidOperationException("Start the encoder first.");
        if (frame is not CapturedTexture captured) throw new ArgumentException("Not a frame from this host's capture.", nameof(frame));

        if (_isAsync) await _needInput.WaitAsync(cancellationToken).ConfigureAwait(false);
        ObjectDisposedException.ThrowIf(_disposed, this);

        long sampleTime;
        bool keyframe;
        lock (_lock)
        {
            if (_lastSampleTime < 0) _baseNanos = captured.TimestampNanos;
            sampleTime = (long)((captured.TimestampNanos - Math.Min(_baseNanos, captured.TimestampNanos)) / 100);
            if (sampleTime <= _lastSampleTime) sampleTime = _lastSampleTime + 1; // re-encoding the same frame as an IDR
            _lastSampleTime = sampleTime;
            keyframe = forceKeyframe || _forceNextKeyframe;
            _forceNextKeyframe = false;
        }

        var nv12 = _converter.Convert(captured.Texture);
        var sample = _isHardware ? GpuSample(nv12) : SystemMemorySample(nv12);
        sample.SampleTime = sampleTime;
        sample.SampleDuration = TimeSpan.TicksPerSecond / _fps;

        lock (_lock) _pending.Enqueue(new Pending(sampleTime, captured.TimestampNanos, Environment.TickCount64));

        if (_isAsync)
        {
            try
            {
                if (keyframe) ForceKeyframe();
                var hr = ProcessInput(sample);
                if (hr < 0) FailInput(hr);
            }
            finally
            {
                sample.Dispose();
            }
        }
        else
        {
            _worker!.Post(() =>
            {
                try
                {
                    if (keyframe) ForceKeyframe();
                    var hr = ProcessInput(sample);
                    if (hr < 0) FailInput(hr);
                    else DrainSync();
                }
                catch (Exception ex)
                {
                    ReportError(ex);
                }
                finally
                {
                    sample.Dispose();
                }
            });
        }
    }

    public void SetBitrate(int kbps)
    {
        if (_disposed || kbps == _kbps) return;
        _kbps = kbps;
        ApplyBitrate(kbps);
    }

    public void SetFrameRate(int fps)
    {
        if (_disposed) return;
        _fps = Math.Clamp(fps, 1, 240);
        ApplyBitrate(_kbps); // the VBV size is in frames
    }

    public void SetMaxQP(int maxQP)
    {
        if (_disposed || _codecApi is null || !_codecApi.IsSupported(CodecApiKeys.AVEncVideoMaxQP)) return;
        var hr = _codecApi.SetValue(CodecApiKeys.AVEncVideoMaxQP, CodecVariant.FromUInt32((uint)Math.Clamp(maxQP, 1, 51)));
        if (hr < 0) _log.LogDebug("AVEncVideoMaxQP {QP} refused (0x{Hr:X8})", maxQP, hr);
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        await _stallTimer.DisposeAsync().ConfigureAwait(false);
        _needInput.Release(64); // wake any EncodeAsync still waiting; it sees _disposed
        try { _transform.ProcessMessage(TMessageType.MessageCommandFlush, 0); } catch (SharpGenException) { }
        if (_isAsync)
        {
            Shutdown(_transform.NativePointer);
            _eventThread?.Join(TimeSpan.FromSeconds(2));
            _events?.Dispose();
        }
        _worker?.Dispose();
        _codecApi?.Dispose();
        _transform.Dispose();
        _deviceManager?.Dispose();
        _staging?.Dispose();
        _converter.Dispose();
        _gpu.Dispose();
        _log.LogDebug("encoder {Name} stopped after {Frames} frames", _name, Interlocked.Read(ref _framesOut));
    }

    // ---- setup ----

    private void ApplyStaticSettings(VideoEncoderSettings settings)
    {
        if (_codecApi is null)
        {
            _log.LogWarning("{Name} has no ICodecAPI; low-latency settings can't be applied", _name);
            return;
        }
        Set(CodecApiKeys.AVLowLatencyMode, CodecVariant.FromBool(true));
        Set(CodecApiKeys.AVEncMPVDefaultBPictureCount, CodecVariant.FromUInt32(0));
        Set(CodecApiKeys.AVEncCommonRateControlMode, CodecVariant.FromUInt32(
            _tuning.RateControl == RateControl.LowDelayVbr ? CodecApiKeys.RateControlLowDelayVbr : CodecApiKeys.RateControlCbr));
        if (!Set(CodecApiKeys.AVEncMPVGOPSize, CodecVariant.FromUInt32(EncoderTuning.GopSize)))
            Set(CodecApiKeys.AVEncMPVGOPSize, CodecVariant.FromUInt32(ushort.MaxValue));
        Set(CodecApiKeys.AVEncMPVProfile, CodecVariant.FromUInt32(CodecApiKeys.ProfileHigh));
        Set(CodecApiKeys.AVEncH264CABACEnable, CodecVariant.FromBool(true), quiet: true);
        _ = settings;
    }

    private void ApplyBitrate(int kbps)
    {
        if (_codecApi is null) return;
        var bps = (uint)Math.Clamp(kbps, 100, 1_000_000) * 1000u;
        Set(CodecApiKeys.AVEncCommonMeanBitRate, CodecVariant.FromUInt32(bps));
        Set(CodecApiKeys.AVEncCommonBufferSize, CodecVariant.FromUInt32(EncoderTuning.BufferBits(kbps, _fps, _tuning.BufferFrames)), quiet: true);
        if (_tuning.RateControl == RateControl.LowDelayVbr)
            Set(CodecApiKeys.AVEncCommonMaxBitRate, CodecVariant.FromUInt32(bps + bps / 2), quiet: true);
    }

    private bool Set(Guid key, CodecVariant value, bool quiet = false)
    {
        var hr = _codecApi!.SetValue(key, value);
        if (hr < 0 && !quiet) _log.LogDebug("{Name}: ICodecAPI {Key} = {Value} refused (0x{Hr:X8})", _name, key, value, hr);
        return hr >= 0;
    }

    private void SetMediaTypes(VideoEncoderSettings settings)
    {
        using (var output = MediaFactory.MFCreateMediaType())
        {
            output.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            output.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.H264);
            output.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)settings.BitrateKbps * 1000u);
            MediaFactory.MFSetAttributeSize(output, MediaTypeAttributeKeys.FrameSize, (uint)_width, (uint)_height);
            MediaFactory.MFSetAttributeRatio(output, MediaTypeAttributeKeys.FrameRate, (uint)_fps, 1);
            MediaFactory.MFSetAttributeRatio(output, MediaTypeAttributeKeys.PixelAspectRatio, 1, 1);
            output.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
            output.Set(MediaTypeAttributeKeys.Mpeg2Profile, CodecApiKeys.ProfileHigh);
            output.Set(MediaTypeAttributeKeys.MaxKeyframeSpacing, EncoderTuning.GopSize);
            SetColour(output);
            _transform.SetOutputType(0, output, 0);
        }

        using (var input = MediaFactory.MFCreateMediaType())
        {
            input.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            input.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.NV12);
            MediaFactory.MFSetAttributeSize(input, MediaTypeAttributeKeys.FrameSize, (uint)_width, (uint)_height);
            MediaFactory.MFSetAttributeRatio(input, MediaTypeAttributeKeys.FrameRate, (uint)_fps, 1);
            MediaFactory.MFSetAttributeRatio(input, MediaTypeAttributeKeys.PixelAspectRatio, 1, 1);
            input.Set(MediaTypeAttributeKeys.InterlaceMode, (uint)VideoInterlaceMode.Progressive);
            if (!_isHardware) input.Set(MediaTypeAttributeKeys.DefaultStride, (uint)_width);
            SetColour(input);
            _transform.SetInputType(0, input, 0);
        }
        CaptureSequenceHeader();
    }

    private static void SetColour(IMFMediaType type)
    {
        type.Set(MediaTypeAttributeKeys.VideoPrimaries, (uint)VideoPrimaries.Bt709);
        type.Set(MediaTypeAttributeKeys.TransferFunction, (uint)VideoTransferFunction.FuncSRGB);
        type.Set(MediaTypeAttributeKeys.YuvMatrix, (uint)VideoTransferMatrix.Bt709);
        type.Set(MediaTypeAttributeKeys.VideoNominalRange, 2u); // MFNominalRange_16_235
    }

    /// <summary>Keeps <c>MF_MT_MPEG_SEQUENCE_HEADER</c> (Annex-B SPS/PPS) for keyframes that arrive without them.</summary>
    private void CaptureSequenceHeader()
    {
        try
        {
            using var current = _transform.GetOutputCurrentType(0);
            if (current.GetBlobSize(MediaTypeAttributeKeys.MpegSequenceHeader, out var size).Success && size > 0)
                _sequenceHeader = current.GetBlob(MediaTypeAttributeKeys.MpegSequenceHeader);
        }
        catch (SharpGenException)
        {
        }
    }

    private static string FriendlyName(IMFActivate activate)
    {
        try { return activate.GetString(TransformAttributeKeys.MftFriendlyNameAttribute); }
        catch (SharpGenException) { return "hardware H.264 encoder"; }
    }

    // ---- input ----

    private IMFSample GpuSample(ID3D11Texture2D nv12)
    {
        var buffer = MediaFactory.MFCreateDXGISurfaceBuffer(typeof(ID3D11Texture2D).GUID, nv12, 0, false);
        try
        {
            using (var dxgi = buffer.QueryInterfaceOrNull<IMF2DBuffer>())
            {
                if (dxgi is not null) buffer.CurrentLength = dxgi.ContiguousLength;
            }
            var sample = MediaFactory.MFCreateSample();
            sample.AddBuffer(buffer);
            return sample;
        }
        finally
        {
            buffer.Dispose();
        }
    }

    private unsafe IMFSample SystemMemorySample(ID3D11Texture2D nv12)
    {
        _staging ??= _gpu.Device.CreateTexture2D(new Texture2DDescription(Format.NV12, (uint)_width, (uint)_height, 1, 1, BindFlags.None,
                                                                            ResourceUsage.Staging, CpuAccessFlags.Read, 1, 0, ResourceOptionFlags.None));
        _gpu.Context.CopyResource(_staging, nv12);
        var mapped = _gpu.Context.Map(_staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
        var length = _width * _height * 3 / 2;
        var buffer = MediaFactory.MFCreateMemoryBuffer(length);
        try
        {
            buffer.Lock(out var destination, out _, out _);
            try
            {
                var source = (byte*)mapped.DataPointer;
                var target = (byte*)destination;
                var pitch = (int)mapped.RowPitch;
                for (var row = 0; row < _height; row++)
                    Buffer.MemoryCopy(source + (long)row * pitch, target + (long)row * _width, _width, _width);
                var chroma = source + (long)pitch * _height;
                var chromaTarget = target + (long)_width * _height;
                for (var row = 0; row < _height / 2; row++)
                    Buffer.MemoryCopy(chroma + (long)row * pitch, chromaTarget + (long)row * _width, _width, _width);
            }
            finally
            {
                buffer.Unlock();
                _gpu.Context.Unmap(_staging, 0);
            }
            buffer.CurrentLength = length;
            var sample = MediaFactory.MFCreateSample();
            sample.AddBuffer(buffer);
            return sample;
        }
        finally
        {
            buffer.Dispose();
        }
    }

    private void ForceKeyframe()
    {
        if (_codecApi is null) return;
        var hr = _codecApi.SetValue(CodecApiKeys.AVEncVideoForceKeyFrame, CodecVariant.FromUInt32(1));
        if (hr < 0) _log.LogWarning("{Name}: AVEncVideoForceKeyFrame refused (0x{Hr:X8})", _name, hr);
    }

    private unsafe int ProcessInput(IMFSample sample)
    {
        var fn = (delegate* unmanaged[Stdcall]<nint, uint, nint, uint, int>)(*(void***)_transform.NativePointer)[24];
        return fn(_transform.NativePointer, 0, sample.NativePointer, 0);
    }

    private void FailInput(int hr)
    {
        // The frame never went in: answer it now so the core's one-in-flight accounting holds.
        lock (_lock)
        {
            foreach (var pending in _pending)
            {
                if (pending.SampleTime == _lastSampleTime) pending.Abandoned = true;
            }
            _forceNextKeyframe = true;
        }
        _log.LogWarning("{Name}: ProcessInput failed (0x{Hr:X8}); frame skipped", _name, hr);
        if (hr == MF_E_NOTACCEPTING && _isAsync) _needInput.Release(); // it will ask again
        _sink?.OnFrameSkipped();
    }

    // ---- output ----

    [StructLayout(LayoutKind.Sequential)]
    private struct OutputDataBuffer
    {
        public uint StreamId;
        public nint Sample;
        public uint Status;
        public nint Events;
    }

    private unsafe int ProcessOutput(ref OutputDataBuffer buffer)
    {
        var fn = (delegate* unmanaged[Stdcall]<nint, uint, uint, OutputDataBuffer*, uint*, int>)(*(void***)_transform.NativePointer)[25];
        uint status = 0;
        fixed (OutputDataBuffer* pointer = &buffer) return fn(_transform.NativePointer, 0, 1, pointer, &status);
    }

    private void EventLoop()
    {
        while (!_disposed)
        {
            IMFMediaEvent mediaEvent;
            try
            {
                mediaEvent = _events!.GetEvent(0);
            }
            catch (SharpGenException ex)
            {
                if (!_disposed && ex.ResultCode.Code != MF_E_SHUTDOWN) ReportError(ex);
                return;
            }
            using (mediaEvent)
            {
                try
                {
                    switch (mediaEvent.EventType)
                    {
                        case MediaEventTypes.TransformNeedInput:
                            _needInput.Release();
                            break;
                        case MediaEventTypes.TransformHaveOutput:
                            DrainOne();
                            break;
                        case MediaEventTypes.Error:
                            ReportError(new COMException($"{_name} reported an error", mediaEvent.Status.Code));
                            break;
                    }
                }
                catch (Exception ex)
                {
                    if (!_disposed) ReportError(ex);
                }
            }
        }
    }

    private void DrainOne()
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var buffer = new OutputDataBuffer();
            var hr = ProcessOutput(ref buffer);
            if (buffer.Events != 0) Marshal.Release(buffer.Events);
            if (hr == MF_E_TRANSFORM_STREAM_CHANGE)
            {
                if (buffer.Sample != 0) Marshal.Release(buffer.Sample);
                Renegotiate();
                continue;
            }
            if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return;
            if (hr < 0)
            {
                if (buffer.Sample != 0) Marshal.Release(buffer.Sample);
                throw new COMException($"{_name}: ProcessOutput failed", hr);
            }
            if (buffer.Sample == 0) return;
            using var sample = new IMFSample(buffer.Sample);
            Deliver(sample);
            return;
        }
    }

    private void DrainSync()
    {
        while (!_disposed)
        {
            IMFSample? own = null;
            var buffer = new OutputDataBuffer();
            if (!_outputProvidesSamples)
            {
                own = MediaFactory.MFCreateSample();
                using var memory = MediaFactory.MFCreateMemoryBuffer(_outputBufferSize);
                own.AddBuffer(memory);
                buffer.Sample = own.NativePointer;
            }
            try
            {
                var hr = ProcessOutput(ref buffer);
                if (buffer.Events != 0) Marshal.Release(buffer.Events);
                if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return;
                if (hr == MF_E_TRANSFORM_STREAM_CHANGE)
                {
                    Renegotiate();
                    continue;
                }
                if (hr < 0) throw new COMException($"{_name}: ProcessOutput failed", hr);
                if (own is not null)
                {
                    Deliver(own);
                }
                else if (buffer.Sample != 0)
                {
                    using var provided = new IMFSample(buffer.Sample);
                    Deliver(provided);
                }
            }
            finally
            {
                own?.Dispose();
            }
        }
    }

    private void Renegotiate()
    {
        using var type = _transform.GetOutputAvailableType(0, 0);
        _transform.SetOutputType(0, type, 0);
        CaptureSequenceHeader();
        _log.LogDebug("{Name}: output type renegotiated", _name);
    }

    private unsafe void Deliver(IMFSample sample)
    {
        var sampleTime = sample.SampleTime;
        var isKeyframe = sample.GetUInt32(MFSampleExtension_CleanPoint, out var clean).Success && clean != 0;
        byte[] data;
        using (var contiguous = sample.ConvertToContiguousBuffer())
        {
            contiguous.Lock(out var pointer, out _, out var length);
            try
            {
                data = new ReadOnlySpan<byte>((void*)pointer, length).ToArray();
            }
            finally
            {
                contiguous.Unlock();
            }
        }
        if (data.Length == 0) return;
        if (!isKeyframe) isKeyframe = NalUnits.Contains(data, NalUnits.Idr);
        if (isKeyframe && _sequenceHeader is { Length: > 0 } header && !NalUnits.Contains(data, NalUnits.Sps))
            data = [.. header, .. data];

        var skipped = 0;
        Pending? match = null;
        lock (_lock)
        {
            while (_pending.Count > 0 && _pending.Peek().SampleTime < sampleTime)
            {
                var gone = _pending.Dequeue();
                if (!gone.Abandoned) skipped++;
            }
            if (_pending.Count > 0 && _pending.Peek().SampleTime == sampleTime) match = _pending.Dequeue();
            if (skipped > 0) _forceNextKeyframe = true;
        }
        for (var i = 0; i < skipped; i++) _sink?.OnFrameSkipped();

        if (match is null || match.Abandoned)
        {
            // An answer to a frame already reported skipped, or one we never sent: drop it, and make
            // the next frame an IDR so the client never decodes against a missing reference.
            lock (_lock) _forceNextKeyframe = true;
            return;
        }

        if (Interlocked.Increment(ref _framesOut) == 1)
            _log.LogInformation("{Name}: first frame {Bytes} bytes, NAL types [{Types}]", _name, data.Length, string.Join(",", NalUnits.Types(data)));
        _sink?.OnFrame(new EncodedFrame
        {
            Data = data,
            Format = NalFormat.AnnexB,
            IsKeyframe = isKeyframe,
            CaptureNanos = match.CaptureNanos,
            Width = _width,
            Height = _height,
        });
    }

    private void CheckForStall()
    {
        var now = Environment.TickCount64;
        var abandoned = 0;
        lock (_lock)
        {
            foreach (var pending in _pending)
            {
                if (pending.Abandoned || now - pending.QueuedAt < StallLimit.TotalMilliseconds) continue;
                pending.Abandoned = true;
                abandoned++;
            }
            if (abandoned > 0) _forceNextKeyframe = true;
        }
        if (abandoned == 0) return;
        _log.LogWarning("{Name}: {Count} frame(s) got no output within {Limit} s; reported skipped", _name, abandoned, StallLimit.TotalSeconds);
        for (var i = 0; i < abandoned; i++) _sink?.OnFrameSkipped();
    }

    private void ReportError(Exception error)
    {
        if (_disposed) return;
        _log.LogError(error, "{Name} failed", _name);
        _sink?.OnError(error);
    }
}

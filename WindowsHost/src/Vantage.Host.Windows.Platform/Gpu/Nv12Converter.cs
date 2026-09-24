using Microsoft.Extensions.Logging;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice;

namespace Vantage.Host.Windows.Gpu;

/// <summary>
/// BGRA → NV12 on the GPU with <c>ID3D11VideoProcessor</c>: sRGB full-range RGB in
/// (<c>RGB_FULL_G22_NONE_P709</c>), BT.709 video-range 4:2:0 out (<c>YCBCR_STUDIO_G22_LEFT_P709</c>),
/// scaling to the encoded size when the desktop is larger than the client can decode (spec §7.3).
/// Output goes to a small ring of NV12 textures the encoder reads from.
/// </summary>
internal sealed class Nv12Converter : IDisposable
{
    private const int MaxCachedInputViews = 8;

    private readonly GpuDevice _gpu;
    private readonly ID3D11VideoProcessorEnumerator _enumerator;
    private readonly ID3D11VideoProcessor _processor;
    private readonly ID3D11Texture2D[] _outputs;
    private readonly ID3D11VideoProcessorOutputView[] _outputViews;
    private readonly Dictionary<nint, ID3D11VideoProcessorInputView> _inputViews = [];
    private int _next;

    public Nv12Converter(GpuDevice gpu, int inputWidth, int inputHeight, int outputWidth, int outputHeight, int ringSize, ILogger log)
    {
        _gpu = gpu;
        OutputWidth = outputWidth;
        OutputHeight = outputHeight;

        var content = new VideoProcessorContentDescription
        {
            InputFrameFormat = VideoFrameFormat.Progressive,
            InputFrameRate = new Rational(60, 1),
            InputWidth = (uint)inputWidth,
            InputHeight = (uint)inputHeight,
            OutputFrameRate = new Rational(60, 1),
            OutputWidth = (uint)outputWidth,
            OutputHeight = (uint)outputHeight,
            Usage = VideoUsage.OptimalSpeed,
        };
        _enumerator = gpu.VideoDevice.CreateVideoProcessorEnumerator(content);
        if ((_enumerator.CheckVideoProcessorFormat(Format.B8G8R8A8_UNorm) & VideoProcessorFormatSupport.Input) == 0)
            throw new NotSupportedException("The GPU's video processor can't read BGRA.");
        if ((_enumerator.CheckVideoProcessorFormat(Format.NV12) & VideoProcessorFormatSupport.Output) == 0)
            throw new NotSupportedException("The GPU's video processor can't write NV12.");
        _processor = gpu.VideoDevice.CreateVideoProcessor(_enumerator, 0);

        var context = gpu.VideoContext;
        using (var context1 = context.QueryInterfaceOrNull<ID3D11VideoContext1>())
        {
            if (context1 is not null)
            {
                context1.VideoProcessorSetStreamColorSpace1(_processor, 0, ColorSpaceType.RgbFullG22NoneP709);
                context1.VideoProcessorSetOutputColorSpace1(_processor, ColorSpaceType.YcbcrStudioG22LeftP709);
            }
            else
            {
                // D3D11_VIDEO_PROCESSOR_COLOR_SPACE bitfields: RGB_Range 0 = full; YCbCr_Matrix 1 = BT.709;
                // Nominal_Range 1 = 16–235.
                context.VideoProcessorSetStreamColorSpace(_processor, 0, new VideoProcessorColorSpace { RGB_Range = 0, YCbCr_Matrix = 1, Nominal_Range = 2 });
                context.VideoProcessorSetOutputColorSpace(_processor, new VideoProcessorColorSpace { RGB_Range = 1, YCbCr_Matrix = 1, Nominal_Range = 1 });
                log.LogDebug("ID3D11VideoContext1 unavailable; using legacy video processor colour spaces");
            }
        }
        context.VideoProcessorSetStreamFrameFormat(_processor, 0, VideoFrameFormat.Progressive);
        context.VideoProcessorSetStreamAutoProcessingMode(_processor, 0, false);
        context.VideoProcessorSetStreamSourceRect(_processor, 0, true, new RawRect(0, 0, inputWidth, inputHeight));
        context.VideoProcessorSetStreamDestRect(_processor, 0, true, new RawRect(0, 0, outputWidth, outputHeight));
        context.VideoProcessorSetOutputTargetRect(_processor, true, new RawRect(0, 0, outputWidth, outputHeight));

        _outputs = new ID3D11Texture2D[ringSize];
        _outputViews = new ID3D11VideoProcessorOutputView[ringSize];
        var description = new Texture2DDescription(Format.NV12, (uint)outputWidth, (uint)outputHeight, 1, 1,
                                                   BindFlags.RenderTarget, ResourceUsage.Default, CpuAccessFlags.None,
                                                   1, 0, ResourceOptionFlags.None);
        var viewDescription = new VideoProcessorOutputViewDescription { ViewDimension = VideoProcessorOutputViewDimension.Texture2D };
        for (var i = 0; i < ringSize; i++)
        {
            _outputs[i] = gpu.Device.CreateTexture2D(description);
            _outputViews[i] = gpu.VideoDevice.CreateVideoProcessorOutputView(_outputs[i], _enumerator, viewDescription);
        }
        if (inputWidth != outputWidth || inputHeight != outputHeight)
            log.LogInformation("scaling {InW}×{InH} to {OutW}×{OutH} for the client's decoder", inputWidth, inputHeight, outputWidth, outputHeight);
    }

    public int OutputWidth { get; }

    public int OutputHeight { get; }

    /// <summary>
    /// Queues the conversion of <paramref name="source"/> (BGRA, the capture size) into the next NV12
    /// texture of the ring and returns it. The GPU copy is ordered before any later write to the
    /// source on the same device, so the caller may release the source afterwards.
    /// </summary>
    public ID3D11Texture2D Convert(ID3D11Texture2D source)
    {
        var index = _next;
        _next = (_next + 1) % _outputs.Length;

        var stream = new VideoProcessorStream
        {
            Enable = true,
            OutputIndex = 0,
            InputFrameOrField = 0,
            InputSurface = InputViewFor(source),
        };
        _gpu.VideoContext.VideoProcessorBlt(_processor, _outputViews[index], 0, 1, [stream]).CheckError();
        return _outputs[index];
    }

    public void Dispose()
    {
        foreach (var view in _inputViews.Values) view.Dispose();
        _inputViews.Clear();
        foreach (var view in _outputViews) view?.Dispose();
        foreach (var texture in _outputs) texture?.Dispose();
        _processor.Dispose();
        _enumerator.Dispose();
    }

    private ID3D11VideoProcessorInputView InputViewFor(ID3D11Texture2D source)
    {
        // Views keep their texture alive, so a cached pointer can't be reused by a new texture.
        if (_inputViews.TryGetValue(source.NativePointer, out var view)) return view;
        if (_inputViews.Count >= MaxCachedInputViews)
        {
            foreach (var old in _inputViews.Values) old.Dispose();
            _inputViews.Clear();
        }
        view = _gpu.VideoDevice.CreateVideoProcessorInputView(source, _enumerator, new VideoProcessorInputViewDescription
        {
            FourCC = 0,
            ViewDimension = VideoProcessorInputViewDimension.Texture2D,
        });
        _inputViews[source.NativePointer] = view;
        return view;
    }
}

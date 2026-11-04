using System.Diagnostics;
using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Capture;
using Vortice.D3DCompiler;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Vantage.Host.Windows.Gpu;

/// <summary>
/// A dirty ratio for captures that don't report dirty regions (Windows before 11 24H2): a compute
/// pass (<c>FrameCompare.hlsl</c>) compares each frame with the previous one in
/// <see cref="FrameChange.BlockSize"/>-pixel blocks on the capture's GPU and writes one byte per
/// block; only that map (8 KB at 4K) comes back to the CPU, never a frame. The previous frame lives
/// in a GPU texture the pass itself updates, so there's no extra full-frame copy.
/// </summary>
/// <remarks>
/// The capture thread only queues the work (dispatch, copy to a staging slot, flush) and returns;
/// the map is read when the core first asks for the frame's dirty ratio, on the session's queue,
/// polling with <c>D3D11_MAP_FLAG_DO_NOT_WAIT</c> first. The compare runs at capture time rather
/// than beside the NV12 conversion because the core decides from the ratio whether to encode at
/// all; conversion happens only for the frames it keeps.
/// </remarks>
internal sealed class FrameComparer : IDisposable
{
    private const int StagingSlots = 8;
    private const int MaxCachedInputViews = 8;
    private static readonly TimeSpan s_pollBudget = TimeSpan.FromMilliseconds(4);
    private static readonly TimeSpan s_statsInterval = TimeSpan.FromSeconds(10);
    private static readonly Lazy<byte[]> s_bytecode = new(CompileShader);

    private readonly Lock _lock = new();
    private readonly GpuDevice _gpu;
    private readonly ILogger _log;
    private readonly string _name;
    private readonly ID3D11ComputeShader? _shader;
    private readonly ID3D11Texture2D? _previous;
    private readonly ID3D11UnorderedAccessView? _previousView;
    private readonly ID3D11Texture2D? _blocks;
    private readonly ID3D11UnorderedAccessView? _blocksView;
    private readonly ID3D11Texture2D?[] _staging = new ID3D11Texture2D?[StagingSlots];
    private readonly ReadbackRing _ring = new(StagingSlots);
    private readonly Dictionary<nint, ID3D11ShaderResourceView> _inputViews = [];
    private readonly CompareStats _stats = new();
    private bool _hasPrevious;
    private bool _disposed;

    /// <param name="gpu">The capture's device (not owned).</param>
    /// <param name="width">Frame width in pixels.</param>
    /// <param name="height">Frame height in pixels.</param>
    /// <param name="name">The display, for the stats log.</param>
    /// <param name="log">Where stats go every 10 s.</param>
    public FrameComparer(GpuDevice gpu, int width, int height, string name, ILogger log)
    {
        _gpu = gpu;
        _log = log;
        _name = name;
        BlocksAcross = FrameChange.Blocks(width);
        BlocksDown = FrameChange.Blocks(height);
        var device = gpu.Device;
        try
        {
            _shader = device.CreateComputeShader(s_bytecode.Value);
            _previous = device.CreateTexture2D(new Texture2DDescription(Format.R32_UInt, (uint)width, (uint)height, 1, 1,
                                                                        BindFlags.UnorderedAccess, ResourceUsage.Default,
                                                                        CpuAccessFlags.None, 1, 0, ResourceOptionFlags.None));
            _previousView = device.CreateUnorderedAccessView(_previous);
            _blocks = device.CreateTexture2D(new Texture2DDescription(Format.R8_UInt, (uint)BlocksAcross, (uint)BlocksDown, 1, 1,
                                                                      BindFlags.UnorderedAccess, ResourceUsage.Default,
                                                                      CpuAccessFlags.None, 1, 0, ResourceOptionFlags.None));
            _blocksView = device.CreateUnorderedAccessView(_blocks);
            var staging = new Texture2DDescription(Format.R8_UInt, (uint)BlocksAcross, (uint)BlocksDown, 1, 1,
                                                   BindFlags.None, ResourceUsage.Staging, CpuAccessFlags.Read,
                                                   1, 0, ResourceOptionFlags.None);
            for (var i = 0; i < StagingSlots; i++) _staging[i] = device.CreateTexture2D(staging);
        }
        catch
        {
            DisposeResources();
            throw;
        }
    }

    /// <summary>Block columns.</summary>
    public int BlocksAcross { get; }

    /// <summary>Block rows.</summary>
    public int BlocksDown { get; }

    /// <summary>
    /// Queues the compare of <paramref name="current"/> (BGRA, the capture size, bindable as a
    /// shader resource) with the previous frame and makes it the new previous frame. Returns at
    /// once; the answer is read later through the returned estimate. The first frame reports 1.
    /// </summary>
    public FrameEstimate Compare(ID3D11Texture2D current)
    {
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var first = !_hasPrevious;
            _hasPrevious = true;
            var ticket = _ring.Begin();
            using (_gpu.LockContext())
            {
                var context = _gpu.Context;
                context.CSSetShader(_shader);
                context.CSSetShaderResource(0, InputViewFor(current));
                context.CSSetUnorderedAccessView(0, _previousView);
                context.CSSetUnorderedAccessView(1, _blocksView);
                context.Dispatch((uint)BlocksAcross, (uint)BlocksDown, 1);
                // Unbind, so the frame can go on to the video processor and the map to its copy.
                context.CSSetShaderResource(0, null);
                context.CSSetUnorderedAccessView(0, null);
                context.CSSetUnorderedAccessView(1, null);
                context.CSSetShader(null);
                context.CopyResource(_staging[ticket.Slot]!, _blocks!);
                context.Flush();
            }
            return new FrameEstimate(this, ticket, first);
        }
    }

    /// <summary>
    /// Reads <paramref name="ticket"/>'s block map: polls without waiting for a few milliseconds,
    /// then waits. 1 when the map is gone (overwritten a ring later, or the comparer disposed).
    /// </summary>
    internal double Resolve(ReadbackTicket ticket, bool first)
    {
        if (first) return 1;
        var began = Stopwatch.GetTimestamp();
        var spinner = new SpinWait();
        while (true)
        {
            var wait = Stopwatch.GetElapsedTime(began) >= s_pollBudget;
            lock (_lock)
            {
                if (_disposed || !_ring.IsCurrent(ticket)) return 1;
                double? ratio;
                using (_gpu.LockContext()) ratio = TryRead(_staging[ticket.Slot]!, wait);
                if (ratio is { } known)
                {
                    _stats.Add(known, Stopwatch.GetElapsedTime(began).TotalMilliseconds);
                    if (_stats.Elapsed >= s_statsInterval) LogStats();
                    return known;
                }
            }
            spinner.SpinOnce(sleep1Threshold: -1);
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed) return;
            _disposed = true;
            DisposeResources();
        }
    }

    /// <summary>Compiles the embedded HLSL once per process (<c>cs_5_0</c>: feature level 11.0).</summary>
    private static byte[] CompileShader()
    {
        using var stream = typeof(FrameComparer).Assembly.GetManifestResourceStream("Vantage.Host.Windows.Gpu.FrameCompare.hlsl")
            ?? throw new InvalidOperationException("FrameCompare.hlsl isn't embedded.");
        using var reader = new StreamReader(stream);
        var source = reader.ReadToEnd();
        var result = Compiler.Compile(source, "main", "FrameCompare.hlsl", "cs_5_0", out var blob, out var errors);
        try
        {
            if (result.Failure || blob is null)
                throw new InvalidOperationException($"FrameCompare.hlsl didn't compile: {errors?.AsString() ?? result.ToString()}");
            return blob.AsBytes();
        }
        finally
        {
            blob?.Dispose();
            errors?.Dispose();
        }
    }

    private unsafe double? TryRead(ID3D11Texture2D staging, bool wait)
    {
        var context = _gpu.Context;
        var result = context.Map(staging, 0, MapMode.Read, wait ? Vortice.Direct3D11.MapFlags.None : Vortice.Direct3D11.MapFlags.DoNotWait, out var mapped);
        if (result == Vortice.DXGI.ResultCode.WasStillDrawing) return null;
        result.CheckError();
        try
        {
            var pitch = (int)mapped.RowPitch;
            var map = new ReadOnlySpan<byte>((void*)mapped.DataPointer, pitch * (BlocksDown - 1) + BlocksAcross);
            var changed = FrameChange.CountChanged(map, pitch, BlocksAcross, BlocksDown);
            return FrameChange.Ratio(changed, BlocksAcross * BlocksDown);
        }
        finally
        {
            context.Unmap(staging, 0);
        }
    }

    private void LogStats()
    {
        var s = _stats.TakeAndReset();
        _log.LogInformation("dirty compare on {Name}: {Frames} frames in {Seconds:0} s, {Unchanged} unchanged, mean ratio {Mean:0.0000}, max {Max:0.0000}; readback {Wait:0.000} ms mean, {MaxWait:0.000} ms max",
                            _name, s.Frames, s.Seconds, s.Unchanged, s.MeanRatio, s.MaxRatio, s.MeanWaitMs, s.MaxWaitMs);
    }

    private ID3D11ShaderResourceView InputViewFor(ID3D11Texture2D source)
    {
        // Views keep their texture alive, so a cached pointer can't be reused by a new texture.
        if (_inputViews.TryGetValue(source.NativePointer, out var view)) return view;
        if (_inputViews.Count >= MaxCachedInputViews)
        {
            foreach (var old in _inputViews.Values) old.Dispose();
            _inputViews.Clear();
        }
        view = _gpu.Device.CreateShaderResourceView(source);
        _inputViews[source.NativePointer] = view;
        return view;
    }

    private void DisposeResources()
    {
        foreach (var view in _inputViews.Values) view.Dispose();
        _inputViews.Clear();
        foreach (var texture in _staging) texture?.Dispose();
        _blocksView?.Dispose();
        _blocks?.Dispose();
        _previousView?.Dispose();
        _previous?.Dispose();
        _shader?.Dispose();
    }
}

/// <summary>A frame's pending compare result, read once on first use.</summary>
internal sealed class FrameEstimate(FrameComparer comparer, ReadbackTicket ticket, bool first)
{
    private double? _ratio;

    /// <summary>The frame's dirty ratio (0 = identical to the previous frame). Reads the GPU's answer the first time.</summary>
    public double Ratio => _ratio ??= comparer.Resolve(ticket, first);
}

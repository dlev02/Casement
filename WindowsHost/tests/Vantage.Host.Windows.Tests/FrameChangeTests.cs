using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging.Abstractions;
using Vantage.Host.Windows.Capture;
using Vantage.Host.Windows.Composition;
using Vantage.Host.Windows.Gpu;
using Vantage.Protocol.Host;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace Vantage.Host.Windows.Tests;

public class FrameChangeTests
{
    [Fact]
    public void NothingChangedIsExactlyZeroSoTheCoreSkipsIt()
    {
        Assert.Equal(0, FrameChange.Ratio(0, 8160));
        Assert.True(FrameChange.Ratio(0, 8160) <= HostSessionCore.IdleDirtyRatio);
    }

    [Fact]
    public void OneChangedBlockStaysAboveTheIdleThresholdEvenAt8K()
    {
        // A caret blink is one block; 8K has 240 × 135 = 32 400 of them.
        var ratio = FrameChange.Ratio(1, 240 * 135);
        Assert.Equal(FrameChange.MinChangedRatio, ratio);
        Assert.True(ratio > HostSessionCore.IdleDirtyRatio);
    }

    [Fact]
    public void RatioIsTheChangedShare()
    {
        Assert.Equal(0.25, FrameChange.Ratio(2040, 8160), 12);
        Assert.Equal(1.0, FrameChange.Ratio(8160, 8160), 12);
        Assert.Equal(1.0, FrameChange.Ratio(1, 0)); // no blocks: unknown
    }

    [Fact]
    public void BlocksCoverPartialEdges()
    {
        Assert.Equal(120, FrameChange.Blocks(3840));
        Assert.Equal(68, FrameChange.Blocks(2160)); // 67.5
        Assert.Equal(1, FrameChange.Blocks(1));
    }

    [Fact]
    public void CountChangedReadsOnlyTheMapAndSkipsRowPadding()
    {
        // 3 × 2 blocks, rows 8 bytes apart; the padding bytes are nonzero and must be ignored.
        byte[] map = [1, 0, 1, 9, 9, 9, 9, 9,
                      0, 0, 1];
        Assert.Equal(3, FrameChange.CountChanged(map, rowPitch: 8, columns: 3, rows: 2));
    }

    [Theory]
    [InlineData(DirtyRegionSource.Native, true, DirtyRegionSource.Native)]
    [InlineData(DirtyRegionSource.Native, false, DirtyRegionSource.Compare)]
    [InlineData(DirtyRegionSource.Compare, true, DirtyRegionSource.Compare)]
    [InlineData(DirtyRegionSource.None, false, DirtyRegionSource.None)]
    public void NativeFallsBackToCompareBefore24H2(DirtyRegionSource asked, bool nativeAvailable, DirtyRegionSource expected) =>
        Assert.Equal(expected, FrameChange.Resolve(asked, nativeAvailable));

    [Fact]
    public void RingHandsOutSlotsRoundRobinAndForgetsOverwrittenOnes()
    {
        var ring = new ReadbackRing(3);
        var first = ring.Begin();
        var second = ring.Begin();
        Assert.Equal(0, first.Slot);
        Assert.Equal(1, second.Slot);
        Assert.True(ring.IsCurrent(first));
        ring.Begin();
        var fourth = ring.Begin(); // wraps onto the first's slot
        Assert.Equal(0, fourth.Slot);
        Assert.False(ring.IsCurrent(first));
        Assert.True(ring.IsCurrent(second));
        Assert.True(ring.IsCurrent(fourth));
        Assert.False(ring.IsCurrent(new ReadbackTicket(7, 0)));
    }

    [Fact]
    public void StatsCountUnchangedFramesAndReset()
    {
        var stats = new CompareStats();
        stats.Add(0, 0.1);
        stats.Add(0, 0.3);
        stats.Add(0.5, 0.2);
        var summary = stats.TakeAndReset();
        Assert.Equal(3, summary.Frames);
        Assert.Equal(2, summary.Unchanged);
        Assert.Equal(0.5 / 3, summary.MeanRatio, 12);
        Assert.Equal(0.3, summary.MaxWaitMs, 12);
        Assert.Equal(0, stats.TakeAndReset().Frames);
    }

    [Theory]
    [InlineData("native", DirtyRegionSource.Native)]
    [InlineData("Compare", DirtyRegionSource.Compare)]
    [InlineData("none", DirtyRegionSource.None)]
    public void DirtyRegionsFlag(string value, DirtyRegionSource expected)
    {
        Assert.Equal(expected, HostCommandLine.Parse(["--dirty-regions", value], debugBuild: false).DirtyRegions);
        Assert.Equal(DirtyRegionSource.Native, HostCommandLine.Parse([], debugBuild: false).DirtyRegions);
        Assert.Throws<ArgumentException>(() => HostCommandLine.Parse(["--dirty-regions", "sometimes"], debugBuild: false));
    }
}

/// <summary>
/// The compute pass itself, on this PC's GPU (or WARP). Skipped where no D3D11 device can be made
/// (a CI runner without one).
/// </summary>
public class FrameComparerGpuTests
{
    [Fact]
    public void ComparesBlocksOnTheGpu()
    {
        using var gpu = CreateDevice();
        // 100 × 70: 4 × 3 blocks, the last column and row partial.
        const int width = 100, height = 70;
        using var comparer = new FrameComparer(gpu, width, height, "test", NullLogger.Instance);
        Assert.Equal(4, comparer.BlocksAcross);
        Assert.Equal(3, comparer.BlocksDown);

        var a = Pixels(width, height, 0xFF336699);
        Assert.Equal(1.0, Compare(gpu, comparer, a, width, height)); // first frame: nothing to compare with
        Assert.Equal(0.0, Compare(gpu, comparer, a, width, height)); // identical

        var oneBlock = (uint[])a.Clone();
        oneBlock[(height - 1) * width + width - 1] = 0xFF336698; // bottom-right pixel, in the partial corner block
        Assert.Equal(1.0 / 12, Compare(gpu, comparer, oneBlock, width, height), 12);
        Assert.Equal(0.0, Compare(gpu, comparer, oneBlock, width, height)); // and it's the new reference

        var alphaOnly = oneBlock.Select(p => p & 0x00FFFFFF).ToArray();
        Assert.Equal(0.0, Compare(gpu, comparer, alphaOnly, width, height)); // alpha is ignored

        var all = Pixels(width, height, 0xFF000000);
        Assert.Equal(1.0, Compare(gpu, comparer, all, width, height), 12);
    }

    [Fact]
    public void A4KCompareIsCheap()
    {
        using var gpu = CreateDevice();
        const int width = 3840, height = 2160;
        using var comparer = new FrameComparer(gpu, width, height, "test", NullLogger.Instance);
        var pixels = Pixels(width, height, 0xFF202020);
        using var texture = Upload(gpu, pixels, width, height);
        comparer.Compare(texture).Ratio.ToString();
        const int frames = 60;
        var watch = Stopwatch.StartNew();
        for (var i = 0; i < frames; i++)
            Assert.Equal(0.0, comparer.Compare(texture).Ratio);
        var perFrame = watch.Elapsed.TotalMilliseconds / frames;
        TestContext.Current.SendDiagnosticMessage($"4K compare + readback on {gpu.AdapterName}: {perFrame:0.000} ms per frame");
        Assert.True(perFrame < 50, $"{perFrame} ms per frame");
    }

    private static GpuDevice CreateDevice()
    {
        foreach (var warp in new[] { false, true })
        {
            try { return GpuDevice.CreateForTesting(warp, NullLogger.Instance); }
            catch (Exception) { }
        }
        Assert.Skip("No Direct3D 11 device on this machine.");
        throw new InvalidOperationException();
    }

    private static uint[] Pixels(int width, int height, uint bgra) => Enumerable.Repeat(bgra, width * height).ToArray();

    private static double Compare(GpuDevice gpu, FrameComparer comparer, uint[] pixels, int width, int height)
    {
        using var texture = Upload(gpu, pixels, width, height);
        return comparer.Compare(texture).Ratio;
    }

    private static ID3D11Texture2D Upload(GpuDevice gpu, uint[] pixels, int width, int height)
    {
        var handle = GCHandle.Alloc(pixels, GCHandleType.Pinned);
        try
        {
            var description = new Texture2DDescription(Format.B8G8R8A8_UNorm, (uint)width, (uint)height, 1, 1,
                                                       BindFlags.ShaderResource, ResourceUsage.Default, CpuAccessFlags.None,
                                                       1, 0, ResourceOptionFlags.None);
            return gpu.Device.CreateTexture2D(description, [new SubresourceData(handle.AddrOfPinnedObject(), (uint)width * 4)]);
        }
        finally
        {
            handle.Free();
        }
    }
}

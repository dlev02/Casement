using Vantage.Host.Windows.Capture;
using Vantage.Host.Windows.Input;

namespace Vantage.Host.Windows.Tests;

public class AbsoluteCoordinatesTests
{
    [Theory]
    [InlineData(1920)]
    [InlineData(2560)]
    [InlineData(3840)]
    [InlineData(5120)]
    public void EdgesMapToTheEndsOfTheRange(int width)
    {
        Assert.Equal(0, AbsoluteCoordinates.Normalize(0, 0, width));
        Assert.Equal(65535, AbsoluteCoordinates.Normalize(width - 1, 0, width));
    }

    [Theory]
    [InlineData(0, 1920)]
    [InlineData(0, 3840)]
    [InlineData(-1920, 3840)] // a monitor left of the primary: the virtual screen starts at -1920
    [InlineData(-2560, 6400)]
    public void EveryPixelRoundTripsThroughWindowsInverse(int origin, int extent)
    {
        for (var pixel = origin; pixel < origin + extent; pixel++)
        {
            var normalized = AbsoluteCoordinates.Normalize(pixel, origin, extent);
            Assert.Equal(pixel, AbsoluteCoordinates.Denormalize(normalized, origin, extent));
        }
    }

    [Fact]
    public void OutsideTheVirtualScreenClamps()
    {
        Assert.Equal(0, AbsoluteCoordinates.Normalize(-50, 0, 1920));
        Assert.Equal(65535, AbsoluteCoordinates.Normalize(5000, 0, 1920));
        Assert.Equal(0, AbsoluteCoordinates.Normalize(10, 0, 1));
    }
}

public class DisplayMathTests
{
    [Theory]
    [InlineData(@"\\.\DISPLAY1", 1u)]
    [InlineData(@"\\.\DISPLAY12", 12u)]
    [InlineData(@"\\.\display3", 3u)]
    public void ReadsTheDisplayNumber(string name, uint expected) => Assert.Equal(expected, DisplayMath.DisplayNumber(name));

    [Theory]
    [InlineData(@"\\.\DISPLAY")]
    [InlineData(@"\\.\DISPLAYx")]
    [InlineData("DISPLAY1")]
    [InlineData("")]
    public void RejectsOtherNames(string name) => Assert.Null(DisplayMath.DisplayNumber(name));

    [Theory]
    [InlineData(96u, 1.0)]
    [InlineData(120u, 1.25)]
    [InlineData(144u, 1.5)]
    [InlineData(192u, 2.0)]
    [InlineData(0u, 1.0)]
    public void ScaleIsDpiOver96(uint dpi, double scale) => Assert.Equal(scale, DisplayMath.Scale(dpi));

    [Theory]
    [InlineData(3840, 1.5, 2560)]
    [InlineData(2160, 1.5, 1440)]
    [InlineData(2560, 1.25, 2048)]
    [InlineData(1366, 1.25, 1093)] // 1092.8 rounds up
    [InlineData(1920, 1.0, 1920)]
    [InlineData(3840, 1.75, 2194)] // 2194.29
    public void PointsAreRoundedPixelsOverScale(int pixels, double scale, int points) =>
        Assert.Equal(points, DisplayMath.Points(pixels, scale));

    [Theory]
    [InlineData(0x80000000u, true)] // INTERNAL
    [InlineData(6u, true)]          // LVDS
    [InlineData(11u, true)]         // DISPLAYPORT_EMBEDDED
    [InlineData(13u, true)]         // UDI_EMBEDDED
    [InlineData(5u, false)]         // HDMI
    [InlineData(10u, false)]        // DISPLAYPORT_EXTERNAL
    public void BuiltInPanels(uint technology, bool builtIn) => Assert.Equal(builtIn, DisplayMath.IsBuiltIn(technology));

    [Theory]
    [InlineData(0u, 60.0)]
    [InlineData(1u, 60.0)]
    [InlineData(144u, 144.0)]
    public void RefreshRateDefaultsTo60(uint frequency, double rate) => Assert.Equal(rate, DisplayMath.RefreshRate(frequency));
}

public class DirtyRegionMathTests
{
    [Fact]
    public void NoRectanglesCountsAsACursorsWorth()
    {
        var ratio = DirtyRegionMath.Ratio([], 1920, 1080);
        Assert.Equal(1024.0 / (1920 * 1080), ratio, 12);
        Assert.True(ratio > 0);
    }

    [Fact]
    public void OneRectangle()
    {
        Assert.Equal(0.25, DirtyRegionMath.Ratio([new PixelRect(0, 0, 960, 540)], 1920, 1080), 12);
    }

    [Fact]
    public void OverlapsCountOnce()
    {
        PixelRect[] rects = [new(0, 0, 100, 100), new(50, 50, 100, 100), new(0, 0, 100, 100)];
        Assert.Equal(100 * 100 + 100 * 100 - 50 * 50, DirtyRegionMath.UnionArea(rects, 1000, 1000));
    }

    [Fact]
    public void ClipsToTheFrame()
    {
        Assert.Equal(50 * 50, DirtyRegionMath.UnionArea([new PixelRect(-50, -50, 100, 100)], 1000, 1000));
        Assert.Equal(0, DirtyRegionMath.UnionArea([new PixelRect(2000, 0, 10, 10)], 1000, 1000));
    }

    [Fact]
    public void WholeFrameIsOne()
    {
        PixelRect[] rects = [new(0, 0, 1920, 540), new(0, 540, 1920, 540), new(10, 10, 20, 20)];
        Assert.Equal(1.0, DirtyRegionMath.Ratio(rects, 1920, 1080), 12);
    }

    [Fact]
    public void DisjointStripsAddUp()
    {
        PixelRect[] rects = [new(0, 0, 10, 1000), new(20, 0, 10, 1000), new(0, 0, 1000, 10)];
        Assert.Equal(10 * 1000 + 10 * 1000 + (1000 - 20) * 10, DirtyRegionMath.UnionArea(rects, 1000, 1000));
    }
}

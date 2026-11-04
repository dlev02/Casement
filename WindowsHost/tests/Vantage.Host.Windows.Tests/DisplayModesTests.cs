using Vantage.Host.Windows.Capture;

namespace Vantage.Host.Windows.Tests;

public class DisplayModesTests
{
    /// <summary>A 4K monitor's modes at 60 Hz (no 3440×1440: that's an ultrawide's).</summary>
    private static readonly DisplayMode[] s_fourK =
    [
        new(3840, 2160, 60), new(2560, 1600, 60), new(2560, 1440, 60), new(1920, 1200, 60), new(1920, 1080, 60),
        new(1680, 1050, 60), new(1600, 900, 60), new(1280, 1024, 60), new(1280, 800, 60), new(1280, 720, 60), new(1024, 768, 60),
    ];

    private static readonly DisplayMode s_native = new(3840, 2160, 60);

    [Theory]
    // 13" iPad Pro landscape: 4:3 wants 2752×2064; 2560×1600 (16:10) is the closest shape with room for 1376×1032 points at 150%.
    [InlineData(1376, 1032, 2, 1.5, 2560, 1600)]
    // 11" iPad Pro landscape (1.45): the same.
    [InlineData(1210, 834, 2, 1.5, 2560, 1600)]
    // The same iPads at 100%: 1920×1200 has room too, but 2560×1600 is nearer the iPad's own pixels.
    [InlineData(1376, 1032, 2, 1.0, 2560, 1600)]
    [InlineData(1210, 834, 2, 1.0, 2560, 1600)]
    // iPad portrait: no landscape mode covers more of it than 16:9 does by enough to be worth it.
    [InlineData(1032, 1376, 2, 1.5, 3840, 2160)]
    // iPhone 16 Pro landscape (2.17): every candidate is 16:9 or squarer, so the current mode stays.
    [InlineData(874, 402, 3, 1.5, 3840, 2160)]
    // iPhone portrait: nothing gains 5%.
    [InlineData(402, 874, 3, 1.5, 3840, 2160)]
    // Vision Pro's default 16:9 window: already the monitor's shape.
    [InlineData(1280, 720, 2, 1.5, 3840, 2160)]
    // A 4:3 Vision Pro window: 16:10.
    [InlineData(1024, 768, 2, 1.5, 2560, 1600)]
    // A 16:10 Mac window, 1440×900 points at 2x: exactly 2560×1600's shape.
    [InlineData(1440, 900, 2, 1.5, 2560, 1600)]
    // A Mac window just too big for 2560×1600 at 150% (2592 px across): only 4K has room.
    [InlineData(1728, 1117, 2, 1.5, 3840, 2160)]
    // A 16:9 Mac window within 1% of the monitor: no switch.
    [InlineData(1920, 1081, 2, 1.5, 3840, 2160)]
    // A small 4:3 window at 1x, 100%: never below 1280×720, so 1024×768 is out; 1280×1024 is the nearest shape.
    [InlineData(800, 600, 1, 1.0, 1280, 1024)]
    public void ChoosesTheModeThatFitsTheViewport(double width, double height, double deviceScale, double displayScale, int wantWidth, int wantHeight)
    {
        var chosen = DisplayModes.Choose(s_fourK, s_native, width, height, deviceScale, displayScale);
        Assert.Equal((wantWidth, wantHeight), (chosen.Width, chosen.Height));
    }

    [Fact]
    public void NeverLargerThanTheNativeModeAndKeepsTheCurrentOneWhenNothingFits()
    {
        // A 1080p monitor: nothing has room for a 13" iPad at 150%, so its mode stays.
        DisplayMode[] fullHd = [new(1920, 1080, 60), new(1680, 1050, 60), new(1280, 1024, 60), new(1280, 720, 60)];
        Assert.Equal(fullHd[0], DisplayModes.Choose(fullHd, fullHd[0], 1376, 1032, 2, 1.5));
        // At 100% it does: 1680×1050, the 16:10 one.
        Assert.Equal(fullHd[1], DisplayModes.Choose(fullHd, fullHd[0], 1376, 1032, 2, 1.0));
        // A user running below native: still bounded by the panel's largest mode, never above it.
        var chosen = DisplayModes.Choose(s_fourK, new DisplayMode(1920, 1080, 60), 1376, 1032, 2, 1.0);
        Assert.Equal((2560, 1600), (chosen.Width, chosen.Height));
        // Nonsense in, current mode out.
        Assert.Equal(s_native, DisplayModes.Choose(s_fourK, s_native, 0, 1032, 2, 1.5));
        Assert.Equal(s_native, DisplayModes.Choose([], s_native, 1376, 1032, 2, 1.5));
    }

    [Fact]
    public void ModesAreThirtyTwoBitProgressiveOnePerSizeAtTheCurrentRefreshRate()
    {
        var current = new DisplayMode(3840, 2160, 60);
        RawDisplayMode[] raw =
        [
            new(3840, 2160, 32, 60), new(3840, 2160, 32, 144), new(3840, 2160, 32, 30),
            new(2560, 1600, 32, 120), new(2560, 1600, 32, 144), // no 60 Hz: the highest
            new(1920, 1080, 16, 60), new(1920, 1080, 32, 60, Interlaced: true), new(1920, 1080, 32, 59),
            new(1280, 720, 8, 60),
        ];
        var modes = DisplayModes.Distinct(raw, current);
        Assert.Equal(new DisplayMode[] { new(3840, 2160, 60), new(2560, 1600, 144), new(1920, 1080, 59) }, modes);
    }

    [Fact]
    public void CoverageIsTheFractionOfTheViewportFilled()
    {
        Assert.Equal(1, DisplayModes.Coverage(16 / 9.0, 16 / 9.0), 6);
        Assert.Equal(0.75, DisplayModes.Coverage(16 / 9.0, 4 / 3.0), 6);
        Assert.Equal(0.75, DisplayModes.Coverage(4 / 3.0, 16 / 9.0), 6);
        Assert.Equal(0, DisplayModes.Coverage(0, 1));
    }
}

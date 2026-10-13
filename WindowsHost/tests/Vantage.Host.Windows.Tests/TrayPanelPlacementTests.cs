using Vantage.Host.Windows.Tray;

namespace Vantage.Host.Windows.Tests;

public class TrayPanelPlacementTests
{
    // A 3024 × 1898 screen at 200% with a 96 px taskbar along the bottom.
    private static readonly ScreenRect BottomWork = new(0, 0, 3024, 1802);

    [Fact]
    public void BottomTaskbarPutsThePanelAboveItCentredOnTheIcon()
    {
        var icon = new ScreenRect(2000, 1820, 2048, 1868);
        Assert.Equal((2024 - 340, 1802 - 24 - 900), TrayPanelPlacement.Place(icon, BottomWork, 680, 900, 24));
    }

    [Fact]
    public void AnIconNearTheCornerKeepsThePanelOnScreen()
    {
        var icon = new ScreenRect(2950, 1820, 2998, 1868);
        Assert.Equal((3024 - 24 - 680, 1802 - 24 - 900), TrayPanelPlacement.Place(icon, BottomWork, 680, 900, 24));
    }

    [Fact]
    public void TopTaskbarPutsThePanelBelowIt()
    {
        var work = new ScreenRect(0, 96, 3024, 1898);
        var icon = new ScreenRect(2000, 24, 2048, 72);
        Assert.Equal((2024 - 340, 96 + 24), TrayPanelPlacement.Place(icon, work, 680, 900, 24));
    }

    [Fact]
    public void SideTaskbarsPutThePanelBesideThem()
    {
        // Centred on the icon's height, then held a margin above the bottom of the screen.
        var right = new ScreenRect(0, 0, 2928, 1898);
        Assert.Equal((2928 - 24 - 680, 1898 - 24 - 900),
                     TrayPanelPlacement.Place(new ScreenRect(2950, 1700, 2998, 1748), right, 680, 900, 24));
        var left = new ScreenRect(96, 0, 3024, 1898);
        Assert.Equal((96 + 24, 1898 - 24 - 900),
                     TrayPanelPlacement.Place(new ScreenRect(24, 1700, 72, 1748), left, 680, 900, 24));
        Assert.Equal((96 + 24, 724 - 450),
                     TrayPanelPlacement.Place(new ScreenRect(24, 700, 72, 748), left, 680, 900, 24));
    }

    [Fact]
    public void AnIconInsideTheWorkAreaGetsThePanelAboveIt()
    {
        // The overflow flyout sits above the taskbar, inside the work area.
        var icon = new ScreenRect(2600, 1600, 2648, 1648);
        Assert.Equal((2624 - 340, 1600 - 24 - 900), TrayPanelPlacement.Place(icon, BottomWork, 680, 900, 24));
        // Too close to the top for that: below it instead.
        var high = new ScreenRect(1000, 300, 1048, 348);
        Assert.Equal((1024 - 340, 348 + 24), TrayPanelPlacement.Place(high, BottomWork, 680, 900, 24));
    }

    [Fact]
    public void APanelTallerThanTheScreenStartsAtTheTop()
    {
        var icon = new ScreenRect(2000, 1820, 2048, 1868);
        Assert.Equal(24, TrayPanelPlacement.Place(icon, BottomWork, 680, 4000, 24).Y);
    }
}

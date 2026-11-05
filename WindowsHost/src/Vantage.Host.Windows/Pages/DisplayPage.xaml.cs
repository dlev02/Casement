using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Vantage.Host.Windows.Capture;

namespace Vantage.Host.Windows.App.Pages;

/// <summary>The display being shared (the primary one), whether devices may change its mode, and, under Advanced, how it's captured and encoded.</summary>
public sealed partial class DisplayPage : Page
{
    private AppController? _controller;
    private bool _updating;

    /// <summary>Creates the page.</summary>
    public DisplayPage()
    {
        InitializeComponent();
        Loaded += async (_, _) => await UpdateAsync();
    }

    /// <inheritdoc />
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _controller = e.Parameter as AppController;
        base.OnNavigatedTo(e);
    }

    private async Task UpdateAsync()
    {
        if (_controller?.Runtime is not { } runtime) return;
        _updating = true;
        FitSwitch.IsOn = runtime.Settings.Current.AllowDisplayFitting;
        FitSwitch.IsEnabled = runtime.DisplayFitter is not null; // synthetic runs never change modes
        _updating = false;
        var displays = await runtime.Environment.Screen.GetDisplaysAsync(CancellationToken.None);
        var main = displays.FirstOrDefault(d => d.IsMain) ?? displays.FirstOrDefault();
        if (main is null)
        {
            SharedCard.Header = "No display is active";
            SharedCard.Description = "The monitor may be asleep or switched off.";
            DeviceSizeCard.Visibility = Visibility.Collapsed;
        }
        else
        {
            SharedCard.Header = $"Sharing {main.Name}";
            SharedCard.Description = string.Create(CultureInfo.CurrentCulture,
                $"{main.PixelWidth} × {main.PixelHeight} at {main.Scale * 100:0}% scale, {main.RefreshRate:0} Hz");
            DeviceSizeCard.Description = string.Create(CultureInfo.CurrentCulture, $"{main.PointWidth} × {main.PointHeight} points");
            DeviceSizeCard.Visibility = Visibility.Visible;
        }
        CaptureCard.Description = "Windows Graphics Capture";
        ChangeCard.Description = runtime.Screen.DirtyRegions switch
        {
            DirtyRegionSource.Native => "Windows reports which parts of the screen changed, so a still screen costs almost nothing.",
            DirtyRegionSource.Compare => "The graphics card compares each frame with the last, so a still screen costs almost nothing.",
            _ => "Every frame counts as changed, so a still screen streams at the full frame rate.",
        };
        EncoderCard.Description = runtime.Encoders.CurrentEncoderName ?? "Chosen when a device first connects: the graphics card's HEVC or H.264 encoder when it has one.";
    }

    private void OnFitToggled(object sender, RoutedEventArgs e)
    {
        if (_updating) return;
        var on = FitSwitch.IsOn;
        _controller?.Runtime?.Settings.Update(s => s with { AllowDisplayFitting = on });
    }
}

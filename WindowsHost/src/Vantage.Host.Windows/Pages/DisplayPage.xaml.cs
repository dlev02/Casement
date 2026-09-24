using System.Globalization;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Vantage.Host.Windows.App.Pages;

/// <summary>The display being shared (the primary one) and the encoder in use.</summary>
public sealed partial class DisplayPage : Page
{
    private AppController? _controller;

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
        var displays = await runtime.Environment.Screen.GetDisplaysAsync(CancellationToken.None);
        var main = displays.FirstOrDefault(d => d.IsMain) ?? displays.FirstOrDefault();
        if (main is null)
        {
            DisplayName.Text = "No display is active";
            DisplayDetail.Text = "The monitor may be asleep or switched off.";
        }
        else
        {
            DisplayName.Text = main.Name;
            DisplayDetail.Text = string.Create(CultureInfo.CurrentCulture,
                $"{main.PixelWidth} × {main.PixelHeight} pixels at {main.Scale * 100:0}% scale ({main.PointWidth} × {main.PointHeight} on the iPad), {main.RefreshRate:0} Hz");
        }
        EncoderText.Text = runtime.Encoders.CurrentEncoderName ?? "Chosen when an iPad first connects (the graphics card's H.264 encoder when it has one).";
    }
}

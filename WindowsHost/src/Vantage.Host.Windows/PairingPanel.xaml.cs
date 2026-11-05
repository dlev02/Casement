using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Vantage.Host.Windows.App;

/// <summary>
/// The pairing code as the tray panel and Settings › Devices show it: the digits, how long they
/// last, Copy, New code and Done, and the name to add this PC by. A code that runs out is withdrawn,
/// so nowhere ever shows a dead one.
/// </summary>
public sealed partial class PairingPanel : UserControl
{
    private readonly DispatcherTimer _countdown = new() { Interval = TimeSpan.FromSeconds(1) };
    private AppController? _controller;

    /// <summary>Creates the panel; <see cref="Attach"/> gives it the app.</summary>
    public PairingPanel()
    {
        InitializeComponent();
        _countdown.Tick += (_, _) => Update();
        Loaded += (_, _) => _countdown.Start();
        Unloaded += (_, _) => _countdown.Stop();
    }

    /// <summary>Connects the panel to the app and shows the current code.</summary>
    public void Attach(AppController controller)
    {
        _controller = controller;
        Update();
    }

    /// <summary>Moves keyboard focus here when the button that asked for a code has just gone away.</summary>
    public void FocusCopy() => CopyButton.Focus(FocusState.Programmatic);

    /// <summary>Shows what the app says now.</summary>
    public void Update()
    {
        if (_controller?.PairingCode is not { } code) return;
        CodeText.Text = code.Length == 6 ? $"{code[..3]} {code[3..]}" : code;
        // Digit by digit: a name replaces the text for a screen reader, and "718 577" reads as numbers.
        AutomationProperties.SetName(CodeText, $"Pairing code: {string.Join(' ', code.ToCharArray())}");
        if (_controller.PairingCodeExpires is { } expires)
        {
            var left = expires - DateTimeOffset.Now;
            if (left <= TimeSpan.Zero)
            {
                _controller.CancelPairingCode();
                return;
            }
            ExpiryText.Text = $"{UiHelpers.ExpiryText(left)} · Works once";
        }
        else
        {
            ExpiryText.Text = "A test code that doesn't expire";
        }

        var address = _controller.Tailnet is { IsRunning: true } self ? self.DnsName ?? self.PrimaryAddress : null;
        AddressPanel.Visibility = address is null ? Visibility.Collapsed : Visibility.Visible;
        AddressText.Text = address ?? "";
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (_controller?.PairingCode is { } code) UiHelpers.Copy(code, CopyButton);
    }

    private void OnNewCode(object sender, RoutedEventArgs e)
    {
        _controller?.ShowPairingCode(openWindow: false);
        Update();
    }

    private void OnDone(object sender, RoutedEventArgs e) => _controller?.CancelPairingCode();

    private void OnCopyAddress(object sender, RoutedEventArgs e)
    {
        if (AddressText.Text.Length > 0) UiHelpers.Copy(AddressText.Text, CopyAddressButton);
    }
}

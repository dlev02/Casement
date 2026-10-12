using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Vantage.Host.Windows.Startup;
using DataPackage = global::Windows.ApplicationModel.DataTransfer.DataPackage;
using WindowsClipboard = global::Windows.ApplicationModel.DataTransfer.Clipboard;

namespace Vantage.Host.Windows.App.Pages;

/// <summary>Status, tailnet address, the pairing code, and start at login.</summary>
public sealed partial class GeneralPage : Page
{
    private AppController? _controller;
    private DispatcherTimer? _countdown;
    private bool _updating;

    /// <summary>Creates the page.</summary>
    public GeneralPage()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            if (_controller is not null) _controller.StateChanged += Update;
            _countdown = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            _countdown.Tick += (_, _) => UpdateCode();
            _countdown.Start();
            Update();
        };
        Unloaded += (_, _) =>
        {
            if (_controller is not null) _controller.StateChanged -= Update;
            _countdown?.Stop();
        };
    }

    /// <inheritdoc />
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _controller = e.Parameter as AppController;
        base.OnNavigatedTo(e);
    }

    private void Update()
    {
        if (_controller is null) return;
        _updating = true;
        var runtime = _controller.Runtime;
        var port = runtime?.ListenerOptions.Port ?? Protocol.VantageProtocol.DefaultPort;
        StatusText.Text = _controller.Problem
            ?? (_controller.IsListening ? $"Ready: iPads can connect to {runtime?.Environment.HostName} on port {port}" : "Starting…");
        StatusIcon.Glyph = _controller.Problem is null ? "" : "";

        var screens = _controller.Sessions.Where(s => !s.IsFilesOnly).ToList();
        ConnectedText.Text = screens.Count switch
        {
            0 => "No iPad is connected.",
            1 => $"{screens[0].ClientName} is connected.",
            _ => $"{string.Join(", ", screens.Select(s => s.ClientName))} are connected.",
        };

        var tailnet = _controller.Tailnet;
        if (tailnet is { IsRunning: true, PrimaryAddress: { } address })
        {
            AddressText.Text = tailnet.DnsName is { } dns ? $"{address}  ·  {dns}" : address;
            AddressHint.Text = "Use this address when you add the PC in Casement.";
        }
        else if (tailnet is not null)
        {
            AddressText.Text = $"Tailscale is {tailnet.BackendState.ToLowerInvariant()}";
            AddressHint.Text = "Casement only accepts connections over Tailscale. Open Tailscale and sign in.";
        }
        else
        {
            AddressText.Text = "Tailscale wasn't found";
            AddressHint.Text = "Install Tailscale on this PC and sign in with the same account as your iPad.";
        }

        ShowCodeButton.IsEnabled = _controller.IsListening;
        StartAtLoginSwitch.IsOn = StartAtLogin.IsEnabled(AppController.ExecutablePath);
        UpdateCode();
        _updating = false;
    }

    private void UpdateCode()
    {
        var code = _controller?.PairingCode;
        if (code is null)
        {
            CodePanel.Visibility = Visibility.Collapsed;
            ShowCodeButton.Visibility = Visibility.Visible;
            return;
        }
        CodeText.Text = code.Length == 6 ? $"{code[..3]} {code[3..]}" : code;
        if (_controller!.PairingCodeExpires is { } expires)
        {
            var left = expires - DateTimeOffset.Now;
            CodeExpiry.Text = left > TimeSpan.Zero
                ? string.Create(CultureInfo.CurrentCulture, $"Works for {Math.Ceiling(left.TotalMinutes):0} more minute{(left.TotalMinutes > 1 ? "s" : "")}, once.")
                : "This code has expired.";
        }
        else
        {
            CodeExpiry.Text = "A test code that doesn't expire.";
        }
        CodePanel.Visibility = Visibility.Visible;
        ShowCodeButton.Visibility = Visibility.Collapsed;
    }

    private void OnShowCode(object sender, RoutedEventArgs e) => _controller?.ShowPairingCode();

    private void OnNewCode(object sender, RoutedEventArgs e) => _controller?.ShowPairingCode();

    private void OnCopyCode(object sender, RoutedEventArgs e)
    {
        if (_controller?.PairingCode is not { } code) return;
        var package = new DataPackage();
        package.SetText(code);
        WindowsClipboard.SetContent(package);
    }

    private void OnStartAtLoginToggled(object sender, RoutedEventArgs e)
    {
        if (_updating) return;
        try
        {
            StartAtLogin.SetEnabled(AppController.ExecutablePath, StartAtLoginSwitch.IsOn);
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            StartAtLoginSwitch.IsOn = !StartAtLoginSwitch.IsOn;
        }
    }
}

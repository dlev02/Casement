using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Vantage.Host.Windows.Startup;
using Vantage.Host.Windows.Tray;

namespace Vantage.Host.Windows.App.Pages;

/// <summary>The host's status, its Tailscale address, start at login and the tray icon, and what happens while a device is connected.</summary>
public sealed partial class GeneralPage : Page
{
    private AppController? _controller;
    private bool _updating;
    private bool _adminBusy;

    /// <summary>Creates the page.</summary>
    public GeneralPage()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            if (_controller is not null) _controller.StateChanged += Update;
            Update();
        };
        Unloaded += (_, _) =>
        {
            if (_controller is not null) _controller.StateChanged -= Update;
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

        // Visibility too: a closed InfoBar still takes the StackPanel's spacing.
        ProblemBar.IsOpen = _controller.Problem is not null;
        ProblemBar.Visibility = _controller.Problem is null ? Visibility.Collapsed : Visibility.Visible;
        ProblemBar.Message = _controller.Problem ?? "";
        StatusCard.Visibility = _controller.Problem is null ? Visibility.Visible : Visibility.Collapsed;

        var hostName = _controller.Runtime?.Environment.HostName;
        var screens = _controller.Sessions.Where(s => !s.IsFilesOnly).ToList();
        StatusCard.Header = screens.Count switch
        {
            _ when !_controller.IsListening => "Starting…",
            0 => "Ready to connect",
            1 => $"Connected to {screens[0].ClientName}",
            _ => $"{screens.Count} devices connected",
        };
        StatusCard.Description = _controller.IsListening ? $"Your devices can connect to {hostName}." : "";
        StatusIcon.Glyph = _controller.IsListening ? "" : ""; // CompletedSolid, Stopwatch
        StatusIcon.Foreground = UiHelpers.StatusBrush(_controller.Status);
        PairButton.Visibility = _controller.IsListening && _controller.PairedDevices.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        UpdateAddress();

        StartAtLoginSwitch.IsOn = StartAtLogin.IsEnabled(AppController.ExecutablePath);
        var iconShown = TrayIconVisibility.Shown(AppController.ExecutablePath);
        TrayIconSwitch.IsEnabled = iconShown is not null;
        TrayIconSwitch.IsOn = iconShown == true;
        TrayIconCard.Description = iconShown is null
            ? "Windows lists the icon once it has appeared. Until then, find it behind the ^ next to the clock."
            : "Otherwise Windows keeps it behind the ^ next to the clock.";
        var asks = _controller.AsksBeforeRestart;
        RestartGuardSwitch.IsEnabled = asks is not null;
        RestartGuardSwitch.IsOn = asks ?? false;
        if (!_adminBusy)
        {
            AdminSwitch.IsOn = _controller.ControlsAdminApps;
            AdminSwitch.IsEnabled = _controller.Runtime is not null;
        }
        _updating = false;
    }

    private void UpdateAddress()
    {
        var port = _controller?.Runtime?.ListenerOptions.Port ?? Protocol.VantageProtocol.DefaultPort;
        var tailnet = _controller?.Tailnet;
        if (tailnet is { IsRunning: true, PrimaryAddress: { } address })
        {
            AddressText.Text = tailnet.DnsName is { } dns ? $"{dns} · {address} · port {port}" : $"{address} · port {port}";
            CopyAddressButton.Visibility = Visibility.Visible;
        }
        else
        {
            AddressText.Text = tailnet is not null
                ? $"Tailscale is {tailnet.BackendState.ToLowerInvariant()}. Casement only connects over Tailscale, so open it and sign in."
                : "Tailscale wasn't found. Install it on this PC and sign in with the same account as your devices.";
            CopyAddressButton.Visibility = Visibility.Collapsed;
        }
    }

    private void OnPair(object sender, RoutedEventArgs e) => _controller?.ShowPairingCode();

    private void OnCopyAddress(object sender, RoutedEventArgs e)
    {
        if (_controller?.Tailnet is { } tailnet && (tailnet.DnsName ?? tailnet.PrimaryAddress) is { } address)
            UiHelpers.Copy(address, CopyAddressButton);
    }

    private void OnStartAtLoginToggled(object sender, RoutedEventArgs e)
    {
        if (_updating) return;
        try
        {
            StartAtLogin.SetEnabled(AppController.ExecutablePath, StartAtLoginSwitch.IsOn);
            _controller?.Runtime?.Settings.Update(s => s with { StartAtLoginSettled = true });
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            _updating = true;
            StartAtLoginSwitch.IsOn = !StartAtLoginSwitch.IsOn;
            _updating = false;
            StartAtLoginCard.Description = $"Windows wouldn't change the startup entry: {ex.Message}";
        }
    }

    private void OnTrayIconToggled(object sender, RoutedEventArgs e)
    {
        if (_updating) return;
        if (TrayIconVisibility.SetShown(AppController.ExecutablePath, TrayIconSwitch.IsOn)) return;
        _updating = true;
        TrayIconSwitch.IsOn = !TrayIconSwitch.IsOn;
        _updating = false;
        TrayIconCard.Description = "Windows wouldn't change it here. Drag the icon onto the taskbar, or choose it under Settings › Personalization › Taskbar › Other system tray icons.";
    }

    private void OnRestartGuardToggled(object sender, RoutedEventArgs e)
    {
        if (_updating) return;
        _controller?.SetAsksBeforeRestart(RestartGuardSwitch.IsOn);
    }

    private async void OnAdminToggled(object sender, RoutedEventArgs e)
    {
        if (_updating || _controller is null) return;
        var on = AdminSwitch.IsOn;
        _adminBusy = true;
        AdminSwitch.IsEnabled = false;
        try
        {
            if (!await _controller.SetControlsAdminAppsAsync(on))
            {
                _updating = true;
                AdminSwitch.IsOn = !on;
                _updating = false;
            }
        }
        finally
        {
            _adminBusy = false;
            AdminSwitch.IsEnabled = true;
        }
    }
}

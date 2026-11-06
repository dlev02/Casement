using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Animation;
using Vantage.Host.Windows.Tray;
using Windows.Foundation;
using Windows.Graphics;
using WinRT.Interop;

namespace Vantage.Host.Windows.App;

/// <summary>
/// What a left click on the tray icon opens, like the Mac host's menu-bar popover: a small acrylic
/// panel beside the taskbar with the host's state, the pairing code right here, who is connected
/// (Send file, Disconnect), files moving (Cancel, and Show in folder once received), the paired
/// devices a click away, and a footer with Settings and Quit. A borderless, always-on-top window
/// placed by <see cref="TrayPanelPlacement"/> from the icon's rectangle, never taller than the
/// screen (the body scrolls and the footer stays); it hides when it loses focus or on Esc, and a
/// click on the icon while it's open closes it. Right click keeps the native menu.
/// </summary>
public sealed partial class TrayPanel : Window
{
    /// <summary>Width in DIPs.</summary>
    private const double PanelWidth = 360;

    /// <summary>Gap to the taskbar and screen edges in DIPs (Windows 11's flyouts use 12).</summary>
    private const double Margin = 12;

    /// <summary>Rows the panel shows before "N more in Settings": it sits beside the taskbar and mustn't outgrow the screen.</summary>
    private const int MaxTransferRows = 4;

    private readonly AppController _controller;
    private readonly TransferRows _transferRows;
    private ScreenRect _icon;
    private long _hiddenAt;
    private bool _visible;
    private bool _closingForQuit;
    private string? _connectedShown;
    private bool _codeWasShowing;
    private readonly DispatcherTimer _resizeTick = new() { Interval = TimeSpan.FromMilliseconds(16) };
    private RectInt32? _targetBounds;
    private RectInt32 _resizeFrom;
    private long _resizeStarted;

    /// <param name="controller">The app.</param>
    public TrayPanel(AppController controller)
    {
        _controller = controller;
        InitializeComponent();
        _transferRows = new TransferRows(TransferList, controller);
        Pairing.Attach(controller);
        _resizeTick.Tick += (_, _) => AnimateResize();

        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "Vantage.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);

        // Windows 11 rounds borderless windows only when asked.
        var corner = DWMWCP_ROUND;
        DwmSetWindowAttribute(WindowNative.GetWindowHandle(this), DWMWA_WINDOW_CORNER_PREFERENCE, ref corner, sizeof(int));

        Activated += OnActivated;
        // Alt+F4 only hides it; the app closes it for real on Quit.
        AppWindow.Closing += (_, args) =>
        {
            if (_closingForQuit) return;
            args.Cancel = true;
            Dismiss();
        };
        _controller.StateChanged += () =>
        {
            if (!_visible) return;
            Update();
            Fit();
        };
    }

#if DEBUG
    /// <summary><c>--open-panel</c>: stays open without focus, for screenshots.</summary>
    public bool KeepOpen { get; set; }
#endif

    /// <summary>Opens the panel next to the tray icon at <paramref name="icon"/>, or closes it if it's open.</summary>
    public void Toggle(ScreenRect icon)
    {
        // A click on the icon while the panel is open first takes focus away from it (hiding it),
        // then arrives here: that click meant "close".
        if (_visible || Environment.TickCount64 - _hiddenAt < 400)
        {
            Dismiss();
            return;
        }
        _icon = icon;
        Update();
        Fit();
        AppWindow.Show(true);
        Activate();
        SetForegroundWindow(WindowNative.GetWindowHandle(this));
        _visible = true;
        // The first thing there is to do; a Tab from here reaches the rest.
        Control first = FirstPair.Visibility == Visibility.Visible ? ShowCodeButton
                      : ShowCodeRow.IsEnabled && DeviceCommands.Visibility == Visibility.Visible ? ShowCodeRow
                      : SettingsButton;
        first.Focus(FocusState.Programmatic);
    }

    /// <summary>Closes the panel for good (Quit).</summary>
    public void CloseForQuit()
    {
        _closingForQuit = true;
        _resizeTick.Stop();
        Close();
    }

    /// <summary>Hides the panel.</summary>
    public void Dismiss()
    {
        if (!_visible) return;
#if DEBUG
        if (KeepOpen) return;
#endif
        _visible = false;
        _resizeTick.Stop();
        _targetBounds = null;
        _hiddenAt = Environment.TickCount64;
        AppWindow.Hide();
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState != WindowActivationState.Deactivated) return;
        // Changing the focused control and resizing the panel can transiently deactivate WinUI.
        // Dismiss only after that transition, if focus really moved to another window.
        DispatcherQueue.TryEnqueue(() =>
        {
            if (GetForegroundWindow() != WindowNative.GetWindowHandle(this)) Dismiss();
        });
    }

    private void OnEscape(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        Dismiss();
    }

    /// <summary>Sizes the panel to its content, up to the screen's height, and places it beside the icon on the icon's monitor.</summary>
    private void Fit()
    {
        var area = DisplayArea.GetFromPoint(new PointInt32(_icon.Left + _icon.Width / 2, _icon.Top + _icon.Height / 2), DisplayAreaFallback.Nearest);
        var work = area.WorkArea;
        var scale = MonitorScale(work);
        // The window's size includes its border; what's measured here has to be the client area
        // inside it, or text wraps differently from the measure and the last row slips under the footer.
        var borderWidth = AppWindow.Size.Width - AppWindow.ClientSize.Width;
        var borderHeight = AppWindow.Size.Height - AppWindow.ClientSize.Height;
        Body.Measure(new Size(PanelWidth, double.PositiveInfinity));
        Footer.Measure(new Size(PanelWidth, double.PositiveInfinity));
        var margin = (int)Math.Round(Margin * scale);
        var width = (int)Math.Ceiling(PanelWidth * scale) + borderWidth;
        var height = (int)Math.Ceiling((Body.DesiredSize.Height + Footer.DesiredSize.Height) * scale) + borderHeight;
        height = Math.Min(height, work.Height - 2 * margin);
        var (x, y) = TrayPanelPlacement.Place(_icon, new ScreenRect(work.X, work.Y, work.X + work.Width, work.Y + work.Height),
                                              width, height, margin);
        var target = new RectInt32(x, y, width, height);
        if (_targetBounds is { } previous && previous.Equals(target)) return;
        _targetBounds = target;
        _resizeTick.Stop();
        if (!_visible || !new global::Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
        {
            ApplyBounds(target);
            return;
        }
        _resizeFrom = new RectInt32(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
        _resizeStarted = Environment.TickCount64;
        _resizeTick.Start();
    }

    private void AnimateResize()
    {
        if (_targetBounds is not { } target) { _resizeTick.Stop(); return; }
        var progress = Math.Clamp((Environment.TickCount64 - _resizeStarted) / 180.0, 0, 1);
        var eased = 1 - Math.Pow(1 - progress, 3);
        int Blend(int from, int to) => (int)Math.Round(from + (to - from) * eased);
        ApplyBounds(new RectInt32(Blend(_resizeFrom.X, target.X), Blend(_resizeFrom.Y, target.Y),
            Blend(_resizeFrom.Width, target.Width), Blend(_resizeFrom.Height, target.Height)));
        if (progress >= 1) _resizeTick.Stop();
    }

    private void ApplyBounds(RectInt32 bounds)
    {
        // Keep focus and Z order unchanged throughout the resize.
        SetWindowPos(WindowNative.GetWindowHandle(this), 0, bounds.X, bounds.Y, bounds.Width, bounds.Height, 0x0010 | 0x0004);
    }

    private void Update()
    {
        var hostName = _controller.Runtime?.Environment.HostName;
        var screens = _controller.Sessions.Where(s => !s.IsFilesOnly).ToList();
        // Files moving say so here, as the tooltip does ("Receiving Report.pdf, 45%").
        var moving = _controller.Problem is null ? _controller.Transfers.Summary : null;
        StatusText.Text = _controller.Problem
            ?? moving
            ?? screens.Count switch
            {
                _ when !_controller.IsListening => "Starting…",
                0 => $"Ready on {hostName}",
                1 => $"Connected to {screens[0].ClientName}",
                _ => $"{screens.Count} devices connected",
            };
        StatusDot.Fill = UiHelpers.StatusBrush(_controller.Status);
        UpdateTransfers();

        var paired = _controller.PairedDevices;
        var showingCode = _controller.PairingCode is not null;
        Pairing.Visibility = showingCode ? Visibility.Visible : Visibility.Collapsed;
        if (showingCode) Pairing.Update();
        FirstPair.Visibility = !showingCode && paired.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowCodeButton.IsEnabled = _controller.IsListening;
        ShowCodeRow.IsEnabled = _controller.IsListening;
        ShowCodeRow.Visibility = showingCode ? Visibility.Collapsed : Visibility.Visible;
        DeviceCommands.Visibility = paired.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        // The button that was focused has just gone: hand focus on, so Tab and Esc keep working.
        if (_visible && showingCode != _codeWasShowing)
        {
            BodyScroller.ChangeView(null, 0, null, true);
            if (showingCode) Pairing.FocusCopy();
            else if (paired.Count > 0) ShowCodeRow.Focus(FocusState.Programmatic);
            else ShowCodeButton.Focus(FocusState.Programmatic);
            if (new global::Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
            {
                var reveal = new DoubleAnimation
                {
                    From = 0.65, To = 1, Duration = new Duration(TimeSpan.FromMilliseconds(160)),
                    EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
                };
                Storyboard.SetTarget(reveal, showingCode ? Pairing : paired.Count > 0 ? ShowCodeRow : FirstPair);
                Storyboard.SetTargetProperty(reveal, "Opacity");
                var storyboard = new Storyboard();
                storyboard.Children.Add(reveal);
                storyboard.Begin();
            }
        }
        _codeWasShowing = showingCode;
        var update = _controller.Updater?.Status;
        UpdateRow.Visibility = update?.Stage == Updates.UpdateStage.Ready ? Visibility.Visible : Visibility.Collapsed;
        UpdateRowText.Text = $"Restart to update to {update?.Version}";
        PairedCount.Text = paired.Count.ToString(System.Globalization.CultureInfo.CurrentCulture);
        AutomationProperties.SetName(PairedRow, paired.Count == 1 ? "1 paired device. Open in Settings" : $"{paired.Count} paired devices. Open in Settings");

        UpdateConnected();
    }

    /// <summary>
    /// The connected rows, rebuilt only when they change: this runs several times a second while
    /// files move, and a new row would take keyboard focus away from its button.
    /// </summary>
    private void UpdateConnected()
    {
        var sessions = _controller.Sessions;
        var channels = _controller.FileChannels;
        var shown = string.Join('\n', sessions.Select(s => $"{s.Id}|{s.ClientName}|{SessionDetail(s)}")
                                              .Concat(channels.Select(c => $"{c.Id}|{c.SessionId}|{c.ClientName}")));
        if (shown == _connectedShown) return;
        _connectedShown = shown;

        ConnectedList.Children.Clear();
        foreach (var session in sessions)
        {
            var channel = channels.FirstOrDefault(c => c.SessionId == session.Id);
            ConnectedList.Children.Add(DeviceRow(session.ClientName, SessionDetail(session), channel?.Id, session.Id));
        }
        // A file channel outlives its session (files keep moving after the screen disconnects).
        foreach (var channel in channels.Where(c => sessions.All(s => s.Id != c.SessionId)))
            ConnectedList.Children.Add(DeviceRow(channel.ClientName, "Moving files", channel.Id, sessionId: null));
        ConnectedSection.Visibility = ConnectedList.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static string SessionDetail(Vantage.Protocol.Host.SessionSnapshot session) =>
        session.IsFilesOnly ? "Moving files" : session.Display is { } display ? $"Viewing {display.Name}" : "Connected";

    /// <summary>The newest files (the Files page lists them all); the section hides when there are none.</summary>
    private void UpdateTransfers()
    {
        var all = _controller.Transfers.Items;
        var shown = all.Skip(Math.Max(0, all.Count - MaxTransferRows)).ToList();
        _transferRows.Sync(shown);
        TransfersSection.Visibility = all.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        var more = all.Count - shown.Count;
        MoreTransfers.Visibility = more > 0 ? Visibility.Visible : Visibility.Collapsed;
        MoreTransfers.Content = more == 1 ? "1 more in Settings" : $"{more} more in Settings";
    }

    private void OnMoreTransfers(object sender, RoutedEventArgs e)
    {
        Dismiss();
        _controller.ShowWindow("files");
    }

    private void OnPairedDevices(object sender, RoutedEventArgs e)
    {
        Dismiss();
        _controller.ShowWindow("devices");
    }

    private Grid DeviceRow(string name, string detail, Guid? channelId, Guid? sessionId)
    {
        var grid = new Grid { ColumnSpacing = 12 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var glyph = UiHelpers.Glyph(UiHelpers.DeviceGlyph(name));
        glyph.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(glyph);

        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = name, TextTrimming = TextTrimming.CharacterEllipsis });
        ToolTipService.SetToolTip(text, name); // the row may have had to shorten it
        text.Children.Add(new TextBlock
        {
            Text = detail,
            Style = UiHelpers.Resource<Style>("CaptionTextBlockStyle"),
            Foreground = UiHelpers.Resource<Microsoft.UI.Xaml.Media.Brush>("TextFillColorSecondaryBrush"),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        if (channelId is { } channel)
        {
            var send = new Button
            {
                Content = UiHelpers.Glyph("", 14), // Upload
                Padding = new Thickness(8),
                Style = UiHelpers.Resource<Style>("PanelButtonStyle"),
            };
            var label = $"Send a file to {name}";
            AutomationProperties.SetName(send, label);
            ToolTipService.SetToolTip(send, label);
            send.Click += (_, _) =>
            {
                Dismiss();
                _ = _controller.SendFilesAsync(channel);
            };
            actions.Children.Add(send);
        }
        if (sessionId is { } session)
        {
            var disconnect = new Button { Content = "Disconnect" };
            AutomationProperties.SetName(disconnect, $"Disconnect {name}");
            disconnect.Click += async (_, _) =>
            {
                disconnect.IsEnabled = false;
                await _controller.DisconnectAsync(session);
            };
            actions.Children.Add(disconnect);
        }
        Grid.SetColumn(actions, 2);
        grid.Children.Add(actions);
        return grid;
    }

    /// <summary>With nobody connected it just restarts; otherwise Settings asks first, since a dialog doesn't fit here.</summary>
    private async void OnUpdateRow(object sender, RoutedEventArgs e)
    {
        Dismiss();
        if (_controller.Sessions.Count == 0 && !_controller.Transfers.Items.Any(t => t.IsActive)) await _controller.InstallUpdateNowAsync();
        else _controller.ShowWindow("general");
    }

    private void OnShowCode(object sender, RoutedEventArgs e)
    {
        _controller.ShowPairingCode(openWindow: false);
    }

    private void OnSettings(object sender, RoutedEventArgs e)
    {
        Dismiss();
        _controller.ShowWindow();
    }

    private async void OnQuit(object sender, RoutedEventArgs e)
    {
        Dismiss();
        await _controller.QuitAsync();
    }

    private static double MonitorScale(RectInt32 work)
    {
        var monitor = MonitorFromPoint(new NativePoint { X = work.X + work.Width / 2, Y = work.Y + work.Height / 2 }, MONITOR_DEFAULTTONEAREST);
        return GetDpiForMonitor(monitor, 0 /* MDT_EFFECTIVE_DPI */, out var dpi, out _) == 0 && dpi > 0 ? dpi / 96.0 : 1.0;
    }

    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWCP_ROUND = 2;
    private const uint MONITOR_DEFAULTTONEAREST = 2;

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X;
        public int Y;
    }

    [DllImport("dwmapi.dll", ExactSpelling = true)]
    private static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern bool SetForegroundWindow(nint hwnd);

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern nint GetForegroundWindow();

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern bool SetWindowPos(nint hwnd, nint insertAfter, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern nint MonitorFromPoint(NativePoint point, uint flags);

    [DllImport("shcore.dll", ExactSpelling = true)]
    private static extern int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);
}

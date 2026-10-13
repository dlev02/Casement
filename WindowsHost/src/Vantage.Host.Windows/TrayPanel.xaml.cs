using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Vantage.Host.Windows.Tray;
using Windows.Foundation;
using Windows.Graphics;
using WinRT.Interop;
using DataPackage = global::Windows.ApplicationModel.DataTransfer.DataPackage;
using WindowsClipboard = global::Windows.ApplicationModel.DataTransfer.Clipboard;

namespace Vantage.Host.Windows.App;

/// <summary>
/// What a left click on the tray icon opens, like the Mac host's menu-bar popover: a small acrylic
/// panel beside the taskbar with the listener's state, Show Pairing Code (the code shows right here),
/// connected and paired devices, Settings… and Quit. A borderless, always-on-top window placed by
/// <see cref="TrayPanelPlacement"/> from the icon's rectangle; it hides when it loses focus or on Esc,
/// and a click on the icon while it's open closes it. Right click keeps the native menu.
/// </summary>
public sealed partial class TrayPanel : Window
{
    /// <summary>Width in DIPs.</summary>
    private const double PanelWidth = 340;

    /// <summary>Gap to the taskbar and screen edges in DIPs (Windows 11's flyouts use 12).</summary>
    private const double Margin = 12;

    private readonly AppController _controller;
    private readonly DispatcherTimer _countdown = new() { Interval = TimeSpan.FromSeconds(1) };
    private ScreenRect _icon;
    private long _hiddenAt;
    private bool _visible;
    private bool _closingForQuit;

    /// <param name="controller">The app.</param>
    public TrayPanel(AppController controller)
    {
        _controller = controller;
        InitializeComponent();

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
        _countdown.Tick += (_, _) => UpdateCode();
        _controller.StateChanged += () =>
        {
            if (!_visible) return;
            Update();
            Fit();
        };
    }

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
        ShowCodeButton.Focus(FocusState.Programmatic);
        _visible = true;
        _countdown.Start();
    }

    /// <summary>Closes the panel for good (Quit).</summary>
    public void CloseForQuit()
    {
        _closingForQuit = true;
        _countdown.Stop();
        Close();
    }

    /// <summary>Hides the panel.</summary>
    public void Dismiss()
    {
        if (!_visible) return;
        _visible = false;
        _hiddenAt = Environment.TickCount64;
        _countdown.Stop();
        AppWindow.Hide();
    }

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated) Dismiss();
    }

    private void OnEscape(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        Dismiss();
    }

    /// <summary>Sizes the panel to its content and places it beside the icon, on the icon's monitor.</summary>
    private void Fit()
    {
        var area = DisplayArea.GetFromPoint(new PointInt32(_icon.Left + _icon.Width / 2, _icon.Top + _icon.Height / 2), DisplayAreaFallback.Nearest);
        var work = area.WorkArea;
        var scale = MonitorScale(work);
        Body.Measure(new Size(PanelWidth, double.PositiveInfinity));
        var width = (int)Math.Ceiling(PanelWidth * scale);
        var height = (int)Math.Ceiling(Body.DesiredSize.Height * scale);
        var (x, y) = TrayPanelPlacement.Place(_icon, new ScreenRect(work.X, work.Y, work.X + work.Width, work.Y + work.Height),
                                              width, height, (int)Math.Round(Margin * scale));
        AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }

    private void Update()
    {
        var runtime = _controller.Runtime;
        var listening = _controller.IsListening;
        StatusText.Text = _controller.Problem
            ?? (listening ? $"Listening on {runtime?.Environment.HostName}" : "Starting…");
        StatusDot.Fill = ThemeBrush(_controller.Problem is not null ? "SystemFillColorCriticalBrush"
                               : listening ? "SystemFillColorSuccessBrush" : "SystemFillColorCautionBrush");
        ShowCodeButton.IsEnabled = listening;

        ConnectedList.Children.Clear();
        foreach (var session in _controller.Sessions)
        {
            var detail = session.IsFilesOnly ? "Moving files" : session.Display is { } display ? $"Viewing {display.Name}" : "Connected";
            ConnectedList.Children.Add(DeviceRow(session.Id, session.ClientName, detail));
        }
        foreach (var channel in _controller.FileChannels)
        {
            var button = new Button
            {
                Content = $"Send File to {channel.ClientName}…",
                Style = (Style)Root.Resources["PanelButtonStyle"],
                Margin = new Thickness(-11, 0, 0, 0),
            };
            var id = channel.Id;
            button.Click += (_, _) =>
            {
                Dismiss();
                _ = _controller.SendFilesAsync(id);
            };
            ConnectedList.Children.Add(button);
        }
        NoneConnected.Visibility = ConnectedList.Children.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        var paired = runtime?.Environment.Trust.List() ?? [];
        PairedText.Text = paired.Count switch
        {
            0 => "Nothing is paired yet.",
            1 => $"Paired: {paired[0].Name}",
            _ => $"Paired: {string.Join(", ", paired.Select(p => p.Name))}",
        };
        UpdateCode();
    }

    private Grid DeviceRow(Guid sessionId, string name, string detail)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(new FontIcon { Glyph = "", FontSize = 16, VerticalAlignment = VerticalAlignment.Center });

        var text = new StackPanel();
        text.Children.Add(new TextBlock { Text = name, TextTrimming = TextTrimming.CharacterEllipsis });
        text.Children.Add(new TextBlock
        {
            Text = detail,
            Style = Resource<Style>("CaptionTextBlockStyle"),
            Foreground = ThemeBrush("TextFillColorSecondaryBrush"),
        });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);

        var disconnect = new Button { Content = "Disconnect", VerticalAlignment = VerticalAlignment.Center };
        disconnect.Click += async (_, _) =>
        {
            disconnect.IsEnabled = false;
            await _controller.DisconnectAsync(sessionId);
        };
        Grid.SetColumn(disconnect, 2);
        grid.Children.Add(disconnect);
        return grid;
    }

    private void UpdateCode()
    {
        var code = _controller.PairingCode;
        var showing = code is not null;
        CodePanel.Visibility = showing ? Visibility.Visible : Visibility.Collapsed;
        ShowCodeButton.Visibility = showing ? Visibility.Collapsed : Visibility.Visible;
        PairHint.Visibility = showing ? Visibility.Collapsed : Visibility.Visible;
        if (code is null) return;
        CodeText.Text = code.Length == 6 ? $"{code[..3]} {code[3..]}" : code;
        if (_controller.PairingCodeExpires is { } expires)
        {
            var left = expires - DateTimeOffset.Now;
            CodeExpiry.Text = left > TimeSpan.Zero
                ? string.Create(CultureInfo.CurrentCulture, $"Works once, for {Math.Ceiling(left.TotalMinutes):0} more minute{(left.TotalMinutes > 1 ? "s" : "")}.")
                : "This code has expired.";
        }
        else
        {
            CodeExpiry.Text = "A test code that doesn't expire.";
        }
    }

    private void OnShowCode(object sender, RoutedEventArgs e)
    {
        _controller.ShowPairingCode(openWindow: false);
        Update();
        Fit();
    }

    private void OnCopyCode(object sender, RoutedEventArgs e)
    {
        if (_controller.PairingCode is not { } code) return;
        var package = new DataPackage();
        package.SetText(code);
        WindowsClipboard.SetContent(package);
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

    private static Brush? ThemeBrush(string key) => Resource<Brush>(key);

    private static T? Resource<T>(string key) where T : class =>
        Application.Current.Resources.TryGetValue(key, out var value) ? value as T : null;

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
    private static extern nint MonitorFromPoint(NativePoint point, uint flags);

    [DllImport("shcore.dll", ExactSpelling = true)]
    private static extern int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);
}

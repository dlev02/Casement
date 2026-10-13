using System.Reflection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Vantage.Host.Windows.Files;

namespace Vantage.Host.Windows.App.Pages;

/// <summary>Version, this PC, where logs live, and Quit.</summary>
public sealed partial class AboutPage : Page
{
    private AppController? _controller;

    /// <summary>Creates the page.</summary>
    public AboutPage()
    {
        InitializeComponent();
        Loaded += (_, _) => Update();
    }

    /// <inheritdoc />
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _controller = e.Parameter as AppController;
        base.OnNavigatedTo(e);
    }

    private void Update()
    {
        var version = typeof(AboutPage).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
                      ?? typeof(AboutPage).Assembly.GetName().Version?.ToString() ?? "";
        // "1.0.1+<40-character commit>" reads better as "1.0.1 (04efdd0)".
        if (version.Split('+') is [var number, { Length: >= 7 } commit]) version = $"{number} ({commit[..7]})";
        VersionText.Text = $"Version {version} · protocol {Protocol.VantageProtocol.Version}";
        if (_controller?.Runtime is not { } runtime) return;
        var tailnet = _controller.Tailnet?.PrimaryAddress is { } address ? $" · {address}" : "";
        HostText.Text = $"{runtime.Environment.HostName}{tailnet} · port {runtime.ListenerOptions.Port}";
        DataText.Text = runtime.Paths.Root;
    }

    private void OnOpenLogs(object sender, RoutedEventArgs e)
    {
        if (_controller?.Runtime is { } runtime) ExplorerActions.OpenFolder(runtime.Paths.LogsDirectory);
    }

    private async void OnQuit(object sender, RoutedEventArgs e)
    {
        if (_controller is not null) await _controller.QuitAsync();
    }
}

using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Vantage.Host.Windows.App;

/// <summary>
/// The app: lives in the tray (<see cref="DispatcherShutdownMode.OnExplicitShutdown"/>, so closing
/// the window only hides it) and opens the settings window on demand.
/// </summary>
public partial class App : Application
{
    private readonly string[] _args;

    /// <summary>The running app's controller (host runtime, tray, notifications, window).</summary>
    public static AppController Controller { get; private set; } = null!;

    /// <param name="args">Command-line arguments (the same flags as the console host).</param>
    public App(string[] args)
    {
        _args = args;
        InitializeComponent();
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        UnhandledException += (_, e) =>
        {
            Controller?.LogUnhandled(e.Exception);
            e.Handled = true;
        };
    }

    /// <inheritdoc />
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Controller = new AppController(_args, DispatcherQueue.GetForCurrentThread());
        AppInstance.GetCurrent().Activated += (_, _) => Controller.RunOnUi(() => Controller.ShowWindow());
        _ = Controller.StartAsync();
    }
}

using System.Net.Sockets;
using Microsoft.Extensions.Logging;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Microsoft.Windows.Storage.Pickers;
using Vantage.Host.Windows.Composition;
using Vantage.Host.Windows.Files;
using Vantage.Host.Windows.Logging;
using Vantage.Host.Windows.Storage;
using Vantage.Host.Windows.Tailscale;
using Vantage.Host.Windows.Tray;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Files;
using Vantage.Protocol.Host;

namespace Vantage.Host.Windows.App;

/// <summary>
/// Everything the app does outside its pages: builds the host runtime (the same composition root as
/// the console host), runs the tray icon, shows notifications for arrived files and new pairings,
/// runs the after-arrival action, and owns the settings window. Public members are for the UI
/// thread; events from the listener and the tray are marshalled here.
/// </summary>
public sealed class AppController
{
#if DEBUG
    private const bool DebugBuild = true;
#else
    private const bool DebugBuild = false;
#endif

    private readonly string[] _args;
    private readonly DispatcherQueue _ui;
    private FileLoggerProvider? _fileLog;
    private ILoggerFactory? _logging;
    private ILogger _log = Microsoft.Extensions.Logging.Abstractions.NullLogger.Instance;
    private TrayIcon? _tray;
    private ArrivalBatcher? _arrivals;
    private MainWindow? _window;
    private TrayPanel? _panel;
    private bool _notificationsRegistered;
    private bool _quitting;

    /// <param name="args">Command-line flags.</param>
    /// <param name="ui">The UI thread's dispatcher.</param>
    public AppController(string[] args, DispatcherQueue ui)
    {
        _args = args;
        _ui = ui;
    }

    /// <summary>Raised on the UI thread when anything the pages show may have changed.</summary>
    public event Action? StateChanged;

    /// <summary>The host, once started.</summary>
    public WindowsHostRuntime? Runtime { get; private set; }

    /// <summary>Why the host isn't listening, or null.</summary>
    public string? Problem { get; private set; }

    /// <summary>The listener is up.</summary>
    public bool IsListening { get; private set; }

    /// <summary>This PC on the tailnet, when Tailscale answered.</summary>
    public TailscaleSelf? Tailnet { get; private set; }

    /// <summary>The pairing code showing now, or null.</summary>
    public string? PairingCode => Runtime?.Listener.Pairing.Current;

    /// <summary>When the code showing now stops working.</summary>
    public DateTimeOffset? PairingCodeExpires { get; private set; }

    /// <summary>The app's executable (for start at login).</summary>
    public static string ExecutablePath => Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "VantageHost.exe");

    /// <summary>Sessions now (empty before the listener is up).</summary>
    public IReadOnlyList<SessionSnapshot> Sessions => Safe(() => Runtime?.Listener.Sessions) ?? [];

    /// <summary>File channels now.</summary>
    public IReadOnlyList<FileChannelSnapshot> FileChannels => Safe(() => Runtime?.Listener.FileChannels) ?? [];

    /// <summary>Starts the host, the tray and notifications.</summary>
    public async Task StartAsync()
    {
        HostCommandLine options;
        try
        {
            options = HostCommandLine.Parse(_args, DebugBuild);
        }
        catch (ArgumentException ex)
        {
            Problem = ex.Message;
            options = new HostCommandLine();
        }

        var paths = HostPaths.ForCurrentUser(options.Synthetic);
        _fileLog = new FileLoggerProvider(options.LogFile ?? paths.DefaultLogFile, options.Verbose ? LogLevel.Debug : LogLevel.Information);
        _logging = LoggerFactory.Create(builder =>
        {
            builder.SetMinimumLevel(options.Verbose ? LogLevel.Debug : LogLevel.Information);
            builder.AddProvider(_fileLog);
        });
        _log = _logging.CreateLogger("Vantage.App");

        try
        {
            Runtime = WindowsHostRuntime.Create(options, _logging, DebugBuild);
        }
        catch (Exception ex)
        {
            _log.LogCritical(ex, "the host couldn't start");
            Problem = "Casement Host couldn't start: " + ex.Message;
            ShowWindow();
            return;
        }

        _tray = new TrayIcon(Runtime.Window, TrayState.Starting(Runtime.Environment.HostName), _logging);
        _tray.OpenRequested += icon => RunOnUi(() => ToggleTrayPanel(icon));
        _tray.CommandInvoked += command => RunOnUi(() => _ = HandleAsync(command));
        _arrivals = new ArrivalBatcher(batch => RunOnUi(() => OnArrived(batch)));
        RegisterNotifications();

        var listener = Runtime.Listener;
        listener.Changed += () => RunOnUi(Refresh);
        listener.Pairing.Cleared += () => RunOnUi(() =>
        {
            PairingCodeExpires = null;
            Refresh();
        });
        listener.Paired += (_, name) => RunOnUi(() =>
        {
            Notify(new AppNotificationBuilder().AddText($"{name} is paired").AddText("It can connect to this PC from now on."));
            Refresh();
        });
        listener.FileTransfer += (_, transferEvent) =>
        {
            if (transferEvent is FileTransferEvent.Finished) RunOnUi(Refresh);
        };
        Runtime.Files.Saved += (path, _) => _arrivals.Add(path);
        Runtime.Environment.Trust.Changed += () => RunOnUi(Refresh);

        try
        {
            await Runtime.StartAsync();
            IsListening = true;
            if (Problem is null && !options.Background && Runtime.Environment.Trust.List().Count == 0) ShowWindow();
        }
        catch (SocketException ex)
        {
            Problem = $"Port {options.Port} is in use by another app ({ex.SocketErrorCode})";
            _log.LogError("can't listen: {Message}", ex.Message);
            ShowWindow();
        }
        catch (Exception ex)
        {
            Problem = "Casement Host couldn't start listening: " + ex.Message;
            _log.LogError(ex, "can't listen");
            ShowWindow();
        }
        Refresh();
        Tailnet = await Runtime.Tailscale.GetSelfAsync();
        Refresh();
    }

    /// <summary>Runs <paramref name="action"/> on the UI thread.</summary>
    public void RunOnUi(Action action)
    {
        if (_ui.HasThreadAccess) action();
        else _ui.TryEnqueue(() => action());
    }

    /// <summary>Opens (or focuses) the settings window, optionally on a page ("general", "devices", "files", "display", "about").</summary>
    public void ShowWindow(string? page = null)
    {
        if (_quitting) return;
        _window ??= new MainWindow(this);
        _window.ShowAndActivate(page);
    }

    /// <summary>Opens the tray panel beside the icon at <paramref name="icon"/>, or closes it.</summary>
    public void ToggleTrayPanel(ScreenRect icon)
    {
        if (_quitting) return;
        _panel ??= new TrayPanel(this);
        _panel.Toggle(icon);
    }

    /// <summary>Makes a new pairing code and shows it on the General page (or only where it was asked for).</summary>
    /// <param name="openWindow">Also open the settings window on General.</param>
    public string? ShowPairingCode(bool openWindow = true)
    {
        if (Runtime is null || !IsListening) return null;
        var code = Runtime.Listener.Pairing.NewCode();
        PairingCodeExpires = DateTimeOffset.Now + PairingCodes.Lifetime;
        _log.LogInformation("showing a pairing code");
        if (openWindow) ShowWindow("general");
        Refresh();
        return code;
    }

    /// <summary>Picks files and sends them to the iPad on <paramref name="channelId"/>.</summary>
    public async Task SendFilesAsync(Guid channelId)
    {
        if (Runtime is null) return;
        ShowWindow();
        var picker = new FileOpenPicker(_window!.AppWindow.Id) { Title = "Send to iPad" };
        picker.FileTypeFilter.Add("*");
        var files = await picker.PickMultipleFilesAsync();
        foreach (var file in files)
        {
            _ = Runtime.Listener.SendFileAsync(channelId, file.Path).ContinueWith(task =>
            {
                if (task.Exception is { } error) _log.LogWarning(error.GetBaseException(), "sending {Path} failed", file.Path);
            }, TaskScheduler.Default);
        }
    }

    /// <summary>Ends a session deliberately (the iPad shows it and doesn't reconnect).</summary>
    public Task DisconnectAsync(Guid sessionId) =>
        Runtime?.Listener.DisconnectAsync(sessionId, "The PC ended the session.") ?? Task.CompletedTask;

    /// <summary>Forgets a paired iPad and closes its connections.</summary>
    public Task RevokeAsync(string fingerprint) => Runtime?.Listener.RevokeAsync(fingerprint) ?? Task.CompletedTask;

    /// <summary>Stops the host and exits.</summary>
    public async Task QuitAsync()
    {
        if (_quitting) return;
        _quitting = true;
        _log.LogInformation("quitting");
        _window?.CloseForQuit();
        _panel?.CloseForQuit();
        _tray?.Dispose();
        _arrivals?.Dispose();
        if (_notificationsRegistered)
        {
            try { AppNotificationManager.Default.Unregister(); } catch (Exception) { }
        }
        if (Runtime is not null) await Runtime.DisposeAsync();
        _logging?.Dispose();
        _fileLog?.Dispose();
        Application.Current.Exit();
    }

    /// <summary>Logs an exception the UI didn't handle.</summary>
    public void LogUnhandled(Exception exception) => _log.LogError(exception, "unhandled UI exception");

    /// <summary>Tells the pages and the tray that something changed.</summary>
    public void Refresh()
    {
        if (Runtime is not null)
        {
            var sessions = Sessions;
            var channels = FileChannels;
            _tray?.Update(new TrayState(
                Runtime.Environment.HostName, IsListening, Problem,
                [.. sessions.Where(s => !s.IsFilesOnly).Select(s => new TrayClient(s.Id, s.ClientName))],
                [.. channels.Select(c => new TrayFileTarget(c.Id, c.ClientName))]));
        }
        StateChanged?.Invoke();
    }

    private async Task HandleAsync(TrayCommand command)
    {
        switch (command.Kind)
        {
            case TrayCommandKind.ShowPairingCode:
                ShowPairingCode();
                break;
            case TrayCommandKind.SendFile:
                await SendFilesAsync(command.Target);
                break;
            case TrayCommandKind.Disconnect:
                await DisconnectAsync(command.Target);
                break;
            case TrayCommandKind.Settings:
                ShowWindow();
                break;
            case TrayCommandKind.Quit:
                await QuitAsync();
                break;
        }
    }

    private void OnArrived(IReadOnlyList<string> batch)
    {
        var settings = Runtime!.Settings.Current;
        if (settings.NotifyOnArrival)
        {
            var title = batch.Count == 1 ? $"Received {Path.GetFileName(batch[0])}" : $"Received {batch.Count} files";
            var builder = new AppNotificationBuilder()
                .AddText(title)
                .AddText($"Saved in {Path.GetDirectoryName(batch[0])}")
                .AddArgument("action", "show")
                .AddArgument("path", batch[0])
                .AddButton(new AppNotificationButton("Show in folder").AddArgument("action", "show").AddArgument("path", batch[0]));
            Notify(builder);
        }

        switch (settings.AfterArrival)
        {
            case AfterArrival.ShowInFolder:
                ExplorerActions.ShowInFolder(batch, _log);
                break;
            case AfterArrival.OpenFile:
                if (batch.Count <= ArrivalPolicy.MaxFilesToOpen && batch.All(ArrivalPolicy.CanAutoOpen))
                    foreach (var path in batch) ExplorerActions.Open(path, _log);
                else
                    ExplorerActions.ShowInFolder(batch, _log);
                break;
        }
    }

    private void RegisterNotifications()
    {
        try
        {
            if (!AppNotificationManager.IsSupported()) return;
            AppNotificationManager.Default.NotificationInvoked += (_, args) =>
            {
                args.Arguments.TryGetValue("action", out var action);
                args.Arguments.TryGetValue("path", out var path);
                RunOnUi(() =>
                {
                    if (action == "show" && path is not null) ExplorerActions.ShowInFolder([path], _log);
                    else ShowWindow();
                });
            };
            AppNotificationManager.Default.Register();
            _notificationsRegistered = true;
        }
        catch (Exception ex)
        {
            _log.LogWarning("notifications unavailable: {Message}", ex.Message);
        }
    }

    private void Notify(AppNotificationBuilder builder)
    {
        if (!_notificationsRegistered) return;
        try { AppNotificationManager.Default.Show(builder.BuildNotification()); }
        catch (Exception ex) { _log.LogDebug("notification failed: {Message}", ex.Message); }
    }

    private static T? Safe<T>(Func<T?> read) where T : class
    {
        try { return read(); }
        catch (NotImplementedException) { return null; }
    }
}

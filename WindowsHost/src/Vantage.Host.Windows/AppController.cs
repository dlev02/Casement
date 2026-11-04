using System.Net.Sockets;
using Microsoft.Extensions.Logging;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Microsoft.Windows.Storage.Pickers;
using Vantage.Host.Windows.Composition;
using Vantage.Host.Windows.Files;
using Vantage.Host.Windows.Input;
using Vantage.Host.Windows.Logging;
using Vantage.Host.Windows.Startup;
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
    private DispatcherQueueTimer? _progressRefresh;
    private DispatcherQueueTimer? _transferTick;

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

    /// <summary>Files moving, paused, and finished in the last minute (the tray, the panel and Settings › Files show them).</summary>
    public HostTransferList Transfers { get; } = new();

    /// <summary>
    /// Progress arrives up to ten times a second per file; the tray icon, tooltip and rows are
    /// redrawn at most this often. Starts, ends and pauses refresh at once.
    /// </summary>
    private static readonly TimeSpan ProgressRefreshInterval = TimeSpan.FromMilliseconds(250);

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
        listener.FileSendQueued += (channel, item) => RunOnUi(() =>
        {
            Transfers.Queue(channel, ChannelName(channel), item);
            Refresh();
        });
        listener.FileTransfer += (channel, transferEvent) => RunOnUi(() => OnTransferEvent(channel, transferEvent));
        listener.FileTransferPaused += pause => RunOnUi(() =>
        {
            // Not a failure: no notification; the row says it resumes when the device is back.
            Transfers.Pause(pause);
            Refresh();
        });
        _progressRefresh = _ui.CreateTimer();
        _progressRefresh.Interval = ProgressRefreshInterval;
        _progressRefresh.IsRepeating = false;
        _progressRefresh.Tick += (_, _) => Refresh();
        _transferTick = _ui.CreateTimer();
        _transferTick.Interval = TimeSpan.FromSeconds(1);
        _transferTick.Tick += (_, _) => OnTransferTick();
        Runtime.Files.Saved += (path, _) => _arrivals.Add(path);
        Runtime.Environment.Trust.Changed += () => RunOnUi(Refresh);
        if (Runtime.Input is { } input) input.ElevatedWindowBlocked += window => RunOnUi(() => OnElevatedWindowBlocked(window));
        _log.LogInformation("running {Mode}", ElevatedWindows.ThisProcessIsElevated ? "as administrator" : "without administrator rights");
        if (!options.Synthetic) TurnOnStartAtLoginOnce();
        if (!options.Synthetic && !DebugBuild) EnsureStartMenuShortcut();

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
        if (TakeOpenOnLaunch() is { } page) ShowWindow(page);
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

    /// <summary>Whether this copy runs as administrator (so it can control administrator apps).</summary>
    public static bool IsElevated => ElevatedWindows.ThisProcessIsElevated;

    /// <summary>"Control apps running as administrator" is on.</summary>
    public bool ControlsAdminApps => Runtime?.Settings.Current.ControlAdminApps ?? false;

    /// <summary>
    /// Turns "Control apps running as administrator" on (registers the elevated task, which Windows
    /// asks permission for, then restarts through it, back on General) or off (deletes the task; this
    /// copy stays elevated until it next starts). False when Windows' prompt was declined or failed.
    /// </summary>
    public async Task<bool> SetControlsAdminAppsAsync(bool on)
    {
        if (Runtime is null) return false;
        if (!(on ? await AdminLaunch.RegisterAsync(ExecutablePath) : await AdminLaunch.UnregisterAsync()))
        {
            _log.LogWarning("couldn't {Action} the administrator task", on ? "register" : "delete");
            return false;
        }
        Runtime.Settings.Update(s => s with { ControlAdminApps = on });
        _log.LogInformation("control of administrator apps turned {State}", on ? "on" : "off");
        if (on && !IsElevated)
        {
            await QuitAsync(afterStop: async () =>
            {
                WriteOpenOnLaunch("general");
                if (!await AdminLaunch.RunAsync()) _log.LogError("the administrator task didn't start");
            });
        }
        return true;
    }

    /// <summary>Stops the host and exits.</summary>
    /// <param name="afterStop">Runs once the listener and tray are gone, just before exiting.</param>
    public async Task QuitAsync(Func<Task>? afterStop = null)
    {
        if (_quitting) return;
        _quitting = true;
        _log.LogInformation("quitting");
        _window?.CloseForQuit();
        _panel?.CloseForQuit();
        _progressRefresh?.Stop();
        _transferTick?.Stop();
        _tray?.Dispose();
        _arrivals?.Dispose();
        if (_notificationsRegistered)
        {
            try { AppNotificationManager.Default.Unregister(); } catch (Exception) { }
        }
        if (Runtime is not null) await Runtime.DisposeAsync();
        if (afterStop is not null)
        {
            // The next copy registers as the running instance.
            AppInstance.GetCurrent().UnregisterKey();
            await afterStop();
        }
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
                [.. channels.Select(c => new TrayFileTarget(c.Id, c.ClientName))])
            {
                Transfers = [.. Transfers.Items.Select(TrayTransfer.From)],
                Activity = Transfers.Activity,
                TransferSummary = Transfers.Summary,
            });
        }
        _progressRefresh?.Stop();
        if (_transferTick is { } tick)
        {
            if (Transfers.NeedsTicking && !tick.IsRunning) tick.Start();
            else if (!Transfers.NeedsTicking && tick.IsRunning) tick.Stop();
        }
        StateChanged?.Invoke();
    }

    /// <summary>Cancels a file (the tray, the panel, Settings › Files). A cancelled receive's partial is deleted.</summary>
    public void CancelTransfer(Guid transferId)
    {
        if (Runtime is null || Transfers.Find(transferId) is not { IsActive: true } transfer) return;
        _log.LogInformation("cancelling a file {Direction} {Device}", transfer.Direction == FileDirection.Sending ? "to" : "from", transfer.DeviceName);
        Runtime.Listener.CancelTransfer(transfer.ChannelId, transferId);
        // Queued and paused files have nothing moving to report back; a moving one ends with the engine's Cancelled.
        Transfers.MarkCancelled(transferId);
        Refresh();
    }

    /// <summary>Cancels every file still waiting, moving or paused (Settings › Files › Cancel All, after asking).</summary>
    public void CancelAllTransfers()
    {
        foreach (var transfer in Transfers.Items.Where(t => t.IsActive).ToList()) CancelTransfer(transfer.Id);
    }

    /// <summary>Selects a received file in File Explorer.</summary>
    public void ShowTransferInFolder(Guid transferId)
    {
        if (Transfers.Find(transferId)?.SavedPath is { } path) ExplorerActions.ShowInFolder([path], _log);
    }

    /// <summary>Opens the folder received files are saved in.</summary>
    public void OpenReceiveFolder()
    {
        if (Runtime is { } runtime) ExplorerActions.OpenFolder(runtime.Files.ReceiveDirectory, _log);
    }

    private void OnTransferEvent(Guid channel, FileTransferEvent transferEvent)
    {
        var ended = Transfers.Apply(channel, ChannelName(channel), transferEvent);
        if (ended is { State: HostTransferState.Failed }) NotifyFailed(ended);
        if (transferEvent is FileTransferEvent.Progress)
        {
            if (_progressRefresh is { IsRunning: false } timer) timer.Start();
        }
        else
        {
            Refresh();
        }
    }

    /// <summary>Paused files whose device didn't come back fail now; finished rows leave after a minute.</summary>
    private void OnTransferTick()
    {
        var before = Transfers.Items.Count;
        var expired = Transfers.Tick();
        foreach (var transfer in expired) NotifyFailed(transfer);
        if (expired.Count > 0 || Transfers.Items.Count != before || !Transfers.NeedsTicking) Refresh();
    }

    /// <summary>"Couldn't send Report.pdf" (the Mac's wording, in Windows' sentence case).</summary>
    private void NotifyFailed(HostTransfer transfer)
    {
        var sending = transfer.Direction == FileDirection.Sending;
        var reason = transfer.FailureReason ?? HostTransferList.LostConnection;
        Notify(new AppNotificationBuilder()
            .AddText(sending ? $"Couldn't send {transfer.Name}" : $"Couldn't receive {transfer.Name}")
            .AddText(sending ? $"{transfer.DeviceName}: {reason}" : reason)
            .AddArgument("action", "files"));
    }

    /// <summary>The device on a file channel; a row it starts keeps the name after the channel closes.</summary>
    private string ChannelName(Guid channelId) =>
        FileChannels.FirstOrDefault(c => c.Id == channelId)?.ClientName ?? "your device";

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
            case TrayCommandKind.CancelTransfer:
                CancelTransfer(command.Target);
                break;
            case TrayCommandKind.ShowTransfer:
                ShowTransferInFolder(command.Target);
                break;
            case TrayCommandKind.OpenReceiveFolder:
                OpenReceiveFolder();
                break;
            case TrayCommandKind.ShowTransfers:
                ShowWindow("files");
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

    private void OnElevatedWindowBlocked(ElevatedWindow window)
    {
        if (!Sessions.Any(s => !s.IsFilesOnly)) return;
        Notify(new AppNotificationBuilder()
            .AddText($"{window.Name} runs as administrator")
            .AddText("To use it from Casement, turn on Control apps running as administrator in Casement Host's settings.")
            .AddArgument("action", "general")
            .AddButton(new AppNotificationButton("Settings").AddArgument("action", "general")));
    }

    /// <summary>Start at login is on for a new install (host apps start at login); the person can turn it off.</summary>
    private void TurnOnStartAtLoginOnce()
    {
        var settings = Runtime!.Settings;
        if (settings.Current.StartAtLoginSettled || DebugBuild) return;
        try
        {
            // Another copy's entry (an installed one, while a build from the repo runs) stays as it is.
            if (!StartAtLogin.IsRegistered())
            {
                StartAtLogin.SetEnabled(ExecutablePath, true);
                _log.LogInformation("start at login turned on for the first launch");
            }
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or IOException)
        {
            _log.LogWarning("couldn't turn on start at login: {Message}", ex.Message);
        }
        settings.Update(s => s with { StartAtLoginSettled = true });
    }

    /// <summary>
    /// A Start menu entry, so Start › "Casement" brings the host back after its window was closed
    /// (the zip has no installer to add one). Rewritten when the folder moved.
    /// </summary>
    private void EnsureStartMenuShortcut()
    {
        try
        {
            if (StartMenuShortcut.Ensure(ExecutablePath)) _log.LogInformation("added the Start menu shortcut");
        }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or IOException or UnauthorizedAccessException)
        {
            _log.LogWarning("couldn't add the Start menu shortcut: {Message}", ex.Message);
        }
    }

    /// <summary>
    /// The settings window was closed (hidden). The first time, says where the host went: Windows 11
    /// keeps a new tray icon behind the ^, so someone who closes the window may think it quit.
    /// </summary>
    public void OnWindowHidden()
    {
        if (Runtime is null || _quitting || Runtime.Settings.Current.TrayHintShown) return;
        Runtime.Settings.Update(s => s with { TrayHintShown = true });
        var shown = TrayIconVisibility.Shown(ExecutablePath) == true;
        Notify(new AppNotificationBuilder()
            .AddText("Casement Host is still running")
            .AddText(shown
                ? "Its icon is in the system tray, next to the clock. Right-click it to quit."
                : "Its icon is in the system tray, behind the ^ next to the clock. Drag it onto the taskbar to keep it in view.")
            .AddArgument("action", "general"));
    }

    private string OpenOnLaunchFile => Path.Combine(Runtime!.Paths.Root, "open-on-launch");

    private void WriteOpenOnLaunch(string page)
    {
        try { File.WriteAllText(OpenOnLaunchFile, page); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>The settings page a restart asked to reopen (read once).</summary>
    private string? TakeOpenOnLaunch()
    {
        try
        {
            if (!File.Exists(OpenOnLaunchFile)) return null;
            var page = File.ReadAllText(OpenOnLaunchFile).Trim();
            File.Delete(OpenOnLaunchFile);
            return page.Length > 0 ? page : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
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
                    else if (action is "general" or "files") ShowWindow(action);
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

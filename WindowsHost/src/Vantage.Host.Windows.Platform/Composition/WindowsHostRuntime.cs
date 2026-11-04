using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Capture;
using Vantage.Host.Windows.Clipboard;
using Vantage.Host.Windows.Desktop;
using Vantage.Host.Windows.Encode;
using Vantage.Host.Windows.Files;
using Vantage.Host.Windows.Input;
using Vantage.Host.Windows.Storage;
using Vantage.Host.Windows.Tailscale;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Host;
using Vantage.Protocol.Input;
using Windows.Win32;
using Windows.Win32.UI.HiDpi;

namespace Vantage.Host.Windows.Composition;

/// <summary>
/// The Windows composition root, shared by the console host and the app: builds every platform
/// piece, the <see cref="HostEnvironment"/> and the <see cref="HostListener"/> from a
/// <see cref="HostCommandLine"/>, and tears them down in order. The app adds the tray and the
/// window on top; the console host runs exactly this, so the PC can bring the pipeline up first.
/// </summary>
public sealed class WindowsHostRuntime : IAsyncDisposable
{
    private readonly List<IDisposable> _owned = [];
    private readonly ILogger _log;

    private WindowsHostRuntime(HostCommandLine options, ILoggerFactory logging, bool debugBuild)
    {
        Options = options;
        Logging = logging;
        _log = logging.CreateLogger("Vantage.Host");

        EnsurePerMonitorDpiAwareness(_log);

        Paths = HostPaths.ForCurrentUser(options.Synthetic);
        Settings = new HostSettingsStore(Paths.SettingsFile);
        Window = Own(MessageWindow.Start());
        Tailscale = new TailscaleCli(logging);
        Files = new WindowsFileStore(options.Synthetic && options.ReceiveFolder is null ? null : Settings,
                                     options.ReceiveFolder ?? (options.Synthetic ? SyntheticReceiveFolder() : null), logging);
        Encoders = new MediaFoundationEncoderFactory(logging, new EncoderTuning(options.Encoder, options.RateControl));
        IVideoEncoderFactory encoders = options.DumpH264 is { } dump
            ? new DumpingEncoderFactory(Encoders, dump, logging.CreateLogger("Vantage.Encode"))
            : Encoders;

        var storage = new DpapiProtectedStorage(Paths.SecretsDirectory);
        var ed25519 = new NSecEd25519();
        var inputLog = logging.CreateLogger("Vantage.Input");
        IInputInjector injector;
        if (options.Synthetic)
        {
            injector = new LoggingInputInjector(inputLog);
        }
        else
        {
            Input = new SendInputInjector(inputLog);
            injector = Input;
        }

        IHostStatusSource status;
        IPowerControl power;
        IClipboard clipboard;
        if (options.Synthetic)
        {
            status = new StaticHostStatus();
            power = new LoggingPowerControl(logging.CreateLogger("Vantage.Power"));
            clipboard = new InMemoryClipboard();
        }
        else
        {
            status = Own(new SessionStatusMonitor(Window, logging));
            power = Own(new PowerControl(Window, logging));
            clipboard = new Win32Clipboard(Window, logging);
        }

        Environment = new HostEnvironment
        {
            HostName = HostName(),
            Platform = options.Platform,
            Screen = new WindowsScreenSource(logging),
            Cursor = new Cursor.WindowsCursorSource(logging),
            Encoders = encoders,
            CreateInputSink = () => new WindowsInputTranslator(injector, inputLog),
            Clipboard = clipboard,
            Status = status,
            Power = power,
            Peers = Tailscale.IsAvailable ? Tailscale : null,
            Files = Files,
            Identity = new ProtectedIdentityStore(storage, ed25519),
            Trust = new ProtectedTrustStore(storage, TimeProvider.System),
            Ed25519 = ed25519,
            Logging = logging,
        };

        ListenerOptions = new HostListenerOptions
        {
            Port = options.Port,
            AllowLoopback = debugBuild,
            FixedPairingCode = debugBuild ? options.PairingCode : null,
            SendFileOnConnect = debugBuild ? options.SendFileOnConnect : null,
            CaptureFailsFor = debugBuild ? options.CaptureFailsFor : null,
        };
        Listener = new HostListener(Environment, ListenerOptions);

        // Synthetic runs share the PC with a real host and never hold its restarts.
        if (!options.Synthetic)
        {
            var guard = Own(new RestartGuard(Window, Settings.Current.AskBeforeRestart, logging));
            RestartGuard = guard;
            Settings.Changed += settings => guard.Enabled = settings.AskBeforeRestart;
            Listener.Changed += () => guard.Update(ConnectedDeviceNames());
            guard.EndingSession += EndEverySessionAsync;
        }
    }

    /// <summary>Builds everything; nothing listens until <see cref="StartAsync"/>.</summary>
    /// <param name="options">Parsed flags.</param>
    /// <param name="logging">Loggers.</param>
    /// <param name="debugBuild">Whether this is a debug build (loopback peers and the debug flags).</param>
    public static WindowsHostRuntime Create(HostCommandLine options, ILoggerFactory logging, bool debugBuild) =>
        new(options, logging, debugBuild);

    /// <summary>The flags this runtime was built from.</summary>
    public HostCommandLine Options { get; }

    /// <summary>Loggers.</summary>
    public ILoggerFactory Logging { get; }

    /// <summary>Where state lives.</summary>
    public HostPaths Paths { get; }

    /// <summary>User settings.</summary>
    public HostSettingsStore Settings { get; }

    /// <summary>The real input injector (null for synthetic runs).</summary>
    public SendInputInjector? Input { get; }

    /// <summary>The hidden Win32 window (tray, clipboard, notifications).</summary>
    public MessageWindow Window { get; }

    /// <summary>Holds sign-outs and restarts while a device is connected (null for synthetic runs).</summary>
    public RestartGuard? RestartGuard { get; }

    /// <summary>
    /// Raised (from the guard's wait on the message window's thread) once Windows is really
    /// signing out or restarting and the listener has stopped; the app quits on it.
    /// </summary>
    public event Action<SessionEnding>? WindowsSessionEnded;

    /// <summary>The Tailscale CLI.</summary>
    public TailscaleCli Tailscale { get; }

    /// <summary>The receive folder and file marking; raises <see cref="WindowsFileStore.Saved"/>.</summary>
    public WindowsFileStore Files { get; }

    /// <summary>The encoder factory (its <see cref="MediaFoundationEncoderFactory.CurrentEncoderName"/> is shown in About).</summary>
    public MediaFoundationEncoderFactory Encoders { get; }

    /// <summary>What the listener runs on.</summary>
    public HostEnvironment Environment { get; }

    /// <summary>Listener settings.</summary>
    public HostListenerOptions ListenerOptions { get; }

    /// <summary>The listener.</summary>
    public HostListener Listener { get; }

    /// <summary>The running executable's version, "1.2 (abc1234)" (the About page and the log).</summary>
    public static string AppVersion { get; } = ReadAppVersion();

    private static string ReadAppVersion()
    {
        var assembly = System.Reflection.Assembly.GetEntryAssembly();
        var version = System.Reflection.CustomAttributeExtensions
                          .GetCustomAttribute<System.Reflection.AssemblyInformationalVersionAttribute>(assembly!)?.InformationalVersion
                      ?? assembly?.GetName().Version?.ToString() ?? "?";
        // "1.0.1+<40-character commit>" reads better as "1.0.1 (04efdd0)".
        if (version.Split('+') is [var number, { Length: >= 7 } commit]) version = $"{number} ({commit[..7]})";
        return version;
    }

    /// <summary>Starts listening.</summary>
    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        _log.LogInformation("Casement Host {Version} (protocol {Protocol}) on {Host} ({Platform}), port {Port}, data in {Root}{Synthetic}",
                            AppVersion, Protocol.VantageProtocol.HostVersion, Environment.HostName, Environment.Platform, ListenerOptions.Port,
                            Paths.Root, Options.Synthetic ? " (synthetic)" : "");
        if (!Environment.Screen.IsCaptureSupported) _log.LogWarning("screen capture isn't supported here: {Why}", Environment.Screen.CaptureUnsupportedMessage);
        await Listener.StartAsync(cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Stops listening (clients reconnect later) and releases everything.</summary>
    public async ValueTask DisposeAsync()
    {
        try
        {
            await Listener.StopAsync().ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is NotImplementedException or ObjectDisposedException or InvalidOperationException)
        {
            _log.LogDebug("listener stop: {Message}", ex.Message);
        }
        for (var i = _owned.Count - 1; i >= 0; i--)
        {
            try { _owned[i].Dispose(); }
            catch (Exception ex) { _log.LogDebug("dispose: {Message}", ex.Message); }
        }
    }

    /// <summary>One name per device with a screen session (what the restart screen names).</summary>
    private List<string> ConnectedDeviceNames()
    {
        try
        {
            return [.. Listener.Sessions.Where(s => !s.IsFilesOnly).DistinctBy(s => s.Fingerprint).Select(s => s.ClientName)];
        }
        catch (Exception ex) when (ex is NotImplementedException or ObjectDisposedException)
        {
            return [];
        }
    }

    /// <summary>
    /// Windows is signing out or restarting: the listener stops, so every connection just drops
    /// without a <c>disconnect</c> (as on the Mac) and the iPad keeps retrying until the host is
    /// back after sign-in; files pause and resume then.
    /// </summary>
    private async Task EndEverySessionAsync(SessionEnding kind)
    {
        try
        {
            var count = Listener.Sessions.Count(s => !s.IsFilesOnly);
            _log.LogInformation("{Kind}: stopping with {Count} screen session(s) connected", RestartGuardPolicy.LogName(kind), count);
            await Listener.StopAsync().ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is NotImplementedException or ObjectDisposedException or InvalidOperationException or IOException)
        {
            _log.LogDebug("stopping for the session end: {Message}", ex.Message);
        }
        WindowsSessionEnded?.Invoke(kind);
    }

    private T Own<T>(T disposable) where T : IDisposable
    {
        _owned.Add(disposable);
        return disposable;
    }

    /// <summary>The DNS host name with its case ("drew-pc"), which <c>Challenge.hostName</c> carries.</summary>
    private static string HostName()
    {
        try
        {
            var name = global::System.Net.Dns.GetHostName();
            if (!string.IsNullOrWhiteSpace(name)) return name;
        }
        catch (global::System.Net.Sockets.SocketException)
        {
        }
        return global::System.Environment.MachineName;
    }

    private static string SyntheticReceiveFolder() =>
        Path.Combine(Path.GetTempPath(), "VantageSynthetic", "Received");

    /// <summary>
    /// Per-monitor-v2 DPI awareness, so monitor rects, <c>SendInput</c> coordinates and capture sizes
    /// are all physical pixels. The manifests declare it too; this covers a host started without one
    /// (it fails harmlessly once awareness is set).
    /// </summary>
    private static void EnsurePerMonitorDpiAwareness(ILogger log)
    {
        if (!PInvoke.SetProcessDpiAwarenessContext(new DPI_AWARENESS_CONTEXT(-4)))
            log.LogDebug("DPI awareness was already set (the manifest)");
    }
}

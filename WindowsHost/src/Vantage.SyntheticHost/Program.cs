// Vantage.SyntheticHost: the Windows host's session logic on macOS (or anywhere), for loopback
// interop tests. It streams a pre-encoded clip, logs input and clipboard to JSONL, and saves files
// to a temp folder. Loopback peers are always accepted (it is a DEBUG tool).

using Microsoft.Extensions.Logging;
using Vantage.Protocol;
using Vantage.Protocol.Auth;
using Vantage.Protocol.Host;
using Vantage.SyntheticHost;

SyntheticOptions options;
try
{
    options = SyntheticOptions.Parse(args);
}
catch (ArgumentException error)
{
    Console.Error.WriteLine(error.Message);
    return 2;
}

using var loggerFactory = LoggerFactory.Create(builder => builder
    .SetMinimumLevel(LogLevel.Information)
    .AddSimpleConsole(console =>
    {
        console.SingleLine = true;
        console.TimestampFormat = "HH:mm:ss.fff ";
    }));
var log = loggerFactory.CreateLogger("Vantage.Synthetic");

var clip = new Clip(options.ResolveClip());
log.LogInformation("clip: {Units} access units, IDRs at {Keyframes}", clip.Units.Count, string.Join(",", clip.Keyframes));
var display = new FakeDisplay(options.DisplayAsleep, options.DisplayAsleep, log);
using var events = new EventLog(options.InputLog, options.LogInputEvents, log);
var storage = new FileProtectedStorage(options.StateDirectory);
var ed25519 = new NSecEd25519();
Directory.CreateDirectory(options.ReceiveFolder);

var environment = new HostEnvironment
{
    HostName = options.HostName ?? (options.Platform == HostPlatforms.Windows ? "Synthetic PC" : "Synthetic Mac"),
    Platform = options.Platform,
    Screen = new ClipScreenSource(display, log),
    Cursor = options.CursorShapes ? new SyntheticCursorSource() : null,
    Encoders = new ClipEncoderFactory(clip),
    CreateInputSink = () => new LoggingInputSink(events, loggerFactory.CreateLogger("Vantage.Input")),
    Clipboard = new MemoryClipboard(options.ClipboardText, events),
    Status = display,
    Power = display,
    Files = new SyntheticFileStore(options.ReceiveFolder, log),
    Identity = new ProtectedIdentityStore(storage, ed25519),
    Trust = new ProtectedTrustStore(storage, TimeProvider.System),
    Ed25519 = ed25519,
    Logging = loggerFactory,
};

await using var listener = new HostListener(environment, new HostListenerOptions
{
    Port = options.Port,
    AllowLoopback = true,
    FixedPairingCode = options.PairingCode,
    RearmFixedPairingCodeAfter = options.PairingCodeRearmSeconds is { } rearm ? TimeSpan.FromSeconds(rearm) : null,
    SendFileOnConnect = options.SendFileOnConnect,
    CaptureFailsFor = options.CaptureFailsForSeconds is { } fails ? TimeSpan.FromSeconds(fails) : null,
});
await listener.StartAsync();
if (listener.Pairing.Current is null) listener.Pairing.NewCode();
log.LogInformation("Vantage synthetic host ({Platform}) on port {Port}; pairing code {Code}; receiving into {Folder}; state in {State}",
                   options.Platform, listener.LocalEndPoint?.Port, listener.Pairing.Current, options.ReceiveFolder, options.StateDirectory);

// Not disposed: the process-exit handler can still fire after Main returns.
var quit = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    quit.Cancel();
};
AppDomain.CurrentDomain.ProcessExit += (_, _) => quit.Cancel();
if (options.ExitAfterSeconds is { } seconds) quit.CancelAfter(TimeSpan.FromSeconds(seconds));
try
{
    await Task.Delay(Timeout.Infinite, quit.Token);
}
catch (OperationCanceledException)
{
    log.LogInformation("stopping");
}
await listener.StopAsync();
return 0;

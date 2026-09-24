using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.Composition;
using Vantage.Host.Windows.Logging;
using Vantage.Host.Windows.Storage;
using Vantage.Protocol.Files;

// Vantage Host (console): the real Windows pipeline without the UI, for bring-up and SSH testing.
//   VantageHostCli --port 47821 --pairing-code 246810 --dump-h264 C:\temp\vantage.h264
// Keys: P shows a new pairing code, Q quits.

#if DEBUG
const bool DebugBuild = true;
#else
const bool DebugBuild = false;
#endif

if (args.Contains("--help") || args.Contains("-h") || args.Contains("/?"))
{
    Console.WriteLine(HostCommandLine.Usage);
    return 0;
}

HostCommandLine options;
try
{
    options = HostCommandLine.Parse(args, DebugBuild);
}
catch (ArgumentException ex)
{
    Console.Error.WriteLine(ex.Message);
    Console.Error.WriteLine(HostCommandLine.Usage);
    return 2;
}

var logFile = options.LogFile ?? HostPaths.ForCurrentUser(options.Synthetic).DefaultLogFile;
using var fileLogger = new FileLoggerProvider(logFile, options.Verbose ? LogLevel.Debug : LogLevel.Information);
using var logging = LoggerFactory.Create(builder =>
{
    builder.SetMinimumLevel(options.Verbose ? LogLevel.Debug : LogLevel.Information);
    builder.AddSimpleConsole(console =>
    {
        console.SingleLine = true;
        console.TimestampFormat = "HH:mm:ss.fff ";
    });
    builder.AddProvider(fileLogger);
});
var log = logging.CreateLogger("Vantage.Cli");
log.LogInformation("logging to {Path}", logFile);

using var quit = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true;
    quit.Cancel();
};
if (options.ExitAfter is { } exitAfter) quit.CancelAfter(exitAfter);

await using var runtime = WindowsHostRuntime.Create(options, logging, DebugBuild);
var listener = runtime.Listener;

listener.Paired += (fingerprint, name) => log.LogInformation("paired {Name} ({Fingerprint})", name, fingerprint);
listener.Pairing.Cleared += () => log.LogInformation("pairing code cleared");
listener.Changed += () =>
{
    try
    {
        foreach (var session in listener.Sessions)
            log.LogInformation("session {Id}: {Name} from {Peer}{FilesOnly}{Display}", session.Id, session.ClientName, session.Peer,
                               session.IsFilesOnly ? " (files only)" : "",
                               session.Display is { } display ? $" streaming {display.Name} {display.PixelWidth}×{display.PixelHeight}" : "");
        if (listener.Sessions.Count == 0) log.LogInformation("no sessions");
    }
    catch (NotImplementedException)
    {
    }
};
listener.FileTransfer += (channel, transferEvent) =>
{
    switch (transferEvent)
    {
        case FileTransferEvent.Started started:
            log.LogInformation("file {Direction} {Name} ({Bytes} bytes)", started.Item.Direction, started.Item.Name, started.Item.ByteCount);
            break;
        case FileTransferEvent.Finished finished:
            log.LogInformation("file {Id} finished: {Outcome}", finished.Id, finished.Outcome);
            break;
    }
};
runtime.Files.Saved += (path, _) => log.LogInformation("saved {Path}", path);

try
{
    await runtime.StartAsync(quit.Token);
}
catch (System.Net.Sockets.SocketException ex)
{
    log.LogCritical("can't listen on port {Port}: {Message}", options.Port, ex.Message);
    return 1;
}
catch (NotImplementedException ex)
{
    log.LogCritical("the protocol library's listener isn't implemented yet ({Message})", ex.Message);
    return 1;
}

if (options.PairingCode is null && runtime.Environment.Trust.List().Count == 0)
    log.LogWarning("no paired devices yet; pairing code {Code} (valid 10 minutes, press P for a new one)", listener.Pairing.NewCode());
else if (options.PairingCode is not null)
    log.LogInformation("fixed pairing code {Code}", options.PairingCode);

var keys = Task.Run(() =>
{
    try
    {
        if (Console.IsInputRedirected) return;
        while (!quit.IsCancellationRequested)
        {
            if (!Console.KeyAvailable)
            {
                Thread.Sleep(100);
                continue;
            }
            switch (char.ToLowerInvariant(Console.ReadKey(intercept: true).KeyChar))
            {
                case 'p':
                    log.LogWarning("pairing code {Code} (valid 10 minutes)", listener.Pairing.NewCode());
                    break;
                case 'q':
                    quit.Cancel();
                    break;
            }
        }
    }
    catch (InvalidOperationException)
    {
        // No console (started by a scheduled task without one).
    }
});

try
{
    await Task.Delay(Timeout.Infinite, quit.Token);
}
catch (OperationCanceledException)
{
}
log.LogInformation("stopping");
return 0;

using System.Globalization;
using Vantage.Protocol;

namespace Vantage.SyntheticHost;

/// <summary>
/// Command-line flags, named like the Mac host's DEBUG flags so tests and scripts can drive either:
/// <c>--port</c>, <c>--pairing-code</c>, <c>--exit-after</c>, <c>--display-asleep</c>,
/// <c>--capture-fails-for</c>, <c>--send-file-on-connect</c>, <c>--receive-folder</c>,
/// <c>--log-input-events</c>, plus <c>--platform windows|macos</c>, <c>--input-log</c>,
/// <c>--clipboard-text</c>, <c>--clip</c>, <c>--state-dir</c>, <c>--host-name</c>, <c>--pairing-code-rearm</c>.
/// </summary>
internal sealed record SyntheticOptions
{
    public int Port { get; init; } = 47851;
    public string? PairingCode { get; init; }
    public double? PairingCodeRearmSeconds { get; init; }
    public double? ExitAfterSeconds { get; init; }
    public bool DisplayAsleep { get; init; }
    public double? CaptureFailsForSeconds { get; init; }
    public string? SendFileOnConnect { get; init; }
    public string ReceiveFolder { get; init; } = Path.Combine(Path.GetTempPath(), "VantageSynthetic", "Received");
    public bool LogInputEvents { get; init; }
    public string Platform { get; init; } = HostPlatforms.Windows;
    public string? InputLog { get; init; }
    public string? ClipboardText { get; init; }
    public string? ClipPath { get; init; }
    public string StateDirectory { get; init; } = Path.Combine(Path.GetTempPath(), "VantageSynthetic", "WindowsHostState");
    public string? HostName { get; init; }

    public static SyntheticOptions Parse(string[] args)
    {
        var options = new SyntheticOptions();
        for (var i = 0; i < args.Length; i++)
        {
            string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{args[i]} needs a value.");
            double Seconds() => double.Parse(Next(), CultureInfo.InvariantCulture);
            options = args[i] switch
            {
                "--port" => options with { Port = int.Parse(Next(), CultureInfo.InvariantCulture) },
                "--pairing-code" => options with { PairingCode = Next() },
                "--pairing-code-rearm" => options with { PairingCodeRearmSeconds = Seconds() },
                "--exit-after" => options with { ExitAfterSeconds = Seconds() },
                "--display-asleep" => options with { DisplayAsleep = true },
                "--capture-fails-for" => options with { CaptureFailsForSeconds = Seconds() },
                "--send-file-on-connect" => options with { SendFileOnConnect = Next() },
                "--receive-folder" => options with { ReceiveFolder = Next() },
                "--log-input-events" => options with { LogInputEvents = true },
                "--platform" => options with { Platform = Next() },
                "--input-log" => options with { InputLog = Next() },
                "--clipboard-text" => options with { ClipboardText = Next() },
                "--clip" => options with { ClipPath = Next() },
                "--state-dir" => options with { StateDirectory = Next() },
                "--host-name" => options with { HostName = Next() },
                "--synthetic-capture" => options, // accepted for symmetry with the Mac host; always synthetic
                _ => throw new ArgumentException($"Unknown option {args[i]}."),
            };
        }
        if (options.Port == VantageProtocol.DefaultPort)
            throw new ArgumentException("Port 47820 belongs to the real host; use 47821 or above.");
        if (options.Platform is not (HostPlatforms.Windows or HostPlatforms.MacOS))
            throw new ArgumentException("--platform is windows or macos.");
        return options;
    }

    /// <summary>The clip: --clip, else assets/test-clip next to the build output or up the tree.</summary>
    public string ResolveClip()
    {
        if (ClipPath is not null) return ClipPath;
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, "assets", "test-clip", "clip-1600x1000.h264");
            if (File.Exists(candidate)) return candidate;
            directory = directory.Parent;
        }
        throw new FileNotFoundException("Can't find assets/test-clip/clip-1600x1000.h264; pass --clip.");
    }
}

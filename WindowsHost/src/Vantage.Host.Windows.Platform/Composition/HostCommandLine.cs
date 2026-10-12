using System.Globalization;
using Vantage.Host.Windows.Encode;
using Vantage.Protocol;

namespace Vantage.Host.Windows.Composition;

/// <summary>
/// Command-line flags shared by the console host and the app, named like the Mac DEBUG host's
/// (spec §11). Debug-only flags are refused by release builds. Pure; unit-tested on macOS.
/// </summary>
public sealed record HostCommandLine
{
    /// <summary><c>--port N</c>.</summary>
    public int Port { get; init; } = VantageProtocol.DefaultPort;

    /// <summary><c>--pairing-code NNNNNN</c> (debug): a fixed code that never expires.</summary>
    public string? PairingCode { get; init; }

    /// <summary><c>--exit-after S</c>: quit by itself after this long.</summary>
    public TimeSpan? ExitAfter { get; init; }

    /// <summary><c>--receive-folder PATH</c>: where received files go (overrides Settings).</summary>
    public string? ReceiveFolder { get; init; }

    /// <summary><c>--log-file PATH</c>.</summary>
    public string? LogFile { get; init; }

    /// <summary><c>--dump-h264 PATH</c>: also write the encoded stream (Annex-B) to this file.</summary>
    public string? DumpH264 { get; init; }

    /// <summary><c>--platform windows|macos</c>: what the host tells the client it is.</summary>
    public string Platform { get; init; } = HostPlatforms.Windows;

    /// <summary><c>--synthetic</c>: separate trust store, logged (not injected) input, in-memory clipboard, no power or lock actions.</summary>
    public bool Synthetic { get; init; }

    /// <summary><c>--background</c>: started at login; stay in the tray.</summary>
    public bool Background { get; init; }

    /// <summary><c>--encoder auto|hardware|software</c>.</summary>
    public EncoderPreference Encoder { get; init; } = EncoderPreference.Auto;

    /// <summary><c>--rate-control cbr|lowdelayvbr</c>.</summary>
    public RateControl RateControl { get; init; } = RateControl.Cbr;

    /// <summary><c>--send-file-on-connect PATH</c> (debug).</summary>
    public string? SendFileOnConnect { get; init; }

    /// <summary><c>--capture-fails-for S</c> (debug).</summary>
    public TimeSpan? CaptureFailsFor { get; init; }

    /// <summary><c>--verbose</c>: debug-level logging.</summary>
    public bool Verbose { get; init; }

    /// <summary>The usage text.</summary>
    public const string Usage = """
        Casement Host for Windows

          --port N                    listen on N (default 47820; tests use 47821+)
          --pairing-code NNNNNN       fixed pairing code that never expires (debug builds)
          --exit-after SECONDS        quit by itself
          --receive-folder PATH       save received files here
          --log-file PATH             also log to this file
          --dump-h264 PATH            append the encoded H.264 (Annex-B) to PATH
          --platform windows|macos    what the host reports itself as
          --synthetic                 separate trust store; log input instead of injecting it
          --encoder auto|hardware|software
          --rate-control cbr|lowdelayvbr
          --send-file-on-connect PATH send a file to each client that attaches (debug builds)
          --capture-fails-for SECONDS make capture fail at first (debug builds)
          --background                start in the tray (used at sign-in)
          --verbose                   debug logging
        """;

    /// <summary>Parses <paramref name="args"/>; throws <see cref="ArgumentException"/> with a user-facing message.</summary>
    /// <param name="args">The arguments.</param>
    /// <param name="debugBuild">Whether debug-only flags are allowed.</param>
    public static HostCommandLine Parse(IReadOnlyList<string> args, bool debugBuild)
    {
        var result = new HostCommandLine();
        for (var i = 0; i < args.Count; i++)
        {
            var arg = args[i];
            string Value()
            {
                if (i + 1 >= args.Count) throw new ArgumentException($"{arg} needs a value.");
                return args[++i];
            }
            void DebugOnly()
            {
                if (!debugBuild) throw new ArgumentException($"{arg} is only available in debug builds.");
            }

            switch (arg)
            {
                case "--port":
                    result = result with { Port = ParsePort(Value()) };
                    break;
                case "--pairing-code":
                    DebugOnly();
                    var code = Value();
                    if (code.Length != 6 || !code.All(char.IsAsciiDigit)) throw new ArgumentException("--pairing-code takes six digits.");
                    result = result with { PairingCode = code };
                    break;
                case "--exit-after":
                    result = result with { ExitAfter = ParseSeconds(arg, Value()) };
                    break;
                case "--receive-folder":
                    result = result with { ReceiveFolder = Value() };
                    break;
                case "--log-file":
                    result = result with { LogFile = Value() };
                    break;
                case "--dump-h264":
                    result = result with { DumpH264 = Value() };
                    break;
                case "--platform":
                    var platform = Value().ToLowerInvariant();
                    if (platform is not (HostPlatforms.Windows or HostPlatforms.MacOS)) throw new ArgumentException("--platform is windows or macos.");
                    result = result with { Platform = platform };
                    break;
                case "--synthetic":
                    result = result with { Synthetic = true };
                    break;
                case "--background":
                    result = result with { Background = true };
                    break;
                case "--encoder":
                    result = result with
                    {
                        Encoder = Value().ToLowerInvariant() switch
                        {
                            "auto" => EncoderPreference.Auto,
                            "hardware" => EncoderPreference.HardwareOnly,
                            "software" => EncoderPreference.SoftwareOnly,
                            _ => throw new ArgumentException("--encoder is auto, hardware or software."),
                        },
                    };
                    break;
                case "--rate-control":
                    result = result with
                    {
                        RateControl = Value().ToLowerInvariant() switch
                        {
                            "cbr" => RateControl.Cbr,
                            "lowdelayvbr" or "vbr" => RateControl.LowDelayVbr,
                            _ => throw new ArgumentException("--rate-control is cbr or lowdelayvbr."),
                        },
                    };
                    break;
                case "--send-file-on-connect":
                    DebugOnly();
                    result = result with { SendFileOnConnect = Value() };
                    break;
                case "--capture-fails-for":
                    DebugOnly();
                    result = result with { CaptureFailsFor = ParseSeconds(arg, Value()) };
                    break;
                case "--verbose":
                    result = result with { Verbose = true };
                    break;
                default:
                    throw new ArgumentException($"Unknown option {arg}.");
            }
        }
        return result;
    }

    private static int ParsePort(string text) =>
        int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var port) && port is > 0 and <= 65535
            ? port
            : throw new ArgumentException("--port takes a number from 1 to 65535.");

    private static TimeSpan ParseSeconds(string flag, string text) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds) && seconds > 0 && seconds < 1e7
            ? TimeSpan.FromSeconds(seconds)
            : throw new ArgumentException($"{flag} takes a number of seconds.");
}

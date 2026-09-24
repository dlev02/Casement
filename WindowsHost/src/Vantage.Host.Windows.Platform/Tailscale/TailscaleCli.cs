using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using Microsoft.Extensions.Logging;
using Vantage.Protocol.Host;

namespace Vantage.Host.Windows.Tailscale;

/// <summary>
/// The Tailscale CLI (<c>C:\Program Files\Tailscale\tailscale.exe</c>, else <c>tailscale.exe</c> on
/// PATH) as an <see cref="IPeerDirectory"/> (whois) and a source of this PC's tailnet address. Every
/// call gives up after 2 s; whois answers are cached per address (10 min, 30 s for misses). Never throws.
/// </summary>
public sealed class TailscaleCli : IPeerDirectory
{
    private static readonly TimeSpan s_timeout = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan s_hitLifetime = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan s_missLifetime = TimeSpan.FromSeconds(30);

    private readonly ILogger _log;
    private readonly string? _executable;
    private readonly ConcurrentDictionary<IPAddress, (PeerIdentity? Identity, DateTimeOffset Expires)> _cache = new();

    /// <param name="logging">Loggers (category <c>Vantage.Tailscale</c>).</param>
    /// <param name="executable">Override the CLI path (tests); null to find it.</param>
    public TailscaleCli(ILoggerFactory logging, string? executable = null)
    {
        _log = logging.CreateLogger("Vantage.Tailscale");
        _executable = executable ?? Find();
        if (_executable is null) _log.LogInformation("tailscale.exe not found; peers are named by their own Hello");
    }

    /// <summary>Whether the CLI was found.</summary>
    public bool IsAvailable => _executable is not null;

    /// <inheritdoc />
    public async Task<PeerIdentity?> WhoisAsync(IPAddress peer, CancellationToken cancellationToken)
    {
        if (_executable is null) return null;
        if (_cache.TryGetValue(peer, out var cached) && cached.Expires > DateTimeOffset.UtcNow) return cached.Identity;
        var output = await RunAsync(["whois", "--json", peer.ToString()], cancellationToken).ConfigureAwait(false);
        var identity = output is null ? null : TailscaleJson.ParseWhois(output);
        _cache[peer] = (identity, DateTimeOffset.UtcNow + (identity is null ? s_missLifetime : s_hitLifetime));
        return identity;
    }

    /// <summary>This PC on the tailnet, or null when Tailscale isn't installed or didn't answer.</summary>
    public async Task<TailscaleSelf?> GetSelfAsync(CancellationToken cancellationToken = default)
    {
        if (_executable is null) return null;
        var output = await RunAsync(["status", "--json"], cancellationToken).ConfigureAwait(false);
        return output is null ? null : TailscaleJson.ParseStatus(output);
    }

    private async Task<string?> RunAsync(string[] arguments, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(s_timeout);
        var start = new ProcessStartInfo(_executable!)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        Process? process = null;
        try
        {
            process = Process.Start(start);
            if (process is null) return null;
            var output = process.StandardOutput.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token).ConfigureAwait(false);
            var text = await output.ConfigureAwait(false);
            return process.ExitCode == 0 ? text : null;
        }
        catch (OperationCanceledException)
        {
            _log.LogDebug("tailscale {Command} timed out", arguments[0]);
            TryKill(process);
            return null;
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
        {
            _log.LogDebug("tailscale {Command} failed: {Message}", arguments[0], ex.Message);
            return null;
        }
        finally
        {
            process?.Dispose();
        }
    }

    private static void TryKill(Process? process)
    {
        try { process?.Kill(entireProcessTree: true); }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception) { }
    }

    private static string? Find()
    {
        foreach (var root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"C:\Program Files" })
        {
            if (string.IsNullOrEmpty(root)) continue;
            var candidate = Path.Combine(root, "Tailscale", "tailscale.exe");
            if (File.Exists(candidate)) return candidate;
        }
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(directory.Trim(), "tailscale.exe");
                if (File.Exists(candidate)) return candidate;
            }
            catch (ArgumentException)
            {
            }
        }
        return null;
    }
}

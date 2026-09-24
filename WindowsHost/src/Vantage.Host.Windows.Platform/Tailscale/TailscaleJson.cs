using System.Text.Json;
using Vantage.Protocol.Host;

namespace Vantage.Host.Windows.Tailscale;

/// <summary>This machine as <c>tailscale status --json</c> describes it.</summary>
/// <param name="BackendState">"Running", "Stopped", "NeedsLogin", …</param>
/// <param name="HostName">The OS host name Tailscale reports ("drew-pc").</param>
/// <param name="DnsName">MagicDNS name without the trailing dot ("drew-pc.tail1234.ts.net"), if any.</param>
/// <param name="Addresses">Tailnet addresses, IPv4 first.</param>
public sealed record TailscaleSelf(string BackendState, string? HostName, string? DnsName, IReadOnlyList<string> Addresses)
{
    /// <summary>Whether Tailscale is up.</summary>
    public bool IsRunning => string.Equals(BackendState, "Running", StringComparison.Ordinal);

    /// <summary>The IPv4 tailnet address, else the first one.</summary>
    public string? PrimaryAddress => Addresses.FirstOrDefault(a => !a.Contains(':', StringComparison.Ordinal)) ?? Addresses.FirstOrDefault();
}

/// <summary>Parses the Tailscale CLI's JSON. Pure; unit-tested on macOS.</summary>
public static class TailscaleJson
{
    /// <summary><c>tailscale whois --json IP</c> → who; null for anything unexpected.</summary>
    public static PeerIdentity? ParseWhois(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            string? login = null, display = null, device = null;
            if (root.TryGetProperty("UserProfile", out var profile) && profile.ValueKind == JsonValueKind.Object)
            {
                login = String(profile, "LoginName");
                display = String(profile, "DisplayName");
            }
            if (root.TryGetProperty("Node", out var node) && node.ValueKind == JsonValueKind.Object)
            {
                if (node.TryGetProperty("Hostinfo", out var hostinfo) && hostinfo.ValueKind == JsonValueKind.Object)
                    device = String(hostinfo, "Hostname");
                device ??= String(node, "ComputedName");
                if (device is null && String(node, "Name") is { } name) device = name.Split('.')[0];
            }
            if (login is null && display is null && device is null) return null;
            return new PeerIdentity(login, display, device);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary><c>tailscale status --json</c> → this machine; null for anything unexpected.</summary>
    public static TailscaleSelf? ParseStatus(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            var backend = String(root, "BackendState") ?? "Unknown";
            string? hostName = null, dnsName = null;
            var addresses = new List<string>();
            if (root.TryGetProperty("Self", out var self) && self.ValueKind == JsonValueKind.Object)
            {
                hostName = String(self, "HostName");
                dnsName = String(self, "DNSName")?.TrimEnd('.');
                if (dnsName is { Length: 0 }) dnsName = null;
                if (self.TryGetProperty("TailscaleIPs", out var ips) && ips.ValueKind == JsonValueKind.Array)
                {
                    foreach (var ip in ips.EnumerateArray())
                        if (ip.ValueKind == JsonValueKind.String && ip.GetString() is { Length: > 0 } text) addresses.Add(text);
                }
            }
            addresses.Sort((a, b) => a.Contains(':', StringComparison.Ordinal).CompareTo(b.Contains(':', StringComparison.Ordinal)));
            return new TailscaleSelf(backend, hostName, dnsName, addresses);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? String(JsonElement element, string name) =>
        element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text
            ? text
            : null;
}

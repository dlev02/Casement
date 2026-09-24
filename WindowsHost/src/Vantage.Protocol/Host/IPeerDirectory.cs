using System.Net;

namespace Vantage.Protocol.Host;

/// <summary>
/// Who a tailnet peer is (Windows: <c>tailscale.exe whois --json &lt;ip&gt;</c>). Optional: a host
/// without Tailscale's CLI returns null and the session carries on.
/// </summary>
public interface IPeerDirectory
{
    /// <summary>
    /// Looks up <paramref name="peer"/> (already mapped to IPv4 when it was IPv4-mapped). Must
    /// finish within about 2 s (give up and return null after that) and should cache per address.
    /// Never throws for "unknown" or "CLI missing": return null.
    /// </summary>
    Task<PeerIdentity?> WhoisAsync(IPAddress peer, CancellationToken cancellationToken);
}

/// <summary>What whois said about a peer.</summary>
/// <param name="LoginName"><c>UserProfile.LoginName</c>: sent as <c>Challenge.peerTailnetName</c>.</param>
/// <param name="DisplayName"><c>UserProfile.DisplayName</c>: used when there's no login name.</param>
/// <param name="DeviceName"><c>Node.Hostinfo.Hostname</c> (e.g. "Drew's iPad Pro"): names the device in the host UI, since iOS only reports "iPad".</param>
public sealed record PeerIdentity(string? LoginName, string? DisplayName, string? DeviceName)
{
    /// <summary>The name for <c>Challenge.peerTailnetName</c>: the login name, else the display name.</summary>
    public string? TailnetName => !string.IsNullOrEmpty(LoginName) ? LoginName : DisplayName;
}

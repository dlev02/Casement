using System.Net;
using System.Net.Sockets;

namespace Vantage.Protocol.Net;

/// <summary>Which peers may connect (spec §1; <c>TailscaleListener.isTailnetPeer</c>).</summary>
public static class PeerPolicy
{
    /// <summary>Maps an IPv4-mapped IPv6 address (<c>::ffff:a.b.c.d</c>) to plain IPv4; anything else unchanged.</summary>
    public static IPAddress Normalize(IPAddress address) => address.IsIPv4MappedToIPv6 ? address.MapToIPv4() : address;

    /// <summary>Tailscale's CGNAT range 100.64.0.0/10 or its ULA range fd7a:115c:a1e0::/48.</summary>
    public static bool IsTailnet(IPAddress address)
    {
        address = Normalize(address);
        Span<byte> bytes = stackalloc byte[16];
        if (!address.TryWriteBytes(bytes, out var written)) return false;
        return address.AddressFamily switch
        {
            AddressFamily.InterNetwork => written == 4 && bytes[0] == 100 && (bytes[1] & 0xC0) == 0x40,
            AddressFamily.InterNetworkV6 => written == 16 && bytes[0] == 0xFD && bytes[1] == 0x7A && bytes[2] == 0x11
                                            && bytes[3] == 0x5C && bytes[4] == 0xA1 && bytes[5] == 0xE0,
            _ => false,
        };
    }

    /// <summary>
    /// Whether a connection from <paramref name="address"/> is accepted: tailnet peers always,
    /// 127.0.0.1 / ::1 only when <paramref name="allowLoopback"/> (DEBUG builds). Everything else is
    /// closed without reading.
    /// </summary>
    public static bool IsAllowed(IPAddress address, bool allowLoopback)
    {
        address = Normalize(address);
        if (IsTailnet(address)) return true;
        return allowLoopback && IPAddress.IsLoopback(address);
    }
}

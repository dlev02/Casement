namespace Vantage.Protocol;

/// <summary>Protocol-level constants shared with the Swift client (<c>VantageProtocol.swift</c>).</summary>
public static class VantageProtocol
{
    /// <summary>Wire protocol version. A <c>hello</c> with any other value gets <c>versionMismatch</c>.</summary>
    public const ushort Version = 2;

    /// <summary>Default TCP port the host listens on (tailnet only).</summary>
    public const int DefaultPort = 47820;

    /// <summary>What <c>Challenge.hostVersion</c> says.</summary>
    public const string HostVersion = "1.0";
}

/// <summary>Values for <c>Challenge.hostPlatform</c> and <c>HostCapabilities.platform</c>.</summary>
public static class HostPlatforms
{
    public const string MacOS = "macos";
    public const string Windows = "windows";
}

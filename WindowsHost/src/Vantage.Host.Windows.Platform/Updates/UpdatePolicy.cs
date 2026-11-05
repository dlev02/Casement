namespace Vantage.Host.Windows.Updates;

/// <summary>What might be going on while an update waits to install (<see cref="UpdatePolicy"/>).</summary>
/// <param name="Connections">Sessions and file channels open now.</param>
/// <param name="ActiveTransfers">Files waiting, moving or paused.</param>
/// <param name="ShowingPairingCode">A pairing code is up: someone is about to connect.</param>
/// <param name="WindowOpen">The settings window or the tray panel is on screen.</param>
/// <param name="QuietFor">How long all of the above has been clear.</param>
public readonly record struct UpdateActivity(int Connections, int ActiveTransfers, bool ShowingPairingCode, bool WindowOpen, TimeSpan QuietFor)
{
    /// <summary>Nothing above is going on right now, however briefly.</summary>
    public bool IsClear => Connections == 0 && ActiveTransfers == 0 && !ShowingPairingCode && !WindowOpen;
}

/// <summary>When to check and when an unattended install may restart the host. Pure.</summary>
public static class UpdatePolicy
{
    /// <summary>How often the background check runs.</summary>
    public static readonly TimeSpan CheckInterval = TimeSpan.FromHours(24);

    /// <summary>The first check waits this long after launch, so signing in isn't slowed by it.</summary>
    public static readonly TimeSpan FirstCheckDelay = TimeSpan.FromMinutes(2);

    /// <summary>
    /// A device that just dropped is usually reconnecting (a network change, a sleeping iPad), so an
    /// install waits for this much quiet rather than taking the host away as it comes back.
    /// </summary>
    public static readonly TimeSpan QuietBeforeInstall = TimeSpan.FromMinutes(5);

    /// <summary>Whether a background check is due.</summary>
    /// <param name="automatic">The "Install updates automatically" setting: off means no background network at all.</param>
    /// <param name="sinceLaunch">How long the host has been running.</param>
    /// <param name="lastCheck">The last check, or null.</param>
    /// <param name="now">The time.</param>
    public static bool ShouldCheck(bool automatic, TimeSpan sinceLaunch, DateTimeOffset? lastCheck, DateTimeOffset now) =>
        automatic && sinceLaunch >= FirstCheckDelay && (lastCheck is not { } last || now - last >= CheckInterval || last > now);

    /// <summary>Whether a ready update may restart the host unasked.</summary>
    public static bool MayInstallUnattended(bool automatic, UpdateActivity activity) =>
        automatic && activity.IsClear && activity.QuietFor >= QuietBeforeInstall;
}

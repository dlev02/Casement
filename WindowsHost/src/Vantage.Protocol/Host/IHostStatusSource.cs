namespace Vantage.Protocol.Host;

/// <summary>
/// Lock, secure-desktop and display-power state (spec §8). The core turns it into
/// <c>HostStatus</c> messages and adds <c>isScreenUnavailable</c> itself from the capture watchdog.
/// </summary>
/// <remarks>
/// Windows: <c>WTSRegisterSessionNotification</c> (<c>WTS_SESSION_LOCK/UNLOCK</c>; initial state
/// from <c>WTSQuerySessionInformation(WTSSessionInfoEx)</c>), an <c>OpenInputDesktop</c> poll once a
/// second (secure desktop = it fails or its name isn't "Default"), and
/// <c>RegisterPowerSettingNotification(GUID_CONSOLE_DISPLAY_STATE)</c> (0 = off).
/// </remarks>
public interface IHostStatusSource
{
    /// <summary>The state right now. Cheap; called on every status change and at stream start.</summary>
    HostConditions Current { get; }

    /// <summary>
    /// Calls <paramref name="onChanged"/> (any thread) after any field of <see cref="Current"/>
    /// changes. Started with a session's first stream, disposed when the session ends.
    /// </summary>
    IDisposable Watch(Action onChanged);
}

/// <summary>Host conditions the client should hear about.</summary>
/// <param name="IsScreenLocked">The session is locked (Windows lock screen).</param>
/// <param name="IsSecureDesktop">
/// The secure desktop is up while the session isn't locked (UAC prompt, Ctrl+Alt+Del screen): input
/// can't reach it. Sent as <c>HostStatus.isSecureInputActive</c>.
/// </param>
/// <param name="IsDisplayAsleep">The console display is off. Sent as <c>HostStatus.isDisplayAsleep</c>.</param>
/// <param name="Message">
/// User-facing text for the banner, or null: e.g. "The PC is locked", "A Windows security prompt
/// is open on the PC".
/// </param>
public sealed record HostConditions(bool IsScreenLocked, bool IsSecureDesktop, bool IsDisplayAsleep, string? Message);

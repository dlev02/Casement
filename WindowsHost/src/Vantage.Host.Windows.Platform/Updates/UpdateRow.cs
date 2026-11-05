using System.Globalization;

namespace Vantage.Host.Windows.Updates;

/// <summary>What the Updates row's button does.</summary>
public enum UpdateRowAction
{
    /// <summary>Nothing to press: it's working.</summary>
    None,
    /// <summary>Check for updates.</summary>
    Check,
    /// <summary>Check again after a failure.</summary>
    TryAgain,
    /// <summary>Restart into the staged version.</summary>
    Restart,
    /// <summary>Open the release's page.</summary>
    Download,
}

/// <summary>The Updates row's wording for a status. Pure, so every state is tested without a window.</summary>
/// <param name="Description">The line under the version.</param>
/// <param name="Action">The button.</param>
public readonly record struct UpdateRow(string Description, UpdateRowAction Action)
{
    /// <summary>The button's label.</summary>
    public string ActionLabel => Action switch
    {
        UpdateRowAction.Check => "Check for updates",
        UpdateRowAction.TryAgain => "Try again",
        UpdateRowAction.Restart => "Restart to update",
        UpdateRowAction.Download => "Download…",
        _ => "",
    };

    /// <summary>The wording for <paramref name="status"/>.</summary>
    /// <param name="status">Where things stand.</param>
    /// <param name="automatic">The "Install updates automatically" setting.</param>
    /// <param name="lastCheck">When a check last got an answer.</param>
    /// <param name="now">The time.</param>
    public static UpdateRow For(UpdateStatus status, bool automatic, DateTimeOffset? lastCheck, DateTimeOffset now)
    {
        var version = status.Version;
        switch (status.Stage)
        {
            case UpdateStage.Checking:
                return new UpdateRow("Checking for updates…", UpdateRowAction.None);
            case UpdateStage.Downloading:
                return new UpdateRow(string.Create(CultureInfo.CurrentCulture, $"Downloading version {version}… {status.Fraction * 100:0}%"), UpdateRowAction.None);
            case UpdateStage.Ready:
                return new UpdateRow(automatic
                    ? $"Version {version} is ready. It installs by itself when no device is connected."
                    : $"Version {version} is ready to install.", UpdateRowAction.Restart);
            case UpdateStage.ManualOnly:
                return new UpdateRow($"Version {version} is out. Casement Host can't change this folder itself, so download it from GitHub.", UpdateRowAction.Download);
            case UpdateStage.Failed:
                return new UpdateRow($"Couldn't check for updates. {status.Message}", UpdateRowAction.TryAgain);
            case UpdateStage.RolledBack:
                return new UpdateRow($"Version {version} wouldn't start, so Casement Host went back to this version.", UpdateRowAction.TryAgain);
            case UpdateStage.UpToDate:
                return new UpdateRow(lastCheck is { } checkedAt ? $"You're up to date. Last checked {When(checkedAt, now)}." : "You're up to date.", UpdateRowAction.Check);
            default:
                return new UpdateRow(
                    lastCheck is { } last ? $"Last checked {When(last, now)}."
                    : automatic ? "Checks for updates once a day." : "Automatic updates are off.",
                    UpdateRowAction.Check);
        }
    }

    private static string When(DateTimeOffset time, DateTimeOffset now)
    {
        var local = time.ToLocalTime();
        var today = now.ToLocalTime().Date;
        var clock = local.ToString("t", CultureInfo.CurrentCulture);
        if (local.Date == today) return $"today at {clock}";
        if (local.Date == today.AddDays(-1)) return $"yesterday at {clock}";
        return local.ToString("MMMM d", CultureInfo.CurrentCulture);
    }
}

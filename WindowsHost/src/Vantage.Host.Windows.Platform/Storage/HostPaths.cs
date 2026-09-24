namespace Vantage.Host.Windows.Storage;

/// <summary>
/// Where the host keeps its files: <c>%LOCALAPPDATA%\Vantage Host\</c> (identity, trust list,
/// settings, logs), or <c>%LOCALAPPDATA%\Vantage Host (Synthetic)\</c> for synthetic/test runs so
/// they never share a trust list with the real host.
/// </summary>
public sealed class HostPaths
{
    /// <summary>Folder name of the real host's data.</summary>
    public const string RealFolderName = "Vantage Host";

    /// <summary>Folder name of synthetic/test hosts' data.</summary>
    public const string SyntheticFolderName = "Vantage Host (Synthetic)";

    /// <param name="root">The data folder (created on first use by the stores).</param>
    public HostPaths(string root) => Root = root;

    /// <summary>The standard location for the real or the synthetic host.</summary>
    public static HostPaths ForCurrentUser(bool synthetic) =>
        new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData,
                                                   Environment.SpecialFolderOption.DoNotVerify),
                         synthetic ? SyntheticFolderName : RealFolderName));

    /// <summary>The data folder.</summary>
    public string Root { get; }

    /// <summary>DPAPI blobs (identity.bin, trusted-clients.json) live directly in <see cref="Root"/>.</summary>
    public string SecretsDirectory => Root;

    /// <summary><c>settings.json</c> (plain JSON; nothing secret).</summary>
    public string SettingsFile => Path.Combine(Root, "settings.json");

    /// <summary>Log folder.</summary>
    public string LogsDirectory => Path.Combine(Root, "logs");

    /// <summary>The default log file (<c>logs\host.log</c>).</summary>
    public string DefaultLogFile => Path.Combine(LogsDirectory, "host.log");
}

using System.Text.Json;
using System.Text.Json.Serialization;

namespace Vantage.Host.Windows.Storage;

/// <summary>What happens after a file from the iPad is saved.</summary>
[JsonConverter(typeof(JsonStringEnumConverter<AfterArrival>))]
public enum AfterArrival
{
    /// <summary>Nothing beyond the notification.</summary>
    DoNothing,
    /// <summary>Open the receive folder in File Explorer with the file selected (the default, like the Mac's Show in Finder).</summary>
    ShowInFolder,
    /// <summary>Open the file with its default app (only for safe document/media types; others are shown in the folder).</summary>
    OpenFile,
}

/// <summary>
/// User settings (Settings window), stored as <c>settings.json</c> next to the identity. Settings
/// whose default isn't false/zero use <c>set</c>, not <c>init</c>: the source-generated reader
/// passes <c>default</c> for an <c>init</c> property the file lacks, so a file saved before a
/// setting existed would load it as false/zero instead of its default.
/// </summary>
public sealed record HostSettings
{
    /// <summary>Chosen receive folder, or null for Downloads.</summary>
    public string? ReceiveFolder { get; init; }

    /// <summary>What to do after a file arrives.</summary>
    public AfterArrival AfterArrival { get; set; } = AfterArrival.ShowInFolder;

    /// <summary>Show a notification when files arrive.</summary>
    public bool NotifyOnArrival { get; set; } = true;

    /// <summary>
    /// Start at login was turned on for the first launch or chosen since (it's on unless switched off,
    /// and the Run value itself is the switch).
    /// </summary>
    public bool StartAtLoginSettled { get; init; }

    /// <summary>Start through the elevated task (<c>AdminLaunch</c>) so input reaches administrator apps.</summary>
    public bool ControlAdminApps { get; init; }

    /// <summary>
    /// Hold a sign-out, restart or shutdown on Windows' "This app is preventing restart" screen while
    /// a device is connected (<c>RestartGuard</c>; on by default, like the Mac's).
    /// </summary>
    public bool AskBeforeRestart { get; set; } = true;

    /// <summary>
    /// Let a device that asks for a display fitted to its screen switch the shared display's mode
    /// while it's connected (<c>DisplayFitter</c>; the mode comes back afterwards). On by default.
    /// </summary>
    public bool AllowDisplayFitting { get; set; } = true;

    /// <summary>The "still running in the system tray" notification was shown (once, the first time the window is closed).</summary>
    public bool TrayHintShown { get; init; }

    /// <summary>
    /// Check GitHub once a day and install updates at a quiet moment. Off, nothing touches the network
    /// until someone presses Check for updates. On by default.
    /// </summary>
    public bool InstallUpdatesAutomatically { get; set; } = true;

    /// <summary>When a check last got an answer.</summary>
    public DateTimeOffset? LastUpdateCheck { get; init; }
}

/// <summary>Loads and saves <see cref="HostSettings"/>; thread-safe.</summary>
public sealed class HostSettingsStore
{
    private readonly string _path;
    private readonly Lock _lock = new();
    private HostSettings _current;

    /// <param name="path">The settings file (its folder is created on save).</param>
    public HostSettingsStore(string path)
    {
        _path = path;
        _current = Load(path);
    }

    /// <summary>Raised (any thread) after <see cref="Update"/> changed the settings.</summary>
    public event Action<HostSettings>? Changed;

    /// <summary>The settings now.</summary>
    public HostSettings Current
    {
        get { lock (_lock) return _current; }
    }

    /// <summary>Applies <paramref name="change"/> and saves.</summary>
    public HostSettings Update(Func<HostSettings, HostSettings> change)
    {
        HostSettings next;
        lock (_lock)
        {
            next = change(_current);
            if (next == _current) return next;
            _current = next;
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temp = _path + ".tmp";
            File.WriteAllBytes(temp, JsonSerializer.SerializeToUtf8Bytes(next, HostSettingsJson.Default.HostSettings));
            File.Move(temp, _path, overwrite: true);
        }
        Changed?.Invoke(next);
        return next;
    }

    private static HostSettings Load(string path)
    {
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize(File.ReadAllBytes(path), HostSettingsJson.Default.HostSettings) ?? new HostSettings();
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
        {
        }
        return new HostSettings();
    }
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = true)]
[JsonSerializable(typeof(HostSettings))]
internal sealed partial class HostSettingsJson : JsonSerializerContext;

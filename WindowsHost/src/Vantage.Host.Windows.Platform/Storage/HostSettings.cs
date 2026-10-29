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

/// <summary>User settings (Settings window), stored as <c>settings.json</c> next to the identity.</summary>
public sealed record HostSettings
{
    /// <summary>Chosen receive folder, or null for Downloads.</summary>
    public string? ReceiveFolder { get; init; }

    /// <summary>What to do after a file arrives.</summary>
    public AfterArrival AfterArrival { get; init; } = AfterArrival.ShowInFolder;

    /// <summary>Show a notification when files arrive.</summary>
    public bool NotifyOnArrival { get; init; } = true;

    /// <summary>
    /// Start at login was turned on for the first launch or chosen since (it's on unless switched off,
    /// and the Run value itself is the switch).
    /// </summary>
    public bool StartAtLoginSettled { get; init; }

    /// <summary>Start through the elevated task (<c>AdminLaunch</c>) so input reaches administrator apps.</summary>
    public bool ControlAdminApps { get; init; }
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

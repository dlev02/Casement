using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using Microsoft.Extensions.Logging;

namespace Vantage.Host.Windows.Logging;

/// <summary>
/// A small append-only file logger (<c>--log-file</c>, and <c>logs\host.log</c> for the app):
/// one line per entry, <c>2026-09-24 14:03:11.482 info  Vantage.Session: message</c>, written by a
/// background thread so logging never blocks the capture or encode path. The file is rotated to
/// <c>.1</c> when it passes <see cref="MaxBytes"/> at startup.
/// </summary>
public sealed class FileLoggerProvider : ILoggerProvider
{
    /// <summary>Size at which the previous log is rotated away at startup.</summary>
    public const long MaxBytes = 10 * 1024 * 1024;

    private readonly BlockingCollection<string> _lines = new(boundedCapacity: 10_000);
    private readonly Thread _writer;
    private readonly LogLevel _minimum;

    /// <param name="path">The log file (folder created if missing).</param>
    /// <param name="minimum">Lowest level written.</param>
    public FileLoggerProvider(string path, LogLevel minimum = LogLevel.Debug)
    {
        _minimum = minimum;
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        try
        {
            var info = new FileInfo(path);
            if (info.Exists && info.Length > MaxBytes) File.Move(path, path + ".1", overwrite: true);
        }
        catch (IOException)
        {
        }
        var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
        var output = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = false };
        _writer = new Thread(() => Pump(output)) { IsBackground = true, Name = "Vantage log writer" };
        _writer.Start();
    }

    /// <inheritdoc />
    public ILogger CreateLogger(string categoryName) => new FileLogger(this, categoryName);

    /// <inheritdoc />
    public void Dispose()
    {
        _lines.CompleteAdding();
        _writer.Join(TimeSpan.FromSeconds(2));
    }

    private void Enqueue(string line)
    {
        if (!_lines.IsAddingCompleted) _lines.TryAdd(line);
    }

    private void Pump(StreamWriter output)
    {
        using (output)
        {
            foreach (var line in _lines.GetConsumingEnumerable())
            {
                output.WriteLine(line);
                if (_lines.Count == 0) output.Flush();
            }
        }
    }

    /// <summary>Formats one entry (also used by tests).</summary>
    internal static string Format(DateTimeOffset time, LogLevel level, string category, string message, Exception? exception)
    {
        var builder = new StringBuilder(64 + message.Length);
        builder.Append(time.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture));
        builder.Append(' ').Append(LevelName(level)).Append(' ').Append(category).Append(": ").Append(message);
        if (exception is not null) builder.Append(Environment.NewLine).Append(exception);
        return builder.ToString();
    }

    private static string LevelName(LogLevel level) => level switch
    {
        LogLevel.Trace => "trace",
        LogLevel.Debug => "debug",
        LogLevel.Information => "info ",
        LogLevel.Warning => "warn ",
        LogLevel.Error => "error",
        LogLevel.Critical => "crit ",
        _ => "     ",
    };

    private sealed class FileLogger(FileLoggerProvider owner, string category) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => logLevel >= owner._minimum && logLevel != LogLevel.None;

        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            if (!IsEnabled(logLevel)) return;
            owner.Enqueue(Format(DateTimeOffset.Now, logLevel, category, formatter(state, exception), exception));
        }
    }
}

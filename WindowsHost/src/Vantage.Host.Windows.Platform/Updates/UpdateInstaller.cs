using System.Diagnostics;
using System.Globalization;

namespace Vantage.Host.Windows.Updates;

/// <summary>
/// Swaps a verified update into the install folder, and undoes it if the new version won't start.
///
/// The folder keeps its path, because the Run value, the administrator task, the firewall rule, the
/// Start menu shortcut and the tray icon's "show next to the clock" choice all name that path. The
/// staged copy sits beside it (<c>Casement Host.update</c>), on the same drive. A running exe can't
/// replace itself, so the staged copy's own exe does it (<see cref="Finish"/>): it waits for the old
/// host to quit, renames the install folder aside, copies itself in, starts the result, and watches
/// the pending file, which only a new host that got as far as listening deletes
/// (<see cref="MarkHealthy"/>). No word within <see cref="HealthTimeout"/> puts the old folder back,
/// and that version is skipped until someone asks for it (<see cref="SkipFile"/>).
/// </summary>
public static class UpdateInstaller
{
    /// <summary>The app's executable name in every install.</summary>
    public const string ExecutableName = "VantageHost.exe";

    /// <summary>How long a new version gets to start listening: long enough for a cold start behind an antivirus scan.</summary>
    public static readonly TimeSpan HealthTimeout = TimeSpan.FromSeconds(120);

    /// <summary>How long a staged copy gets to say it runs, before the host stays put.</summary>
    public static readonly TimeSpan SwapperTimeout = TimeSpan.FromSeconds(20);

    /// <summary>The flag that runs a staged exe as the swapper instead of the app.</summary>
    public const string FinishFlag = "--finish-update";

    /// <summary>Where the update is staged, beside <paramref name="install"/>.</summary>
    public static string StagedDirectory(string install) => TrimEnd(install) + ".update";

    /// <summary>Where the current version waits during a swap, beside <paramref name="install"/>.</summary>
    public static string OldDirectory(string install) => TrimEnd(install) + ".old";

    /// <summary>Exists from the moment a swap is asked for until a new host says it started.</summary>
    public static string PendingFile(string updates) => Path.Combine(updates, "pending");

    /// <summary>The version that failed to start, which background checks then skip.</summary>
    public static string SkipFile(string updates) => Path.Combine(updates, "skip-version");

    /// <summary>The swapper writes this as soon as it runs, which is what lets the host quit.</summary>
    public static string AckFile(string updates) => Path.Combine(updates, "swapper-running");

    /// <summary>The swapper's own log: it runs while the host's log is closed.</summary>
    public static string LogFile(string updates) => Path.Combine(updates, "update.log");

    /// <summary>
    /// Whether this copy can be replaced in place: a folder made beside it can be created. A copy
    /// unzipped under Program Files can't, and gets told to download instead.
    /// </summary>
    public static bool CanReplace(string install)
    {
        var probe = TrimEnd(install) + ".probe";
        try
        {
            Directory.CreateDirectory(probe);
            Directory.Delete(probe);
            return File.Exists(Path.Combine(install, ExecutableName));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>
    /// Starts the staged exe as the swapper, waiting for process <paramref name="hostPid"/> to quit,
    /// and waits for it to say it's running. Called before the host quits: a copy Windows refuses to
    /// run, or one too broken to get as far as that word, leaves the host running. Without this, a bad
    /// release would take a PC nobody is sitting at off the air for good. False when it didn't start.
    /// </summary>
    /// <param name="install">The install folder.</param>
    /// <param name="updates">The updates folder.</param>
    /// <param name="hostPid">This process.</param>
    /// <param name="passThrough">Arguments for the swapper to hand the new host (debug runs only).</param>
    public static async Task<bool> StartSwapAsync(string install, string updates, int hostPid, IEnumerable<string> passThrough)
    {
        Process? swapper = null;
        try
        {
            Directory.CreateDirectory(updates);
            File.Delete(AckFile(updates));
            File.WriteAllText(PendingFile(updates), hostPid.ToString(CultureInfo.InvariantCulture));
            var staged = StagedDirectory(install);
            var start = new ProcessStartInfo(Path.Combine(staged, ExecutableName))
            {
                UseShellExecute = false,
                WorkingDirectory = staged,
            };
            start.ArgumentList.Add(FinishFlag);
            start.ArgumentList.Add(hostPid.ToString(CultureInfo.InvariantCulture));
            foreach (var argument in passThrough) start.ArgumentList.Add(argument);
            swapper = Process.Start(start);
            var waited = Stopwatch.StartNew();
            while (swapper is not null && !swapper.HasExited && waited.Elapsed < SwapperTimeout)
            {
                if (File.Exists(AckFile(updates))) return true;
                await Task.Delay(100);
            }
            if (swapper is { HasExited: false }) swapper.Kill();
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
        }
        finally
        {
            swapper?.Dispose();
        }
        try { File.Delete(PendingFile(updates)); } catch (Exception inner) when (inner is IOException or UnauthorizedAccessException) { }
        return false;
    }

    /// <summary>
    /// A new host got as far as listening (or reporting why it can't): the swapper may stop watching.
    /// Every launch calls it, so a pending file left by a crash can't linger.
    /// </summary>
    public static void MarkHealthy(string updates)
    {
        try { File.Delete(PendingFile(updates)); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Removes what a finished swap leaves behind. Safe while the swapper is exiting: it just tries again next launch.</summary>
    public static void CleanUp(string install, string updates)
    {
        if (File.Exists(PendingFile(updates))) return;
        foreach (var leftover in new[] { StagedDirectory(install), OldDirectory(install), StagedDirectory(install) + ".tmp" })
        {
            try
            {
                if (Directory.Exists(leftover)) Directory.Delete(leftover, recursive: true);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>What the swapper does to the outside world, so tests can run it on plain folders.</summary>
    /// <param name="Install">The install folder.</param>
    /// <param name="Updates">The updates folder.</param>
    /// <param name="WaitForHostExit">Waits for the old host to quit.</param>
    /// <param name="StartHost">Starts the exe in the install folder.</param>
    /// <param name="StopHost">Stops a new host that didn't report in.</param>
    /// <param name="Log">Writes a line to the swapper's log.</param>
    public sealed record SwapEnvironment(string Install, string Updates, Action WaitForHostExit, Action StartHost, Action StopHost, Action<string> Log)
    {
        /// <summary>How long to wait for the new host.</summary>
        public TimeSpan HealthTimeout { get; init; } = UpdateInstaller.HealthTimeout;

        /// <summary>How often to look, and to retry a folder an antivirus is holding.</summary>
        public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(1);
    }

    /// <summary>How a swap ended.</summary>
    public enum SwapResult
    {
        /// <summary>The new version is running.</summary>
        Installed,
        /// <summary>It couldn't be put in place, or didn't start; the old version is back.</summary>
        RolledBack,
    }

    /// <summary>The swap itself. <paramref name="staged"/> is the running copy, and <paramref name="version"/> its version.</summary>
    public static SwapResult Finish(string staged, string version, SwapEnvironment environment)
    {
        var (install, updates) = (environment.Install, environment.Updates);
        var old = OldDirectory(install);
        Directory.CreateDirectory(updates);
        File.WriteAllText(AckFile(updates), version);
        environment.WaitForHostExit();
        environment.Log($"swapping in {version}");
        try
        {
            if (Directory.Exists(old)) Directory.Delete(old, recursive: true);
            Retry(() => Directory.Move(install, old), environment);
            CopyDirectory(staged, install);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            environment.Log($"couldn't put {version} in place: {ex.Message}");
            return RollBack(version, environment);
        }

        environment.StartHost();
        var deadline = Stopwatch.StartNew();
        while (deadline.Elapsed < environment.HealthTimeout)
        {
            if (!File.Exists(PendingFile(updates)))
            {
                environment.Log($"{version} started");
                try { File.Delete(SkipFile(updates)); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
                return SwapResult.Installed;
            }
            Thread.Sleep(environment.PollInterval);
        }
        environment.Log($"{version} didn't report in within {environment.HealthTimeout.TotalSeconds:0} s");
        environment.StopHost();
        return RollBack(version, environment);
    }

    private static SwapResult RollBack(string version, SwapEnvironment environment)
    {
        var (install, updates) = (environment.Install, environment.Updates);
        var old = OldDirectory(install);
        try
        {
            if (Directory.Exists(old))
            {
                Retry(() =>
                {
                    if (Directory.Exists(install)) Directory.Delete(install, recursive: true);
                    Directory.Move(old, install);
                }, environment);
            }
            File.WriteAllText(SkipFile(updates), version);
            environment.Log($"went back from {version}");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Nothing more can be done from here; the old version is still whole in the .old folder.
            environment.Log($"couldn't restore the old version: {ex.Message}");
        }
        try { File.Delete(PendingFile(updates)); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        environment.StartHost();
        return SwapResult.RolledBack;
    }

    /// <summary>An antivirus or Explorer often holds a just-used folder for a moment.</summary>
    private static void Retry(Action action, SwapEnvironment environment)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                action();
                return;
            }
            catch (Exception ex) when (attempt < 30 && ex is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(environment.PollInterval);
            }
        }
    }

    private static void CopyDirectory(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var directory in Directory.EnumerateDirectories(from, "*", SearchOption.AllDirectories))
            Directory.CreateDirectory(Path.Combine(to, Path.GetRelativePath(from, directory)));
        foreach (var file in Directory.EnumerateFiles(from, "*", SearchOption.AllDirectories))
            File.Copy(file, Path.Combine(to, Path.GetRelativePath(from, file)), overwrite: true);
    }

    private static string TrimEnd(string path) => path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
}

using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Vantage.Host.Windows.Input;
using Vantage.Host.Windows.Startup;
using Vantage.Host.Windows.Storage;
using Vantage.Host.Windows.Updates;

namespace Vantage.Host.Windows.App;

/// <summary>
/// Entry point (the XAML-generated Main is disabled): one Vantage Host per user. A second launch
/// (the Start menu shortcut, or the Run key while it's already running) hands its activation to the
/// first, which opens its window, and exits. With "Control apps running as administrator" on, a
/// launch that isn't elevated starts the elevated task instead (<see cref="AdminLaunch"/>) and exits.
/// </summary>
public static class Program
{
    /// <summary>Key the running instance registers under.</summary>
    public const string InstanceKey = "VantageHost";

    [STAThread]
    private static int Main(string[] args)
    {
        // A staged update running as the swapper: no window, no instance key, no XAML.
        if (args is [UpdateInstaller.FinishFlag, ..]) return FinishUpdate(args);
#if DEBUG
        // The end-to-end run's stand-in for a release that won't start.
        if (File.Exists(Path.Combine(AppContext.BaseDirectory, "crash-on-start.txt"))) return 3;
#endif

        WinRT.ComWrappersSupport.InitializeComWrappers();

        var current = AppInstance.GetCurrent();
#if DEBUG
        // A synthetic copy from a checkout runs beside the installed host instead of handing off to it.
        var main = AppInstance.FindOrRegisterForKey(args.Contains("--synthetic") ? InstanceKey + ".Synthetic" : InstanceKey);
#else
        // --synthetic is refused here, so a copy started with it is a real host: still one per user.
        var main = AppInstance.FindOrRegisterForKey(InstanceKey);
#endif
        if (!main.IsCurrent)
        {
            var activation = current.GetActivatedEventArgs();
            // Redirect off the STA thread: waiting on it here would block the COM call it needs.
            Task.Run(() => main.RedirectActivationToAsync(activation).AsTask()).Wait(TimeSpan.FromSeconds(5));
            return 0;
        }

        if (ShouldRelaunchElevated(args))
        {
            // Let the elevated copy register as the running instance.
            main.UnregisterKey();
            if (Task.Run(AdminLaunch.RunAsync).GetAwaiter().GetResult()) return 0;
            AppInstance.FindOrRegisterForKey(InstanceKey);
        }

        Application.Start(callback =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App(args);
        });
        return 0;
    }

    /// <summary>
    /// <c>--finish-update PID</c>, run from the staged folder (<see cref="UpdateInstaller"/>). The
    /// folder to replace is worked out from where this copy is, never taken from the command line, so
    /// the flag can't aim it at anything else: a copy that isn't in a ".update" folder does nothing.
    /// </summary>
    private static int FinishUpdate(string[] args)
    {
        var staged = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        const string suffix = ".update";
        if (!staged.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) || args.Length < 2 || !int.TryParse(args[1], out var hostPid)) return 1;
        var install = staged[..^suffix.Length];
        var exe = Path.Combine(install, UpdateInstaller.ExecutableName);
#if DEBUG
        var passThrough = args[2..];
#else
        string[] passThrough = [];
#endif
        var updates = HostPaths.ForCurrentUser(synthetic: passThrough.Contains("--synthetic")).UpdatesDirectory;
        var version = FileVersionInfo.GetVersionInfo(Path.Combine(staged, UpdateInstaller.ExecutableName)).ProductVersion ?? "the new version";
        var environment = new UpdateInstaller.SwapEnvironment(
            install,
            updates,
            WaitForHostExit: () =>
            {
                try
                {
                    using var host = Process.GetProcessById(hostPid);
                    if (!host.WaitForExit(TimeSpan.FromSeconds(30))) host.Kill();
                    host.WaitForExit(TimeSpan.FromSeconds(5));
                }
                catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
                {
                    // Already gone.
                }
            },
            StartHost: () =>
            {
                // Started by itself, with no window, like a launch at sign-in. Through this same exe path
                // the administrator setting still applies: a launch that isn't elevated goes through its task.
                var start = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = install };
                start.ArgumentList.Add("--background");
                foreach (var argument in passThrough) start.ArgumentList.Add(argument);
                try { Process.Start(start)?.Dispose(); }
                catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or IOException) { LogSwap(updates, $"couldn't start {exe}: {ex.Message}"); }
            },
            StopHost: () =>
            {
                foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(exe)))
                {
                    try
                    {
                        if (process.Id != Environment.ProcessId && string.Equals(process.MainModule?.FileName, exe, StringComparison.OrdinalIgnoreCase)) process.Kill();
                    }
                    catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
                    {
                    }
                    process.Dispose();
                }
                Thread.Sleep(1000);
            },
            Log: line => LogSwap(updates, line));
        return UpdateInstaller.Finish(staged, version, environment) == UpdateInstaller.SwapResult.Installed ? 0 : 2;
    }

    private static void LogSwap(string updates, string line)
    {
        try
        {
            Directory.CreateDirectory(updates);
            File.AppendAllText(UpdateInstaller.LogFile(updates), $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss} {line}{Environment.NewLine}");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static bool ShouldRelaunchElevated(string[] args)
    {
        if (ElevatedWindows.ThisProcessIsElevated || args.Contains("--synthetic")) return false;
        try
        {
            return new HostSettingsStore(HostPaths.ForCurrentUser(synthetic: false).SettingsFile).Current.ControlAdminApps;
        }
        catch (Exception)
        {
            return false;
        }
    }
}

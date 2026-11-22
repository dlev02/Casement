using System.Diagnostics;
using System.Security.Principal;
using System.ServiceProcess;
using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.DesktopHelper;
using Vantage.Protocol.Auth;

namespace Vantage.Host.Windows.Service;

/// <summary>
/// <c>install</c> and <c>uninstall</c>, run elevated by Casement Host (one UAC prompt at the PC).
/// Exit code 0 means done.
/// </summary>
internal static class Installer
{
    /// <summary>The task the old "Control apps running as administrator" registered (<c>AdminLaunch.TaskName</c>).</summary>
    private const string LegacyTaskName = "Casement Host";

    public static int Install(ILogger log)
    {
        if (!IsElevated()) return Fail(log, "install must run as administrator");
        var source = Environment.ProcessPath!;
        log.LogInformation("installing from {Source}", source);

        StopService(log);
        Directory.CreateDirectory(HelperInstall.InstallFolder);
        if (!string.Equals(Path.GetFullPath(source), Path.GetFullPath(HelperInstall.InstalledExecutable), StringComparison.OrdinalIgnoreCase))
            CopyWithRetry(source, HelperInstall.InstalledExecutable);
        HelperInstall.CreateKeys(new NSecEd25519());

        var binPath = $"\"{HelperInstall.InstalledExecutable}\" service";
        var exists = ServiceExists();
        var created = exists
            ? Sc(log, "config", HelperInstall.ServiceName, "binPath=", binPath, "start=", "auto", "obj=", "LocalSystem", "DisplayName=", HelperInstall.DisplayName)
            : Sc(log, "create", HelperInstall.ServiceName, "binPath=", binPath, "start=", "auto", "obj=", "LocalSystem", "DisplayName=", HelperInstall.DisplayName);
        if (created != 0) return Fail(log, $"sc {(exists ? "config" : "create")} failed ({created})");
        Sc(log, "description", HelperInstall.ServiceName,
           "Lets Casement Host show and control this PC's lock screen and administrator prompts, and apps that run as administrator, for a device you've paired.");
        Sc(log, "failure", HelperInstall.ServiceName, "reset=", "86400", "actions=", "restart/5000/restart/5000/restart/30000");
        if (Sc(log, "start", HelperInstall.ServiceName) != 0) return Fail(log, "the service didn't start");

        // The elevated launch task this replaces could be started by any program running as the user.
        if (Run(log, Path.Combine(Environment.SystemDirectory, "schtasks.exe"), "/Delete", "/TN", LegacyTaskName, "/F") == 0)
            log.LogInformation("removed the old elevated launch task");
        log.LogInformation("installed");
        return 0;
    }

    public static int Uninstall(ILogger log)
    {
        if (!IsElevated()) return Fail(log, "uninstall must run as administrator");
        StopService(log);
        if (ServiceExists() && Sc(log, "delete", HelperInstall.ServiceName) != 0) return Fail(log, "sc delete failed");

        var self = Path.GetFullPath(Environment.ProcessPath!);
        foreach (var folder in new[] { HelperInstall.InstallFolder, HelperInstall.PrivateFolder })
        {
            if (!Directory.Exists(folder)) continue;
            foreach (var file in Directory.EnumerateFiles(folder))
            {
                if (string.Equals(Path.GetFullPath(file), self, StringComparison.OrdinalIgnoreCase)) continue;
                if (file.EndsWith("uninstall.log", StringComparison.OrdinalIgnoreCase)) continue;
                try { File.Delete(file); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { log.LogWarning("couldn't delete {File}: {Message}", file, ex.Message); }
            }
        }
        try { Directory.Delete(HelperInstall.InstallFolder); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        log.LogInformation("uninstalled");
        return 0;
    }

    private static bool ServiceExists() => HelperInstall.IsInstalled;

    private static void StopService(ILogger log)
    {
        if (!ServiceExists()) return;
        try
        {
            using var service = new ServiceController(HelperInstall.ServiceName);
            if (service.Status is ServiceControllerStatus.Stopped) return;
            service.Stop();
            service.WaitForStatus(ServiceControllerStatus.Stopped, TimeSpan.FromSeconds(15));
            log.LogInformation("service stopped");
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ServiceProcess.TimeoutException)
        {
            log.LogWarning("stopping the service: {Message}", ex.Message);
        }
        // Its helpers end with it; give the files a moment to be released.
        foreach (var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(HelperInstall.ExecutableName)))
        {
            using (process)
            {
                if (process.Id == Environment.ProcessId) continue;
                try
                {
                    if (string.Equals(process.MainModule?.FileName, HelperInstall.InstalledExecutable, StringComparison.OrdinalIgnoreCase))
                    {
                        process.Kill();
                        process.WaitForExit(5000);
                    }
                }
                catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception) { }
            }
        }
    }

    private static void CopyWithRetry(string source, string destination)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                File.Copy(source, destination, overwrite: true);
                return;
            }
            catch (IOException) when (attempt < 10)
            {
                Thread.Sleep(500);
            }
        }
    }

    private static int Sc(ILogger log, params string[] arguments) =>
        Run(log, Path.Combine(Environment.SystemDirectory, "sc.exe"), arguments);

    private static int Run(ILogger log, string program, params string[] arguments)
    {
        var info = new ProcessStartInfo(program) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        using var process = Process.Start(info)!;
        var output = process.StandardOutput.ReadToEnd() + process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0) log.LogInformation("{Program} {Arguments}: {Code} {Output}", Path.GetFileName(program), string.Join(' ', arguments), process.ExitCode, output.Trim());
        return process.ExitCode;
    }

    private static bool IsElevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static int Fail(ILogger log, string message)
    {
        log.LogError("{Message}", message);
        return 1;
    }
}

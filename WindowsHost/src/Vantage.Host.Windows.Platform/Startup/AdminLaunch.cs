using System.ComponentModel;
using System.Diagnostics;
using System.Security;
using System.Security.Principal;
using System.Text;

namespace Vantage.Host.Windows.Startup;

/// <summary>
/// "Control apps running as administrator": a Task Scheduler task, <c>Casement Host</c>, that starts
/// the host with the user's full (elevated) token and has no trigger. Registering it takes one UAC
/// prompt; after that a normal launch (the Run value, the Start menu) runs the task instead
/// (<c>schtasks /Run</c>, no prompt), so the host can send input to elevated windows such as Task
/// Manager, which UIPI otherwise drops. A UAC prompt is on the secure desktop, so it must be
/// answered at the PC.
/// </summary>
public static class AdminLaunch
{
    /// <summary>The task's name in Task Scheduler.</summary>
    public const string TaskName = "Casement Host";

    /// <summary>The task's definition. Pure.</summary>
    /// <param name="executablePath">The host's executable.</param>
    /// <param name="userSid">The signed-in user's SID (the task runs in their session only).</param>
    public static string TaskXml(string executablePath, string userSid) => $"""
        <?xml version="1.0" encoding="UTF-16"?>
        <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
          <RegistrationInfo>
            <Description>Starts Casement Host as administrator so it can control apps that run as administrator.</Description>
          </RegistrationInfo>
          <Principals>
            <Principal id="Author">
              <UserId>{SecurityElement.Escape(userSid)}</UserId>
              <LogonType>InteractiveToken</LogonType>
              <RunLevel>HighestAvailable</RunLevel>
            </Principal>
          </Principals>
          <Settings>
            <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
            <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
            <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
            <AllowHardTerminate>false</AllowHardTerminate>
            <StartWhenAvailable>false</StartWhenAvailable>
            <AllowStartOnDemand>true</AllowStartOnDemand>
            <Enabled>true</Enabled>
            <Hidden>false</Hidden>
            <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
            <Priority>4</Priority>
          </Settings>
          <Actions Context="Author">
            <Exec>
              <Command>"{SecurityElement.Escape(executablePath)}"</Command>
              <WorkingDirectory>{SecurityElement.Escape(Path.GetDirectoryName(executablePath) ?? "")}</WorkingDirectory>
            </Exec>
          </Actions>
        </Task>
        """;

    /// <summary>
    /// Registers (or replaces) the task, asking Windows for permission unless this process is
    /// already elevated. False when the user declined or it failed.
    /// </summary>
    public static async Task<bool> RegisterAsync(string executablePath)
    {
        using var identity = WindowsIdentity.GetCurrent();
        var sid = identity.User?.Value ?? throw new InvalidOperationException("no user SID");
        var file = Path.Combine(Path.GetTempPath(), $"casement-host-task-{Guid.NewGuid():N}.xml");
        await File.WriteAllTextAsync(file, TaskXml(executablePath, sid), Encoding.Unicode);
        try
        {
            return await SchtasksAsync(elevate: true, "/Create", "/TN", TaskName, "/XML", file, "/F") == 0;
        }
        finally
        {
            try { File.Delete(file); } catch (IOException) { }
        }
    }

    /// <summary>Starts the task (elevated, no prompt). False when it isn't registered or didn't start.</summary>
    public static async Task<bool> RunAsync() => await SchtasksAsync(elevate: false, "/Run", "/TN", TaskName) == 0;

    /// <summary>Deletes the task (asks for permission unless elevated). False when it failed.</summary>
    public static async Task<bool> UnregisterAsync() =>
        await SchtasksAsync(elevate: false, "/Query", "/TN", TaskName) != 0
        || await SchtasksAsync(elevate: true, "/Delete", "/TN", TaskName, "/F") == 0;

    private static async Task<int> SchtasksAsync(bool elevate, params string[] arguments)
    {
        var path = Path.Combine(Environment.SystemDirectory, "schtasks.exe");
        ProcessStartInfo info;
        if (elevate && !Input.ElevatedWindows.ThisProcessIsElevated)
        {
            // "runas" needs the shell, which takes one command-line string.
            info = new ProcessStartInfo(path, string.Join(' ', arguments.Select(Quote)))
            {
                UseShellExecute = true,
                Verb = "runas",
                WindowStyle = ProcessWindowStyle.Hidden,
            };
        }
        else
        {
            info = new ProcessStartInfo(path) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var argument in arguments) info.ArgumentList.Add(argument);
        }

        try
        {
            using var process = Process.Start(info);
            if (process is null) return -1;
            if (!info.UseShellExecute)
            {
                // Drain the pipes so a chatty schtasks never blocks.
                _ = process.StandardOutput.ReadToEndAsync();
                _ = process.StandardError.ReadToEndAsync();
            }
            await process.WaitForExitAsync();
            return process.ExitCode;
        }
        catch (Win32Exception)
        {
            // 1223: the user chose No on the UAC prompt.
            return -1;
        }
    }

    private static string Quote(string argument) =>
        argument.Contains(' ') || argument.Contains('"') ? "\"" + argument.Replace("\"", "\\\"") + "\"" : argument;
}

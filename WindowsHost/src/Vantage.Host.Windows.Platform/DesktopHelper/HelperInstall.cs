using System.ComponentModel;
using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32;
using Vantage.Protocol.Auth;

namespace Vantage.Host.Windows.DesktopHelper;

/// <summary>
/// Where Casement Host Service lives and how the host turns it on and off. "Control administrator
/// prompts and apps" installs it: one UAC prompt at the PC runs <c>CasementHostService.exe
/// install</c> from the host's folder, which copies it into Program Files (writable only by
/// administrators, so a program running as the user can't swap the file a SYSTEM service runs),
/// makes its signing key, registers and starts the service. Turning it off runs <c>uninstall</c>
/// the same way.
/// </summary>
public static class HelperInstall
{
    /// <summary>The service's name in Services.</summary>
    public const string ServiceName = "CasementHostService";

    /// <summary>What Services shows.</summary>
    public const string DisplayName = "Casement Host Service";

    /// <summary>The executable's file name, beside the host's own and in <see cref="InstallFolder"/>.</summary>
    public const string ExecutableName = "CasementHostService.exe";

    /// <summary><c>C:\Program Files\Casement Host Service</c>.</summary>
    public static string InstallFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), DisplayName);

    /// <summary>The service's executable.</summary>
    public static string InstalledExecutable => Path.Combine(InstallFolder, ExecutableName);

    /// <summary>The helper's public key (32 bytes), readable by everyone, writable by administrators.</summary>
    public static string PublicKeyFile => Path.Combine(InstallFolder, "helper.pub");

    /// <summary><c>C:\ProgramData\Casement Host Service</c>: the private key, readable by SYSTEM and administrators only.</summary>
    public static string PrivateFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), DisplayName);

    /// <summary>The helper's private key seed.</summary>
    public static string PrivateKeyFile => Path.Combine(PrivateFolder, "helper.key");

    /// <summary>Whether the service is registered (Services knows it).</summary>
    public static bool IsInstalled
    {
        get
        {
            try
            {
                using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Services\{ServiceName}");
                return key is not null;
            }
            catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
            {
                return false;
            }
        }
    }

    /// <summary>The helper's public key, or null when it isn't installed or the file is damaged.</summary>
    public static byte[]? ReadPublicKey()
    {
        try
        {
            var key = File.ReadAllBytes(PublicKeyFile);
            return key.Length == 32 ? key : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>
    /// Runs <c>CasementHostService.exe install</c> (or <c>uninstall</c>) from the host's folder as
    /// administrator: Windows asks the person at the PC. True when it finished without error; false
    /// when they declined or it failed (its log is in <see cref="PrivateFolder"/>).
    /// </summary>
    /// <param name="hostFolder">The folder with the host's executable and <see cref="ExecutableName"/>.</param>
    /// <param name="install">Install (true) or uninstall (false).</param>
    public static async Task<bool> RunElevatedAsync(string hostFolder, bool install)
    {
        var source = Path.Combine(hostFolder, ExecutableName);
        // Uninstalling works from the installed copy too (a host folder without one, e.g. a dev build).
        if (!File.Exists(source) && !install) source = InstalledExecutable;
        if (!File.Exists(source)) return false;
        var info = new ProcessStartInfo(source, install ? "install" : "uninstall")
        {
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        try
        {
            using var process = Process.Start(info);
            if (process is null) return false;
            await process.WaitForExitAsync().ConfigureAwait(false);
            return process.ExitCode == 0;
        }
        catch (Win32Exception)
        {
            // 1223: No on the UAC prompt.
            return false;
        }
    }

    /// <summary>
    /// Makes <see cref="PrivateFolder"/> readable by SYSTEM and administrators only (nothing
    /// inherited), and a new key pair in it and beside the service. Run elevated, by <c>install</c>.
    /// </summary>
    public static void CreateKeys(IEd25519 ed25519)
    {
        var folder = Directory.CreateDirectory(PrivateFolder);
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in new[] { WellKnownSidType.LocalSystemSid, WellKnownSidType.BuiltinAdministratorsSid })
        {
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid, null), FileSystemRights.FullControl,
                                                            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                                                            PropagationFlags.None, AccessControlType.Allow));
        }
        folder.SetAccessControl(security);

        var seed = ed25519.GenerateSeed();
        File.WriteAllBytes(PrivateKeyFile, seed);
        File.WriteAllBytes(PublicKeyFile, ed25519.PublicKeyFromSeed(seed));
    }

    /// <summary>The private key seed (the helper reads it as SYSTEM).</summary>
    public static byte[] ReadPrivateKey() => File.ReadAllBytes(PrivateKeyFile);
}

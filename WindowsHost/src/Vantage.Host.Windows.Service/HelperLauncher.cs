using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Windows.Win32;
using Windows.Win32.Foundation;
using Windows.Win32.Security;
using Windows.Win32.System.Threading;

namespace Vantage.Host.Windows.Service;

/// <summary>
/// Starts <c>CasementHostService.exe helper</c> as SYSTEM in another session: the service's own
/// token, duplicated and moved to that session, on its interactive window station, so the helper
/// can reach the session's desktops (the secure one included).
/// </summary>
internal static class HelperLauncher
{
    public static unsafe Process Start(uint session, string executable)
    {
        HANDLE own = default, primary = default;
        try
        {
            if (!PInvoke.OpenProcessToken(PInvoke.GetCurrentProcess(),
                                          TOKEN_ACCESS_MASK.TOKEN_DUPLICATE | TOKEN_ACCESS_MASK.TOKEN_QUERY | TOKEN_ACCESS_MASK.TOKEN_ASSIGN_PRIMARY
                                          | TOKEN_ACCESS_MASK.TOKEN_ADJUST_SESSIONID | TOKEN_ACCESS_MASK.TOKEN_ADJUST_DEFAULT, &own))
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "OpenProcessToken");
            if (!PInvoke.DuplicateTokenEx(own, TOKEN_ACCESS_MASK.TOKEN_ALL_ACCESS, null, SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation,
                                          TOKEN_TYPE.TokenPrimary, &primary))
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "DuplicateTokenEx");
            if (!PInvoke.SetTokenInformation(primary, TOKEN_INFORMATION_CLASS.TokenSessionId, &session, sizeof(uint)))
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "SetTokenInformation(TokenSessionId)");

            var commandLine = $"\"{executable}\" helper\0".ToCharArray();
            var desktopName = "winsta0\\default\0".ToCharArray();
            using var token = new Microsoft.Win32.SafeHandles.SafeFileHandle((nint)primary.Value, ownsHandle: false);
            fixed (char* desktop = desktopName)
            {
                var startup = new STARTUPINFOW { cb = (uint)sizeof(STARTUPINFOW), lpDesktop = desktop };
                Span<char> command = commandLine;
                if (!PInvoke.CreateProcessAsUser(token, null, ref command, null, null, false,
                                                 PROCESS_CREATION_FLAGS.CREATE_NO_WINDOW | PROCESS_CREATION_FLAGS.CREATE_UNICODE_ENVIRONMENT,
                                                 null, Path.GetDirectoryName(executable), in startup, out var process))
                    throw new Win32Exception(Marshal.GetLastPInvokeError(), "CreateProcessAsUser");
                PInvoke.CloseHandle(process.hThread);
                try
                {
                    return Process.GetProcessById((int)process.dwProcessId);
                }
                finally
                {
                    PInvoke.CloseHandle(process.hProcess);
                }
            }
        }
        finally
        {
            if (!own.IsNull) PInvoke.CloseHandle(own);
            if (!primary.IsNull) PInvoke.CloseHandle(primary);
        }
    }
}

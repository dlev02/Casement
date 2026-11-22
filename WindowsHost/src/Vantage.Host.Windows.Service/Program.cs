// Casement Host Service: one executable, four jobs, chosen by the first argument.
//   install    (elevated, from the host's folder) copy into Program Files, make the helper's key,
//              register and start the service; also removes the old elevated launch task.
//   uninstall  (elevated) stop and remove the service, its files and its key.
//   service    (Services, as LocalSystem) keep the desktop helper running in the signed-in
//              console session.
//   helper     (started by the service, SYSTEM in the user's session) serve Casement Host's pipe:
//              the secure desktop's picture and input there, and input to administrator apps.
// Logs: %ProgramData%\Casement Host Service\{install,service,helper}.log (administrators only).

using System.ServiceProcess;
using Microsoft.Extensions.Logging;
using Vantage.Host.Windows.DesktopHelper;
using Vantage.Host.Windows.Logging;
using Vantage.Host.Windows.Service;

var mode = args.Length > 0 ? args[0].ToLowerInvariant() : "service";
using var logging = LoggerFactory.Create(builder =>
{
    builder.SetMinimumLevel(LogLevel.Information);
    try
    {
        Directory.CreateDirectory(HelperInstall.PrivateFolder);
        builder.AddProvider(new FileLoggerProvider(Path.Combine(HelperInstall.PrivateFolder, $"{mode}.log")));
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
    {
        // Not elevated yet (a mistaken run): no log.
    }
});
var log = logging.CreateLogger("Vantage.Service");

try
{
    switch (mode)
    {
        case "install":
            return Installer.Install(log);
        case "uninstall":
            return Installer.Uninstall(log);
        case "helper":
            using (var quit = new CancellationTokenSource())
            {
                Console.CancelKeyPress += (_, e) =>
                {
                    e.Cancel = true;
                    quit.Cancel();
                };
                return await SecureDesktopHelper.RunAsync(logging.CreateLogger("Vantage.Helper"), quit.Token);
            }
        case "service":
            ServiceBase.Run(new HostService(logging));
            return 0;
        default:
            log.LogError("unknown mode {Mode}; use install or uninstall", mode);
            return 2;
    }
}
catch (Exception ex)
{
    log.LogCritical(ex, "{Mode} failed", mode);
    return 1;
}

using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Vantage.Host.Windows.App;

/// <summary>
/// Entry point (the XAML-generated Main is disabled): one Vantage Host per user. A second launch
/// (the Start menu shortcut, or the Run key while it's already running) hands its activation to the
/// first, which opens its window, and exits.
/// </summary>
public static class Program
{
    /// <summary>Key the running instance registers under.</summary>
    public const string InstanceKey = "VantageHost";

    [STAThread]
    private static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();

        var current = AppInstance.GetCurrent();
        var main = AppInstance.FindOrRegisterForKey(InstanceKey);
        if (!main.IsCurrent)
        {
            var activation = current.GetActivatedEventArgs();
            // Redirect off the STA thread: waiting on it here would block the COM call it needs.
            Task.Run(() => main.RedirectActivationToAsync(activation).AsTask()).Wait(TimeSpan.FromSeconds(5));
            return 0;
        }

        Application.Start(callback =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App(args);
        });
        return 0;
    }
}

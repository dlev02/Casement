using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Vantage.Host.Windows.App.Pages;
using WinRT.Interop;

namespace Vantage.Host.Windows.App;

/// <summary>
/// The settings window: Mica, content in the title bar, a NavigationView with General, Devices,
/// Files, Display and About. Closing it only hides it; the host keeps running in the tray.
/// </summary>
public sealed partial class MainWindow : Window
{
    private readonly AppController _controller;
    private bool _closingForQuit;

    /// <param name="controller">The app.</param>
    public MainWindow(AppController controller)
    {
        _controller = controller;
        InitializeComponent();

        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "Vantage.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);

        var scale = GetDpiForWindow(WindowNative.GetWindowHandle(this)) / 96.0;
        AppWindow.Resize(new global::Windows.Graphics.SizeInt32((int)(960 * scale), (int)(680 * scale)));
        AppWindow.Closing += OnClosing;
    }

    /// <summary>Shows the window (bringing it to the front) on <paramref name="page"/>, or where it was.</summary>
    public void ShowAndActivate(string? page)
    {
        AppWindow.Show();
        Activate();
        if (page is not null || ContentFrame.Content is null) Select(page ?? "general");
    }

    /// <summary>Lets the window really close (Quit).</summary>
    public void CloseForQuit()
    {
        _closingForQuit = true;
        Close();
    }

    private void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_closingForQuit) return;
        args.Cancel = true;
        sender.Hide();
    }

    private void Select(string tag)
    {
        foreach (var item in NavView.MenuItems.Concat(NavView.FooterMenuItems).OfType<NavigationViewItem>())
        {
            if (item.Tag as string == tag)
            {
                NavView.SelectedItem = item;
                return;
            }
        }
    }

    private void OnSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item) return;
        var page = (item.Tag as string) switch
        {
            "devices" => typeof(DevicesPage),
            "files" => typeof(FilesPage),
            "display" => typeof(DisplayPage),
            "about" => typeof(AboutPage),
            _ => typeof(GeneralPage),
        };
        if (ContentFrame.CurrentSourcePageType != page) ContentFrame.Navigate(page, _controller);
    }

    private void OnPaneToggleRequested(TitleBar sender, object args) => NavView.IsPaneOpen = !NavView.IsPaneOpen;

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern uint GetDpiForWindow(nint hwnd);
}

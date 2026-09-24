using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Vantage.Host.Windows.App.Pages;

/// <summary>Connected iPads (with Disconnect) and paired iPads (with Remove).</summary>
public sealed partial class DevicesPage : Page
{
    private AppController? _controller;

    /// <summary>Creates the page.</summary>
    public DevicesPage()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            if (_controller is not null) _controller.StateChanged += Update;
            Update();
        };
        Unloaded += (_, _) =>
        {
            if (_controller is not null) _controller.StateChanged -= Update;
        };
    }

    /// <inheritdoc />
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _controller = e.Parameter as AppController;
        base.OnNavigatedTo(e);
    }

    private void Update()
    {
        if (_controller?.Runtime is not { } runtime) return;

        ConnectedList.Children.Clear();
        foreach (var session in _controller.Sessions)
        {
            var detail = session.IsFilesOnly ? "Moving files" : session.Display is { } display ? $"Viewing {display.Name}" : "Connected";
            var button = new Button { Content = "Disconnect" };
            var id = session.Id;
            button.Click += async (_, _) =>
            {
                button.IsEnabled = false;
                await _controller.DisconnectAsync(id);
            };
            ConnectedList.Children.Add(Row(session.ClientName, $"{detail} · {session.Peer}", button));
        }
        NoneConnected.Visibility = ConnectedList.Children.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        TrustedList.Children.Clear();
        foreach (var client in runtime.Environment.Trust.List())
        {
            var button = new Button { Content = "Remove" };
            var fingerprint = client.Fingerprint;
            var name = client.Name;
            button.Click += async (_, _) =>
            {
                var confirm = new ContentDialog
                {
                    XamlRoot = XamlRoot,
                    Title = $"Remove {name}?",
                    Content = "It will be disconnected and will need a new pairing code to connect again.",
                    PrimaryButtonText = "Remove",
                    CloseButtonText = "Cancel",
                    DefaultButton = ContentDialogButton.Close,
                };
                if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
                button.IsEnabled = false;
                await _controller.RevokeAsync(fingerprint);
            };
            TrustedList.Children.Add(Row(client.Name, $"Paired {client.AddedAt.LocalDateTime:d} · key {client.Fingerprint}", button));
        }
        NonePaired.Visibility = TrustedList.Children.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private static Border Row(string title, string detail, Button action)
    {
        var grid = new Grid { ColumnSpacing = 16 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel { Spacing = 2 };
        text.Children.Add(new TextBlock { Text = title, Style = Resource<Style>("BodyStrongTextBlockStyle") });
        var detailText = new TextBlock { Text = detail, TextWrapping = TextWrapping.Wrap };
        if (Resource<Microsoft.UI.Xaml.Media.Brush>("TextFillColorSecondaryBrush") is { } secondary) detailText.Foreground = secondary;
        text.Children.Add(detailText);
        grid.Children.Add(text);
        action.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(action, 1);
        grid.Children.Add(action);
        return new Border { Style = Resource<Style>("CardStyle"), Child = grid };
    }

    private static T? Resource<T>(string key) where T : class =>
        Application.Current.Resources.TryGetValue(key, out var value) ? value as T : null;
}

using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Vantage.Protocol.Host;

namespace Vantage.Host.Windows.App.Pages;

/// <summary>Pairing a device (the code shows right here), connected devices (Send file, Disconnect) and paired devices (Remove).</summary>
public sealed partial class DevicesPage : Page
{
    private AppController? _controller;
    private string? _connectedShown;
    private string? _pairedShown;
    private bool _codeWasShowing;

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
        if (_controller is not null) Pairing.Attach(_controller);
        base.OnNavigatedTo(e);
    }

    /// <summary>
    /// The lists are rebuilt only when what they show changes: this runs several times a second
    /// while files move, and a new row would take keyboard focus away from its button.
    /// </summary>
    private void Update()
    {
        if (_controller is null) return;

        var showingCode = _controller.PairingCode is not null;
        PairCard.Visibility = showingCode ? Visibility.Collapsed : Visibility.Visible;
        CodeCard.Visibility = showingCode ? Visibility.Visible : Visibility.Collapsed;
        ShowCodeButton.IsEnabled = _controller.IsListening;
        if (showingCode) Pairing.Update();
        // The button that was focused has just gone: hand focus on, so Tab keeps its place.
        if (IsLoaded && showingCode != _codeWasShowing)
        {
            if (showingCode) Pairing.FocusCopy();
            else ShowCodeButton.Focus(FocusState.Programmatic);
        }
        _codeWasShowing = showingCode;

        var sessions = _controller.Sessions;
        var channels = _controller.FileChannels;
        var connected = string.Join('\n', sessions.Select(s => $"{s.Id}|{s.ClientName}|{Detail(s)}|{channels.Any(c => c.SessionId == s.Id)}"));
        if (connected != _connectedShown)
        {
            _connectedShown = connected;
            ConnectedList.Children.Clear();
            foreach (var session in sessions)
                ConnectedList.Children.Add(ConnectedRow(session, channels.FirstOrDefault(c => c.SessionId == session.Id)));
            NoneConnected.Visibility = sessions.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        }

        var trusted = _controller.PairedDevices;
        var paired = string.Join('\n', trusted.Select(c => $"{c.Fingerprint}|{c.DisplayName}"));
        if (paired != _pairedShown)
        {
            _pairedShown = paired;
            TrustedList.Children.Clear();
            foreach (var client in trusted) TrustedList.Children.Add(PairedRow(client));
            PairedHeader.Text = trusted.Count == 0 ? "Paired" : $"Paired ({trusted.Count})";
            NonePaired.Visibility = trusted.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            PairedNote.Visibility = trusted.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    private static string Detail(SessionSnapshot session) =>
        session.IsFilesOnly ? "Moving files" : session.Display is { } display ? $"Viewing {display.Name}" : "Connected";

    private SettingsCard ConnectedRow(SessionSnapshot session, FileChannelSnapshot? channel)
    {
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        if (channel is not null)
        {
            var send = new Button { Content = "Send file…" };
            AutomationProperties.SetName(send, $"Send a file to {session.ClientName}");
            var channelId = channel.Id;
            send.Click += (_, _) => _ = _controller!.SendFilesAsync(channelId);
            actions.Children.Add(send);
        }
        var disconnect = new Button { Content = "Disconnect" };
        AutomationProperties.SetName(disconnect, $"Disconnect {session.ClientName}");
        var id = session.Id;
        disconnect.Click += async (_, _) =>
        {
            disconnect.IsEnabled = false;
            await _controller!.DisconnectAsync(id);
        };
        actions.Children.Add(disconnect);
        return new SettingsCard
        {
            Header = session.ClientName,
            Description = $"{Detail(session)} · {session.Peer}",
            HeaderIcon = UiHelpers.Glyph(UiHelpers.DeviceGlyph(session.ClientName), 20),
            Content = actions,
        };
    }

    private SettingsCard PairedRow(TrustedClient client)
    {
        var name = client.DisplayName;
        var remove = new MenuFlyoutItem { Text = "Remove device", Icon = UiHelpers.Glyph("") };
        var fingerprint = client.Fingerprint;
        remove.Click += async (_, _) =>
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
            await _controller!.RevokeAsync(fingerprint);
        };
        var flyout = new MenuFlyout();
        var rename = new MenuFlyoutItem { Text = "Rename device", Icon = UiHelpers.Glyph("") };
        rename.Click += async (_, _) =>
        {
            var field = new TextBox { Text = name, MaxLength = 100, Header = "Device name" };
            AutomationProperties.SetName(field, "Device name");
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot, Title = "Rename device", Content = field,
                PrimaryButtonText = "Save", CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Primary,
            };
            field.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = !string.IsNullOrWhiteSpace(field.Text);
            dialog.PrimaryButtonClick += (_, args) =>
            {
                try
                {
                    if (_controller?.Runtime?.Environment.Trust.Rename(fingerprint, field.Text) != true)
                    {
                        args.Cancel = true;
                        field.Header = "This device is no longer paired. Cancel and try again.";
                    }
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    args.Cancel = true;
                    field.Header = "Couldn't save the name. Check access to the data folder and try again.";
                }
            };
            await dialog.ShowAsync();
        };
        flyout.Items.Add(rename);
        flyout.Items.Add(remove);

        var more = new Button
        {
            Content = UiHelpers.Glyph(""), // More
            Padding = new Thickness(8),
            Flyout = flyout,
            Style = UiHelpers.Resource<Style>("PanelButtonStyle"),
        };
        var label = $"More options for {name}";
        AutomationProperties.SetName(more, label);
        ToolTipService.SetToolTip(more, "More options");

        // Two devices can share a name ("iPad"): the date and the key tell them apart.
        return new SettingsCard
        {
            Header = name,
            Description = $"Paired {client.AddedAt.LocalDateTime:MMMM d, yyyy} · Key {client.Fingerprint}",
            HeaderIcon = UiHelpers.Glyph(UiHelpers.DeviceGlyph(name), 20),
            Content = more,
        };
    }

    private void OnShowCode(object sender, RoutedEventArgs e) => _controller?.ShowPairingCode(openWindow: false);
}

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Windows.Storage.Pickers;
using Vantage.Host.Windows.Files;
using Vantage.Host.Windows.Storage;

namespace Vantage.Host.Windows.App.Pages;

/// <summary>
/// Files moving now (and finished in the last minute, with Show in folder), the receive folder, what
/// happens after files arrive, and arrival notifications.
/// </summary>
public sealed partial class FilesPage : Page
{
    private AppController? _controller;
    private TransferRows? _transferRows;
    private bool _updating;

    /// <summary>Creates the page.</summary>
    public FilesPage()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            if (_controller is not null) _controller.StateChanged += UpdateTransfers;
            Update();
            UpdateTransfers();
        };
        Unloaded += (_, _) =>
        {
            if (_controller is not null) _controller.StateChanged -= UpdateTransfers;
        };
    }

    /// <inheritdoc />
    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _controller = e.Parameter as AppController;
        if (_controller is not null) _transferRows = new TransferRows(TransferList, _controller);
        base.OnNavigatedTo(e);
    }

    private void UpdateTransfers()
    {
        if (_controller is null || _transferRows is null) return;
        var transfers = _controller.Transfers.Items;
        _transferRows.Sync(transfers);
        TransfersSection.Visibility = transfers.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        // One file has its own Cancel; Cancel All is for a batch.
        CancelAllButton.Visibility = transfers.Count(t => t.IsActive) >= 2 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void OnCancelAll(object sender, RoutedEventArgs e)
    {
        if (_controller is null) return;
        var active = _controller.Transfers.Items.Count(t => t.IsActive);
        if (active == 0) return;
        var confirm = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = $"Cancel {active} transfers?",
            Content = "Files on their way to your devices stop, and files still arriving here are deleted.",
            PrimaryButtonText = "Cancel all",
            CloseButtonText = "Keep going",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
        _controller.CancelAllTransfers();
    }

    private HostSettingsStore? Settings => _controller?.Runtime?.Settings;

    private void Update()
    {
        if (_controller?.Runtime is not { } runtime) return;
        _updating = true;
        var settings = runtime.Settings.Current;
        var folder = runtime.Files.ReceiveDirectory;
        FolderText.Text = folder;
        var chosenButUnusable = settings.ReceiveFolder is { } chosen && !string.Equals(chosen, folder, StringComparison.OrdinalIgnoreCase);
        FolderHint.Text = chosenButUnusable ? $"{settings.ReceiveFolder} can't be used right now (missing or read-only), so files go to the folder above." : "";
        FolderHint.Visibility = chosenButUnusable ? Visibility.Visible : Visibility.Collapsed;
        ResetButton.Visibility = settings.ReceiveFolder is not null ? Visibility.Visible : Visibility.Collapsed;
        AfterArrivalChoice.SelectedIndex = settings.AfterArrival switch
        {
            AfterArrival.DoNothing => 0,
            AfterArrival.OpenFile => 2,
            _ => 1,
        };
        NotifySwitch.IsOn = settings.NotifyOnArrival;
        _updating = false;
    }

    private async void OnChooseFolder(object sender, RoutedEventArgs e)
    {
        if (Settings is not { } settings || XamlRoot?.ContentIslandEnvironment is not { } island) return;
        var picker = new FolderPicker(island.AppWindowId)
        {
            Title = "Save files from your devices in",
            SuggestedStartLocation = PickerLocationId.Downloads,
        };
        var result = await picker.PickSingleFolderAsync();
        if (result is null) return;
        if (!ReceiveFolder.IsWritableDirectory(result.Path))
        {
            await new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = "That folder can't be used",
                Content = "Casement Host can't save files there. Choose a folder you can write to.",
                CloseButtonText = "OK",
            }.ShowAsync();
            return;
        }
        settings.Update(s => s with { ReceiveFolder = result.Path });
        Update();
    }

    private void OnResetFolder(object sender, RoutedEventArgs e)
    {
        Settings?.Update(s => s with { ReceiveFolder = null });
        Update();
    }

    private void OnOpenFolder(object sender, RoutedEventArgs e)
    {
        if (_controller?.Runtime is { } runtime) ExplorerActions.OpenFolder(runtime.Files.ReceiveDirectory);
    }

    private void OnAfterArrivalChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updating || AfterArrivalChoice.SelectedIndex < 0) return;
        var choice = AfterArrivalChoice.SelectedIndex switch
        {
            0 => AfterArrival.DoNothing,
            2 => AfterArrival.OpenFile,
            _ => AfterArrival.ShowInFolder,
        };
        Settings?.Update(s => s with { AfterArrival = choice });
    }

    private void OnNotifyToggled(object sender, RoutedEventArgs e)
    {
        if (_updating) return;
        var on = NotifySwitch.IsOn;
        Settings?.Update(s => s with { NotifyOnArrival = on });
    }
}

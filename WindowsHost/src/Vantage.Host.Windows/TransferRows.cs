using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Vantage.Host.Windows.Files;
using Vantage.Protocol.Files;

namespace Vantage.Host.Windows.App;

/// <summary>
/// The transfer rows the tray panel and Settings › Files share: per file a glyph, its name, a thin
/// <see cref="ProgressBar"/> while bytes move, the status line (<see cref="HostTransferText.Detail"/>)
/// and one action (Cancel while it's active, Show in folder once received). Rows are kept per
/// transfer id and updated in place, so progress several times a second doesn't rebuild them
/// (the bar keeps animating and keyboard focus stays on its button).
/// </summary>
public sealed class TransferRows
{
    private readonly Panel _host;
    private readonly AppController _controller;
    private readonly Dictionary<Guid, Row> _rows = [];

    /// <param name="host">Where the rows go (its children are managed here).</param>
    /// <param name="controller">The app, for Cancel and Show in folder.</param>
    public TransferRows(Panel host, AppController controller)
    {
        _host = host;
        _controller = controller;
    }

    /// <summary>Shows exactly <paramref name="transfers"/>, in order.</summary>
    public void Sync(IReadOnlyList<HostTransfer> transfers)
    {
        var wanted = transfers.Select(t => t.Id).ToHashSet();
        foreach (var gone in _rows.Keys.Where(id => !wanted.Contains(id)).ToList())
        {
            _host.Children.Remove(_rows[gone].Root);
            _rows.Remove(gone);
        }
        for (var index = 0; index < transfers.Count; index++)
        {
            var transfer = transfers[index];
            if (!_rows.TryGetValue(transfer.Id, out var row))
            {
                row = new Row(_controller, transfer.Id);
                _rows[transfer.Id] = row;
            }
            var at = _host.Children.IndexOf(row.Root);
            if (at != index)
            {
                if (at >= 0) _host.Children.RemoveAt(at);
                _host.Children.Insert(Math.Min(index, _host.Children.Count), row.Root);
            }
            row.Update(transfer);
        }
    }

    private sealed class Row
    {
        private readonly AppController _controller;
        private readonly Guid _id;
        private readonly FontIcon _glyph = new() { FontSize = 16, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) };
        private readonly TextBlock _name = new() { TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 };
        private readonly ProgressBar _bar = new() { Minimum = 0, Maximum = 100, Margin = new Thickness(0, 4, 0, 2) };
        private readonly TextBlock _detail = new() { TextWrapping = TextWrapping.Wrap };
        private readonly Button _action = new() { VerticalAlignment = VerticalAlignment.Center, Padding = new Thickness(8) };
        private readonly FontIcon _actionGlyph = new() { FontSize = 14 };
        private readonly ToolTip _actionTip = new();
        private HostTransfer? _transfer;

        public Row(AppController controller, Guid id)
        {
            _controller = controller;
            _id = id;
            _detail.Style = Resource<Style>("CaptionTextBlockStyle");
            _detail.Foreground = Resource<Brush>("TextFillColorSecondaryBrush");
            // Subtle until hovered, like a list's inline commands in Windows 11.
            _action.Background = Resource<Brush>("SubtleFillColorTransparentBrush");
            _action.BorderBrush = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
            _action.Content = _actionGlyph;
            ToolTipService.SetToolTip(_action, _actionTip);
            _action.Click += (_, _) => OnAction();

            var text = new StackPanel();
            text.Children.Add(_name);
            text.Children.Add(_bar);
            text.Children.Add(_detail);

            Root = new Grid { ColumnSpacing = 12 };
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Root.Children.Add(_glyph);
            Grid.SetColumn(text, 1);
            Root.Children.Add(text);
            Grid.SetColumn(_action, 2);
            Root.Children.Add(_action);
        }

        public Grid Root { get; }

        public void Update(HostTransfer transfer)
        {
            _transfer = transfer;
            var name = transfer.DisplayName;
            _name.Text = name;
            _detail.Text = transfer.Detail;

            var moving = transfer.State == HostTransferState.Moving;
            _bar.Visibility = moving ? Visibility.Visible : Visibility.Collapsed;
            _bar.Value = transfer.Fraction * 100;
            AutomationProperties.SetName(_bar, $"{(transfer.Direction == FileDirection.Sending ? "Sending" : "Receiving")} {name}");

            (_glyph.Glyph, _glyph.Foreground) = transfer.State switch
            {
                HostTransferState.Paused => ("", Resource<Brush>("TextFillColorSecondaryBrush")),   // Info: waiting, not wrong
                HostTransferState.Done => ("", Resource<Brush>("SystemFillColorSuccessBrush")),     // CheckMark
                HostTransferState.Failed => ("", Resource<Brush>("SystemFillColorCautionBrush")),   // Warning
                HostTransferState.Cancelled => ("", Resource<Brush>("TextFillColorTertiaryBrush")), // Document, dimmed
                _ => ("", Resource<Brush>("TextFillColorPrimaryBrush")),                            // Document
            };

            if (transfer.IsActive)
            {
                _action.Visibility = Visibility.Visible;
                _actionGlyph.Glyph = ""; // Cancel
                _actionTip.Content = "Cancel";
                AutomationProperties.SetName(_action, $"Cancel {name}");
            }
            else if (transfer is { State: HostTransferState.Done, SavedPath: not null })
            {
                _action.Visibility = Visibility.Visible;
                _actionGlyph.Glyph = ""; // FolderOpen
                _actionTip.Content = "Show in folder";
                AutomationProperties.SetName(_action, $"Show {name} in folder");
            }
            else
            {
                _action.Visibility = Visibility.Collapsed;
            }
        }

        private void OnAction()
        {
            if (_transfer is null) return;
            if (_transfer.IsActive) _controller.CancelTransfer(_id);
            else _controller.ShowTransferInFolder(_id);
        }
    }

    private static T? Resource<T>(string key) where T : class =>
        Application.Current.Resources.TryGetValue(key, out var value) ? value as T : null;
}

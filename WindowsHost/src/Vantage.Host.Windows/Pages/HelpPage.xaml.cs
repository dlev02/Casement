using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace Vantage.Host.Windows.App.Pages;

/// <summary>Offline help for connecting to and maintaining this Windows host.</summary>
public sealed partial class HelpPage : Page
{
    private readonly List<(TextBlock Heading, Expander Question, string SearchText)> _entries = [];
    private readonly Dictionary<Expander, bool> _expandedBeforeSearch = [];
    private bool _searching;

    /// <summary>Creates the help page.</summary>
    public HelpPage()
    {
        InitializeComponent();
        TextBlock? heading = null;
        foreach (var child in HelpContent.Children)
        {
            if (child is TextBlock section) heading = section;
            else if (child is Expander question && heading is not null && question.Content is TextBlock answer)
                _entries.Add((heading, question, $"{heading.Text} {question.Header} {answer.Text}"));
        }
        ResultStatus.Text = $"{_entries.Count} questions";
    }

#if DEBUG
    /// <summary>Sets a query for a repeatable UI capture.</summary>
    public void SearchForPreview(string query) => SearchBox.Text = query;
#endif

    private void OnFind(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        SearchBox.Focus(FocusState.Programmatic);
        args.Handled = true;
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs args)
    {
        if (ResultStatus is null) return;
        var terms = SearchBox.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var searching = terms.Length > 0;
        if (searching && !_searching)
            foreach (var entry in _entries) _expandedBeforeSearch[entry.Question] = entry.Question.IsExpanded;

        foreach (var heading in _entries.Select(e => e.Heading).Distinct()) heading.Visibility = Visibility.Collapsed;
        var matches = 0;
        foreach (var entry in _entries)
        {
            var match = terms.All(term => entry.SearchText.Contains(term, StringComparison.OrdinalIgnoreCase));
            entry.Question.Visibility = match ? Visibility.Visible : Visibility.Collapsed;
            if (match)
            {
                entry.Heading.Visibility = Visibility.Visible;
                matches++;
            }
            if (searching) entry.Question.IsExpanded = match;
            else if (_searching && _expandedBeforeSearch.TryGetValue(entry.Question, out var expanded))
                entry.Question.IsExpanded = expanded;
        }
        _searching = searching;
        if (!searching) _expandedBeforeSearch.Clear();
        ResultStatus.Text = !searching ? $"{matches} questions"
            : matches == 0 ? "No matches. Try device, pairing or administrator."
            : matches == 1 ? "1 matching question" : $"{matches} matching questions";
    }
}

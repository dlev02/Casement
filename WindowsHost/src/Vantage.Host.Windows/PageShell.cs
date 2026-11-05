using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Vantage.Host.Windows.App;

/// <summary>
/// The frame of a settings page: a title that stays put above a scrolling column, as in Windows 11
/// Settings. Every page uses it, so margins and the title's line-up with the navigation pane are
/// decided once (the template is in App.xaml; MainWindow.xaml sets the space above the title).
/// </summary>
public sealed partial class PageShell : ContentControl
{
    /// <summary>The page's title.</summary>
    public static readonly DependencyProperty TitleProperty =
        DependencyProperty.Register(nameof(Title), typeof(string), typeof(PageShell), new PropertyMetadata(""));

    /// <summary>The page's title.</summary>
    public string Title
    {
        get => (string)GetValue(TitleProperty);
        set => SetValue(TitleProperty, value);
    }
}

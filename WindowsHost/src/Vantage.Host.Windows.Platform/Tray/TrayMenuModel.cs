using Vantage.Host.Windows.Files;

namespace Vantage.Host.Windows.Tray;

/// <summary>A connected iPad, for the tray.</summary>
/// <param name="SessionId">Session to disconnect.</param>
/// <param name="Name">"Drew's iPad Pro" (whois name when known).</param>
public sealed record TrayClient(Guid SessionId, string Name);

/// <summary>A file channel files can be sent on.</summary>
/// <param name="ChannelId">For <c>HostListener.SendFileAsync</c>.</param>
/// <param name="Name">Who is on the other end.</param>
public sealed record TrayFileTarget(Guid ChannelId, string Name);

/// <summary>A file in the menu's Files section.</summary>
/// <param name="Id">The transfer id (what Cancel and Show act on).</param>
/// <param name="Name">The file's name (the saved one, once received).</param>
/// <param name="Detail">Its status line (<see cref="HostTransferText.Detail"/>).</param>
/// <param name="CanCancel">Still waiting, moving or paused.</param>
/// <param name="CanShow">A received file that's saved, so it can be shown in its folder.</param>
public sealed record TrayTransfer(Guid Id, string Name, string Detail, bool CanCancel, bool CanShow)
{
    /// <summary>The menu's row for a list entry.</summary>
    public static TrayTransfer From(HostTransfer transfer) =>
        new(transfer.Id, transfer.DisplayName, transfer.Detail, transfer.IsActive,
            transfer is { State: HostTransferState.Done, SavedPath: not null });
}

/// <summary>What the tray shows.</summary>
/// <param name="HostName">This PC's name ("drew-pc").</param>
/// <param name="IsListening">The listener is up.</param>
/// <param name="Problem">Why it isn't (port in use, …), or null.</param>
/// <param name="Clients">Screen sessions connected now.</param>
/// <param name="FileTargets">File channels up now.</param>
public sealed record TrayState(string HostName, bool IsListening, string? Problem, IReadOnlyList<TrayClient> Clients,
                               IReadOnlyList<TrayFileTarget> FileTargets)
{
    /// <summary>Files listed in the menu, oldest first.</summary>
    public IReadOnlyList<TrayTransfer> Transfers { get; init; } = [];

    /// <summary>The ring the icon shows while files move; null shows the display glyph.</summary>
    public HostTransferActivity? Activity { get; init; }

    /// <summary>What's moving ("Receiving Report.pdf, 45%"), for the tooltip; null when nothing is.</summary>
    public string? TransferSummary { get; init; }

    /// <summary>Starting up.</summary>
    public static TrayState Starting(string hostName) => new(hostName, false, null, [], []);
}

/// <summary>What a menu item does.</summary>
public enum TrayCommandKind
{
    /// <summary>A label.</summary>
    None,
    /// <summary>Show Pairing Code…</summary>
    ShowPairingCode,
    /// <summary>Send File to ⟨iPad⟩… (<see cref="TrayCommand.Target"/> is the channel).</summary>
    SendFile,
    /// <summary>Disconnect ⟨iPad⟩ (<see cref="TrayCommand.Target"/> is the session).</summary>
    Disconnect,
    /// <summary>Cancel ⟨file⟩ (<see cref="TrayCommand.Target"/> is the transfer).</summary>
    CancelTransfer,
    /// <summary>Show ⟨file⟩ in folder (<see cref="TrayCommand.Target"/> is the transfer).</summary>
    ShowTransfer,
    /// <summary>Open Receive Folder.</summary>
    OpenReceiveFolder,
    /// <summary>"N more files…": Settings › Files, which lists them all.</summary>
    ShowTransfers,
    /// <summary>Settings…</summary>
    Settings,
    /// <summary>Quit Vantage Host.</summary>
    Quit,
}

/// <summary>A menu command.</summary>
public readonly record struct TrayCommand(TrayCommandKind Kind, Guid Target = default);

/// <summary>One row of the tray menu.</summary>
/// <param name="Text">Label (plain; <see cref="TrayMenuModel.MenuText"/> escapes it for Win32).</param>
/// <param name="Command">What it does; <see cref="TrayCommandKind.None"/> for labels and separators.</param>
/// <param name="IsEnabled">Clickable.</param>
/// <param name="IsSeparator">A divider.</param>
public sealed record TrayMenuItem(string Text, TrayCommand Command, bool IsEnabled, bool IsSeparator = false)
{
    /// <summary>A divider.</summary>
    public static readonly TrayMenuItem Separator = new("", default, false, true);
}

/// <summary>
/// The tray's menu and tooltip for a <see cref="TrayState"/> (plan §1): "Vantage Host: Listening on
/// drew-pc" · "Connected: Drew's iPad" · — · Show Pairing Code… · Send File to ⟨iPad⟩… · Disconnect
/// ⟨iPad⟩ · — · the Files section (each file's status, Cancel ⟨file⟩, Show ⟨file⟩ in folder, Open
/// Receive Folder) · — · Settings… · Quit Vantage Host. Pure; unit-tested on macOS.
/// </summary>
public static class TrayMenuModel
{
    /// <summary>Win32 tooltips hold 127 characters.</summary>
    public const int MaxTooltip = 127;

    /// <summary>
    /// Files the menu lists before "N more files…". A popup menu taller than the screen scrolls
    /// with arrows, which hides Quit; the Files page lists everything.
    /// </summary>
    public const int MaxTransfers = 5;

    /// <summary>The menu rows, top to bottom.</summary>
    public static IReadOnlyList<TrayMenuItem> Build(TrayState state)
    {
        var items = new List<TrayMenuItem>
        {
            new(Headline(state), default, false),
        };
        if (state.Clients.Count > 0)
            items.Add(new TrayMenuItem("Connected: " + string.Join(", ", state.Clients.Select(c => c.Name)), default, false));
        items.Add(TrayMenuItem.Separator);
        items.Add(new TrayMenuItem("Show Pairing Code…", new TrayCommand(TrayCommandKind.ShowPairingCode), state.IsListening));
        foreach (var target in state.FileTargets)
            items.Add(new TrayMenuItem($"Send File to {target.Name}…", new TrayCommand(TrayCommandKind.SendFile, target.ChannelId), true));
        foreach (var client in state.Clients)
            items.Add(new TrayMenuItem($"Disconnect {client.Name}", new TrayCommand(TrayCommandKind.Disconnect, client.SessionId), true));
        items.Add(TrayMenuItem.Separator);
        // The newest files, oldest of those first, so the list reads in the order they came.
        var shown = state.Transfers.Skip(Math.Max(0, state.Transfers.Count - MaxTransfers));
        foreach (var transfer in shown)
        {
            // Win32 menus have one line per item: the name and its status, then what you can do with it.
            items.Add(new TrayMenuItem($"{transfer.Name}: {transfer.Detail}", default, false));
            if (transfer.CanCancel)
                items.Add(new TrayMenuItem($"Cancel {transfer.Name}", new TrayCommand(TrayCommandKind.CancelTransfer, transfer.Id), true));
            else if (transfer.CanShow)
                items.Add(new TrayMenuItem($"Show {transfer.Name} in folder", new TrayCommand(TrayCommandKind.ShowTransfer, transfer.Id), true));
        }
        if (state.Transfers.Count > MaxTransfers)
        {
            var more = state.Transfers.Count - MaxTransfers;
            items.Add(new TrayMenuItem(more == 1 ? "1 more file…" : $"{more} more files…", new TrayCommand(TrayCommandKind.ShowTransfers), true));
        }
        items.Add(new TrayMenuItem("Open Receive Folder", new TrayCommand(TrayCommandKind.OpenReceiveFolder), true));
        items.Add(TrayMenuItem.Separator);
        items.Add(new TrayMenuItem("Settings…", new TrayCommand(TrayCommandKind.Settings), true));
        items.Add(new TrayMenuItem("Quit Casement Host", new TrayCommand(TrayCommandKind.Quit), true));
        return items;
    }

    /// <summary>The first, disabled row.</summary>
    public static string Headline(TrayState state) =>
        state.IsListening ? $"Casement Host: Listening on {state.HostName}"
        : state.Problem is { Length: > 0 } problem ? $"Casement Host: {problem}"
        : "Casement Host: Starting…";

    /// <summary>The hover tooltip, at most <see cref="MaxTooltip"/> characters. Files moving say so first (Narrator reads it).</summary>
    public static string Tooltip(TrayState state)
    {
        var text = state.TransferSummary is { Length: > 0 } moving ? $"Casement Host — {moving}"
            : state.Clients.Count switch
            {
                0 when !state.IsListening => state.Problem is { Length: > 0 } problem ? $"Casement Host — {problem}" : "Casement Host",
                0 => "Casement Host — ready",
                1 => $"Casement Host — {state.Clients[0].Name} connected",
                _ => $"Casement Host — {state.Clients.Count} devices connected",
            };
        return text.Length <= MaxTooltip ? text : text[..(MaxTooltip - 1)] + "…";
    }

    /// <summary>Escapes a label for a Win32 menu (<c>&amp;</c> would underline the next letter).</summary>
    public static string MenuText(string text) => text.Replace("&", "&&", StringComparison.Ordinal);
}

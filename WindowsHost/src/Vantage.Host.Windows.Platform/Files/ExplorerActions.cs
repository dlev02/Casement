using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;

namespace Vantage.Host.Windows.Files;

/// <summary>
/// File Explorer actions for arrived files: one window on the folder with the batch selected
/// (<c>SHOpenFolderAndSelectItems</c>), or opening a file with its default app.
/// </summary>
public static class ExplorerActions
{
    /// <summary>Opens the folder of <paramref name="paths"/> (all in one folder) with them selected.</summary>
    public static void ShowInFolder(IReadOnlyList<string> paths, ILogger? log = null)
    {
        if (paths.Count == 0) return;
        var thread = new Thread(() =>
        {
            try
            {
                CoInitializeEx(0, 2 /* COINIT_APARTMENTTHREADED */);
                SelectInFolder(paths);
            }
            catch (Exception ex)
            {
                log?.LogDebug("SHOpenFolderAndSelectItems failed ({Message}); using explorer /select", ex.Message);
                try { Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{paths[0]}\"") { UseShellExecute = false }); }
                catch (Exception fallback) { log?.LogWarning("couldn't open File Explorer: {Message}", fallback.Message); }
            }
        })
        { IsBackground = true, Name = "Vantage show in folder" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
    }

    /// <summary>Opens a file with its default app.</summary>
    public static void Open(string path, ILogger? log = null)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception ex) { log?.LogWarning("couldn't open {Path}: {Message}", path, ex.Message); }
    }

    /// <summary>Opens a folder in File Explorer.</summary>
    public static void OpenFolder(string folder, ILogger? log = null)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = false }); }
        catch (Exception ex) { log?.LogWarning("couldn't open {Folder}: {Message}", folder, ex.Message); }
    }

    private static void SelectInFolder(IReadOnlyList<string> paths)
    {
        var folder = Path.GetDirectoryName(paths[0]) ?? throw new ArgumentException("No folder.");
        Marshal.ThrowExceptionForHR(SHParseDisplayName(folder, 0, out var folderPidl, 0, out _));
        var items = new List<nint>(paths.Count);
        try
        {
            foreach (var path in paths)
            {
                if (SHParseDisplayName(path, 0, out var pidl, 0, out _) >= 0) items.Add(pidl);
            }
            var children = items.Select(ILFindLastID).ToArray();
            Marshal.ThrowExceptionForHR(SHOpenFolderAndSelectItems(folderPidl, (uint)children.Length, children, 0));
        }
        finally
        {
            foreach (var item in items) Marshal.FreeCoTaskMem(item);
            Marshal.FreeCoTaskMem(folderPidl);
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHParseDisplayName(string name, nint bindContext, out nint pidl, uint attributesIn, out uint attributesOut);

    [DllImport("shell32.dll", ExactSpelling = true)]
    private static extern int SHOpenFolderAndSelectItems(nint folder, uint count, nint[] items, uint flags);

    [DllImport("shell32.dll", ExactSpelling = true)]
    private static extern nint ILFindLastID(nint pidl);

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoInitializeEx(nint reserved, uint coInit);
}

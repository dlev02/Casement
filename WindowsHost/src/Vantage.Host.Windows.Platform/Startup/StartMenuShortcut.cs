using System.Runtime.InteropServices;
using System.Text;

namespace Vantage.Host.Windows.Startup;

/// <summary>
/// "Casement Host" in the Start menu: <c>%APPDATA%\Microsoft\Windows\Start Menu\Programs\Casement
/// Host.lnk</c>. Setup makes it, and the host writes it too when it starts, for a copy from the zip,
/// and rewrites it when its folder moved; with it, Start › "Casement" brings the host back after its
/// window was closed (a second launch opens the running copy's window, see the app's Program).
/// Plain <c>IShellLinkW</c> through built-in COM interop; nothing here needs packaging.
/// </summary>
public static class StartMenuShortcut
{
    /// <summary>The shortcut's file name (what the Start menu shows).</summary>
    public const string FileName = "Casement Host.lnk";

    /// <summary>The shortcut's tooltip.</summary>
    public const string Description = "Casement Host: control this PC from your iPhone, iPad, Mac or Vision Pro";

    /// <summary>The user's Start menu Programs folder.</summary>
    public static string DefaultDirectory => Environment.GetFolderPath(Environment.SpecialFolder.Programs);

    /// <summary>The shortcut's path in <paramref name="directory"/>. Pure.</summary>
    public static string PathIn(string directory) => Path.Combine(directory, FileName);

    /// <summary>Whether a shortcut's target is <paramref name="executablePath"/>. Pure.</summary>
    public static bool PointsAt(string? target, string executablePath) =>
        !string.IsNullOrWhiteSpace(target)
        && string.Equals(Path.GetFullPath(target), Path.GetFullPath(executablePath), StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Writes the shortcut unless one already points at <paramref name="executablePath"/>.
    /// True when it was written. Throws (<see cref="COMException"/>, <see cref="IOException"/>,
    /// <see cref="UnauthorizedAccessException"/>) when the Start menu can't be written.
    /// </summary>
    public static bool Ensure(string executablePath, string? directory = null)
    {
        var path = PathIn(directory ?? DefaultDirectory);
        if (PointsAt(TargetOf(path), executablePath)) return false;
        Write(path, executablePath);
        return true;
    }

    /// <summary>The target of the shortcut at <paramref name="path"/>, or null when there is none or it can't be read.</summary>
    public static string? TargetOf(string path)
    {
        if (!File.Exists(path)) return null;
        var link = (IShellLinkW)new ShellLink();
        try
        {
            ((IPersistFile)link).Load(path, 0);
            var buffer = new StringBuilder(1024);
            link.GetPath(buffer, buffer.Capacity, IntPtr.Zero, 0);
            return buffer.ToString();
        }
        catch (COMException)
        {
            return null;
        }
        finally
        {
            Marshal.ReleaseComObject(link);
        }
    }

    /// <summary>Writes a shortcut to <paramref name="executablePath"/> at <paramref name="path"/>, replacing any.</summary>
    public static void Write(string path, string executablePath)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var link = (IShellLinkW)new ShellLink();
        try
        {
            link.SetPath(executablePath);
            link.SetWorkingDirectory(Path.GetDirectoryName(executablePath) ?? "");
            link.SetIconLocation(executablePath, 0);
            link.SetDescription(Description);
            ((IPersistFile)link).Save(path, true);
        }
        finally
        {
            Marshal.ReleaseComObject(link);
        }
    }

    /// <summary>Deletes the shortcut, if there is one.</summary>
    public static void Remove(string? directory = null)
    {
        try
        {
            File.Delete(PathIn(directory ?? DefaultDirectory));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    [ComImport]
    [Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLink;

    [ComImport]
    [Guid("000214F9-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
        void GetHotkey(out ushort pwHotkey);
        void SetHotkey(ushort wHotkey);
        void GetShowCmd(out int piShowCmd);
        void SetShowCmd(int iShowCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
        void Resolve(IntPtr hwnd, uint fFlags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
    }

    [ComImport]
    [Guid("0000010b-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPersistFile
    {
        void GetClassID(out Guid pClassID);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string? pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile(out IntPtr ppszFileName);
    }
}

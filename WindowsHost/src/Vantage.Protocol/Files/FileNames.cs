using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace Vantage.Protocol.Files;

/// <summary>
/// Makes a file name from the other device safe to create, and picks a free one the way Finder
/// does ("Report 2.pdf") (<c>Transfer/FileNames.swift</c>, spec §10.7, plus the Windows rules).
/// </summary>
public static class FileNames
{
    /// <summary>UTF-8 bytes kept for a name.</summary>
    public const int MaxLength = 200;

    /// <summary>What a name that sanitises to nothing is called.</summary>
    public const string Fallback = "Untitled";

    private static readonly HashSet<string> s_reservedDevices = BuildReserved();

    /// <summary>
    /// The last path component only; no control, format, separator, surrogate or unassigned
    /// characters; ':' → '-'; no leading or trailing dots or spaces; at most 200 UTF-8 bytes (the
    /// extension kept when it's short). With <paramref name="windowsRules"/> (the default) also
    /// <c>&lt; &gt; " | ? *</c> → '-' and a '_' before reserved device names (CON, NUL, COM1…).
    /// </summary>
    public static string Sanitize(string raw, bool windowsRules = true)
    {
        var normalized = raw.Normalize(NormalizationForm.FormC);
        var components = normalized.Split(['/', '\\']);
        var name = components.LastOrDefault(c => c.Trim().Length > 0) ?? "";

        var builder = new StringBuilder(name.Length);
        var index = 0;
        while (index < name.Length)
        {
            var status = Rune.DecodeFromUtf16(name.AsSpan(index), out var rune, out var consumed);
            index += Math.Max(1, consumed);
            if (status != System.Buffers.OperationStatus.Done) continue; // a lone surrogate (Cs)
            switch (Rune.GetUnicodeCategory(rune))
            {
                case UnicodeCategory.Control:
                case UnicodeCategory.Format:
                case UnicodeCategory.LineSeparator:
                case UnicodeCategory.ParagraphSeparator:
                case UnicodeCategory.Surrogate:
                case UnicodeCategory.OtherNotAssigned:
                    continue;
            }
            builder.Append(rune.ToString());
        }
        name = builder.ToString().Replace(':', '-');
        if (windowsRules)
        {
            foreach (var bad in "<>\"|?*") name = name.Replace(bad, '-');
        }
        name = name.Trim();
        var start = 0;
        while (start < name.Length && (name[start] == '.' || char.IsWhiteSpace(name[start]))) start++;
        var end = name.Length;
        while (end > start && (name[end - 1] == '.' || char.IsWhiteSpace(name[end - 1]))) end--;
        name = name[start..end];
        if (name.Length == 0) return Fallback;
        name = Truncated(name);
        if (windowsRules && IsReservedDeviceName(name)) name = Truncated("_" + name);
        return name;
    }

    /// <summary>CON, PRN, AUX, NUL, COM0–9, LPT0–9 (and ¹²³), with or without an extension, any case.</summary>
    public static bool IsReservedDeviceName(string name)
    {
        var dot = name.IndexOf('.', StringComparison.Ordinal);
        var stem = (dot >= 0 ? name[..dot] : name).TrimEnd();
        return s_reservedDevices.Contains(stem);
    }

    /// <summary>Shortens the base name (never a sensible extension) to fit <see cref="MaxLength"/>, on whole grapheme clusters.</summary>
    public static string Truncated(string name)
    {
        if (Encoding.UTF8.GetByteCount(name) <= MaxLength) return name;
        var (stem, extension) = Split(name);
        var suffix = extension is null ? "" : "." + extension;
        if (Encoding.UTF8.GetByteCount(suffix) > 16) return PrefixFitting(name, MaxLength);
        return PrefixFitting(stem, MaxLength - Encoding.UTF8.GetByteCount(suffix)) + suffix;
    }

    /// <summary>"Report.pdf" → ("Report", "pdf"); "Makefile" → ("Makefile", null). A dot that is the first or last character doesn't count.</summary>
    public static (string Stem, string? Extension) Split(string name)
    {
        var dot = name.LastIndexOf('.');
        if (dot <= 0 || dot == name.Length - 1) return (name, null);
        return (name[..dot], name[(dot + 1)..]);
    }

    /// <summary>The <paramref name="number"/>th name to try: 1 is the name itself, 2 is "Report 2.pdf".</summary>
    public static string Candidate(string name, int number)
    {
        if (number <= 1) return name;
        var (stem, extension) = Split(name);
        return extension is null ? $"{stem} {number}" : $"{stem} {number}.{extension}";
    }

    /// <summary>
    /// The first <see cref="Candidate"/> not taken in <paramref name="directory"/> ("Name.ext",
    /// "Name 2.ext", … "Name 9999.ext", then a random number 10 000–999 999). Callers still expect
    /// the move to fail if another writer takes it first.
    /// </summary>
    public static string UniquePath(string name, string directory, bool caseInsensitive)
    {
        HashSet<string>? taken = null;
        if (caseInsensitive)
        {
            taken = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (Directory.Exists(directory))
            {
                foreach (var entry in Directory.EnumerateFileSystemEntries(directory)) taken.Add(Path.GetFileName(entry));
            }
        }
        bool Exists(string candidate) =>
            taken is not null ? taken.Contains(candidate) : Path.Exists(Path.Combine(directory, candidate));
        for (var number = 1; number <= 9_999; number++)
        {
            var candidate = Candidate(name, number);
            if (!Exists(candidate)) return Path.Combine(directory, candidate);
        }
        return Path.Combine(directory, Candidate(name, RandomNumberGenerator.GetInt32(10_000, 1_000_000)));
    }

    private static string PrefixFitting(string source, int bytes)
    {
        var builder = new StringBuilder();
        var used = 0;
        var elements = StringInfo.GetTextElementEnumerator(source);
        while (elements.MoveNext())
        {
            var element = (string)elements.Current;
            var size = Encoding.UTF8.GetByteCount(element);
            if (used + size > bytes) break;
            builder.Append(element);
            used += size;
        }
        return builder.ToString();
    }

    private static HashSet<string> BuildReserved()
    {
        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "CON", "PRN", "AUX", "NUL" };
        foreach (var prefix in new[] { "COM", "LPT" })
        {
            for (var digit = 0; digit <= 9; digit++) set.Add(prefix + digit.ToString(CultureInfo.InvariantCulture));
            foreach (var superscript in "¹²³") set.Add(prefix + superscript);
        }
        return set;
    }
}

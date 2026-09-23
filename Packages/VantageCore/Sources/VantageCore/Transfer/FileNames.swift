import Foundation

/// Turns a file name from the other device into one that is safe to create, and picks a free
/// name the way Finder does ("Report 2.pdf").
///
/// The name comes off the network, so it is treated as hostile: it can't climb out of the folder
/// ("../../.ssh/authorized_keys" becomes "authorized_keys"), hide itself (leading dots go), carry
/// control or bidirectional-override characters (the "invoice‮fdp.app" trick), or exceed what
/// APFS allows.
public enum FileNames {
    /// UTF-8 bytes kept for a name, leaving room under APFS's 255 for " 999" and the rest.
    public static let maxLength = 200
    /// What a name that sanitises to nothing is called.
    public static let fallback = "Untitled"

    public static func sanitize(_ raw: String) -> String {
        let normalized = raw.precomposedStringWithCanonicalMapping
        // Only the last path component counts, whichever separator the sender used.
        let components = normalized.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        var name = String(components.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "")

        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned: false
            default: true
            }
        }))
        // A colon is the path separator underneath Finder.
        name = name.replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = name.first, first == "." || first.isWhitespace { name.removeFirst() }
        while let last = name.last, last == "." || last.isWhitespace { name.removeLast() }
        guard !name.isEmpty else { return fallback }
        return truncated(name)
    }

    /// Shortens the base name (never the extension, when it is a sensible length) to fit.
    static func truncated(_ name: String) -> String {
        guard name.utf8.count > maxLength else { return name }
        let (base, ext) = split(name)
        let suffix = ext.map { ".\($0)" } ?? ""
        guard suffix.utf8.count <= 16 else { return String(prefixFitting: name, bytes: maxLength) }
        return String(prefixFitting: base, bytes: maxLength - suffix.utf8.count) + suffix
    }

    /// "Report.pdf" → ("Report", "pdf"); "Makefile" → ("Makefile", nil).
    static func split(_ name: String) -> (base: String, ext: String?) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else {
            return (name, nil)
        }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    /// The `number`th name Finder would try: 1 is the name itself, 2 is "Report 2.pdf".
    public static func candidate(_ name: String, number: Int) -> String {
        guard number > 1 else { return name }
        let (base, ext) = split(name)
        return "\(base) \(number)" + (ext.map { ".\($0)" } ?? "")
    }

    /// The first `candidate` that doesn't exist in `directory` yet. Callers should still expect
    /// the create or move to fail if another writer takes the name first, and try the next one.
    public static func uniqueURL(for name: String, in directory: URL, fileManager: FileManager = .default) -> URL {
        for number in 1...9_999 {
            let url = directory.appending(path: candidate(name, number: number), directoryHint: .notDirectory)
            if !fileManager.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        return directory.appending(path: candidate(name, number: Int.random(in: 10_000...999_999)), directoryHint: .notDirectory)
    }
}

private extension String {
    /// The longest prefix of whole characters that fits in `bytes` of UTF-8.
    init(prefixFitting source: String, bytes: Int) {
        var result = ""
        var used = 0
        for character in source {
            let size = character.utf8.count
            guard used + size <= bytes else { break }
            result.append(character)
            used += size
        }
        self = result
    }
}

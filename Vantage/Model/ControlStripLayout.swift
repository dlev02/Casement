import Foundation

/// One control the session strip can show. Everything the editor, storage, and sync need to know
/// about a control lives here, so a new case only needs its rows below and a button in
/// `ControlStrip`. The session menu and the collapse button aren't items: they're always there,
/// always last.
nonisolated enum StripItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case control, option, command, shift
    case escape, tab, leftArrow, upArrow, downArrow, rightArrow
    case spotlight, missionControl, applicationWindows, showDesktop, typePassword, sendClipboard
    case macAudio, dictate, keyboard, disconnect

    /// Groups the strip separates with a thin divider, and the editor tints alike.
    enum Category: String, CaseIterable, Sendable {
        case modifiers, keys, shortcuts, actions
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .control: "Control"
        case .option: "Option"
        case .command: "Command"
        case .shift: "Shift"
        case .escape: "Escape"
        case .tab: "Tab"
        case .leftArrow: "Left Arrow"
        case .upArrow: "Up Arrow"
        case .downArrow: "Down Arrow"
        case .rightArrow: "Right Arrow"
        case .spotlight: "Spotlight"
        case .missionControl: "Mission Control"
        case .applicationWindows: "Application Windows"
        case .showDesktop: "Show Desktop"
        case .typePassword: "Type Password"
        case .sendClipboard: "Send Clipboard"
        case .macAudio: "Mac Audio"
        case .dictate: "Dictate"
        case .keyboard: "Keyboard"
        case .disconnect: "Disconnect"
        }
    }

    var symbol: String {
        switch self {
        case .control: "control"
        case .option: "option"
        case .command: "command"
        case .shift: "shift"
        case .escape: "escape"
        case .tab: "arrow.right.to.line"
        case .leftArrow: "chevron.left"
        case .upArrow: "chevron.up"
        case .downArrow: "chevron.down"
        case .rightArrow: "chevron.right"
        case .spotlight: "magnifyingglass"
        case .missionControl: "rectangle.3.group"
        case .applicationWindows: "rectangle.on.rectangle"
        case .showDesktop: "menubar.dock.rectangle"
        case .typePassword: "key.radiowaves.forward"
        case .sendClipboard: "doc.on.clipboard"
        case .macAudio: "speaker.wave.2" // `.fill` while on
        case .dictate: "mic"
        case .keyboard: "keyboard"
        case .disconnect: "xmark.circle"
        }
    }

    /// One line under the name in the editor: the chord it sends, or what it does.
    var detail: String {
        switch self {
        case .control: "Holds ⌃ for the next key"
        case .option: "Holds ⌥ for the next key"
        case .command: "Holds ⌘ for the next key"
        case .shift: "Holds ⇧ for the next key"
        case .escape: "Esc key"
        case .tab: "Tab key"
        case .leftArrow: "← key"
        case .upArrow: "↑ key"
        case .downArrow: "↓ key"
        case .rightArrow: "→ key"
        case .spotlight: "⌘ Space"
        case .missionControl: "⌃ ↑"
        case .applicationWindows: "⌃ ↓"
        case .showDesktop: "F11"
        case .typePassword: "Types the saved password"
        case .sendClipboard: "Sends your clipboard to the Mac"
        case .macAudio: "Hear the Mac's sound on this iPad"
        case .dictate: "Hold to talk, or tap to start and stop"
        case .keyboard: "Shows the on-screen keyboard"
        case .disconnect: "Ends the session right away"
        }
    }

    var category: Category {
        switch self {
        case .control, .option, .command, .shift: .modifiers
        case .escape, .tab, .leftArrow, .upArrow, .downArrow, .rightArrow: .keys
        case .spotlight, .missionControl, .applicationWindows, .showDesktop, .typePassword, .sendClipboard: .shortcuts
        case .macAudio, .dictate, .keyboard, .disconnect: .actions
        }
    }
}

/// Which controls the session strip shows, in order. Stored as the global default
/// (`vantage.controlStrip`) and optionally per Mac (`SavedDevice.controlStrip`), which syncs with
/// the device list.
///
/// Encodes as a plain array of raw values. Decoding drops values this build doesn't know and
/// repeats, so a layout saved by a newer build (with controls added since) still loads here.
nonisolated struct ControlStripLayout: Hashable, Sendable {
    private(set) var items: [StripItem]

    init(items: [StripItem]) {
        var seen = Set<StripItem>()
        self.items = items.filter { seen.insert($0).inserted }
    }

    /// Unknown raw values (from a newer build) and repeats are dropped.
    init(rawItems: [String]) {
        self.init(items: rawItems.compactMap(StripItem.init(rawValue:)))
    }

    /// Where `@AppStorage` keeps the default layout (Settings → Controls).
    static let defaultsKey = "vantage.controlStrip"

    /// What the strip shows until someone customizes it.
    static let standard = ControlStripLayout(items: [
        .control, .option, .command, .shift,
        .escape, .tab, .leftArrow, .upArrow, .downArrow, .rightArrow,
        .spotlight, .missionControl, .typePassword,
        .macAudio, .dictate, .keyboard, .disconnect,
    ])

    /// Every standard layout that has shipped, oldest first; the last is `standard`. Append the
    /// new standard here whenever a control joins it.
    static let standardHistory: [ControlStripLayout] = [
        ControlStripLayout(items: [
            .control, .option, .command, .shift,
            .escape, .tab, .leftArrow, .upArrow, .downArrow, .rightArrow,
            .spotlight, .missionControl, .typePassword,
            .dictate, .keyboard, .disconnect,
        ]),
        standard,
    ]

    /// Where `upgradeSavedLayouts` records the standard it last brought layouts up to.
    static let standardVersionKey = "vantage.controlStripStandardVersion"

    /// A saved layout that is exactly an earlier standard was never really customized: the editor
    /// saves the whole list even on Reset to Default. It moves to the current standard, so new
    /// controls (Mac Audio) show up for people who opened the editor. Anything else is kept.
    func upgraded(fromStandardVersion version: Int) -> ControlStripLayout {
        let earlier = Self.standardHistory.prefix(Self.standardHistory.count - 1).dropFirst(max(0, version))
        return earlier.contains(self) ? Self.standard : self
    }

    /// Runs once per new standard: brings the default layout in `defaults` forward, and returns
    /// the per-Mac layouts brought forward (nil for "use the default").
    @MainActor static func upgradeSavedLayouts(defaults: UserDefaults, perMac: [ControlStripLayout?]) -> [ControlStripLayout?] {
        let current = standardHistory.count - 1
        let version = defaults.object(forKey: standardVersionKey) as? Int ?? 0
        guard version < current else { return perMac }
        if let raw = defaults.string(forKey: defaultsKey), let saved = ControlStripLayout(rawValue: raw) {
            let upgraded = saved.upgraded(fromStandardVersion: version)
            if upgraded != saved { defaults.set(upgraded.rawValue, forKey: defaultsKey) }
        }
        defaults.set(current, forKey: standardVersionKey)
        return perMac.map { layout in
            guard let layout else { return nil }
            return layout.upgraded(fromStandardVersion: version) == standard ? nil : layout
        }
    }

    /// Controls not on the strip, in their natural order.
    var hidden: [StripItem] { StripItem.allCases.filter { !items.contains($0) } }

    func contains(_ item: StripItem) -> Bool { items.contains(item) }

    /// Appends to the end; an item already shown stays where it is.
    mutating func add(_ item: StripItem) {
        guard !items.contains(item) else { return }
        items.append(item)
    }

    mutating func remove(_ item: StripItem) {
        items.removeAll { $0 == item }
    }

    /// `List.onMove` semantics: `destination` is an index in the list before the move.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().filter(items.indices.contains).map { items[$0] }
        guard !moving.isEmpty else { return }
        let before = source.filter { $0 < destination }.count
        var rest = items
        for index in source.sorted(by: >) where rest.indices.contains(index) { rest.remove(at: index) }
        let insertAt = min(max(destination - before, 0), rest.count)
        rest.insert(contentsOf: moving, at: insertAt)
        items = rest
    }

    /// Moves one item a step earlier (negative) or later (positive), for VoiceOver's Move Up and
    /// Move Down. Stops at the ends.
    mutating func move(_ item: StripItem, by offset: Int) {
        guard let index = items.firstIndex(of: item) else { return }
        let target = min(max(index + offset, 0), items.count - 1)
        guard target != index else { return }
        items.remove(at: index)
        items.insert(item, at: target)
    }

    /// Splits a strip into `count` rows for narrow windows: only where the category changes
    /// (where a separator would be), keeping the order, with the widest row as narrow as
    /// possible. Falls back to splitting anywhere when there are fewer groups than rows. Returns
    /// fewer rows when there aren't enough controls to fill them.
    ///
    /// Generic so the strip can include its fixed trailing buttons; `separatorWeight` is a
    /// separator's width as a fraction of a button's.
    static func rows<Element>(_ elements: [Element], count: Int, separatorWeight: Double = 0.2,
                              category: (Element) -> StripItem.Category) -> [[Element]] {
        guard count > 1, elements.count > 1 else { return elements.isEmpty ? [] : [elements] }
        var groups: [[Element]] = []
        for element in elements {
            if let last = groups.last?.last, category(last) == category(element) {
                groups[groups.count - 1].append(element)
            } else {
                groups.append([element])
            }
        }
        let chunks = groups.count >= count ? groups : elements.map { [$0] }
        let rowCount = min(count, chunks.count)

        func width(_ range: Range<Int>) -> Double {
            let row = chunks[range].flatMap { $0 }
            var total = Double(row.count)
            for (a, b) in zip(row, row.dropFirst()) where category(a) != category(b) { total += separatorWeight }
            return total
        }

        // Smallest widest row first, then the most even split. Small inputs (a strip has a few
        // dozen controls at most), so plain memoised search is plenty.
        // Cost is (widest row, sum of squared widths), compared in that order.
        typealias Cost = (widest: Double, squares: Double)
        var memo: [Int: (Cost, [Int])] = [:]
        func best(from start: Int, rows: Int) -> (Cost, [Int]) {
            let key = start * 64 + rows
            if let cached = memo[key] { return cached }
            var result: (Cost, [Int])
            if rows == 1 {
                let w = width(start..<chunks.count)
                result = ((w, w * w), [])
            } else {
                result = ((.infinity, .infinity), [])
                for end in (start + 1)...(chunks.count - rows + 1) {
                    let w = width(start..<end)
                    let (rest, cuts) = best(from: end, rows: rows - 1)
                    let cost: Cost = (max(w, rest.widest), w * w + rest.squares)
                    if cost < result.0 { result = (cost, [end] + cuts) }
                }
            }
            memo[key] = result
            return result
        }
        let cuts = best(from: 0, rows: rowCount).1
        var rows: [[Element]] = []
        var start = 0
        for end in cuts + [chunks.count] {
            rows.append(chunks[start..<end].flatMap { $0 })
            start = end
        }
        return rows
    }
}

extension ControlStripLayout: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawItems: try container.decode([String].self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(items.map(\.rawValue))
    }
}

/// Lets `@AppStorage` keep the default layout as a JSON string.
extension ControlStripLayout: RawRepresentable {
    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        self.init(rawItems: raw)
    }

    var rawValue: String {
        guard let data = try? JSONEncoder().encode(items.map(\.rawValue)) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

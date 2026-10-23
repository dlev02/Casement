import Foundation
import VantageCore

/// One control the session strip can show. Everything the editor, storage, and sync need to know
/// about a control lives here, so a new case only needs its rows below and a button in
/// `ControlStrip`. The session menu and the collapse button aren't items: they're always there,
/// always last.
///
/// The shortcut controls are slots, not chords: Spotlight is ⌘Space on a Mac and Search (Win S)
/// on a PC, and so on (`HostShortcut.forItem`), so one saved layout suits both. `label(for:)`,
/// `symbol(for:)` and `detail(for:)` name a control for the host at hand; the plain `label`,
/// `symbol` and `detail` describe it for any host (the default layout's editor).
nonisolated enum StripItem: String, Codable, CaseIterable, Identifiable, Sendable {
    case control, option, command, shift
    case escape, tab, leftArrow, upArrow, downArrow, rightArrow
    case startMenu, spotlight, missionControl, applicationWindows, showDesktop, taskManager, typePassword, sendClipboard
    case sendFile, macAudio, dictate, keyboard, disconnect

    /// Groups the strip separates with a thin divider, and the editor tints alike.
    enum Category: String, CaseIterable, Sendable {
        case modifiers, keys, shortcuts, actions
    }

    var id: String { rawValue }

    var label: String { label(for: nil) }
    var symbol: String { symbol(for: nil) }
    var detail: String { detail(for: nil) }

    /// The control's name on this host; nil describes it for any host.
    func label(for platform: HostPlatform?) -> String {
        if platform == .windows {
            switch self {
            case .control: return "Ctrl"
            case .option: return "Alt"
            case .command: return "Windows Key"
            default: if let shortcut = HostShortcut.forItem(self, on: .windows) { return shortcut.label }
            }
        }
        return macLabel
    }

    private var macLabel: String {
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
        case .startMenu: "Start"
        case .taskManager: "Task Manager"
        case .spotlight: "Spotlight"
        case .missionControl: "Mission Control"
        case .applicationWindows: "Application Windows"
        case .showDesktop: "Show Desktop"
        case .typePassword: "Type Password"
        case .sendClipboard: "Send Clipboard"
        case .sendFile: "Send File"
        case .macAudio: "Mac Audio"
        case .dictate: "Dictate"
        case .keyboard: "Keyboard"
        case .disconnect: "Disconnect"
        }
    }

    /// The glyph on the strip and in the editor. A PC's Ctrl, Alt and Windows keys show as words
    /// instead (`keycapText(for:)`).
    func symbol(for platform: HostPlatform?) -> String {
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
        case .startMenu: HostShortcut.start.symbol
        case .taskManager: HostShortcut.taskManager.symbol
        case .spotlight: "magnifyingglass"
        case .missionControl: "rectangle.3.group"
        case .applicationWindows: "rectangle.on.rectangle"
        case .showDesktop: "menubar.dock.rectangle"
        case .typePassword: "key.radiowaves.forward"
        case .sendClipboard: "doc.on.clipboard"
        case .sendFile: "arrow.up.doc"
        case .macAudio: "speaker.wave.2" // `.fill` while on
        case .dictate: "mic"
        case .keyboard: "keyboard"
        case .disconnect: "xmark.circle"
        }
    }

    /// A PC's modifier keys as keycap words ("ctrl", "alt", "win"), since SF Symbols has no
    /// glyph for them; nil where the symbol says it.
    func keycapText(for platform: HostPlatform?) -> String? {
        guard platform == .windows else { return nil }
        switch self {
        case .control: return "ctrl"
        case .option: return "alt"
        case .command: return "win"
        default: return nil
        }
    }

    /// One line under the name in the editor: the chord it sends, or what it does.
    func detail(for platform: HostPlatform?) -> String {
        let host = platform == nil ? "the computer" : HostNoun(platform).the
        switch (self, platform) {
        case (.control, .windows?): return "Holds Ctrl for the next key"
        case (.option, .windows?): return "Holds Alt for the next key"
        case (.command, .windows?): return "Holds the Windows key for the next key"
        case (.control, nil): return "Holds ⌃ for the next key (Ctrl on a PC)"
        case (.option, nil): return "Holds ⌥ for the next key (Alt on a PC)"
        case (.command, nil): return "Holds ⌘ for the next key (the Windows key on a PC)"
        case (.startMenu, _): return platform == nil ? "Windows key: opens Start. PCs only" : "Windows key: opens Start"
        case (.taskManager, _): return platform == nil ? "Ctrl Shift Esc. PCs only" : "Ctrl Shift Esc"
        case (.spotlight, .windows?), (.missionControl, .windows?), (.applicationWindows, .windows?), (.showDesktop, .windows?):
            return HostShortcut.forItem(self, on: .windows)?.chord ?? ""
        case (.spotlight, nil): return "⌘ Space: Spotlight, or whatever you've set there, like Raycast. Search (Win S) on a PC"
        case (.missionControl, nil): return "⌃ ↑. Task View (Win Tab) on a PC"
        case (.applicationWindows, nil): return "⌃ ↓. Switch Apps (Alt Tab) on a PC"
        case (.showDesktop, nil): return "F11. Win D on a PC"
        case (.typePassword, nil): return "Types the Mac's saved password. Macs only"
        case (.macAudio, nil): return "Hear the Mac's sound on \(LocalDevice.this). Macs only"
        case (.sendClipboard, _): return "Sends your clipboard to \(host)"
        case (.sendFile, _): return "Sends a file from \(LocalDevice.this) to \(host)"
        default: return macDetail
        }
    }

    private var macDetail: String {
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
        case .startMenu: "Windows key"
        case .taskManager: "Ctrl Shift Esc"
        case .spotlight: "⌘ Space: Spotlight, or whatever you've set there, like Raycast"
        case .missionControl: "⌃ ↑"
        case .applicationWindows: "⌃ ↓"
        case .showDesktop: "F11"
        case .typePassword: "Types the saved password"
        case .sendClipboard: "Sends your clipboard to the Mac"
        case .sendFile: "Sends a file from \(LocalDevice.this) to the Mac"
        case .macAudio: "Hear the Mac's sound on \(LocalDevice.this)"
        case .dictate: "Hold to talk, or \(LocalDevice.tap) to start and stop"
        case .keyboard: "Shows the on-screen keyboard"
        case .disconnect: "Ends the session right away"
        }
    }

    var category: Category {
        switch self {
        case .control, .option, .command, .shift: .modifiers
        case .escape, .tab, .leftArrow, .upArrow, .downArrow, .rightArrow: .keys
        case .startMenu, .spotlight, .missionControl, .applicationWindows, .showDesktop, .taskManager, .typePassword, .sendClipboard: .shortcuts
        case .sendFile, .macAudio, .dictate, .keyboard, .disconnect: .actions
        }
    }

    /// Controls this device can't use, so neither the strip nor the editor shows them: a Mac
    /// types on its own keyboard, so it has no on-screen one to show.
    static var unavailableHere: Set<StripItem> {
        #if os(macOS)
        [.keyboard]
        #else
        []
        #endif
    }

    /// `unavailableHere` plus what the host can't use: Start and Task Manager are for a PC, and a
    /// PC has no Mac Audio or saved-password typing. Nil (the default layout's editor, before
    /// any host is known) leaves them all in.
    static func unavailable(on platform: HostPlatform?) -> Set<StripItem> {
        switch platform {
        case nil: unavailableHere
        case .windows?: unavailableHere.union([.macAudio, .typePassword])
        default: unavailableHere.union([.startMenu, .taskManager])
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
    /// Start and Task Manager only show for a PC, Type Password and Mac Audio only for a Mac.
    static let standard = ControlStripLayout(items: [
        .control, .option, .command, .shift,
        .escape, .tab, .leftArrow, .upArrow, .downArrow, .rightArrow,
        .startMenu, .spotlight, .missionControl, .taskManager, .typePassword,
        .sendFile, .macAudio, .dictate, .keyboard, .disconnect,
    ])

    /// What the strip shows on a Mac until someone customizes it. The Mac has a keyboard (and
    /// the menu bar and ⌃⌥⌘ shortcuts), so it starts with only what a keyboard can't easily do.
    static let macStandard = ControlStripLayout(items: [
        .startMenu, .spotlight, .missionControl, .applicationWindows, .showDesktop, .taskManager, .typePassword,
        .sendClipboard, .dictate,
    ])

    /// Every Mac-client standard that has shipped, oldest first; the last is `macStandard`.
    static let macStandardHistory: [ControlStripLayout] = [
        ControlStripLayout(items: [
            .spotlight, .missionControl, .applicationWindows, .showDesktop, .typePassword, .sendClipboard,
            .dictate,
        ]),
        macStandard, // + Start, Task Manager
    ]

    /// The standard layout for the device this runs on.
    static var platformStandard: ControlStripLayout {
        #if os(macOS)
        macStandard
        #else
        standard
        #endif
    }

    /// Every standard layout that has shipped, oldest first; the last is `standard`. Append the
    /// new standard here whenever a control joins it.
    static let standardHistory: [ControlStripLayout] = [
        ControlStripLayout(items: [
            .control, .option, .command, .shift,
            .escape, .tab, .leftArrow, .upArrow, .downArrow, .rightArrow,
            .spotlight, .missionControl, .typePassword,
            .dictate, .keyboard, .disconnect,
        ]),
        ControlStripLayout(items: [ // + Mac Audio
            .control, .option, .command, .shift,
            .escape, .tab, .leftArrow, .upArrow, .downArrow, .rightArrow,
            .spotlight, .missionControl, .typePassword,
            .macAudio, .dictate, .keyboard, .disconnect,
        ]),
        ControlStripLayout(items: [ // + Send File
            .control, .option, .command, .shift,
            .escape, .tab, .leftArrow, .upArrow, .downArrow, .rightArrow,
            .spotlight, .missionControl, .typePassword,
            .sendFile, .macAudio, .dictate, .keyboard, .disconnect,
        ]),
        standard, // + Start, Task Manager (PCs)
    ]

    /// Where `upgradeSavedLayouts` records the standard it last brought layouts up to.
    static let standardVersionKey = "vantage.controlStripStandardVersion"

    /// A saved layout that is exactly an earlier standard was never really customized: the editor
    /// saves the whole list even on Reset to Default. It moves to the current standard, so new
    /// controls (Mac Audio, Send File) show up for people who opened the editor. The Mac client's
    /// own standard moves the same way. Anything else is kept.
    func upgraded(fromStandardVersion version: Int) -> ControlStripLayout {
        let earlier = Self.standardHistory.prefix(Self.standardHistory.count - 1).dropFirst(max(0, version))
        if earlier.contains(self) { return Self.standard }
        if Self.macStandardHistory.dropLast().contains(self) { return Self.macStandard }
        return self
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
            let upgraded = layout.upgraded(fromStandardVersion: version)
            return upgraded == standard ? nil : upgraded
        }
    }

    /// Controls not on the strip, in their natural order.
    var hidden: [StripItem] { StripItem.allCases.filter { !items.contains($0) } }

    func contains(_ item: StripItem) -> Bool { items.contains(item) }

    /// The controls this device shows, in order. A Mac's layout can come from an iPad through
    /// iCloud, so it may hold controls a Mac can't use; they're skipped here, never removed.
    func visibleItems(excluding unavailable: Set<StripItem> = StripItem.unavailableHere) -> [StripItem] {
        items.filter { !unavailable.contains($0) }
    }

    /// `hidden`, less the controls this device can't use.
    func hiddenItems(excluding unavailable: Set<StripItem> = StripItem.unavailableHere) -> [StripItem] {
        hidden.filter { !unavailable.contains($0) }
    }

    /// Takes `edited` as the new order of the controls this device shows, and keeps each one it
    /// can't show right after the control it followed before (or at the start), so editing a
    /// synced layout on the Mac leaves the iPad's Keyboard button where it was.
    func replacingVisible(with edited: [StripItem], unavailable: Set<StripItem> = StripItem.unavailableHere) -> ControlStripLayout {
        var result = edited.filter { !unavailable.contains($0) }
        var anchor: StripItem?
        for item in items {
            if unavailable.contains(item) {
                let index = anchor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                result.insert(item, at: index)
                anchor = item
            } else if result.contains(item) {
                anchor = item
            }
        }
        return ControlStripLayout(items: result)
    }

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
    /// `splittingGroups` lets a group carry on into the next row, for a phone too narrow for
    /// whole groups in few rows: the widest row is still as narrow as possible, then cuts land
    /// where the category changes wherever they can.
    ///
    /// Generic so the strip can include its fixed trailing buttons; `separatorWeight` is a
    /// separator's width as a fraction of a button's.
    static func rows<Element>(_ elements: [Element], count: Int, separatorWeight: Double = 0.2,
                              splittingGroups: Bool = false,
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
        let chunks = groups.count >= count && !splittingGroups ? groups : elements.map { [$0] }
        let rowCount = min(count, chunks.count)

        func width(_ range: Range<Int>) -> Double {
            let row = chunks[range].flatMap { $0 }
            var total = Double(row.count)
            for (a, b) in zip(row, row.dropFirst()) where category(a) != category(b) { total += separatorWeight }
            return total
        }

        // Smallest widest row first, then the fewest cuts inside a group, then the most even
        // split. Small inputs (a strip has a few dozen controls at most), so plain memoised
        // search is plenty.
        typealias Cost = (widest: Double, splits: Int, squares: Double)
        /// Whether a cut before `chunk` lands inside a group.
        func splitsGroup(at chunk: Int) -> Int {
            category(chunks[chunk - 1].last!) == category(chunks[chunk].first!) ? 1 : 0
        }
        var memo: [Int: (Cost, [Int])] = [:]
        func best(from start: Int, rows: Int) -> (Cost, [Int]) {
            let key = start * 64 + rows
            if let cached = memo[key] { return cached }
            var result: (Cost, [Int])
            if rows == 1 {
                let w = width(start..<chunks.count)
                result = ((w, 0, w * w), [])
            } else {
                result = ((.infinity, .max, .infinity), [])
                for end in (start + 1)...(chunks.count - rows + 1) {
                    let w = width(start..<end)
                    let (rest, cuts) = best(from: end, rows: rows - 1)
                    let cost: Cost = (max(w, rest.widest), splitsGroup(at: end) + rest.splits, w * w + rest.squares)
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

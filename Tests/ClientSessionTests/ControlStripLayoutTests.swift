import Foundation
import Testing
@testable import VantageClientLogic

@MainActor struct ControlStripLayoutTests {
    @Test func standardIsTodaysStripPlusDisconnect() {
        #expect(ControlStripLayout.standard.items == [
            .control, .option, .command, .shift,
            .escape, .tab, .leftArrow, .upArrow, .downArrow, .rightArrow,
            .spotlight, .missionControl, .typePassword,
            .sendFile, .macAudio, .dictate, .keyboard, .disconnect,
        ])
        #expect(ControlStripLayout.standard.hidden == [.applicationWindows, .showDesktop, .sendClipboard])
    }

    @Test func everyItemDescribesItself() {
        for item in StripItem.allCases {
            #expect(!item.label.isEmpty && !item.symbol.isEmpty && !item.detail.isEmpty)
        }
        #expect(StripItem.spotlight.detail == "⌘ Space")
        #expect(StripItem.disconnect.category == .actions)
        #expect(StripItem.macAudio.label == "Mac Audio" && StripItem.macAudio.category == .actions)
        #expect(StripItem.sendFile.label == "Send File" && StripItem.sendFile.symbol == "arrow.up.doc")
        #expect(StripItem.sendFile.category == .actions)
    }

    @Test func addAppendsOnceAndRemoveHides() {
        var layout = ControlStripLayout.standard
        layout.add(.showDesktop)
        layout.add(.showDesktop)
        #expect(layout.items.last == .showDesktop)
        #expect(layout.items.filter { $0 == .showDesktop }.count == 1)
        layout.remove(.escape)
        #expect(!layout.contains(.escape))
        #expect(layout.hidden.contains(.escape))
        #expect(Set(layout.items).union(layout.hidden) == Set(StripItem.allCases))
    }

    @Test func moveMatchesListOnMove() {
        var layout = ControlStripLayout(items: [.escape, .tab, .dictate, .keyboard])
        // Drag Escape below Dictate: List passes the destination as an index before the move.
        layout.move(fromOffsets: [0], toOffset: 3)
        #expect(layout.items == [.tab, .dictate, .escape, .keyboard])
        layout.move(fromOffsets: [3], toOffset: 0)
        #expect(layout.items == [.keyboard, .tab, .dictate, .escape])
        layout.move(fromOffsets: [0, 1], toOffset: 4)
        #expect(layout.items == [.dictate, .escape, .keyboard, .tab])
    }

    @Test func stepMovesStopAtTheEnds() {
        var layout = ControlStripLayout(items: [.escape, .tab, .dictate])
        layout.move(.escape, by: -1)
        #expect(layout.items == [.escape, .tab, .dictate])
        layout.move(.escape, by: 1)
        #expect(layout.items == [.tab, .escape, .dictate])
        layout.move(.dictate, by: 1)
        #expect(layout.items == [.tab, .escape, .dictate])
    }

    @Test func decodingDropsUnknownControlsAndRepeats() throws {
        let json = Data(#"["escape","holoDeck","tab","escape","teleport","disconnect"]"#.utf8)
        let layout = try JSONDecoder().decode(ControlStripLayout.self, from: json)
        #expect(layout.items == [.escape, .tab, .disconnect])
        #expect(ControlStripLayout(items: [.tab, .tab, .shift]).items == [.tab, .shift])
    }

    @Test func encodesAsAPlainArray() throws {
        let data = try JSONEncoder().encode(ControlStripLayout(items: [.escape, .disconnect]))
        #expect(String(decoding: data, as: UTF8.self) == #"["escape","disconnect"]"#)
    }

    @Test func rawValueRoundTripsForAppStorage() {
        let layout = ControlStripLayout(items: [.dictate, .spotlight, .shift])
        #expect(ControlStripLayout(rawValue: layout.rawValue) == layout)
        #expect(ControlStripLayout(rawValue: ControlStripLayout.standard.rawValue) == .standard)
        #expect(ControlStripLayout(rawValue: "not json") == nil)
        #expect(ControlStripLayout(rawValue: #"["escape","someday"]"#)?.items == [.escape])
    }

    @Test func savedDeviceWithoutLayoutDecodesAndRoundTrips() throws {
        let old = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Studio Mac","host":"studio.ts.net","port":47820,"os":"macOS","connectionCount":3,"naturalScroll":true}"#.utf8)
        var device = try JSONDecoder().decode(SavedDevice.self, from: old)
        #expect(device.controlStrip == nil)
        #expect(device.playMacAudio == nil) // Mac Audio stays off for Macs saved before it existed
        device.controlStrip = ControlStripLayout(items: [.escape, .disconnect])
        device.playMacAudio = true
        let again = try JSONDecoder().decode(SavedDevice.self, from: JSONEncoder().encode(device))
        #expect(again.controlStrip?.items == [.escape, .disconnect])
        #expect(again.playMacAudio == true)
    }

    @Test func layoutsSavedAsTheOldStandardPickUpMacAudioOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "ControlStripLayoutTests.\(UUID())"))
        let old = ControlStripLayout.standardHistory[0]
        #expect(!old.contains(.macAudio) && ControlStripLayout.standardHistory.last == .standard)
        defaults.set(old.rawValue, forKey: ControlStripLayout.defaultsKey)
        let custom = ControlStripLayout(items: [.escape, .disconnect])
        let perMac = ControlStripLayout.upgradeSavedLayouts(defaults: defaults, perMac: [old, custom, nil])
        #expect(perMac == [nil, custom, nil])
        #expect(ControlStripLayout(rawValue: defaults.string(forKey: ControlStripLayout.defaultsKey)!) == .standard)

        // Only once: someone who then removes Mac Audio (back to the old list) keeps that choice.
        defaults.set(old.rawValue, forKey: ControlStripLayout.defaultsKey)
        #expect(ControlStripLayout.upgradeSavedLayouts(defaults: defaults, perMac: [old]) == [old])
        #expect(ControlStripLayout(rawValue: defaults.string(forKey: ControlStripLayout.defaultsKey)!) == old)
    }

    /// Someone who got the Mac Audio standard (and saved it from the editor) picks up Send
    /// File the same way, once.
    @Test func layoutsSavedAsTheMacAudioStandardPickUpSendFileOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "ControlStripLayoutTests.\(UUID())"))
        #expect(ControlStripLayout.standardHistory.count == 3)
        let macAudioStandard = ControlStripLayout.standardHistory[1]
        #expect(macAudioStandard.contains(.macAudio) && !macAudioStandard.contains(.sendFile))
        defaults.set(1, forKey: ControlStripLayout.standardVersionKey)
        defaults.set(macAudioStandard.rawValue, forKey: ControlStripLayout.defaultsKey)
        let perMac = ControlStripLayout.upgradeSavedLayouts(defaults: defaults, perMac: [macAudioStandard, ControlStripLayout.standardHistory[0]])
        // Version 1 had already moved the oldest standard; a layout still equal to it was chosen.
        #expect(perMac == [nil, ControlStripLayout.standardHistory[0]])
        #expect(ControlStripLayout(rawValue: defaults.string(forKey: ControlStripLayout.defaultsKey)!) == .standard)
        #expect(defaults.integer(forKey: ControlStripLayout.standardVersionKey) == 2)
    }

    // MARK: Wrapping

    private func widths(_ rows: [[StripItem]]) -> [Int] { rows.map(\.count) }

    @Test func rowsSplitOnlyWhereTheCategoryChanges() {
        let items = ControlStripLayout.standard.items
        let rows = ControlStripLayout.rows(items, count: 3) { $0.category }
        #expect(rows.flatMap { $0 } == items)
        #expect(widths(rows) == [4, 6, 8]) // modifiers | keys | shortcuts + actions
        for row in rows.dropFirst() {
            let before = items[items.firstIndex(of: row[0])! - 1]
            #expect(before.category != row[0].category)
        }
    }

    @Test func twoRowsAreAsEvenAsTheGroupsAllow() {
        let rows = ControlStripLayout.rows(ControlStripLayout.standard.items, count: 2) { $0.category }
        #expect(widths(rows) == [10, 8])
    }

    @Test func oneRowAndTooFewControlsStayTogether() {
        #expect(ControlStripLayout.rows([StripItem.escape, .tab], count: 1) { $0.category } == [[.escape, .tab]])
        #expect(ControlStripLayout.rows([StripItem.escape], count: 3) { $0.category } == [[.escape]])
        #expect(ControlStripLayout.rows([StripItem](), count: 2) { $0.category }.isEmpty)
    }

    @Test func oneGroupSplitsAnywhereWhenItMust() {
        let keys: [StripItem] = [.escape, .tab, .leftArrow, .upArrow, .downArrow, .rightArrow]
        #expect(widths(ControlStripLayout.rows(keys, count: 2) { $0.category }) == [3, 3])
    }
}

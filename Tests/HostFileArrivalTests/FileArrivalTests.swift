import Foundation
import Testing
@testable import VantageHostFiles

/// A throwaway folder, removed when the test's value goes away.
private final class Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "arrival-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String, contents: String = "x", executable: Bool = false) throws -> URL {
        let file = url.appending(path: name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        return file
    }
}

private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/received/\(name)") }

@Suite struct FileArrivalSettingsTests {
    @Test func defaultsNotifyAndShowInFinder() throws {
        let defaults = try #require(UserDefaults(suiteName: "arrival-tests-\(UUID().uuidString)"))
        let settings = FileArrivalSettings(defaults: defaults)
        #expect(settings == FileArrivalSettings())
        #expect(settings.notify)
        #expect(settings.action == .showInFinder)
        #expect(settings.showOnScreen)
        #expect(settings.folderPath == nil)
    }

    @Test func readsWhatSettingsStored() throws {
        let defaults = try #require(UserDefaults(suiteName: "arrival-tests-\(UUID().uuidString)"))
        defaults.set(false, forKey: FileArrivalSettings.Key.notify)
        defaults.set(FileArrivalAction.open.rawValue, forKey: FileArrivalSettings.Key.action)
        defaults.set(false, forKey: FileArrivalSettings.Key.showOnScreen)
        defaults.set("/Users/drew/Projects", forKey: FileArrivalSettings.Key.folder)
        #expect(FileArrivalSettings(defaults: defaults)
                == FileArrivalSettings(notify: false, action: .open, showOnScreen: false, folderPath: "/Users/drew/Projects"))
    }

    @Test func unknownActionAndEmptyFolderFallBack() throws {
        let defaults = try #require(UserDefaults(suiteName: "arrival-tests-\(UUID().uuidString)"))
        defaults.set("launch", forKey: FileArrivalSettings.Key.action)
        defaults.set("", forKey: FileArrivalSettings.Key.folder)
        let settings = FileArrivalSettings(defaults: defaults)
        #expect(settings.action == .showInFinder)
        #expect(settings.folderPath == nil)
    }
}

@Suite struct ReceiveFolderTests {
    let downloads = URL(fileURLWithPath: "/Users/drew/Downloads", isDirectory: true)

    @Test func noChoiceMeansDownloads() {
        let resolved = ReceiveFolder.resolve(choice: nil, downloads: downloads)
        #expect(resolved.url == downloads)
        #expect(!resolved.isFallback)
    }

    @Test func usesTheChosenFolderWhileItExists() throws {
        let scratch = try Scratch()
        let resolved = ReceiveFolder.resolve(choice: scratch.url.path, downloads: downloads)
        #expect(resolved.url.standardizedFileURL.path == scratch.url.standardizedFileURL.path)
        #expect(!resolved.isFallback)
    }

    @Test func missingFolderFallsBackToDownloads() {
        let gone = "/tmp/vantage-no-such-folder-\(UUID().uuidString)"
        let resolved = ReceiveFolder.resolve(choice: gone, downloads: downloads)
        #expect(resolved.url == downloads)
        #expect(resolved.unavailableChoice == gone)
    }

    @Test func aFileOrReadOnlyFolderFallsBack() throws {
        let scratch = try Scratch()
        let file = try scratch.file("not-a-folder")
        #expect(ReceiveFolder.resolve(choice: file.path, downloads: downloads).isFallback)

        let locked = scratch.url.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        #expect(ReceiveFolder.resolve(choice: locked.path, downloads: downloads).isFallback)
    }
}

@Suite struct AutoOpenTests {
    @Test(arguments: ["Photo.jpg", "IMG_0001.HEIC", "shot.png", "Clip.mov", "clip.mp4", "Song.mp3", "memo.m4a",
                      "Report.pdf", "notes.txt", "README.md", "data.csv", "data.json", "letter.rtf", "Essay.docx",
                      "Budget.xlsx", "Deck.pptx", "Essay.doc", "Draft.pages", "Talk.key", "Sheet.numbers", "Book.epub",
                      "model.usdz", "REPORT.PDF"])
    func documentsOpen(_ name: String) {
        #expect(AutoOpen.isSafe(url(name)))
    }

    @Test(arguments: ["Tool.app", "run.command", "install.sh", "script.py", "Do.scpt", "Do.applescript", "app.js",
                      "Setup.pkg", "Setup.mpkg", "Installer.dmg", "disk.iso", "Archive.zip", "backup.tar", "log.gz",
                      "stuff.7z", "tool.jar", "setup.exe", "run.bat", "Link.webloc", "Link.inetloc", "Local.fileloc",
                      "Flow.workflow", "Thing.shortcut", "Profile.terminal", "Profile.mobileconfig", "Pane.prefPane",
                      "page.html", "page.webarchive", "drawing.svg", "Macro.docm", "Macro.xlsm", "Code.swift",
                      "Invite.ics", "Card.vcf", "Invoice.pdf.app", "Invoice.pdf.command", "noextension"])
    func codeInstallersArchivesAndPointersDoNot(_ name: String) {
        #expect(!AutoOpen.isSafe(url(name)))
    }

    @Test func whatIsOnDiskCountsToo() throws {
        let scratch = try Scratch()
        #expect(AutoOpen.isSafe(try scratch.file("photo.jpg")))
        #expect(!AutoOpen.isSafe(try scratch.file("tool", contents: "#!/bin/sh\necho hi\n", executable: true)))
    }
}

@Suite struct ArrivalBatcherTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func arrival(_ name: String, from device: String = "Drew's iPad") -> ArrivalBatcher.Arrival {
        .init(url: url(name), device: device, byteCount: 10)
    }

    @Test func aSingleFileIsHandedOverOnceItSettles() {
        var batcher = ArrivalBatcher(settle: 1.5, maxHold: 20)
        let a = UUID()
        batcher.started(a, at: t0)
        #expect(batcher.deadline == nil)
        batcher.arrived(a, arrival("a.pdf"), at: t0 + 2)
        #expect(batcher.deadline == t0 + 3.5)
        #expect(batcher.takeBatch(now: t0 + 3) == nil)
        #expect(batcher.takeBatch(now: t0 + 3.5)?.map(\.url) == [url("a.pdf")])
        #expect(batcher.deadline == nil)
        #expect(batcher.takeBatch(now: t0 + 60) == nil)
    }

    @Test func filesSentTogetherMakeOneBatch() {
        var batcher = ArrivalBatcher(settle: 1.5, maxHold: 20)
        let a = UUID(), b = UUID(), c = UUID()
        batcher.started(a, at: t0)
        batcher.arrived(a, arrival("a.pdf"), at: t0 + 1)
        batcher.started(b, at: t0 + 1.05)
        // Still coming in: nothing is handed over until the queue drains (or maxHold).
        #expect(batcher.takeBatch(now: t0 + 5) == nil)
        batcher.arrived(b, arrival("b.jpg"), at: t0 + 6)
        batcher.started(c, at: t0 + 6.9) // within `settle` of the last one
        batcher.arrived(c, arrival("c.mov"), at: t0 + 9)
        #expect(batcher.takeBatch(now: t0 + 10) == nil)
        #expect(batcher.takeBatch(now: t0 + 10.5)?.map(\.url.lastPathComponent) == ["a.pdf", "b.jpg", "c.mov"])
    }

    @Test func aFailedFileDoesNotHoldTheOthers() {
        var batcher = ArrivalBatcher(settle: 1.5, maxHold: 20)
        let a = UUID(), b = UUID()
        batcher.started(a, at: t0)
        batcher.arrived(a, arrival("a.pdf"), at: t0 + 1)
        batcher.started(b, at: t0 + 1.1)
        batcher.ended(b, at: t0 + 2)
        #expect(batcher.deadline == t0 + 3.5)
        #expect(batcher.takeBatch(now: t0 + 3.5)?.count == 1)
    }

    @Test func aLongTransferDoesNotHoldEarlierFilesForever() {
        var batcher = ArrivalBatcher(settle: 1.5, maxHold: 20)
        let a = UUID(), big = UUID()
        batcher.started(a, at: t0)
        batcher.arrived(a, arrival("a.pdf"), at: t0 + 1)
        batcher.started(big, at: t0 + 1.1)
        #expect(batcher.deadline == t0 + 21)
        #expect(batcher.takeBatch(now: t0 + 21)?.map(\.url.lastPathComponent) == ["a.pdf"])
        batcher.arrived(big, arrival("movie.mov"), at: t0 + 90)
        #expect(batcher.takeBatch(now: t0 + 91.5)?.map(\.url.lastPathComponent) == ["movie.mov"])
    }

    @Test func endingSomethingItNeverSawChangesNothing() {
        var batcher = ArrivalBatcher()
        batcher.ended(UUID(), at: t0)
        #expect(batcher.deadline == nil)
        #expect(batcher.receiving.isEmpty)
    }
}

@Suite struct ArrivalPlanTests {
    let files = [url("Report.pdf"), url("Photo.jpg")]

    @Test func byDefaultItNotifiesAndSelectsTheBatchInFinder() {
        let plan = ArrivalPlan.make(files: files, settings: FileArrivalSettings(), viewedRemotely: false, bannersShowWhileShared: false)
        #expect(plan.notify)
        #expect(plan.reveal == files)
        #expect(plan.open.isEmpty)
        #expect(!plan.showOnScreen) // someone at the Mac sees the banner
    }

    @Test func onScreenNoticeOnlyWhenAWatchingIPadWouldMissTheBanner() {
        let settings = FileArrivalSettings()
        #expect(ArrivalPlan.make(files: files, settings: settings, viewedRemotely: true, bannersShowWhileShared: false).showOnScreen)
        #expect(!ArrivalPlan.make(files: files, settings: settings, viewedRemotely: true, bannersShowWhileShared: true).showOnScreen)
        var quiet = settings
        quiet.notify = false // no banner at all, so the notice stands in
        #expect(ArrivalPlan.make(files: files, settings: quiet, viewedRemotely: true, bannersShowWhileShared: true).showOnScreen)
        var off = settings
        off.showOnScreen = false
        #expect(!ArrivalPlan.make(files: files, settings: off, viewedRemotely: true, bannersShowWhileShared: false).showOnScreen)
    }

    @Test func doNothingLeavesFinderAlone() {
        let plan = ArrivalPlan.make(files: files, settings: FileArrivalSettings(action: .nothing), viewedRemotely: false,
                                    bannersShowWhileShared: false)
        #expect(plan.reveal.isEmpty && plan.open.isEmpty)
    }

    @Test func openShowsAppsAndScriptsInFinderInstead() {
        let batch = [url("Report.pdf"), url("Tool.app"), url("run.command"), url("Photo.jpg")]
        let plan = ArrivalPlan.make(files: batch, settings: FileArrivalSettings(action: .open), viewedRemotely: false,
                                    bannersShowWhileShared: false)
        #expect(plan.open == [url("Report.pdf"), url("Photo.jpg")])
        #expect(plan.notOpened == [url("Tool.app"), url("run.command")])
        #expect(plan.reveal == plan.notOpened)
        #expect(!plan.tooManyToOpen)
    }

    @Test func openStopsAtFiveAndShowsTheRestInFinder() {
        let five = (1...5).map { url("Photo \($0).jpg") }
        let fivePlan = ArrivalPlan.make(files: five, settings: FileArrivalSettings(action: .open), viewedRemotely: false,
                                        bannersShowWhileShared: false)
        #expect(fivePlan.open == five)

        let six = (1...6).map { url("Photo \($0).jpg") }
        let sixPlan = ArrivalPlan.make(files: six, settings: FileArrivalSettings(action: .open), viewedRemotely: false,
                                       bannersShowWhileShared: false)
        #expect(sixPlan.open.isEmpty)
        #expect(sixPlan.reveal == six)
        #expect(sixPlan.tooManyToOpen)
    }
}

@Suite struct ArrivalSummaryTests {
    @Test func oneFile() {
        let summary = ArrivalSummary(files: [url("Report.pdf")], devices: ["Drew's iPad"], folderName: "Downloads", isDownloads: true)
        #expect(summary.notificationTitle == "Received Report.pdf")
        #expect(summary.notificationBody == "From Drew's iPad. It's in Downloads.")
        #expect(summary.subtitle == "From Drew's iPad · in Downloads")
        #expect(summary.announcement == "Received Report.pdf from Drew's iPad")
    }

    @Test func aBatchListsTheFirstFewIntoAChosenFolder() {
        let two = ArrivalSummary(files: [url("a.pdf"), url("b.jpg")], devices: ["Drew's iPad", "Drew's iPad"],
                                 folderName: "Projects", isDownloads: false)
        #expect(two.notificationTitle == "Received 2 Files")
        #expect(two.notificationBody == "a.pdf and b.jpg, from Drew's iPad. They're in “Projects”.")

        let four = ArrivalSummary(files: [url("a.pdf"), url("b.jpg"), url("c.mov"), url("d.txt")], devices: ["Drew's iPad"],
                                  folderName: "Downloads", isDownloads: true)
        #expect(four.notificationBody == "a.pdf, b.jpg and 2 more, from Drew's iPad. They're in Downloads.")
        #expect(four.headline == "4 Files")
        #expect(four.announcement == "Received 4 files from Drew's iPad")
    }

    @Test func saysWhyAFileWasShownInsteadOfOpened() {
        let one = ArrivalSummary(files: [url("Tool.app")], devices: ["Drew's iPad"], folderName: "Downloads",
                                 isDownloads: true, notOpenedCount: 1)
        #expect(one.notificationBody == "From Drew's iPad. It's in Downloads. Vantage only opens documents and media by itself, so it's shown in Finder.")

        let mixed = ArrivalSummary(files: [url("a.pdf"), url("b.app"), url("c.sh")], devices: ["Drew's iPad"],
                                   folderName: "Downloads", isDownloads: true, notOpenedCount: 2)
        #expect(mixed.notOpenedNote == "Vantage only opens documents and media by itself, so 2 are shown in Finder.")

        let many = ArrivalSummary(files: (1...6).map { url("\($0).jpg") }, devices: ["Drew's iPad"], folderName: "Downloads",
                                  isDownloads: true, tooManyToOpen: true)
        #expect(many.notOpenedNote == "That's more than Vantage opens at once, so they're shown in Finder.")

        let opened = ArrivalSummary(files: [url("a.pdf")], devices: ["Drew's iPad"], folderName: "Downloads", isDownloads: true)
        #expect(opened.notOpenedNote == nil)
        #expect(opened.shortNotOpenedNote == nil)
        #expect(one.shortNotOpenedNote == "Shown instead of opened")
        #expect(mixed.shortNotOpenedNote == "2 shown instead of opened")
    }

    @Test func namesEverySender() {
        let summary = ArrivalSummary(files: [url("a.pdf"), url("b.pdf")], devices: ["Drew's iPad", "Drew's iPhone"],
                                     folderName: "Downloads", isDownloads: true)
        #expect(summary.sender == "Drew's iPad and Drew's iPhone")
    }
}

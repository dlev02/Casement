import AppKit
import Foundation
import Testing
import VantageCore
@testable import VantageHostClipboard

/// Collects what the bridge reports, from whichever thread it reports on.
private final class Changes: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClipboardPayload] = []
    func append(_ payload: ClipboardPayload) { lock.withLock { items.append(payload) } }
    var all: [ClipboardPayload] { lock.withLock { items } }
}

/// Hands a test's private pasteboard to a detached task.
private struct UncheckedBoard: @unchecked Sendable { let board: NSPasteboard }

private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.benjaminlevinson.vantage.tests.\(UUID().uuidString)"))
}

private func copy(_ text: String, to board: NSPasteboard) {
    board.clearContents()
    board.setString(text, forType: .string)
}

@MainActor
struct ClipboardBridgeTests {
    /// The bridge used to set a "skip the next change" flag when it applied the iPad's clipboard,
    /// but it also recorded the change count, so the flag outlived the write and swallowed the
    /// user's next real copy.
    @Test func theNextRealCopyAfterAnAppliedClipboardIsSent() {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let bridge = ClipboardBridge(pasteboard: board)
        let changes = Changes()
        bridge.onLocalChange = { changes.append($0) }

        bridge.write(ClipboardPayload(text: "from the iPad"))
        bridge.poll()
        #expect(changes.all.isEmpty, "its own write isn't a local change")

        copy("copied on the Mac", to: board)
        bridge.poll()
        #expect(changes.all.map(\.text) == ["copied on the Mac"])

        bridge.poll()
        #expect(changes.all.count == 1, "nothing new, nothing sent")
    }

    @Test func applyWritesOnTheMainThreadWithoutAnEcho() async throws {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let bridge = ClipboardBridge(pasteboard: board)
        let changes = Changes()
        bridge.onLocalChange = { changes.append($0) }

        await bridge.apply(ClipboardPayload(text: "hello"))
        #expect(board.string(forType: .string) == "hello")
        bridge.poll()
        #expect(changes.all.isEmpty)
    }

    /// A Mac client's ⌘V sends the clipboard, then the key, on one stream. The session awaits
    /// `apply` before it reads the key, so the pasteboard must already hold the payload, however
    /// large, when `apply` returns — even called from off the main thread, as the session is.
    @Test func applyReturnsOnlyOnceTheClipboardIsWritten() async throws {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        copy("the old clipboard", to: board)
        let bridge = ClipboardBridge(pasteboard: board)
        let big = String(repeating: "pasted through ⌘V. ", count: 400_000) // ~8 MB of text
        let side = 1024
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        // Checked in the same detached task, straight after `apply`, as the session reads its next
        // message. Read right here, off the main thread (fine for this private test pasteboard):
        // any hop to the main queue would line up behind a late write and pass anyway.
        let target = UncheckedBoard(board: board)
        let writtenInTime = await Task.detached { () -> Bool in
            await bridge.apply(ClipboardPayload(text: big, imagePNG: png))
            return target.board.string(forType: .string) == big && target.board.data(forType: .png) == png
        }.value
        #expect(writtenInTime)
    }

    /// The session actor reads the pasteboard from the cooperative pool; the bridge hops to the
    /// main thread for it.
    @Test func readsFromAnyThread() async {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        copy("from a background thread", to: board)
        let bridge = ClipboardBridge(pasteboard: board)
        let payload = await Task.detached { bridge.currentPayload() }.value
        #expect(payload.text == "from a background thread")
    }

    @Test func tiffOnlyImagesAreSentAsPNG() throws {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        board.clearContents()
        board.setData(try #require(rep.tiffRepresentation), forType: .tiff)
        let png = try #require(ClipboardBridge(pasteboard: board).currentPayload().imagePNG)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    /// Dictation is pasted through the Mac's clipboard; what the user had copied must come back,
    /// and neither the dictation nor the restore may reach the iPad as a copy.
    @Test func pasteGivesTheClipboardBackWithoutAnEcho() async throws {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        copy("copied on the Mac", to: board)
        let bridge = ClipboardBridge(pasteboard: board)
        let changes = Changes()
        bridge.onLocalChange = { changes.append($0) }
        let pasted = Changes()
        let boardBox = UncheckedBoard(board: board)

        await bridge.paste("a long dictation that is better pasted than typed") {
            pasted.append(ClipboardPayload(text: boardBox.board.string(forType: .string)))
        }
        #expect(pasted.all.map(\.text) == ["a long dictation that is better pasted than typed"])
        #expect(board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
        bridge.poll()

        try await Task.sleep(for: .seconds(ClipboardBridge.pasteRestoreDelay + 0.3))
        #expect(board.string(forType: .string) == "copied on the Mac")
        bridge.poll()
        #expect(changes.all.isEmpty)
    }
}

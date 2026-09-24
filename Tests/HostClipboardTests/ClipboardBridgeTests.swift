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

        bridge.apply(ClipboardPayload(text: "hello"))
        let deadline = ContinuousClock.now + .seconds(5)
        while board.string(forType: .string) != "hello" {
            #expect(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
        bridge.poll()
        #expect(changes.all.isEmpty)
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
}

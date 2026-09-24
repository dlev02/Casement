#if os(macOS)
import AppKit
import Foundation
import Testing
import VantageCore
@testable import VantageClientLogic

private func scratchPasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.benjaminlevinson.vantage.tests.\(UUID().uuidString)"))
}

/// Another app (or the host, when both run on one Mac) copying something.
private func copy(_ text: String, to board: NSPasteboard) {
    board.clearContents()
    board.setString(text, forType: .string)
}

@MainActor
struct ClipboardSyncTests {
    @Test func payloadRoundTripsThroughThePasteboard() throws {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let rtf = Data(#"{\rtf1\ansi Hello {\b world}}"#.utf8)
        let payload = ClipboardPayload(text: "Hello world", imagePNG: png, rtf: rtf)

        PasteboardSync(pasteboard: board).apply(payload)
        #expect(board.types?.contains(.tiff) == true, "Mac apps that paste only TIFF get the image too")
        #expect(PasteboardSync(pasteboard: board).currentPayload() == payload)
    }

    @Test func tiffOnlyImagesAreSentAsPNG() throws {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        board.clearContents()
        board.setData(try #require(rep.tiffRepresentation), forType: .tiff)
        let png = try #require(PasteboardSync(pasteboard: board).currentPayload().imagePNG)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    /// Client and host on one Mac share the pasteboard: the host sends each change, the client
    /// writes it, the host sees that write as a change and sends it again. The repeat must not
    /// be written, or the two bounce it forever.
    @Test func theSameMacsEchoIsWrittenOnce() {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let sync = PasteboardSync(pasteboard: board)
        copy("copied on the Mac", to: board)
        let fromHost = ClipboardPayload(text: "copied on the Mac")

        sync.apply(fromHost) // the host saw the copy
        let afterWrite = board.changeCount
        sync.apply(fromHost) // the host saw the client's write
        #expect(board.changeCount == afterWrite)
    }

    @Test func aRepeatIsWrittenAgainOnceSomethingElseWasCopied() {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let sync = PasteboardSync(pasteboard: board)
        let payload = ClipboardPayload(text: "from the Mac")
        sync.apply(payload)
        copy("something local", to: board)
        sync.apply(payload)
        #expect(board.string(forType: .string) == "from the Mac")
    }

    /// ⌘V paste-through sends the clipboard only when there's something new to send.
    @Test func changedPayloadSendsOnlyWhatsNew() {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        let sync = PasteboardSync(pasteboard: board)

        sync.apply(ClipboardPayload(text: "from the Mac"))
        #expect(sync.changedPayload() == nil, "the Mac sent it; don't send it back")

        copy("copied here", to: board)
        #expect(sync.changedPayload()?.text == "copied here")
        #expect(sync.changedPayload() == nil, "already sent")

        // The host, on the same Mac, writes back what it was just sent.
        copy("copied here", to: board)
        #expect(sync.changedPayload() == nil)
    }

    @Test func emptyPayloadsLeaveThePasteboardAlone() {
        let board = scratchPasteboard()
        defer { board.releaseGlobally() }
        copy("keep me", to: board)
        let count = board.changeCount
        PasteboardSync(pasteboard: board).apply(ClipboardPayload())
        #expect(board.changeCount == count)
    }
}
#endif

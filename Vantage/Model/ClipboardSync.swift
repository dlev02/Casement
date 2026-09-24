#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
import VantageCore

/// Bridges `UIPasteboard` and the wire clipboard payload. Reading is only done on explicit
/// user action (so iPadOS never shows a surprise paste banner); writing is silent.
@MainActor
enum ClipboardSync {
    static func apply(_ payload: ClipboardPayload) {
        guard !payload.isEmpty else { return }
        var item: [String: Any] = [:]
        if let text = payload.text { item[UTType.utf8PlainText.identifier] = text }
        if let rtf = payload.rtf { item[UTType.rtf.identifier] = rtf }
        if let png = payload.imagePNG { item[UTType.png.identifier] = png }
        UIPasteboard.general.setItems([item], options: [:])
    }

    /// Reads the iPad clipboard for sending to the Mac. Call only from a user-initiated action.
    static func currentPayload() -> ClipboardPayload {
        let board = UIPasteboard.general
        var payload = ClipboardPayload()
        if let data = board.data(forPasteboardType: UTType.png.identifier) {
            payload.imagePNG = data
        } else if let image = board.image, let png = image.pngData() {
            payload.imagePNG = png
        }
        payload.rtf = board.data(forPasteboardType: UTType.rtf.identifier)
        payload.text = board.string
        return payload
    }
}
#elseif os(macOS)
import AppKit
import VantageCore

/// Bridges the Mac's general pasteboard and the wire clipboard payload (same calls as on iOS).
///
/// Reading is only done on explicit user action: macOS 15.4+ asks before an app reads the
/// general pasteboard programmatically, except for access that is user-originated and paste
/// related (⌘V, a Send Clipboard click). Writing never asks.
@MainActor
enum ClipboardSync {
    static let general = PasteboardSync(pasteboard: .general)

    static func apply(_ payload: ClipboardPayload) { general.apply(payload) }

    /// Reads the clipboard for sending to the Mac. Call only from a user-initiated action.
    static func currentPayload() -> ClipboardPayload { general.currentPayload() }

    /// For ⌘V paste-through: the clipboard, only if it changed since it was last sent or written
    /// here, else nil. Call only from the paste itself.
    static func changedPayload() -> ClipboardPayload? { general.changedPayload() }
}

/// One pasteboard's side of clipboard sync, injectable for tests (`NSPasteboard(name:)`).
///
/// When the client and the host run on the same Mac they share one pasteboard: the host polls
/// it and sends every change to the client, which writes it back, which the host sees as a new
/// change. So a payload equal to the last one that crossed the wire is never written again while
/// the pasteboard still holds it, and never sent again.
@MainActor
final class PasteboardSync {
    /// Images larger than this aren't sent (bytes of PNG), matching the host.
    static let maxImageBytes = 24 * 1024 * 1024

    let pasteboard: NSPasteboard
    /// The last payload applied here or read for sending.
    private(set) var lastSynced: ClipboardPayload?
    /// The pasteboard's change count right after that write or read.
    private var lastChangeCount: Int

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    /// Writes a payload from the Mac. Skipped when it's what the pasteboard already holds from
    /// the last sync (the same-Mac echo); written again if anything else was copied since.
    func apply(_ payload: ClipboardPayload) {
        guard !payload.isEmpty else { return }
        if payload == lastSynced, pasteboard.changeCount == lastChangeCount { return }
        pasteboard.clearContents()
        var types: [NSPasteboard.PasteboardType] = []
        if payload.text != nil { types.append(.string) }
        if payload.rtf != nil { types.append(.rtf) }
        if payload.imagePNG != nil { types += [.png, .tiff] }
        pasteboard.declareTypes(types, owner: nil)
        if let text = payload.text { pasteboard.setString(text, forType: .string) }
        if let rtf = payload.rtf { pasteboard.setData(rtf, forType: .rtf) }
        if let png = payload.imagePNG {
            pasteboard.setData(png, forType: .png)
            // Many Mac apps paste images only as TIFF.
            if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        }
        lastSynced = payload
        lastChangeCount = pasteboard.changeCount
    }

    /// Reads the pasteboard and remembers it as sent.
    func currentPayload() -> ClipboardPayload {
        let payload = read()
        lastChangeCount = pasteboard.changeCount
        if !payload.isEmpty { lastSynced = payload }
        return payload
    }

    /// The pasteboard if something new was copied since the last sync (and it isn't what the
    /// Mac sent last), else nil. Checking the change count reads nothing.
    func changedPayload() -> ClipboardPayload? {
        guard pasteboard.changeCount != lastChangeCount else { return nil }
        let payload = read()
        lastChangeCount = pasteboard.changeCount
        guard !payload.isEmpty, payload != lastSynced else { return nil }
        lastSynced = payload
        return payload
    }

    private func read() -> ClipboardPayload {
        var payload = ClipboardPayload()
        payload.text = pasteboard.string(forType: .string)
        payload.rtf = pasteboard.data(forType: .rtf)
        if let png = pasteboard.data(forType: .png), png.count <= Self.maxImageBytes {
            payload.imagePNG = png
        } else if let tiff = pasteboard.data(forType: .tiff),
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  png.count <= Self.maxImageBytes {
            payload.imagePNG = png
        }
        return payload
    }
}
#endif

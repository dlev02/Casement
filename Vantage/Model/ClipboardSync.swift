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
#endif

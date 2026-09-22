import AppKit
import Foundation
import VantageCore

/// Polls the host pasteboard for changes and applies remote clipboard payloads without looping.
/// Carries plain text, RTF, and images (as PNG).
nonisolated final class ClipboardBridge: @unchecked Sendable {
    /// Images larger than this are not synced automatically (bytes of PNG).
    static let maxImageBytes = 24 * 1024 * 1024

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "vantage.clipboard")
    private var suppressNextChange = false
    var onLocalChange: (@Sendable (ClipboardPayload) -> Void)?

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Reads the current pasteboard as a payload (used on session start and on change).
    func currentPayload() -> ClipboardPayload {
        var payload = ClipboardPayload()
        payload.text = pasteboard.string(forType: .string)
        payload.rtf = pasteboard.data(forType: .rtf)
        if let png = pasteboard.data(forType: .png), png.count <= Self.maxImageBytes {
            payload.imagePNG = png
        } else if let tiff = pasteboard.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]),
                  png.count <= Self.maxImageBytes {
            payload.imagePNG = png
        }
        return payload
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if suppressNextChange {
            suppressNextChange = false
            return
        }
        let payload = currentPayload()
        if !payload.isEmpty {
            onLocalChange?(payload)
        }
    }

    /// Applies a payload received from the client, suppressing the resulting local-change echo.
    func apply(_ payload: ClipboardPayload) {
        queue.async {
            guard !payload.isEmpty else { return }
            self.suppressNextChange = true
            self.pasteboard.clearContents()
            var types: [NSPasteboard.PasteboardType] = []
            if payload.text != nil { types.append(.string) }
            if payload.rtf != nil { types.append(.rtf) }
            if payload.imagePNG != nil { types.append(.png); types.append(.tiff) }
            self.pasteboard.declareTypes(types, owner: nil)
            if let text = payload.text { self.pasteboard.setString(text, forType: .string) }
            if let rtf = payload.rtf { self.pasteboard.setData(rtf, forType: .rtf) }
            if let png = payload.imagePNG {
                self.pasteboard.setData(png, forType: .png)
                if let image = NSImage(data: png), let tiff = image.tiffRepresentation {
                    self.pasteboard.setData(tiff, forType: .tiff)
                }
            }
            self.lastChangeCount = self.pasteboard.changeCount
        }
    }
}

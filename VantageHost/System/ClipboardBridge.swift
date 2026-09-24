import AppKit
import Foundation
import VantageCore

/// Polls the host pasteboard for changes and applies remote clipboard payloads without looping.
/// Carries plain text, RTF, and images (as PNG).
///
/// Every pasteboard access runs on the main thread: AppKit mutates the pasteboard's owner
/// bookkeeping there, and reading it from another thread is a known crash.
nonisolated final class ClipboardBridge: @unchecked Sendable {
    /// Images larger than this are not synced automatically (bytes of PNG).
    static let maxImageBytes = 24 * 1024 * 1024

    private let pasteboard: NSPasteboard
    /// Main thread only.
    private var lastChangeCount: Int
    private var timer: DispatchSourceTimer?
    var onLocalChange: (@Sendable (ClipboardPayload) -> Void)?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
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
        onMain { self.read() }
    }

    /// Sends a change made on this Mac. Changes this bridge wrote itself are already counted.
    func poll() {
        onMain {
            let count = self.pasteboard.changeCount
            guard count != self.lastChangeCount else { return }
            self.lastChangeCount = count
            let payload = self.read()
            if !payload.isEmpty { self.onLocalChange?(payload) }
        }
    }

    /// Applies a payload received from the client. The change count it leaves behind is recorded
    /// in the same main-thread block, so the next poll never takes the write for a local copy
    /// and the one after still sees the user's next real copy.
    func apply(_ payload: ClipboardPayload) {
        guard !payload.isEmpty else { return }
        DispatchQueue.main.async { self.write(payload) }
    }

    /// Main thread.
    func write(_ payload: ClipboardPayload) {
        pasteboard.clearContents()
        var types: [NSPasteboard.PasteboardType] = []
        if payload.text != nil { types.append(.string) }
        if payload.rtf != nil { types.append(.rtf) }
        if payload.imagePNG != nil { types.append(.png); types.append(.tiff) }
        pasteboard.declareTypes(types, owner: nil)
        if let text = payload.text { pasteboard.setString(text, forType: .string) }
        if let rtf = payload.rtf { pasteboard.setData(rtf, forType: .rtf) }
        if let png = payload.imagePNG {
            pasteboard.setData(png, forType: .png)
            if let image = NSImage(data: png), let tiff = image.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
        lastChangeCount = pasteboard.changeCount
    }

    private func read() -> ClipboardPayload {
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

    /// Runs on the main thread, synchronously. The session actor calls in from the cooperative
    /// pool; the main thread never blocks on the session, so the hop can't deadlock.
    private func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }
}

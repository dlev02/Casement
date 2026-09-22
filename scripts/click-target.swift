import AppKit

// A small always-on-top window that records pointer activity so injected clicks can be verified
// without touching anything else on the desktop. Prints to stdout.
final class TargetView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseDown(with event: NSEvent) { report("mouseDown", event) }
    override func mouseUp(with event: NSEvent) { report("mouseUp", event) }
    override func rightMouseDown(with event: NSEvent) { report("rightMouseDown", event) }
    override func mouseMoved(with event: NSEvent) { report("mouseMoved", event) }
    override func mouseDragged(with event: NSEvent) { report("mouseDragged", event) }
    override func scrollWheel(with event: NSEvent) { report("scroll dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY)", event) }
    override func keyDown(with event: NSEvent) { print("keyDown code=\(event.keyCode) chars=\(event.characters ?? "") flags=\(event.modifierFlags.rawValue)"); fflush(stdout) }
    override func flagsChanged(with event: NSEvent) { print("flagsChanged flags=\(event.modifierFlags.rawValue)"); fflush(stdout) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemOrange.setFill(); bounds.fill()
        let text = "VANTAGE CLICK TARGET" as NSString
        text.draw(at: NSPoint(x: 20, y: bounds.midY), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.black])
    }
    private func report(_ what: String, _ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        print("\(what) at view (\(Int(p.x)),\(Int(p.y))) clicks=\(event.clickCount) screen=\(NSEvent.mouseLocation)")
        fflush(stdout)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// CG top-left rect x 400–700, y 300–500 on a 834pt-tall display → Cocoa origin y = 834-500 = 334.
let frame = NSRect(x: 400, y: 334, width: 300, height: 200)
let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.level = .floating
window.isOpaque = true
window.ignoresMouseEvents = false
window.contentView = TargetView(frame: NSRect(origin: .zero, size: frame.size))
window.makeKeyAndOrderFront(nil)
print("target window up at \(window.frame)"); fflush(stdout)
app.run()

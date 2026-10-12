import AppKit
import VantageCore

/// The menu bar icon: a display glyph for the host's state and, while files move, a small
/// progress ring with an arrow (down receiving, up sending) knocked out of its bottom-right corner.
/// Template images, so the menu bar tints them; cached per state and 1/24th of progress, so a
/// transfer's progress events don't redraw the icon every time.
@MainActor
enum StatusItemIcon {
    /// Files moving right now, as the icon shows them.
    struct Activity: Hashable {
        /// Progress across every active file, in 24 steps.
        let step: Int
        let receiving: Bool
        let sending: Bool

        static let steps = 24

        init?(_ transfers: [HostTransfer]) {
            let active = StatusItemIcon.moving(transfers)
            guard !active.isEmpty else { return nil }
            let total = active.reduce(UInt64(0)) { $0 + $1.byteCount }
            let done = active.reduce(UInt64(0)) { $0 + min($1.bytesDone, $1.byteCount) }
            let fraction = total > 0 ? Double(done) / Double(total) : 0
            step = min(Self.steps, Int((fraction * Double(Self.steps)).rounded(.down)))
            receiving = active.contains { $0.direction == .receiving }
            sending = active.contains { $0.direction == .sending }
        }
    }

    /// The files the icon counts as moving (the one place that decides; a paused file shouldn't spin).
    static func moving(_ transfers: [HostTransfer]) -> [HostTransfer] {
        // A file waiting for its iPad to reconnect (`interruptedAt`) can wait an hour: not moving.
        transfers.filter { $0.isActive && $0.interruptedAt == nil }
    }

    private struct Key: Hashable {
        let symbol: String
        let activity: Activity?
    }

    private static var cache: [Key: NSImage] = [:]

    static func image(for status: HostController.Status, activity: Activity?) -> NSImage {
        // While files move the ring says more than the connection arrow, so the plain display carries it.
        let key = Key(symbol: activity == nil ? symbol(for: status) : "display", activity: activity)
        if let cached = cache[key] { return cached }
        let image = render(key)
        cache[key] = image
        return image
    }

    static func symbol(for status: HostController.Status) -> String {
        switch status {
        case .connected: "display.and.arrow.down"
        case .listening, .idle: "display"
        case .error: "display.trianglebadge.exclamationmark"
        }
    }

    /// VoiceOver: "Receiving Report.pdf, 45 percent", "Sending 3 files, 10 percent".
    static func accessibilityValue(status: HostController.Status, transfers: [HostTransfer]) -> String {
        let active = moving(transfers)
        guard !active.isEmpty else {
            return switch status {
            case .connected(let count): count == 1 ? "1 device connected" : "\(count) devices connected"
            case .listening: "Ready for connections"
            case .error(let message): message
            case .idle: "Not listening"
            }
        }
        let receiving = active.allSatisfy { $0.direction == .receiving }
        let sending = active.allSatisfy { $0.direction == .sending }
        let verb = receiving ? "Receiving" : sending ? "Sending" : "Transferring"
        let what = active.count == 1 ? active[0].name : "\(active.count) files"
        let total = active.reduce(UInt64(0)) { $0 + $1.byteCount }
        let done = active.reduce(UInt64(0)) { $0 + min($1.bytesDone, $1.byteCount) }
        let fraction = total > 0 ? Double(done) / Double(total) : 0
        return "\(verb) \(what), \(fraction.formatted(.percent.precision(.fractionLength(0))))"
    }

    private static func render(_ key: Key) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: key.symbol, accessibilityDescription: "Casement Host")?
            .withSymbolConfiguration(configuration) else { return NSImage() }
        guard let activity = key.activity else {
            base.isTemplate = true
            return base
        }
        let fraction = Double(activity.step) / Double(Activity.steps)
        // Down when anything is arriving; up only when everything is going out.
        let pointsDown = activity.receiving || !activity.sending
        let size = NSSize(width: base.size.width + 3, height: base.size.height + 1)
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: 1, width: base.size.width, height: base.size.height))
            guard let context = NSGraphicsContext.current else { return true }
            let diameter: CGFloat = 10
            let center = NSPoint(x: rect.maxX - diameter / 2, y: diameter / 2)
            // A clear gap between the glyph and the badge.
            context.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: center.x - diameter / 2 - 1.5, y: center.y - diameter / 2 - 1.5,
                                        width: diameter + 3, height: diameter + 3)).fill()
            context.compositingOperation = .sourceOver

            let radius = diameter / 2 - 0.75
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.5
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * max(0.04, fraction), clockwise: true)
            arc.lineWidth = 1.5
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()

            let arrow = NSBezierPath()
            let half: CGFloat = 2.1, wing: CGFloat = 1.6
            let tip = pointsDown ? center.y - half : center.y + half
            let tail = pointsDown ? center.y + half : center.y - half
            let back = pointsDown ? tip + wing : tip - wing
            arrow.move(to: NSPoint(x: center.x, y: tail))
            arrow.line(to: NSPoint(x: center.x, y: tip))
            arrow.move(to: NSPoint(x: center.x - wing, y: back))
            arrow.line(to: NSPoint(x: center.x, y: tip))
            arrow.line(to: NSPoint(x: center.x + wing, y: back))
            arrow.lineWidth = 1.2
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Casement Host"
        return image
    }
}

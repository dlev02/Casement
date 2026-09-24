import AppKit
import QuickLookThumbnailing
import SwiftUI

/// The on-screen notice for files that just arrived: a small glass card near the top-right of the
/// screen the pointer is on (where an iPad controlling the Mac has left it), with the file's
/// preview, who sent it, where it went, and Show in Finder.
///
/// It exists because macOS hides notification banners while the screen is shared, and Vantage's
/// own capture counts as sharing, so an iPad that's watching would never see the banner. It never
/// takes focus (a non-activating panel that can't become key), sits above other apps' windows and
/// full-screen spaces, stays while the pointer is over it, and leaves by itself after a few seconds.
@MainActor
final class ArrivalNotice {
    static let shared = ArrivalNotice()

    private let model = ArrivalNoticeModel()
    private var panel: NoticePanel?
    private var dismissal: Task<Void, Never>?
    private var generation = 0
    private var lingers = false

    /// How long the notice stays; the pointer resting on it pauses the clock.
    private static let visibleFor: Duration = .seconds(6)
    private static let afterHover: Duration = .seconds(3)

    /// - Parameter lingers: stay until closed (DEBUG `--preview-arrival`, for screenshots).
    func show(_ summary: ArrivalSummary, files: [URL], lingers: Bool = false) {
        generation += 1
        let current = generation
        model.summary = summary
        model.files = files
        model.previews = []
        let panel = panel ?? makePanel()
        self.panel = panel
        let wasShowing = panel.isVisible && model.isPresented
        position(panel)
        if !wasShowing {
            model.isPresented = false
            panel.orderFrontRegardless()
            // Next turn, so the card animates in from its resting offset rather than appearing there.
            Task { @MainActor in
                guard self.generation == current else { return }
                self.model.isPresented = true
            }
        }
        announce(summary)
        self.lingers = lingers
        scheduleDismissal(after: Self.visibleFor)
        Task { await loadPreviews(for: files, generation: current) }
    }

    func dismiss() {
        dismissal?.cancel()
        guard let panel, panel.isVisible else { return }
        let current = generation
        model.isPresented = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard self.generation == current, !self.model.isPresented else { return }
            panel.orderOut(nil)
        }
    }

    private func reveal() {
        HostNotifications.reveal(model.files)
        dismiss()
    }

    private func hoverChanged(_ hovering: Bool) {
        model.isHovering = hovering
        if hovering {
            dismissal?.cancel()
        } else {
            scheduleDismissal(after: Self.afterHover)
        }
    }

    private func scheduleDismissal(after delay: Duration) {
        dismissal?.cancel()
        guard !model.isHovering, !lingers else { return }
        dismissal = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            self.dismiss()
        }
    }

    private func makePanel() -> NoticePanel {
        let root = ArrivalNoticeView(model: model, onReveal: { [weak self] in self?.reveal() },
                                     onClose: { [weak self] in self?.dismiss() })
        let hosting = NoticeHostingView(rootView: root)
        hosting.onHover = { [weak self] in self?.hoverChanged($0) }
        return NoticePanel(content: hosting)
    }

    /// Top-right of the visible area on the pointer's screen, clear of the menu bar.
    private func position(_ panel: NoticePanel) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let size = panel.contentView?.fittingSize ?? NSSize(width: ArrivalNoticeView.panelWidth, height: 120)
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.maxX - size.width + ArrivalNoticeView.margin - 14,
                             y: visible.maxY - size.height + ArrivalNoticeView.margin - 10)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// VoiceOver on the Mac hears the arrival even though the notice never takes focus.
    private func announce(_ summary: ArrivalSummary) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: summary.announcement,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    private func loadPreviews(for files: [URL], generation current: Int) async {
        var previews: [NSImage] = []
        for url in files.prefix(3) {
            previews.append(await FilePreview.image(for: url, side: 44))
        }
        guard generation == current else { return }
        model.previews = previews
    }
}

@MainActor
@Observable
final class ArrivalNoticeModel {
    var summary: ArrivalSummary?
    var files: [URL] = []
    /// Up to three, in arrival order.
    var previews: [NSImage] = []
    var isPresented = false
    var isHovering = false
}

/// A QuickLook thumbnail (a picture's own pixels, a PDF's first page) or the file's Finder icon.
@MainActor
enum FilePreview {
    static func image(for url: URL, side: CGFloat) async -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale,
                                                   representationTypes: .all)
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return representation.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
    }
}

struct ArrivalNoticeView: View {
    static let cardWidth: CGFloat = 372
    /// Transparent room around the card for its shadow and entrance.
    static let margin: CGFloat = 24
    static var panelWidth: CGFloat { cardWidth + margin * 2 }

    let model: ArrivalNoticeModel
    let onReveal: () -> Void
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        card
            // The panel is never key, which would draw the button dimmed as if disabled.
            .environment(\.controlActiveState, .key)
            .padding(Self.margin)
            .opacity(model.isPresented ? 1 : 0)
            .offset(x: model.isPresented || reduceMotion ? 0 : 18)
            .scaleEffect(model.isPresented || reduceMotion ? 1 : 0.97, anchor: .topTrailing)
            .animation(model.isPresented ? .spring(duration: 0.34, bounce: 0.08) : .easeOut(duration: 0.18), value: model.isPresented)
    }

    private var card: some View {
        HStack(spacing: 12) {
            PreviewStack(images: model.previews, count: model.files.count)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.summary?.headline ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Who sent it and where it went; just who, when that's all that fits.
                ViewThatFits(in: .horizontal) {
                    Text(model.summary?.subtitle ?? "")
                    Text(model.summary.map { "From \($0.sender)" } ?? "")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let note = model.summary?.shortNotOpenedNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(model.summary?.notOpenedNote ?? note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button("Show in Finder", action: onReveal)
                .buttonStyle(.glass)
                .controlSize(.small)
                .help(model.files.count == 1 ? "Select the file in Finder" : "Select the files in Finder")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Self.cardWidth)
        // Like a notification banner, a click anywhere does the main thing.
        .contentShape(.rect(cornerRadius: 22))
        .onTapGesture(perform: onReveal)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .overlay(alignment: .topLeading) { closeButton }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.summary?.announcement ?? "")
        .accessibilityAction(named: "Dismiss", onClose)
    }

    /// Like a notification banner's: only while the pointer is on the card.
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .offset(x: -6, y: -6)
        .opacity(model.isHovering ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: model.isHovering)
        .accessibilityLabel("Dismiss")
        .help("Dismiss")
    }
}

/// One preview, or up to three fanned like a small stack of papers.
private struct PreviewStack: View {
    let images: [NSImage]
    let count: Int
    /// The newest lies straight on top; the ones under it peek out either side.
    private static let tilt: [Double] = [0, -7, 7]
    private static let shift: [CGFloat] = [0, -3, 3]

    var body: some View {
        ZStack {
            if images.isEmpty {
                Image(systemName: count > 1 ? "doc.on.doc" : "doc")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(images.enumerated().reversed()), id: \.offset) { index, image in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .clipShape(.rect(cornerRadius: 5))
                    .shadow(color: .black.opacity(images.count > 1 ? 0.15 : 0), radius: 1.5, y: 0.5)
                    .rotationEffect(.degrees(Self.tilt[index]))
                    .offset(x: Self.shift[index])
            }
        }
        .frame(width: 46, height: 46)
    }
}

/// Borderless, transparent, never key or main: it can't pull focus from what the user is doing.
private final class NoticePanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: ArrivalNoticeView.panelWidth, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes the first click while another app is active, and tracks the pointer even though the
/// panel is never key (SwiftUI's hover only follows the key window).
private final class NoticeHostingView: NSHostingView<ArrivalNoticeView> {
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}

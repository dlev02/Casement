#if os(visionOS)
import OSLog
import SwiftUI
import UIKit

/// Shapes the session window like the Mac's display so the stream fills it edge to edge, then
/// keeps that shape while the user resizes it. Place it in the session view's background.
struct WindowAspectMatcher: UIViewRepresentable {
    /// The Mac display's size in points, once the host has said which display it's streaming.
    let displaySize: CGSize?

    func makeUIView(context: Context) -> AspectMatchingView {
        AspectMatchingView()
    }

    func updateUIView(_ view: AspectMatchingView, context: Context) {
        view.displaySize = displaySize
    }

    final class AspectMatchingView: UIView {
        private static let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "window")
        private var appliedSize: CGSize?

        var displaySize: CGSize? {
            didSet { matchWindow() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            matchWindow()
        }

        /// Keeps the window's current width and fits the height to the Mac, with uniform resizing
        /// so dragging a corner scales the whole window instead of letterboxing the video.
        private func matchWindow() {
            guard let displaySize, displaySize.width > 0, displaySize.height > 0, displaySize != appliedSize,
                  let window, let scene = window.windowScene, window.bounds.width > 0 else { return }
            appliedSize = displaySize
            let width = window.bounds.width
            let size = CGSize(width: width, height: (width * displaySize.height / displaySize.width).rounded())
            scene.requestGeometryUpdate(.Vision(size: size, resizingRestrictions: .uniform)) { error in
                Self.log.error("Couldn't fit the window to the Mac: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI

/// Lets the session's menus and toolbar resize its window (Actual Size, Full Screen).
@MainActor @Observable
final class SessionWindowShape {
    @ObservationIgnored fileprivate weak var matcher: WindowAspectMatcher.AspectMatchingView?
    /// The window is in full screen (View › Enter/Exit Full Screen says which).
    fileprivate(set) var isFullScreen = false

    /// Sizes the window so the Mac's screen shows point for point, or as large as this screen
    /// allows.
    func actualSize() { matcher?.fitWindow(animate: true) }

    func toggleFullScreen() { matcher?.window?.toggleFullScreen(nil) }
}

/// Shapes the Mac client's session window like the Mac's display, so the picture fills it with
/// no black bars, and keeps that shape while the window is resized. The first time a display is
/// known the window is sized to show it point for point, or as large as the screen allows.
/// Full screen is left alone (the picture is letterboxed there; its edges still map to the Mac's).
///
/// `contentAspectRatio` covers the whole content view, which runs under the title bar and
/// toolbar while the picture sits below them, so the ratio is worked out again for the current
/// width on every resize, with the toolbar's height added.
struct WindowAspectMatcher: NSViewRepresentable {
    /// The Mac display's size in points, once the host has said which display it's streaming.
    let displaySize: CGSize?
    let shape: SessionWindowShape

    func makeNSView(context: Context) -> AspectMatchingView {
        let view = AspectMatchingView()
        shape.matcher = view
        view.shape = shape
        return view
    }

    func updateNSView(_ view: AspectMatchingView, context: Context) {
        shape.matcher = view
        view.shape = shape
        view.displaySize = displaySize
    }

    static func dismantleNSView(_ view: AspectMatchingView, coordinator: ()) {
        view.stopObserving()
    }

    final class AspectMatchingView: NSView {
        private var hasFitted = false
        private var observers: [NSObjectProtocol] = []
        weak var shape: SessionWindowShape?

        var displaySize: CGSize? {
            didSet {
                guard displaySize != oldValue else { return }
                matchWindow(refit: true)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.matchWindow(refit: false) }
                })
            }
            for (name, entering) in [(NSWindow.willEnterFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.shape?.isFullScreen = entering }
                })
            }
            shape?.isFullScreen = isFullScreen
            matchWindow(refit: true)
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }

        private var isFullScreen: Bool { window?.styleMask.contains(.fullScreen) == true }

        /// Height of the title bar and toolbar the picture sits under.
        private func chromeHeight(of window: NSWindow) -> CGFloat {
            guard let content = window.contentView else { return 0 }
            return max(0, content.bounds.height - window.contentLayoutRect.height)
        }

        /// Sets the ratio for the current width. `refit`: a new display, so fit the window to it
        /// the first time, or square its height up to the new shape after that.
        private func matchWindow(refit: Bool) {
            guard let displaySize, displaySize.width > 0, displaySize.height > 0,
                  let window, !isFullScreen else { return }
            let width = window.contentLayoutRect.width
            guard width > 0 else { return }
            window.contentAspectRatio = NSSize(width: width, height: width * displaySize.height / displaySize.width + chromeHeight(of: window))
            guard refit else { return }
            if !hasFitted {
                hasFitted = true
                fitWindow(animate: false)
            } else {
                resize(toPictureWidth: width, animate: true)
            }
        }

        /// Point for point, or the largest that fits the screen's visible area.
        func fitWindow(animate: Bool) {
            guard let displaySize, displaySize.width > 0, displaySize.height > 0,
                  let window, !isFullScreen, let screen = window.screen ?? NSScreen.main else { return }
            let titleBar = window.frame.height - window.contentRect(forFrameRect: window.frame).height
            let available = screen.visibleFrame
            let aspect = displaySize.width / displaySize.height
            let width = min(displaySize.width, available.width, (available.height - titleBar - chromeHeight(of: window)) * aspect)
            resize(toPictureWidth: width.rounded(.down), animate: animate)
        }

        /// Resizes the window around a picture `width` points wide, keeping its top centre where
        /// it was and the whole window on screen.
        private func resize(toPictureWidth width: CGFloat, animate: Bool) {
            guard let displaySize, let window else { return }
            let height = (width * displaySize.height / displaySize.width).rounded() + chromeHeight(of: window)
            var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height))
            let old = window.frame
            frame.origin = NSPoint(x: old.midX - frame.width / 2, y: old.maxY - frame.height)
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
                frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
            }
            window.setFrame(frame, display: true, animate: animate)
        }
    }
}
#endif

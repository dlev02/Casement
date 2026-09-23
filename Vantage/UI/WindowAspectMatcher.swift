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

#if canImport(UIKit)
import SwiftUI
import UIKit
import VantageCore

/// Hosts the `RemoteInteractionView` in a view controller so it can own first-responder status
/// for the hardware keyboard and manage the home-indicator/edge behaviors during a session.
struct RemoteSessionRepresentable: UIViewControllerRepresentable {
    let input: InputController
    let video: VideoStreamController
    let stickyModifiers: KeyModifiers
    /// What VoiceOver calls the picture: "Screen of Studio".
    var screenLabel = ""
    var pencilSqueeze: PencilAction = .collapseControls
    var pencilDoubleTap: PencilAction = .rightClick
    var onPencilAction: (PencilAction) -> Void = { _ in }

    func makeUIViewController(context: Context) -> RemoteSessionViewController {
        RemoteSessionViewController(input: input, video: video)
    }

    func updateUIViewController(_ controller: RemoteSessionViewController, context: Context) {
        let view = controller.interactionView
        view.setStickyModifiers(stickyModifiers)
        view.accessibilityLabel = screenLabel
        view.pencilSqueezeAction = pencilSqueeze
        view.pencilDoubleTapAction = pencilDoubleTap
        view.onPencilAction = onPencilAction
    }
}

final class RemoteSessionViewController: UIViewController {
    let interactionView: RemoteInteractionView

    init(input: InputController, video: VideoStreamController) {
        self.interactionView = RemoteInteractionView(input: input, displayLayer: video.displayLayer)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = interactionView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        interactionView.becomeFirstResponder()
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    // No `prefersPointerLocked`: pointer lock is deliberately off (see "Input routing" in
    // CLAUDE.md). The `true` that used to be here never took effect — the session's SwiftUI
    // presentation controller doesn't ask its children (`childViewControllerForPointerLock` is
    // nil) — and if SwiftUI ever started asking, every mouse would stop moving the Mac's pointer.
}
#endif

#if os(iOS)
/// A trackpad of its own beside the picture (an iPhone Duo set up like a laptop): Trackpad mode's
/// gestures, always relative, whatever the touch mode says about the picture.
struct TrackpadSurface: UIViewRepresentable {
    let input: InputController
    let stickyModifiers: KeyModifiers

    func makeUIView(context: Context) -> RemoteInteractionView {
        RemoteInteractionView(input: input, displayLayer: nil)
    }

    func updateUIView(_ view: RemoteInteractionView, context: Context) {
        view.setStickyModifiers(stickyModifiers)
    }
}
#endif

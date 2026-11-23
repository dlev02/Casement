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
    /// The host takes Pencil pressure and tilt (`HostCapabilities.stylus`).
    var stylus = false

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
        view.stylusEnabled = stylus
    }
}

final class RemoteSessionViewController: UIViewController {
    let interactionView: RemoteInteractionView
    #if !os(visionOS)
    private let refreshHint: StreamRefreshHint
    #endif

    init(input: InputController, video: VideoStreamController) {
        self.interactionView = RemoteInteractionView(input: input, displayLayer: video.displayLayer)
        #if !os(visionOS)
        self.refreshHint = StreamRefreshHint(video: video)
        #endif
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = interactionView
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        interactionView.becomeFirstResponder()
        #if !os(visionOS)
        refreshHint.start { CADisplayLink(target: $0, selector: $1) }
        #endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        #if !os(visionOS)
        refreshHint.stop()
        #endif
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    // No `prefersPointerLocked`: pointer lock is deliberately off (see "Input routing" in
    // docs/guide/input.md). The `true` that used to be here never took effect — the session's SwiftUI
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
    /// Keys from a hardware keyboard go to the computer through this pad (Trackpad & Keyboard).
    var takesHardwareKeyboard = false

    func makeUIView(context: Context) -> RemoteInteractionView {
        let view = RemoteInteractionView(input: input, displayLayer: nil)
        if takesHardwareKeyboard { DispatchQueue.main.async { view.becomeFirstResponder() } }
        return view
    }

    func updateUIView(_ view: RemoteInteractionView, context: Context) {
        view.setStickyModifiers(stickyModifiers)
    }
}
#endif

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

    func makeUIViewController(context: Context) -> RemoteSessionViewController {
        RemoteSessionViewController(input: input, video: video)
    }

    func updateUIViewController(_ controller: RemoteSessionViewController, context: Context) {
        controller.interactionView.setStickyModifiers(stickyModifiers)
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
    override var prefersPointerLocked: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
}
#endif

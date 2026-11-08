#if os(macOS)
import AppKit
import SwiftUI
import SystemConfiguration
import VantageCore

/// Hosts the Mac client's session surface (`RemoteInteractionNSView`) in the session window.
/// SwiftUI lays it out; this only passes the session's settings down.
struct RemoteSessionNSRepresentable: NSViewRepresentable {
    let input: InputController
    let video: VideoStreamController
    /// Connected, not View Only, not locked.
    var sendsInput: Bool
    var capturesShortcuts: Bool
    var swapsCommandAndControl: Bool
    /// The modifier of the host's paste chord: ⌘ on a Mac, Ctrl on a PC.
    var pasteModifier: KeyModifiers = .command
    var stickyModifiers: KeyModifiers
    /// What VoiceOver calls the picture: "Screen of Studio".
    var screenLabel = ""
    /// Just before ⌘V goes to the Mac.
    var onPaste: () -> Void
    #if DEBUG
    var keyProbe: KeyProbe?
    #endif

    func makeNSView(context: Context) -> RemoteInteractionNSView {
        RemoteInteractionNSView(input: input, displayLayer: video.displayLayer)
    }

    func updateNSView(_ view: RemoteInteractionNSView, context: Context) {
        view.keyboard.capturesShortcuts = capturesShortcuts
        view.keyboard.swapsCommandAndControl = swapsCommandAndControl
        view.keyboard.pasteModifier = pasteModifier
        view.keyboard.onPaste = onPaste
        #if DEBUG
        view.keyboard.probe = keyProbe
        #endif
        view.stickyModifiers = stickyModifiers
        view.screenLabel = screenLabel
        view.sendsInput = sendsInput
    }

    static func dismantleNSView(_ view: RemoteInteractionNSView, coordinator: ()) {
        view.sendsInput = false // lets go of anything still held
        view.keyboard.detach()
    }
}
#endif

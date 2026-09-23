#if canImport(UIKit)
import SwiftUI
import UIKit

/// A text-input responder with no local buffer. Keeping hasText true lets Backspace reach the
/// remote Mac even when this view has never stored a character.
struct RemoteKeyboardField: UIViewRepresentable {
    @Binding var isPresented: Bool
    let onText: (String) -> Void
    let onKey: (UInt16) -> Void

    func makeUIView(context: Context) -> RemoteKeyboardView { RemoteKeyboardView() }

    func updateUIView(_ view: RemoteKeyboardView, context: Context) {
        view.onText = onText
        view.onKey = onKey
        view.onDismiss = { isPresented = false }
        view.wantsKeyboard = isPresented
        if isPresented, view.window != nil, !view.isFirstResponder { view.becomeFirstResponder() }
        else if !isPresented, view.isFirstResponder { view.resignFirstResponder() }
    }

    static func dismantleUIView(_ view: RemoteKeyboardView, coordinator: ()) {
        view.resignFirstResponder()
    }
}

final class RemoteKeyboardView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onKey: ((UInt16) -> Void)?
    var onDismiss: (() -> Void)?
    var wantsKeyboard = false
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, wantsKeyboard { becomeFirstResponder() }
    }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    override init(frame: CGRect) { super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if !os(visionOS) // no keyboard accessory views on visionOS
    /// iPadOS puts a hide-keyboard key on its own keyboard, and the control strip toggles
    /// the keyboard too, so an accessory bar there only covers more of the Mac and can't line
    /// up with the floating controls. iPhone's keyboard has no dismiss key, so it keeps one.
    private lazy var accessory: UIView? = {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return nil }
        let toolbar = UIToolbar()
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace),
                         UIBarButtonItem(title: "Done", style: .prominent, target: self, action: #selector(dismissKeyboard))]
        toolbar.sizeToFit()
        return toolbar
    }()

    override var inputAccessoryView: UIView? { accessory }
    #endif

    func insertText(_ text: String) {
        if text == "\n" || text == "\r" { onKey?(0x24) }
        else { onText?(text) }
    }

    func deleteBackward() { onKey?(0x33) }
    @objc private func dismissKeyboard() { resignFirstResponder(); onDismiss?() }
}
#endif

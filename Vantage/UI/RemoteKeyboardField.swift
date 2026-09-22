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

    override init(frame: CGRect) {
        super.init(frame: frame)
        let toolbar = UIToolbar()
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace),
                         UIBarButtonItem(title: "Done", style: .prominent, target: self, action: #selector(dismissKeyboard))]
        toolbar.sizeToFit()
        accessory = toolbar
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var accessory: UIView?
    override var inputAccessoryView: UIView? { accessory }

    func insertText(_ text: String) {
        if text == "\n" || text == "\r" { onKey?(0x24) }
        else { onText?(text) }
    }

    func deleteBackward() { onKey?(0x33) }
    @objc private func dismissKeyboard() { resignFirstResponder(); onDismiss?() }
}
#endif

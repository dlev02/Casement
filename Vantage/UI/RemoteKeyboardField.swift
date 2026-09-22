#if canImport(UIKit)
import SwiftUI
import UIKit

/// An invisible text field used to raise the software keyboard and forward typed characters
/// (including dictation and emoji) to the host as Unicode text.
struct RemoteKeyboardField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isPresented: Bool
    let onText: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if isPresented, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isPresented, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: RemoteKeyboardField
        init(_ parent: RemoteKeyboardField) { self.parent = parent }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if string.isEmpty {
                // Backspace.
                parent.onText("\u{8}")
            } else {
                parent.onText(string)
            }
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onText("\n")
            return false
        }
    }
}
#endif

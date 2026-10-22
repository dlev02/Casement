import SwiftUI

/// Prompts for the six-digit pairing code shown on the Mac or PC.
struct PairingPrompt: View {
    var host = HostNoun.mac
    @State private var code = ""
    @FocusState private var isCodeFocused: Bool
    var errorMessage: String? = nil
    let onSubmit: (String) -> Void
    /// Grows with the text so six digits never clip at the largest sizes.
    @ScaledMetric(relativeTo: .title2) private var fieldWidth: CGFloat = 160

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal.fill").font(.largeTitle).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Enter Pairing Code").font(.headline).foregroundStyle(.primary)
            Text("On your \(host.name), \(host.pairingInstruction)")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairingError")
            }
            // A fill of its own rather than .roundedBorder: over the dark session the digits
            // inherited white text on the bordered style's white field and vanished.
            TextField("000000", text: $code)
                .textFieldStyle(.plain)
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.vertical, 8)
                .frame(width: fieldWidth)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                #if canImport(UIKit)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif
            .onChange(of: code) { _, value in
                code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
            }
            .onSubmit { if code.count == 6 { onSubmit(code) } }
            .accessibilityLabel("Pairing Code")
            .focused($isCodeFocused)
            Button("Pair") { onSubmit(code) }
                .buttonStyle(.onCardProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(code.count != 6)
        }
        #if os(macOS)
        .frame(maxWidth: 360) // a session window can be far wider than an iPad; keep the prompt compact
        #endif
        .onAppear { isCodeFocused = true }
        // The error appears without focus moving to it.
        .onChange(of: errorMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
    }
}

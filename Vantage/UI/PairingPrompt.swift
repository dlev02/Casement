import SwiftUI

/// Prompts for the six-digit pairing code shown on the Mac or PC.
struct PairingPrompt: View {
    var host = HostNoun.mac
    @State private var code = ""
    @FocusState private var isCodeFocused: Bool
    var errorMessage: String? = nil
    let onSubmit: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal.fill").font(.largeTitle).foregroundStyle(.tint)
            Text("Enter Pairing Code").font(.headline).foregroundStyle(.white)
            Text("Open Vantage Host on your \(host.name) and choose “Show pairing code.”")
                .font(.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairingError")
            }
            TextField("000000", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title2, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 160)
                #if canImport(UIKit)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                #endif
            .onChange(of: code) { _, value in
                code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
            }
            .accessibilityLabel("Pairing Code")
            .focused($isCodeFocused)
            Button("Pair") { onSubmit(code) }
                .buttonStyle(.glassProminent)
                .disabled(code.count != 6)
        }
        #if os(macOS)
        .frame(maxWidth: 360) // a session window can be far wider than an iPad; keep the prompt compact
        #endif
        .onAppear { isCodeFocused = true }
    }
}

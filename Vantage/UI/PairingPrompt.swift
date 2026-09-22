import SwiftUI

/// Prompts for the six-digit pairing code shown on the Mac.
struct PairingPrompt: View {
    @State private var code = ""
    let onSubmit: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal.fill").font(.largeTitle).foregroundStyle(.tint)
            Text("Enter Pairing Code").font(.headline).foregroundStyle(.white)
            Text("Open Vantage Host on your Mac and choose “Show pairing code.”")
                .font(.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            TextField("000000", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title2, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 160)
                #if canImport(UIKit)
                .keyboardType(.numberPad)
                #endif
            Button("Pair") { onSubmit(code) }
                .buttonStyle(.glassProminent)
                .disabled(code.count < 6)
        }
    }
}

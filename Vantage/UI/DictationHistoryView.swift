import SwiftUI

/// Recent dictations, newest first: send one to the computer again or copy it, in one tap.
/// Opened from the dictation panel's clock and the session menu.
struct DictationHistoryView: View {
    /// The computer can take typing right now (connected, no secure field in the way).
    let canSend: Bool
    /// The computer Send types on, for the button's label.
    let computer: String
    let onSend: (String) -> Void
    let onCopy: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    private let history = DictationHistory.shared
    @State private var isConfirmingClear = false
    /// The entry just copied, to say so on its button for a moment.
    @State private var copiedID: UUID?

    var body: some View {
        List {
            ForEach(history.entries) { entry in
                row(entry)
            }
            .onDelete { offsets in
                for entry in offsets.map({ history.entries[$0] }) { history.remove(entry) }
            }
        }
        .overlay {
            if history.entries.isEmpty {
                ContentUnavailableView("No Dictations Yet", systemImage: "clock",
                                       description: Text("Text you send appears here, on \(LocalDevice.this) only."))
            }
        }
        .navigationTitle("Dictation History")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            // Away from Done: the far corner on iOS, the sheet's other side on the Mac.
            ToolbarItem(placement: Self.clearPlacement) {
                Button("Clear", role: .destructive) { isConfirmingClear = true }
                    .disabled(history.entries.isEmpty)
            }
        }
        .confirmationDialog("Clear dictation history?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        }
        .task { history.load() }
    }

    #if os(macOS)
    private static let clearPlacement = ToolbarItemPlacement.destructiveAction
    #else
    private static let clearPlacement = ToolbarItemPlacement.topBarLeading
    #endif

    private func row(_ entry: DictationHistory.Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.text)
                .lineLimit(4)
                .textSelection(.enabled)
            // When and where on the buttons' line if it fits whole; on its own line on a phone.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    captionText(entry)
                    Spacer(minLength: 8)
                    buttons(entry)
                }
                VStack(alignment: .leading, spacing: 8) {
                    captionText(entry)
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        buttons(entry)
                    }
                }
            }
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(role: .destructive) { history.remove(entry) } label: { Label("Remove", systemImage: "trash") }
        }
    }

    private func captionText(_ entry: DictationHistory.Entry) -> some View {
        Text(caption(for: entry))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    @ViewBuilder private func buttons(_ entry: DictationHistory.Entry) -> some View {
        Button {
            onCopy(entry.text)
            copiedID = entry.id
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if copiedID == entry.id { copiedID = nil }
            }
        } label: {
            // Only the symbol changes, so the row doesn't reflow under the finger.
            Label("Copy", systemImage: copiedID == entry.id ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(copiedID == entry.id ? "Copied" : "Copy")
        Button {
            onSend(entry.text)
            dismiss()
        } label: {
            Label("Send", systemImage: "arrow.up")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canSend)
        .accessibilityLabel("Send to \(computer)")
    }

    /// "5 minutes ago · Studio".
    private func caption(for entry: DictationHistory.Entry) -> String {
        let when = lastConnectedText(entry.date)
        guard let computer = entry.computer, !computer.isEmpty else { return when }
        return "\(when) · \(computer)"
    }
}

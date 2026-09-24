import SwiftUI

/// The Mac's display is asleep, so there's no live picture: the last one dims behind a note in
/// the same glass as the lock banner. A tap anywhere, the Wake button, or any key wakes it.
/// Covers the Mac's screen (so a tap can't click something nobody can see) but not the strip.
struct DisplayAsleepView: View {
    /// A wake was asked for and the Mac hasn't answered yet.
    let isWaking: Bool
    /// There's a frozen frame behind to dim; otherwise the background is nearly black.
    let hasPicture: Bool
    let onWake: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            Color.black.opacity(hasPicture ? 0.6 : 0.9)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onWake)
                .accessibilityHidden(true) // the note carries the words and the button
            note
                .padding(24)
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var note: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 14) { noteContent }
                .multilineTextAlignment(.center)
                .padding(20)
                .platformGlass(in: .rect(cornerRadius: 28))
                .noteAccessibility()
        } else {
            HStack(spacing: 14) { noteContent }
                .padding(.leading, 18)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .platformGlass(in: .capsule)
                .frame(maxWidth: 560)
                .noteAccessibility()
        }
    }

    @ViewBuilder private var noteContent: some View {
        Image(systemName: "moon.zzz.fill")
            .font(.title3)
            .foregroundStyle(.secondary)
            .symbolEffect(.breathe, options: .repeat(.continuous), isActive: !reduceMotion && !isWaking)
            .accessibilityHidden(true)
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .center : .leading, spacing: 2) {
            Text("The Mac's display is asleep")
                .font(.callout.weight(.semibold))
            Text(isWaking ? "Waking it…" : "Tap anywhere to wake it")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        Button(action: onWake) {
            ZStack {
                Text("Wake").opacity(isWaking ? 0 : 1) // keeps the button's width while waiting
                if isWaking { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(.glassProminent)
        .disabled(isWaking)
        .accessibilityLabel(isWaking ? "Waking the Mac's display" : "Wake the Mac's display")
        .accessibilityIdentifier("session.wakeDisplay")
    }
}

private extension View {
    func noteAccessibility() -> some View {
        accessibilityElement(children: .contain)
            .accessibilityIdentifier("session.displayAsleep")
    }
}

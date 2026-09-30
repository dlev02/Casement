import SwiftUI

/// Why there's no live picture of the Mac, shown over the last frame (dimmed) in the same glass
/// as the lock banner, never a frozen frame without a word. A tap anywhere, the button, or any key
/// sends Wake, which also makes the host try capture again. Covers the Mac's screen (so a tap
/// can't click something nobody can see) but not the strip.
struct MacScreenNote: View {
    enum Kind: Equatable {
        /// The Mac's display is asleep.
        case asleep
        /// The display is awake, but the host has had no picture for a few seconds; it keeps trying.
        case unavailable
    }

    let kind: Kind
    /// "Mac" or "PC".
    var host = HostNoun.mac
    /// Wake/Retry was sent and the Mac hasn't answered yet.
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

    private var symbol: String { kind == .asleep ? "moon.zzz.fill" : "display" }
    private var title: String {
        kind == .asleep ? "\(host.thePossessiveCapitalized) display is asleep" : "Waiting for \(host.thePossessive) screen…"
    }
    private var subtitle: String {
        switch (kind, isWaking) {
        case (.asleep, false): "\(LocalDevice.tap.capitalized) anywhere to wake it"
        case (.asleep, true): "Waking it…"
        case (.unavailable, false): "Vantage keeps trying. \(LocalDevice.tap.capitalized) to try now."
        case (.unavailable, true): "Trying again…"
        }
    }
    private var buttonTitle: String { kind == .asleep ? "Wake" : "Retry" }
    private var buttonLabel: String {
        switch (kind, isWaking) {
        case (.asleep, false): "Wake \(host.thePossessive) display"
        case (.asleep, true): "Waking \(host.thePossessive) display"
        case (.unavailable, false): "Try to show \(host.thePossessive) screen again"
        case (.unavailable, true): "Trying to show \(host.thePossessive) screen again"
        }
    }

    @ViewBuilder private var note: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 14) { noteContent }
                .multilineTextAlignment(.center)
                .padding(20)
                .platformGlass(in: .rect(cornerRadius: 28))
                .noteAccessibility(kind)
        } else {
            HStack(spacing: 14) { noteContent }
                .padding(.leading, 18)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .platformGlass(in: .capsule)
                .frame(maxWidth: 560)
                .noteAccessibility(kind)
        }
    }

    @ViewBuilder private var noteContent: some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(.secondary)
            .symbolEffect(.breathe, options: .repeat(.continuous), isActive: !reduceMotion && !isWaking)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .center : .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.semibold))
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        Button(action: onWake) {
            ZStack {
                Text(buttonTitle).opacity(isWaking ? 0 : 1) // keeps the button's width while waiting
                if isWaking { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(.onCardProminent)
        .disabled(isWaking)
        .accessibilityLabel(buttonLabel)
        .accessibilityIdentifier(kind == .asleep ? "session.wakeDisplay" : "session.retryScreen")
    }
}

private extension View {
    func noteAccessibility(_ kind: MacScreenNote.Kind) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityIdentifier(kind == .asleep ? "session.displayAsleep" : "session.screenUnavailable")
    }
}

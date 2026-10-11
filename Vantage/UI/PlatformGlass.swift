import SwiftUI

extension View {
    /// Liquid Glass on iPadOS and iOS. visionOS has no Liquid Glass; its own glass material is the
    /// native equivalent there.
    @ViewBuilder
    func platformGlass(in shape: some InsettableShape) -> some View {
        #if os(visionOS)
        glassBackgroundEffect(in: shape)
        #else
        glassEffect(in: shape)
        #endif
    }
}

#if os(visionOS)
// `.glass` and `.glassProminent` are unavailable on visionOS. These stand-ins keep the shared call
// sites unchanged; bordered buttons already render as glass platters in a visionOS window.
extension PrimitiveButtonStyle where Self == BorderedButtonStyle {
    static var glass: BorderedButtonStyle { .bordered }
}

extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle {
    static var glassProminent: BorderedProminentButtonStyle { .borderedProminent }
}
#endif

// Buttons that sit on a glass card. On the Mac a glass button on a glass card reads as one
// smear, so they're plain bordered buttons there (as they already are on visionOS); iPadOS and
// iOS keep Liquid Glass.
#if os(macOS) || os(visionOS)
extension PrimitiveButtonStyle where Self == BorderedButtonStyle {
    static var onCard: BorderedButtonStyle { .bordered }
}

extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle {
    static var onCardProminent: BorderedProminentButtonStyle { .borderedProminent }
}
#else
extension PrimitiveButtonStyle where Self == GlassButtonStyle {
    static var onCard: GlassButtonStyle { .glass }
}

extension PrimitiveButtonStyle where Self == GlassProminentButtonStyle {
    static var onCardProminent: GlassProminentButtonStyle { .glassProminent }
}
#endif

extension View {
    /// `.buttonStyle(.plain)`, except that on visionOS the gaze highlight fills the whole label in
    /// `shape`. The plain style's own highlight is a capsule hugging the label, which lit only part
    /// of a list row or card.
    @ViewBuilder
    func rowButtonStyle(in shape: some Shape) -> some View {
        #if os(visionOS)
        buttonStyle(HighlightedPlainButtonStyle(shape: shape))
        #else
        buttonStyle(.plain)
        #endif
    }
}

#if os(visionOS)
/// A custom style gets no automatic gaze highlight, so the one added here, with its shape, is
/// the only one.
private struct HighlightedPlainButtonStyle<S: Shape>: ButtonStyle {
    var shape: S

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
#endif

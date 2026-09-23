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

#if DEBUG
import SwiftUI
import WidgetKit

/// Renders the Connect widget at every size it ships in, using the live catalog, so the design
/// can be checked from `-VantageOpenScreen widgets` without placing a widget by hand. Debug only.
struct WidgetGalleryScreen: View {
    private let recents = DeviceCatalog.recents()
    private let smallSize = CGSize(width: 170, height: 170)
    private let mediumSize = CGSize(width: 364, height: 170)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 20) {
                    sample("Small", size: smallSize, family: .systemSmall,
                           primary: recents.first, others: Array(recents.dropFirst()))
                    sample("No Macs", size: smallSize, family: .systemSmall, primary: nil, others: [])
                    sample("Pinned Mac removed", size: smallSize, family: .systemSmall,
                           primary: nil, others: [], pinnedMacRemoved: true)
                }
                sample("Medium", size: mediumSize, family: .systemMedium,
                       primary: recents.first, others: Array(recents.dropFirst()))
                HStack(alignment: .top, spacing: 20) {
                    sample("Tinted (approximation)", size: mediumSize, family: .systemMedium,
                           primary: recents.first, others: Array(recents.dropFirst()), accented: true)
                    sample(" ", size: smallSize, family: .systemSmall,
                           primary: recents.first, others: [], accented: true)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Widgets")
        // Tall enough to show every sample without scrolling, for screenshots.
        .presentationSizing(.page)
    }

    /// `accented` sets the accented rendering mode and roughly mimics the Home Screen's tinted
    /// look (no container background, monochrome content over a translucent tile). The real
    /// system tint can only be seen on a Home Screen.
    private func sample(_ title: String, size: CGSize, family: WidgetFamily,
                        primary: DeviceCatalog.Mac?, others: [DeviceCatalog.Mac],
                        pinnedMacRemoved: Bool = false, accented: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ConnectWidgetView(primary: primary, others: others, pinnedMacRemoved: pinnedMacRemoved, familyOverride: family)
                .environment(\.widgetRenderingMode, accented ? .accented : .fullColor)
                .grayscale(accented ? 1 : 0)
                .padding(16)
                .frame(width: size.width, height: size.height)
                // Outside WidgetKit `containerBackground` draws nothing, so paint the same one here.
                .background(background(accented: accented), in: .rect(cornerRadius: 24))
                .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
        }
    }

    private func background(accented: Bool) -> AnyShapeStyle {
        if accented {
            return AnyShapeStyle(Color(red: 0.25, green: 0.27, blue: 0.32))
        }
        return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.06, green: 0.11, blue: 0.28), Color(red: 0.02, green: 0.04, blue: 0.12)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}
#endif

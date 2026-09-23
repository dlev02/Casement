import SwiftUI
import WidgetKit

/// What the Connect widget draws. Shared with the app so a debug screen can render every size
/// without adding the widget to a Home Screen by hand.
///
/// Small: one Mac, tap anywhere to connect. Medium: the chosen Mac plus the next two recents,
/// each its own link. Both read as "tap and you're on the Mac" — no status, no chrome, because a
/// widget can't probe the tailnet and shouldn't pretend to.
struct ConnectWidgetView: View {
    let primary: DeviceCatalog.Mac?
    let others: [DeviceCatalog.Mac]
    /// The widget was pinned to a Mac that has since been removed. Says so rather than quietly
    /// connecting somewhere else.
    var pinnedMacRemoved = false
    /// The debug gallery renders sizes side by side, where the environment can't say which.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            if pinnedMacRemoved {
                removed
            } else if let primary {
                switch familyOverride ?? environmentFamily {
                case .systemMedium: medium(primary)
                default: small(primary)
                }
            } else {
                empty
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.06, green: 0.11, blue: 0.28), Color(red: 0.02, green: 0.04, blue: 0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    // MARK: Layouts

    private func small(_ mac: DeviceCatalog.Mac) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            macGlyph(size: 30)
            Spacer(minLength: 8)
            Text(mac.name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
                .privacySensitive()
            lastUsed(mac)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(DeviceCatalog.connectURL(for: mac.id))
    }

    private func medium(_ mac: DeviceCatalog.Mac) -> some View {
        HStack(spacing: 14) {
            Link(destination: DeviceCatalog.connectURL(for: mac.id)) {
                VStack(alignment: .leading, spacing: 0) {
                    macGlyph(size: 30)
                    Spacer(minLength: 8)
                    Text(mac.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.leading)
                        .privacySensitive()
                    lastUsed(mac)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                // Fixed so the recents column keeps enough room for a full Mac name.
                .frame(width: 104, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(others.prefix(2)) { other in
                        Link(destination: DeviceCatalog.connectURL(for: other.id)) {
                            HStack(spacing: 8) {
                                Image(systemName: "laptopcomputer")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(width: 20)
                                Text(other.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .privacySensitive()
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            // Kept in every rendering mode: in accented (tinted) mode the system
                            // turns it into a translucent tinted pill, which still marks each row
                            // as its own tap target.
                            .background(.white.opacity(renderingMode == .accented ? 0.16 : 0.12), in: .rect(cornerRadius: 12))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            macGlyph(size: 26)
            Spacer(minLength: 6)
            Text("No Macs yet")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Add one in Vantage")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "vantage://")!)
    }

    private var removed: some View {
        VStack(alignment: .leading, spacing: 6) {
            macGlyph(size: 26)
            Spacer(minLength: 6)
            Text("Mac removed")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Edit the widget to choose another")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "vantage://")!)
    }

    // MARK: Pieces

    /// The same rounded blue tile the device list uses, so the widget reads as Vantage.
    private func macGlyph(size: CGFloat) -> some View {
        Image(systemName: "laptopcomputer")
            .font(.system(size: size * 0.55, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(renderingMode == .accented ? 0 : 0.9), in: .rect(cornerRadius: size * 0.28))
            .widgetAccentable()
    }

    /// A live reference to the last connection ("5 min ago"), redrawn by the system as time
    /// passes, so the one-entry timeline never shows a stale age.
    private func lastUsed(_ mac: DeviceCatalog.Mac) -> Text {
        guard let date = mac.lastConnected else { return Text("Tap to connect") }
        return Text(.currentDate, format: .reference(to: date, allowedFields: [.year, .month, .week, .day, .hour, .minute],
                                                     maxFieldCount: 1, thresholdField: .year))
    }
}

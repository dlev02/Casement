import SwiftUI

// The menu speaks System Settings' language: a hero at the top (the device, its name, one line
// of status), one prominent button, then inset grouped sections whose rows carry a coloured
// rounded-square icon, a title, and a value or chevron at the trailing edge.

enum MenuMetrics {
    static let sectionRadius: CGFloat = 12
    static let rowHeight: CGFloat = 36
    static let iconSize: CGFloat = 22
}

/// An inset grouped section: an optional small title above a rounded box of rows divided by
/// hairlines that start where the text does.
struct GroupedSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Divider().padding(.leading, 10 + MenuMetrics.iconSize + 10)
                        }
                        row
                    }
                }
            }
            .background(.quinary, in: .rect(cornerRadius: MenuMetrics.sectionRadius))
            .clipShape(.rect(cornerRadius: MenuMetrics.sectionRadius))
        }
    }
}

/// System Settings' icon: a white glyph on a coloured rounded square.
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: MenuMetrics.iconSize, height: MenuMetrics.iconSize)
            .background(color.gradient, in: .rect(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row: icon, title (and an optional line under it), then a value and/or chevron.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let symbol: String
    let color: Color
    var chevron = false
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, symbol: String, color: Color, chevron: Bool = false,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.color = color
        self.chevron = chevron
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
                .foregroundStyle(.secondary)
                .fixedSize()
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: MenuMetrics.rowHeight)
        .contentShape(.rect)
    }
}

/// A row that's a button: it lights up under the pointer, inside its section's rounded box.
struct SettingsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background(.primary.opacity(isEnabled ? (configuration.isPressed ? 0.1 : hovering ? 0.05 : 0) : 0))
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == SettingsRowButtonStyle {
    static var settingsRow: SettingsRowButtonStyle { SettingsRowButtonStyle() }
}

/// Three dots that run from one device to the other while they're connected.
struct ConnectionDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    let distance = abs(phase * 3 - Double(index) - 0.5)
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.8 : max(0.25, 1 - distance * 0.6))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The action at the end of a row that is itself a button ("Open", "Allow"): a small glass
/// capsule, so the row reads as something to click.
struct RowAction: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .glassEffect(.regular, in: .capsule)
    }
}

/// "● Connected" at the end of a device's row.
struct ConnectedBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(.green).frame(width: 6, height: 6)
            Text("Connected")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

/// One device inside the opened Paired Devices row: what it is, when it paired, whether it's
/// connected, and Remove. Remove shows under the pointer and asks once more in place (a red
/// Remove) before revoking, so a stray click in a menu never unpairs anything.
struct PairedDeviceRow: View {
    let client: TrustStore.TrustedClient
    let isConnected: Bool
    let onRemove: () -> Void
    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            // A plain glyph, not a coloured square: these sit under Paired Devices.
            Image(systemName: client.symbol)
                .font(.system(size: 14))
                .foregroundStyle(isConnected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: MenuMetrics.iconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Paired \(client.addedAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if confirming {
                Button("Remove", role: .destructive, action: onRemove)
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .help("\(client.name) won't be able to connect until it pairs again")
            } else if hovering {
                Button { confirming = true } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.body)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove \(client.name)")
            } else if isConnected {
                ConnectedBadge()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: MenuMetrics.rowHeight)
        .contentShape(.rect)
        .onHover { inside in
            hovering = inside
            if !inside { confirming = false }
        }
        .contextMenu {
            Button("Remove \(client.name)", role: .destructive, action: onRemove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isConnected ? "Connected" : "")
        .accessibilityAction(named: "Remove", onRemove)
    }
}

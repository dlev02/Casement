import SwiftUI
import VantageCore

/// The Connection card: how the session is doing, floating in a corner of the picture (a short
/// sheet on an iPhone held upright). Everything on it is what this device measures or already
/// knows; nothing is asked of the computer. The session menu's Connection item shows and hides
/// it, and so does its close button.
struct ConnectionCard: View {
    struct Facts: Equatable {
        var details: ConnectionDetails?
        var stream: StreamConfig?
        var quality: QualityPreset
        /// Over the local network rather than Tailscale; nil until connected.
        var isLocal: Bool?
        var address: String?
        var host: HostNoun
    }

    let facts: Facts
    /// Glass of its own, floating over the picture; false inside a sheet, which has its own.
    var floats = true
    let onClose: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: floats ? cardWidth : nil)
        .modifier(CardGlass(floats: floats))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection")
        .accessibilityIdentifier("session.connection")
    }

    private var cardWidth: CGFloat { dynamicTypeSize.isAccessibilitySize ? 340 : 268 }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Connection")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.onCard)
                .buttonBorderShape(.circle)
                .controlSize(.small)
                .help("Hide Connection")
                .accessibilityLabel("Hide Connection")
                .accessibilityIdentifier("session.connection.close")
            }

            group {
                row("Latency", value: facts.details?.roundTripMillis.map { "\(Int($0.rounded())) ms" }) {
                    if let history = facts.details?.roundTripHistory, history.count > 1 {
                        Sparkline(values: history)
                            .frame(width: 44, height: 14)
                    }
                }
                if let isLocal = facts.isLocal {
                    row("Route", value: isLocal ? "Local Network" : "Tailscale")
                }
                if let address = facts.address {
                    row("Address", value: address, truncates: true)
                }
            }

            Divider()

            group {
                if let size = facts.details?.pictureSize {
                    row("Picture", value: "\(Int(size.width)) × \(Int(size.height))")
                }
                if let stream = facts.stream {
                    row("Codec", value: stream.codec == .hevc ? "HEVC" : "H.264")
                }
                row("Frame Rate", value: facts.details.map { "\(Int($0.framesPerSecond.rounded())) fps" })
                row("Bitrate", value: facts.details.map { String(format: "%.1f Mbps", $0.megabitsPerSecond) })
                row("Dropped", value: facts.details.map { "\($0.droppedFrames)" })
                row("Quality", value: facts.quality.label)
            }

            Divider()

            group {
                row("Computer", value: facts.host.name)
            }
        }
        .padding(16)
    }

    @ViewBuilder private func group(@ViewBuilder _ rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) { rows() }
    }

    /// One row, one element for VoiceOver ("Latency, 12 ms"). Values use monospaced digits, so a
    /// figure changing every second doesn't shift the row. "–" only while the first second is
    /// being measured.
    private func row(_ label: String, value: String?, truncates: Bool = false,
                     @ViewBuilder accessory: () -> some View = { EmptyView() }) -> some View {
        let shown = value ?? "–"
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).foregroundStyle(.secondary)
                    Text(shown).monospacedDigit()
                }
            } else {
                HStack(spacing: 8) {
                    Text(label).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    accessory()
                    Text(shown)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(truncates ? 0 : 1)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "Measuring")
    }
}

/// The card's own glass when it floats over the picture.
private struct CardGlass: ViewModifier {
    let floats: Bool

    func body(content: Content) -> some View {
        if floats {
            content.platformGlass(in: .rect(cornerRadius: 22))
        } else {
            content
        }
    }
}

/// The last half-minute of round trips as a line, scaled to its own range.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1, let low = values.min(), let high = values.max() else { return }
            let span = max(high - low, 1)
            var path = Path()
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                                    y: size.height * (1 - CGFloat((value - low) / span)))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .style(.tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

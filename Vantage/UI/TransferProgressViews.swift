import SwiftUI
import VantageCore

/// Words for a run of files, shared by the device list, the session's capsule, and Transfers.
enum TransferSummaryFormat {
    /// "Report.pdf", "Sending 3 of 12", "Receiving 2 of 5", or "3 of 12 files" both ways.
    static func title(_ summary: FileTransferController.Summary) -> String {
        if summary.count == 1, let current = summary.current { return current.name }
        let place = "\(summary.position) of \(summary.count)"
        if summary.receiving == 0 { return "Sending \(place)" }
        if summary.sending == 0 { return "Receiving \(place)" }
        return "\(place) files"
    }

    /// "45% · 38 GB left · 2 min", or why it's stopped.
    static func detail(_ summary: FileTransferController.Summary) -> String {
        if summary.isPaused { return "Paused · picks up when connected" }
        var parts = ["\(percent(summary))%"]
        if summary.count > 1 || summary.bytesLeft >= 50_000_000 {
            parts.append("\(TransferFormat.bytes(summary.bytesLeft)) left")
        }
        if let seconds = summary.secondsRemaining { parts.append(TransferFormat.duration(seconds)) }
        return parts.joined(separator: " · ")
    }

    /// One line for the device list: "Sending 3 of 12 · 45% · 2 min", "Sending · 45%", "Paused · 3 of 12".
    static func compact(_ summary: FileTransferController.Summary) -> String {
        let verb = summary.receiving == 0 ? "Sending" : (summary.sending == 0 ? "Receiving" : "Moving")
        let place = summary.count > 1 ? " \(summary.position) of \(summary.count)" : ""
        if summary.isPaused { return "Paused\(place.isEmpty ? "" : " ·\(place)")" }
        var text = "\(verb)\(place) · \(percent(summary))%"
        if let seconds = summary.secondsRemaining { text += " · \(TransferFormat.duration(seconds))" }
        return text
    }

    /// What VoiceOver reads for the run.
    static func spoken(_ summary: FileTransferController.Summary, macName: String) -> String {
        let direction = summary.receiving == 0 ? "Sending to \(macName)" : (summary.sending == 0 ? "Receiving from \(macName)" : "Moving files with \(macName)")
        let place = summary.count > 1 ? ", file \(summary.position) of \(summary.count)" : ""
        if summary.isPaused { return "\(direction)\(place), paused until it reconnects" }
        var text = "\(direction)\(place), \(percent(summary)) percent"
        if let seconds = summary.secondsRemaining { text += ", \(TransferFormat.remaining(seconds))" }
        return text
    }

    static func percent(_ summary: FileTransferController.Summary) -> Int {
        Int((summary.fraction * 100).rounded(.down))
    }
}

/// A small ring that fills with a run's progress, with its direction in the middle.
struct TransferMiniRing: View {
    let summary: FileTransferController.Summary
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: summary.isPaused ? summary.fraction : max(0.03, summary.fraction))
                .stroke(summary.isPaused ? Color.secondary : Color.accentColor,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.12), value: summary.fraction)
            Image(systemName: glyph)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(summary.isPaused ? Color.secondary : Color.accentColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityHidden(true)
    }

    private var glyph: String {
        if summary.isPaused { return "pause.fill" }
        if summary.receiving == 0 { return "arrow.up" }
        if summary.sending == 0 { return "arrow.down" }
        return "arrow.up.arrow.down"
    }
}

/// The line on a Mac's row or card while files move with it; tapping it opens Transfers.
struct DeviceTransferBadge: View {
    let files: FileTransferController
    let macName: String
    let onOpen: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var ringSide: CGFloat = 15

    var body: some View {
        let summary = files.summary
        Button(action: onOpen) {
            HStack(spacing: 6) {
                TransferMiniRing(summary: summary, lineWidth: 2)
                    .frame(width: ringSide, height: ringSide)
                Text(TransferSummaryFormat.compact(summary))
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(summary.isPaused ? Color.secondary : Color.accentColor)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .padding(.vertical, 2)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Transfers")
        .accessibilityValue(TransferSummaryFormat.spoken(summary, macName: macName))
        .accessibilityHint("Shows the files moving with \(macName).")
        .accessibilityIdentifier("devices.transfers")
    }
}

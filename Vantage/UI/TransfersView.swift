import SwiftUI
import UniformTypeIdentifiers
import VantageCore

/// Files sent to and received from the Mac this session: what's moving (with a ring that fills
/// as it goes, the rate, and time left), then how the rest ended. Received files can be shared or
/// shown in Files. The session presents it in a sheet with its own navigation stack.
struct TransfersView: View {
    let files: FileTransferController
    let macName: String
    /// Nil hides Send File… (the debug screen has no session to send over).
    var canSend = true
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false

    private var active: [FileTransferController.Transfer] { files.transfers.filter(\.isActive) }
    private var finished: [FileTransferController.Transfer] { files.transfers.filter { !$0.isActive }.reversed() }

    var body: some View {
        Group {
            if files.transfers.isEmpty {
                ContentUnavailableView {
                    Label("No Transfers Yet", systemImage: "arrow.up.arrow.down")
                } description: {
                    Text("Files you send to \(macName) or receive from it show up here. Use Send File, or drop files onto the Mac's screen.")
                } actions: {
                    if canSend {
                        Button("Send File…") { showImporter = true }
                            .buttonStyle(.glassProminent)
                    }
                }
            } else {
                List {
                    if !active.isEmpty {
                        Section("In Progress") {
                            ForEach(active) { transfer in
                                TransferRow(transfer: transfer, macName: macName) { files.cancel(transfer.id) }
                            }
                        }
                    }
                    if !finished.isEmpty {
                        Section {
                            ForEach(finished) { transfer in
                                TransferRow(transfer: transfer, macName: macName)
                            }
                        } header: {
                            Text("Finished")
                        } footer: {
                            Text("Files from \(macName) are in Files, under On My iPad › Vantage › Received.")
                        }
                    }
                }
                .animation(.smooth(duration: 0.25), value: files.transfers.map(\.id))
                .animation(.smooth(duration: 0.25), value: active.map(\.id))
            }
        }
        .navigationTitle("Transfers")
        #if !os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            if canSend, !files.transfers.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button { showImporter = true } label: {
                        Label("Send File…", systemImage: StripItem.sendFile.symbol)
                    }
                    .accessibilityIdentifier("transfers.sendFile")
                }
            }
            if files.transfers.contains(where: { !$0.isActive }) {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Clear") {
                        withAnimation(.smooth(duration: 0.25)) { files.clearFinished() }
                    }
                    .accessibilityHint("Removes finished transfers from this list. Received files stay in Files.")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { files.send(urls, securityScoped: true) }
        }
    }
}

/// One file: a progress ring with its direction, the name, and what's happening to it.
private struct TransferRow: View {
    let transfer: FileTransferController.Transfer
    let macName: String
    var onCancel: (() -> Void)?
    @ScaledMetric(relativeTo: .body) private var ringSide: CGFloat = 34
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                TransferRing(transfer: transfer, glyphSize: ringSide * 0.38)
                    .frame(width: ringSide, height: ringSide)
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                        .lineLimit(3)
                        .contentTransition(.numericText())
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(transfer.name)
            .accessibilityValue(accessibilityStatus)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("transfers.row")
    }

    @ViewBuilder private var trailing: some View {
        if transfer.isActive, let onCancel {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel \(transfer.name)")
        } else if transfer.state == .done, let url = transfer.savedURL {
            HStack(spacing: 4) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Share \(transfer.name)")
                Button {
                    if let files = ReceivedFiles.filesAppURL(for: url) { openURL(files) }
                } label: {
                    Image(systemName: "folder")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Show \(transfer.name) in Files")
            }
            .buttonStyle(.borderless)
            .font(.title3)
        }
    }

    private var isFailure: Bool { if case .failed = transfer.state { true } else { false } }

    private var detail: String {
        let total = TransferFormat.bytes(transfer.byteCount)
        switch transfer.state {
        case .waiting where transfer.interruptedAt != nil:
            return "Paused · \(TransferFormat.bytes(transfer.bytesDone)) of \(total) · picks up when connected"
        case .waiting:
            return "Waiting · \(total)"
        case .active:
            var parts = ["\(TransferFormat.bytes(transfer.bytesDone)) of \(total)"]
            if transfer.bytesPerSecond > 0 { parts.append("\(TransferFormat.bytes(UInt64(transfer.bytesPerSecond)))/s") }
            if let seconds = transfer.secondsRemaining { parts.append(TransferFormat.remaining(seconds)) }
            return parts.joined(separator: " · ")
        case .done:
            if transfer.direction == .receiving { return "Received · \(total)" }
            if let saved = transfer.savedName, saved != transfer.name { return "Sent · saved on \(macName) as \(saved)" }
            return "Sent to \(macName)'s Downloads · \(total)"
        case .failed(let reason):
            return reason
        case .cancelled:
            return "Cancelled"
        }
    }

    private var accessibilityStatus: String {
        let direction = transfer.direction == .sending ? "Sending to \(macName)" : "Receiving from \(macName)"
        switch transfer.state {
        case .waiting where transfer.interruptedAt != nil:
            return "Paused at \(Int((transfer.fraction * 100).rounded())) percent. It picks up where it stopped when \(macName) is connected again."
        case .waiting: return "Waiting to send, \(TransferFormat.bytes(transfer.byteCount))"
        case .active:
            var text = "\(direction), \(Int((transfer.fraction * 100).rounded())) percent"
            if let seconds = transfer.secondsRemaining { text += ", \(TransferFormat.remaining(seconds))" }
            return text
        case .done: return detail
        case .failed(let reason): return "Failed. \(reason)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// The circular progress, with the direction (or the outcome) in the middle.
private struct TransferRing: View {
    let transfer: FileTransferController.Transfer
    /// Grows with Dynamic Type along with the ring.
    var glyphSize: CGFloat = 13

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 3)
            Circle()
                .trim(from: 0, to: trimEnd)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Progress lands every ~100 ms; a linear glide over the same span reads as one
                // continuous fill.
                .animation(.linear(duration: 0.12), value: transfer.fraction)
                .animation(.easeOut(duration: 0.2), value: transfer.state)
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(1.5)
    }

    /// Filled to the progress while moving, and to where it stopped while paused.
    private var trimEnd: Double {
        switch transfer.state {
        case .active: max(0.015, transfer.fraction)
        case .waiting: transfer.interruptedAt != nil ? transfer.fraction : 0
        case .done: 1
        case .failed, .cancelled: 0
        }
    }

    private var symbol: String {
        switch transfer.state {
        case .waiting where transfer.interruptedAt != nil: "pause.fill"
        case .waiting, .active: transfer.direction == .sending ? "arrow.up" : "arrow.down"
        case .done: "checkmark"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        }
    }

    private var tint: Color {
        switch transfer.state {
        case .waiting, .cancelled: .secondary
        case .active: .accentColor
        case .done: .green
        case .failed: .red
        }
    }
}

enum TransferFormat {
    static func bytes(_ count: UInt64) -> String {
        Int64(clamping: count).formatted(.byteCount(style: .file))
    }

    static func remaining(_ seconds: Double) -> String {
        let rounded = seconds < 60 ? max(1, seconds.rounded()) : (seconds / 60).rounded() * 60
        let text = Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
        return "\(text) left"
    }
}

enum ReceivedFiles {
    /// Opens Files at the folder holding `url` (On My iPad › Vantage › Received).
    static func filesAppURL(for url: URL) -> URL? {
        URL(string: "shareddocuments://" + url.deletingLastPathComponent().path(percentEncoded: true))
    }
}

/// "Received Report.pdf" at the top of the session, with Show and Share. It clears itself after
/// a few seconds; the file stays in the Transfers list.
struct ReceivedFileNotice: View {
    let transfer: FileTransferController.Transfer
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Received \(transfer.name)")
                .lineLimit(1)
                .truncationMode(.middle)
            if let url = transfer.savedURL {
                Divider().frame(height: 18)
                Button("Show") {
                    if let files = ReceivedFiles.filesAppURL(for: url) { openURL(files) }
                }
                .accessibilityLabel("Show in Files")
                ShareLink(item: url) { Text("Share") }
            }
        }
        .font(.callout)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .platformGlass(in: .capsule)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.receivedNotice")
    }
}

/// Shown while files are dragged over the Mac's screen.
struct DropToSendHint: View {
    let macName: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: StripItem.sendFile.symbol)
                .accessibilityHidden(true)
            Text("Drop to send to \(macName)")
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .platformGlass(in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session.dropHint")
    }
}

#if DEBUG
/// `-VantageOpenScreen transfers`: the sheet with one row in each state, for screenshots.
struct TransfersFixtureScreen: View {
    @State private var files = FileTransferController.fixture()

    var body: some View {
        TransfersView(files: files, macName: "Studio Mac", canSend: false)
    }
}
#endif

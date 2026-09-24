import SwiftUI
import VantageCore

/// The menu's Files section: "Send File to ⟨iPad⟩…" while an iPad that can take files is
/// connected, the folder received files go to, and a line per file moving either way (progress,
/// speed, time left and cancel while active, then how it ended for a minute).
struct HostFilesSection: View {
    let controller: HostController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Files").font(.subheadline.weight(.semibold))
                Spacer()
                receiveFolderButton
            }
            if sendTargets.isEmpty {
                Button {} label: {
                    Label("Send File to iPad…", systemImage: "arrow.up.doc")
                }
                .disabled(true)
                Text("Connect from Vantage on your iPad to send files either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(sendTargets) { channel in
                    Button {
                        controller.chooseFilesToSend(to: channel)
                    } label: {
                        Label("Send File to \(channel.clientName)…", systemImage: "arrow.up.doc")
                    }
                    .help("Choose files on this Mac to send to \(channel.clientName)")
                }
            }
            ForEach(controller.transfers) { transfer in
                HostTransferRow(transfer: transfer) { controller.cancelTransfer(transfer.id) }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.transfers.map(\.id))
    }

    /// One "Send File to ⟨iPad⟩…" per iPad that can take files, most recent first. The one place
    /// that decides which file channels are offered. File channels outlive their sessions, so an
    /// iPad can briefly have two (the old one winding down, a new one up): offer its newest.
    private var sendTargets: [HostFileChannel] {
        var seen = Set<String>()
        return controller.fileChannels.reversed().filter { seen.insert($0.clientKey).inserted }
    }

    /// Where received files go, with its Finder icon; opens the folder.
    private var receiveFolderButton: some View {
        let store = HostFileStore.current
        return Button {
            NSWorkspace.shared.open(store.directory)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: store.directory.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                Text(store.displayName)
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Files from the iPad are saved in \(store.displayName). Click to open it.")
        .accessibilityLabel("Open \(store.displayName), where received files are saved")
    }
}

private struct HostTransferRow: View {
    let transfer: HostTransfer
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                // Once saved, the name it got ("Report 2.pdf" when Report.pdf was taken).
                Text(transfer.savedURL?.lastPathComponent ?? transfer.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if transfer.state == .active {
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .animation(.linear(duration: 0.1), value: transfer.fraction)
                        .accessibilityLabel(transfer.direction == .sending ? "Sending" : "Receiving")
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if transfer.isActive {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Stop this transfer")
                .accessibilityLabel("Cancel \(transfer.name)")
            } else if let url = transfer.savedURL {
                Button {
                    HostNotifications.reveal([url])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show \(transfer.name) in Finder")
            }
        }
        .accessibilityElement(children: .contain)
        .contextMenu {
            if let url = transfer.savedURL {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { HostNotifications.reveal([url]) }
            } else if transfer.isActive {
                Button("Cancel", action: onCancel)
            }
        }
    }

    private var symbol: String {
        switch transfer.state {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .waiting where transfer.interruptedAt != nil: "pause.circle"
        case .waiting, .active: transfer.direction == .sending ? "arrow.up.circle" : "arrow.down.circle"
        }
    }

    private var tint: Color {
        switch transfer.state {
        case .done: .green
        case .failed: .orange
        case .cancelled, .waiting: .secondary
        case .active: .accentColor
        }
    }

    /// The row's status line, and the one place it's worded: "Waiting · 12 MB · From Drew's iPad",
    /// "12.4 MB of 48 MB · 6.2 MB/s · 5 sec left", "Received from Drew's iPad · in Downloads".
    private var detail: String {
        let total = Self.bytes(transfer.byteCount)
        let toFrom = transfer.direction == .sending ? "To \(transfer.deviceName)" : "From \(transfer.deviceName)"
        switch transfer.state {
        case .waiting where transfer.interruptedAt != nil:
            // Cut off mid-file: it picks up where it stopped when the iPad comes back.
            return "Paused at \(Int((transfer.fraction * 100).rounded(.down)))% · resumes when \(transfer.deviceName) reconnects"
        case .waiting:
            return "Waiting · \(total) · \(toFrom)"
        case .active:
            var parts = ["\(Self.bytes(transfer.bytesDone)) of \(total)"]
            if let rate = transfer.bytesPerSecond, rate > 0 { parts.append("\(Self.bytes(UInt64(rate)))/s") }
            if let left = transfer.secondsRemaining, left >= 1 {
                let duration = Duration.seconds(left.rounded(.up))
                parts.append("\(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))) left")
            } else {
                parts.append(toFrom)
            }
            return parts.joined(separator: " · ")
        case .done:
            if transfer.direction == .sending { return "Sent to \(transfer.deviceName)" }
            let folder = transfer.savedURL.map { FileManager.default.displayName(atPath: $0.deletingLastPathComponent().path(percentEncoded: false)) }
            return folder.map { "Received from \(transfer.deviceName) · in \($0)" } ?? "Received from \(transfer.deviceName)"
        case .failed(let reason):
            return reason
        case .cancelled:
            return "Cancelled"
        }
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}

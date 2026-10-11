import SwiftUI
import VantageCore

/// The menu's Files section: "Send File to ⟨iPad⟩…" for each iPad that can take files, the
/// folder received files go to, and a row per file moving either way (progress, speed, time left
/// and cancel while active, then how it ended for a minute).
struct HostFilesSection: View {
    let controller: HostController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let store = HostFileStore.current
        GroupedSection(title: "Files") {
            ForEach(Self.sendTargets(controller)) { channel in
                Button {
                    controller.chooseFilesToSend(to: channel)
                } label: {
                    SettingsRow("Send File to \(channel.clientName)…", symbol: "arrow.up.doc.fill", color: .blue)
                }
                .help("Choose files on this Mac to send to \(channel.clientName)")
            }
            Button {
                NSWorkspace.shared.open(store.directory)
            } label: {
                SettingsRow("Received Files", symbol: "folder.fill", color: .cyan, chevron: true) {
                    Text(store.displayName)
                }
            }
            .help("Files sent from Porthole are saved in \(store.displayName). Click to open it.")
            .accessibilityLabel("Open \(store.displayName), where received files are saved")
            ForEach(controller.transfers) { transfer in
                HostTransferRow(transfer: transfer) { controller.cancelTransfer(transfer.id) }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .buttonStyle(.settingsRow)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.transfers.map(\.id))
    }

    /// One send target per iPad that can take files, most recent first. The one place that
    /// decides which file channels are offered. File channels outlive their sessions, so an iPad
    /// can briefly have two (the old one winding down, a new one up): offer its newest.
    static func sendTargets(_ controller: HostController) -> [HostFileChannel] {
        var seen = Set<String>()
        return controller.fileChannels.reversed().filter { seen.insert($0.clientKey).inserted }
    }
}

private struct HostTransferRow: View {
    let transfer: HostTransfer
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // As wide as a row's icon, so the name lines up with the row titles.
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: MenuMetrics.iconSize)
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

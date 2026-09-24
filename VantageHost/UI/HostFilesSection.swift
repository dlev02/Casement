import SwiftUI
import VantageCore

/// The menu's Files section: "Send File to ⟨iPad⟩…" while an iPad that can take files is
/// connected, and a line per file moving either way (progress and cancel while active, then how
/// it ended for a minute).
struct HostFilesSection: View {
    let controller: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files").font(.subheadline.weight(.semibold))
            if controller.fileChannels.isEmpty {
                Button {} label: {
                    Label("Send File to iPad…", systemImage: "arrow.up.doc")
                }
                .disabled(true)
                Text("Connect from Vantage on your iPad to send files either way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(controller.fileChannels.reversed()) { channel in
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
            }
        }
        .animation(.easeOut(duration: 0.2), value: controller.transfers.map(\.id))
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
                Text(transfer.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if transfer.state == .active {
                    ProgressView(value: transfer.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .animation(.linear(duration: 0.1), value: transfer.fraction)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show \(transfer.name) in Finder")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch transfer.state {
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
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

    private var detail: String {
        let total = ByteCountFormatter.string(fromByteCount: Int64(clamping: transfer.byteCount), countStyle: .file)
        let toFrom = transfer.direction == .sending ? "To \(transfer.deviceName)" : "From \(transfer.deviceName)"
        switch transfer.state {
        case .waiting: return "Waiting · \(total)"
        case .active:
            let done = ByteCountFormatter.string(fromByteCount: Int64(clamping: transfer.bytesDone), countStyle: .file)
            return "\(done) of \(total) · \(toFrom)"
        case .done:
            if transfer.direction == .sending { return "Sent to \(transfer.deviceName)" }
            let folder = transfer.savedURL.map { FileManager.default.displayName(atPath: $0.deletingLastPathComponent().path(percentEncoded: false)) }
            return "Received · in \(folder ?? "Downloads")"
        case .failed(let reason): return reason
        case .cancelled: return "Cancelled"
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers
import VantageCore
import os
#if os(macOS)
import AppKit
#endif

/// Files sent to and received from the Mac this session: what's moving (with a ring that fills
/// as it goes, the rate, and time left), then how the rest ended. Received files can be shared or
/// shown in Files (in Finder on the Mac). The session presents it in a sheet with its own
/// navigation stack.
struct TransfersView: View {
    let files: FileTransferController
    let macName: String
    /// "Mac" or "PC", where the text names the kind of computer.
    var host = HostNoun.mac
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
                    Text("Files you send to \(macName) or receive from it show up here. Use Send File, or drop files onto \(host.the).")
                } actions: {
                    if canSend {
                        Button("Send File…") { showImporter = true }
                            .buttonStyle(.glassProminent)
                    }
                }
            } else {
                List {
                    let summary = files.summary
                    if summary.isActive, summary.count > 1 {
                        Section {
                            TransferRunSummary(summary: summary, macName: macName) { files.cancelAll() }
                        }
                    }
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
                            Text("Files from \(macName) are \(ReceivedFiles.location).")
                        }
                    }
                }
                .animation(.smooth(duration: 0.25), value: files.transfers.map(\.id))
                .animation(.smooth(duration: 0.25), value: active.map(\.id))
            }
        }
        .navigationTitle("Transfers")
        #if os(iOS)
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
                    .accessibilityHint("Removes finished transfers from this list. Received files stay \(ReceivedFiles.location).")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { files.send(urls, securityScoped: true) }
        }
    }
}

/// The run as a whole, above its files: "12 of 340", what's left and how long, one bar, and
/// Cancel All.
private struct TransferRunSummary: View {
    let summary: FileTransferController.Summary
    let macName: String
    let onCancelAll: () -> Void
    @State private var confirmCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Side by side while it fits; stacked at the largest text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 8)
                    cancelAll
                }
                VStack(alignment: .leading, spacing: 6) {
                    title
                    cancelAll
                }
            }
            ProgressView(value: summary.fraction)
                .tint(summary.isPaused ? .secondary : .accentColor)
                .animation(.linear(duration: 0.12), value: summary.fraction)
            Text(TransferSummaryFormat.detail(summary))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("All transfers")
        .accessibilityValue(TransferSummaryFormat.spoken(summary, macName: macName))
        .accessibilityAction(named: "Cancel All") { confirmCancel = true }
        .accessibilityIdentifier("transfers.summary")
        .confirmationDialog("Cancel \(summary.count - summary.finished) files?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel All Transfers", role: .destructive, action: onCancelAll)
            Button("Keep Going", role: .cancel) {}
        } message: {
            Text("Files already sent or received stay where they are.")
        }
    }

    private var title: some View {
        Text(TransferSummaryFormat.title(summary))
            .font(.headline)
            .monospacedDigit()
    }

    private var cancelAll: some View {
        Button("Cancel All", role: .destructive) { confirmCancel = true }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.medium))
    }
}

/// One file: a progress ring with its direction, the name, and what's happening to it.
private struct TransferRow: View {
    let transfer: FileTransferController.Transfer
    let macName: String
    var onCancel: (() -> Void)?
    @ScaledMetric(relativeTo: .body) private var ringSide: CGFloat = 34
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                TransferRing(transfer: transfer, glyphSize: ringSide * 0.38)
                    .frame(width: ringSide, height: ringSide)
                VStack(alignment: .leading, spacing: 2) {
                    // At the largest text sizes the name wraps instead of losing its middle.
                    Text(transfer.name)
                        .font(.body)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        .truncationMode(.middle)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .monospacedDigit()
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
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

    /// Finger-sized targets on iPad; the Mac's pointer needs far less.
    #if os(macOS)
    private let buttonSide: CGFloat = 28
    #else
    private let buttonSide: CGFloat = 44
    #endif

    @ViewBuilder private var trailing: some View {
        if transfer.isActive, let onCancel {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: buttonSide, minHeight: buttonSide)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel \(transfer.name)")
        } else if transfer.state == .done, let url = transfer.savedURL {
            HStack(spacing: 4) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(minWidth: buttonSide, minHeight: buttonSide)
                        .contentShape(.rect)
                }
                .help("Share")
                .accessibilityLabel("Share \(transfer.name)")
                Button {
                    ReceivedFiles.show(url, openURL: openURL)
                } label: {
                    Image(systemName: "folder")
                        .frame(minWidth: buttonSide, minHeight: buttonSide)
                        .contentShape(.rect)
                }
                .help("Show in \(ReceivedFiles.browser)")
                .accessibilityLabel("Show \(transfer.name) in \(ReceivedFiles.browser)")
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
        "\(duration(seconds)) left"
    }

    /// "40 sec", "2 min", "3 hr": one unit, rounded the way a person would say it.
    static func duration(_ seconds: Double) -> String {
        let rounded = seconds < 60 ? max(1, seconds.rounded()) : (seconds / 60).rounded() * 60
        return Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
    }
}

enum ReceivedFiles {
    #if os(macOS)
    static let browser = "Finder"
    static let location = "in your Downloads folder"
    #else
    static let browser = "Files"
    static let location = "in Files, under On My iPad › Casement › Received"
    #endif

    /// Opens Files at the folder holding `url` (On My iPad › Vantage › Received).
    static func filesAppURL(for url: URL) -> URL? {
        URL(string: "shareddocuments://" + url.deletingLastPathComponent().path(percentEncoded: true))
    }

    /// Shows a received file: a Finder window selecting it on the Mac, Files at its folder on iOS.
    static func show(_ url: URL, openURL: OpenURLAction) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #else
        if let files = filesAppURL(for: url) { openURL(files) }
        #endif
    }
}

/// "Received Report.pdf" at the top of the session, with Show and Share. It clears itself after
/// a few seconds; the file stays in the Transfers list.
struct ReceivedFileNotice: View {
    let transfer: FileTransferController.Transfer
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.doc.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("Received \(transfer.name)")
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .truncationMode(.middle)
            if let url = transfer.savedURL {
                Divider().frame(height: 18)
                Button("Show") {
                    ReceivedFiles.show(url, openURL: openURL)
                }
                .accessibilityLabel("Show in \(ReceivedFiles.browser)")
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

/// Asks before sending a file another app opened in Casement ("Send “Report.pdf” to Studio?").
/// Any app, or the system, can ask Casement to open a file, so nothing opened that way leaves
/// without a yes; Don't Send deletes the copy.
struct SharedFileConfirmation: ViewModifier {
    /// Where the files would go ("Studio", "the computer you're connected to"); nil while there's
    /// nowhere to send them, and the question waits.
    let destination: String?
    /// False while another view asks instead, or the app is locked.
    let isActive: Bool
    /// After Send: the files are in `SharedFileInbox.pending`.
    let onSend: () -> Void
    private let inbox = SharedFileInbox.shared

    func body(content: Content) -> some View {
        content.alert(title, isPresented: isPresented) {
            Button("Send") {
                inbox.approve()
                onSend()
            }
            Button("Don't Send", role: .cancel) { inbox.decline() }
        } message: {
            Text(inbox.offered.count == 1
                 ? "Another app asked Casement to send this file. Send it only if you just shared it to Casement."
                 : "Another app asked Casement to send these files. Send them only if you just shared them to Casement.")
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { isActive && destination != nil && !inbox.offered.isEmpty }, set: { _ in })
    }

    private var title: String {
        let target = destination ?? ""
        if inbox.offered.count == 1, let name = inbox.offered.first?.lastPathComponent {
            return "Send “\(name)” to \(target)?"
        }
        return "Send \(inbox.offered.count) files to \(target)?"
    }
}

/// Files dragged onto the Mac's screen, or onto its row in the device list: copied out of the
/// drag (its files only live for the callback) and queued for the Mac's Downloads.
///
/// On the Mac client, files dragged from Finder are sent from where they are: the drag hands the
/// app a file URL (and the sandbox access to it), so a 2 GB file isn't copied first. Anything
/// that isn't a file on disk (an image dragged out of a browser) is copied as on iOS.
struct FileDropDelegate: DropDelegate {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    /// Asked only when something is dropped, so a row needn't make its Mac's link to be a target.
    let files: () -> FileTransferController

    func validateDrop(info: DropInfo) -> Bool { isEnabled && info.hasItemsConforming(to: [.item]) }
    func dropEntered(info: DropInfo) { if validateDrop(info: info) { isTargeted = true } }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: isEnabled ? .copy : .forbidden) }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard isEnabled else { return false }
        let providers = info.itemProviders(for: [.item])
        for provider in providers {
            #if os(macOS)
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                sendInPlace(provider)
                continue
            }
            #endif
            // The file's own type (a JPEG, a PDF), not a private or text flavour of it.
            let type = provider.registeredContentTypes.first { $0.conforms(to: .data) || $0.conforms(to: .package) } ?? .item
            let files = self.files()
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                guard let url else {
                    Logger(subsystem: "com.benjaminlevinson.vantage", category: "files")
                        .error("dropped item had no file: \(error?.localizedDescription ?? "?", privacy: .public)")
                    return
                }
                do {
                    let copy = try FileTransferController.copyToOutbox(url)
                    Task { @MainActor in files.sendOutboxCopy(copy) }
                } catch {
                    Logger(subsystem: "com.benjaminlevinson.vantage", category: "files")
                        .error("couldn't copy a dropped file: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return !providers.isEmpty
    }

    #if os(macOS)
    private func sendInPlace(_ provider: NSItemProvider) {
        let files = self.files()
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            let log = Logger(subsystem: "com.benjaminlevinson.vantage", category: "files")
            guard let url, url.isFileURL else {
                log.error("dropped item had no file URL: \(error?.localizedDescription ?? "?", privacy: .public)")
                return
            }
            // Folders aren't sent (yet); a package (an .app, a .pages) is a folder too.
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else {
                log.info("dropped a folder; skipped")
                return
            }
            Task { @MainActor in files.send([url], securityScoped: false) }
        }
    }
    #endif
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

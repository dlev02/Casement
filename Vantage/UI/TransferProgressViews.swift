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

    /// "45% · 38 GB left · 2 min", "30% · 9 sec left", or why it's stopped.
    static func detail(_ summary: FileTransferController.Summary) -> String {
        if summary.isPaused { return "Paused · picks up when connected" }
        var parts = ["\(percent(summary))%"]
        let showsBytes = summary.count > 1 || summary.bytesLeft >= 50_000_000
        if showsBytes { parts.append("\(TransferFormat.bytes(summary.bytesLeft)) left") }
        if let seconds = summary.secondsRemaining {
            parts.append(showsBytes ? TransferFormat.duration(seconds) : TransferFormat.remaining(seconds))
        }
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
    var glyphSize: CGFloat = 8

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
                .font(.system(size: glyphSize, weight: .bold))
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

/// The session's glance at files moving with the Mac. It appears by itself when a run of files
/// starts ("Report.pdf" or "Sending 3 of 12", then percent, what's left, and time), turns into a
/// checkmark when they're done, and gets out of the way a moment later. Tapping it opens
/// Transfers. The session places it on the edge away from the control strip.
struct TransferCapsule: View {
    let files: FileTransferController
    let macName: String
    let onOpen: () -> Void
    /// What's on screen: follows the live run, then holds the ended one briefly. Kept in state
    /// (rather than read straight from `files`) so the capsule stays one view as it turns done.
    @State private var shown: FileTransferController.Summary?
    @State private var dismissTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var ringSide: CGFloat = 30

    var body: some View {
        ZStack {
            if let shown {
                capsule(shown, done: !shown.isActive)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94)),
                        removal: .opacity.combined(with: .scale(scale: 0.97))))
            }
        }
        .onAppear { if files.summary.isActive { shown = files.summary } }
        .onChange(of: files.summary) { old, new in follow(old: old, new: new) }
    }

    private func follow(old: FileTransferController.Summary, new: FileTransferController.Summary) {
        if new.isActive {
            dismissTask?.cancel()
            let appearing = shown == nil || shown?.isActive == false
            withAnimation(appearing ? (reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.24)) : nil) { shown = new }
        } else if old.isActive, shown != nil {
            runEnded(new)
        }
    }

    private func capsule(_ summary: FileTransferController.Summary, done: Bool) -> some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                ZStack {
                    if done {
                        Image(systemName: summary.failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                            .resizable()
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, summary.failed > 0 ? Color.orange : Color.green)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                    } else {
                        TransferMiniRing(summary: summary, lineWidth: 3, glyphSize: ringSide * 0.36)
                            .transition(.opacity)
                    }
                }
                .frame(width: ringSide, height: ringSide)
                VStack(alignment: .leading, spacing: 1) {
                    Text(done ? Self.doneTitle(summary, macName: macName) : TransferSummaryFormat.title(summary))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .truncationMode(.middle)
                    Text(done ? Self.doneDetail(summary, macName: macName) : TransferSummaryFormat.detail(summary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                }
                .frame(minWidth: 120, alignment: .leading)
            }
            .padding(.leading, 9)
            .padding(.trailing, 18)
            .padding(.vertical, 8)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        #if os(visionOS)
        .glassBackgroundEffect(in: .capsule)
        #else
        .glassEffect(.regular.interactive(), in: .capsule)
        #endif
        .frame(maxWidth: 380)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.3), value: done)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Transfers")
        .accessibilityValue(done ? "\(Self.doneTitle(summary, macName: macName)). \(Self.doneDetail(summary, macName: macName))"
                                 : TransferSummaryFormat.spoken(summary, macName: macName))
        .accessibilityHint("Shows every file moving with \(macName).")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("session.transferCapsule")
    }

    /// Shows the ended run as done for a moment (longer with VoiceOver, so it can be reached) and
    /// says how it went, then hides. A run of only received files leaves that to the Received
    /// notice, and one that was all cancelled just goes.
    private func runEnded(_ summary: FileTransferController.Summary) {
        let hide = { withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeIn(duration: 0.18)) { shown = nil } }
        guard summary.cancelled < summary.count else { hide(); return }
        if summary.sending > 0 || summary.count > 1 || summary.failed > 0 {
            AccessibilityNotification.Announcement("\(Self.doneTitle(summary, macName: macName)). \(Self.doneDetail(summary, macName: macName))").post()
        }
        guard summary.sending > 0 || summary.failed > 0 else { hide(); return }
        shown = summary
        dismissTask?.cancel()
        dismissTask = Task {
            do { try await Task.sleep(for: .seconds(voiceOverEnabled ? 8 : 2.6)) } catch { return }
            hide()
        }
    }

    static func doneTitle(_ summary: FileTransferController.Summary, macName: String) -> String {
        let moved = summary.count - summary.failed - summary.cancelled
        let noun = summary.count == 1 ? "file" : "files"
        if summary.failed > 0 { return "\(moved) of \(summary.count) \(noun) moved" }
        if summary.receiving == 0 { return moved == 1 ? "Sent to \(macName)" : "Sent \(moved) files" }
        if summary.sending == 0 { return moved == 1 ? "Received from \(macName)" : "Received \(moved) files" }
        return "Moved \(moved) files"
    }

    static func doneDetail(_ summary: FileTransferController.Summary, macName: String) -> String {
        if summary.failed > 0 { return "\(summary.failed) couldn't be moved · open Transfers" }
        if summary.count == 1, let name = summary.first?.name { return name }
        return summary.receiving == 0 ? "to \(macName)" : "with \(macName)"
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
            #if os(iOS)
            .frame(minHeight: 44) // a finger-sized target, though the line is small
            #endif
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Transfers")
        .accessibilityValue(TransferSummaryFormat.spoken(summary, macName: macName))
        .accessibilityHint("Shows the files moving with \(macName).")
        .accessibilityIdentifier("devices.transfers")
    }
}

import SwiftUI
import VantageCore

/// The glass card that shows a dictation: live transcript and level while listening (with Pause
/// and Stop), a spinner while the Mac transcribes, then editable text with Send, Send + Return,
/// and Cancel.
struct DictationPanel: View {
    @Bindable var dictation: DictationController
    /// macOS drops typed text while a secure field has focus; offer Copy instead of Send then.
    let isTypingBlocked: Bool
    let onCopy: (String) -> Void
    /// Opens the recent dictations (hidden while Settings has the history off).
    let onShowHistory: () -> Void

    @AppStorage(DictationHistory.enabledKey) private var savesHistory = true

    @FocusState private var editorFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .footnote) private var stopSide: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            if isTypingBlocked, canSend {
                Label("A secure field on the Mac is blocking typing. Copy the text instead.", systemImage: "key.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            buttons
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .platformGlass(in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictation")
    }

    // MARK: Header

    /// One line normally; at accessibility text sizes the status, the engine, and the buttons
    /// each get a line of their own rather than squeezing into one.
    @ViewBuilder private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { status }
                engine
                HStack(spacing: Self.controlSpacing) { controls }
            }
        } else {
            HStack(spacing: 8) {
                status
                Spacer(minLength: 8)
                engine
                    .lineLimit(1)
                HStack(spacing: Self.controlSpacing) { controls }
            }
        }
    }

    #if os(iOS)
    private static let controlSpacing: CGFloat = 2 // each button already keeps a 44 pt target
    #else
    private static let controlSpacing: CGFloat = 8
    #endif

    @ViewBuilder private var status: some View {
        statusIndicator
        Text(statusTitle)
            .font(.subheadline.weight(.semibold))
            .contentTransition(.opacity)
        if let startedAt = dictation.startedAt, dictation.phase == .listening {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                elapsedTime(dictation.elapsed(at: context.date))
            }
        } else if dictation.phase == .paused {
            elapsedTime(dictation.elapsedBeforePause)
        }
    }

    private func elapsedTime(_ seconds: TimeInterval) -> some View {
        Text(Duration.seconds(seconds), format: .time(pattern: .minuteSecond))
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// Which engine wrote the text, once there is text: the Mac's (it may have fallen back to
    /// another) or this device's Parakeet. Never while recording, where the header belongs to
    /// the clock and the buttons, and never for the plain on-device default.
    @ViewBuilder private var engine: some View {
        if let engineName {
            Label(engineName, systemImage: dictation.route.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
    }

    private var engineName: String? {
        switch dictation.phase {
        case .transcribing: dictation.route == .iPad ? nil : dictation.route.label
        case .review: dictation.resultEngine.map(DictationRoute.label(for:))
        default: nil
        }
    }

    /// History, then Pause or Resume and Stop while a recording is open.
    @ViewBuilder private var controls: some View {
        if savesHistory {
            Button(action: onShowHistory) {
                Image(systemName: "clock")
                    .font(.body)
                    .frame(width: stopSide, height: stopSide)
            }
            .buttonStyle(.borderless)
            .tint(.secondary)
            #if os(iOS)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.rect)
            #endif
            .accessibilityLabel("Dictation History")
            .help("Dictation History")
            .accessibilityIdentifier("dictation.history")
        }
        if dictation.phase == .listening {
            roundButton("Pause", symbol: "pause.fill") { dictation.pause() }
                .accessibilityIdentifier("dictation.pause")
        } else if dictation.phase == .paused {
            roundButton("Resume", symbol: "play.fill") { dictation.resume() }
                .accessibilityIdentifier("dictation.resume")
        }
        if dictation.phase == .listening || dictation.phase == .paused {
            roundButton("Stop and Review", symbol: "stop.fill") { dictation.stop(then: .review) }
                .accessibilityIdentifier("dictation.stop")
        }
    }

    private func roundButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote)
                .frame(width: stopSide, height: stopSide)
        }
        .buttonStyle(.onCard)
        .buttonBorderShape(.circle)
        #if os(iOS)
        .frame(minWidth: 44, minHeight: 44) // the glass circle grows with its padding; this keeps the target
        .contentShape(.rect)
        #endif
        .accessibilityLabel(title)
        .help(title)
    }

    @ViewBuilder private var statusIndicator: some View {
        switch dictation.phase {
        case .listening:
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .scaleEffect(reduceMotion ? 1 : 0.8 + CGFloat(dictation.level) * 0.5)
                .animation(.easeOut(duration: 0.12), value: dictation.level)
                .accessibilityHidden(true)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .preparing, .transcribing:
            ProgressView().controlSize(.small)
        case .review:
            Image(systemName: "text.bubble").foregroundStyle(.tint)
                .accessibilityHidden(true) // the title beside it says Review
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
        case .idle:
            EmptyView()
        }
    }

    private var statusTitle: String {
        switch dictation.phase {
        case .idle: ""
        case .preparing(let progress?): "Downloading speech model \(progress.formatted(.percent.precision(.fractionLength(0))))"
        case .preparing: "Getting ready…"
        case .listening: "Listening"
        case .paused: "Paused"
        case .transcribing: if case .mac = dictation.route { "Transcribing on Mac…" } else { "Transcribing…" }
        case .review: "Review"
        case .failed(let failure): failure.title
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch dictation.phase {
        case .review:
            TextField("Nothing was recognized. Try again, or type here.", text: $dictation.text, axis: .vertical)
                .lineLimit(1...6)
                .focused($editorFocused)
                .font(.body)
                .padding(10)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12))
                .accessibilityLabel("Transcript")
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !dictation.text.isEmpty {
                    transcriptText(Text(dictation.text))
                }
            }
        case .preparing(let progress?):
            ProgressView(value: progress)
                .accessibilityLabel("Speech model download")
        case .preparing:
            EmptyView()
        default:
            liveTranscript
        }
    }

    /// Final words in the primary color; the volatile guess trails in secondary. On the Mac
    /// engine this is a preview; MacWhisper's text replaces it.
    private var liveTranscript: some View {
        let transcript = dictation.transcript
        let committed = transcript.committed
        let placeholder: String? = {
            guard committed.isEmpty, transcript.volatile.isEmpty else { return nil }
            if dictation.phase != .listening { return nil }
            if dictation.route != .iPad, !dictation.hasLivePreview { return "Speak now. \(dictation.route.label) transcribes when you stop." }
            return "Speak now…"
        }()
        return VStack(alignment: .leading, spacing: 10) {
            if let placeholder {
                Text(placeholder).foregroundStyle(.tertiary)
            } else if !committed.isEmpty || !transcript.volatile.isEmpty {
                transcriptText(Text("\(committed)\(committed.isEmpty ? "" : " ")\(Text(transcript.volatile).foregroundStyle(.secondary))"))
                    .opacity(dictation.phase == .transcribing ? 0.55 : 1)
            }
            if dictation.phase == .listening || dictation.phase == .paused {
                // Flat and dimmed while paused, so the card keeps its shape. A meter of its
                // own for each stretch: the bars from before the pause don't linger.
                LevelMeter(level: dictation.level)
                    .id(dictation.phase == .paused)
                    .frame(height: 36)
                    .opacity(dictation.phase == .paused ? 0.4 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transcriptText(_ text: Text) -> some View {
        ScrollView {
            text
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: 140)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Buttons

    private var canSend: Bool {
        switch dictation.phase {
        case .listening, .paused: true
        case .review: !dictation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: false
        }
    }

    /// Icons beside the titles where the row fits on one line; titles alone on a narrow phone,
    /// rather than "Send + Return" wrapping onto two.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            buttonRow.labelStyle(.titleAndIcon)
            buttonRow.labelStyle(.titleOnly)
        }
        .controlSize(.regular)
    }

    private var buttonRow: some View {
        HStack(spacing: 10) {
            Button("Cancel", role: .cancel) { dictation.cancel() }
                .buttonStyle(.onCard)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 0)
            if case .failed(let failure) = dictation.phase {
                if failure.opensSettings {
                    Button("Open Settings") {
                        if let url = failure.settings?.url { openURL(url) }
                        dictation.cancel()
                    }
                    .buttonStyle(.onCardProminent)
                } else if !dictation.text.isEmpty {
                    copyButton
                }
            } else if isTypingBlocked, dictation.phase == .review {
                copyButton.disabled(!canSend)
            } else if dictation.phase != .transcribing, !isPreparing {
                Button {
                    dictation.stop(then: .send(pressReturn: true))
                } label: {
                    Label("Send + Return", systemImage: "return")
                }
                .buttonStyle(.onCard)
                .disabled(!canSend || isTypingBlocked)
                .accessibilityHint("Types the text on the Mac, then presses Return.")
                Button {
                    dictation.stop(then: .send(pressReturn: false))
                } label: {
                    Label("Send", systemImage: "arrow.up")
                }
                .buttonStyle(.onCardProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSend || isTypingBlocked)
                .accessibilityHint("Types the text on the Mac.")
            }
        }
    }

    private var copyButton: some View {
        Button {
            onCopy(dictation.text)
            dictation.cancel()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .buttonStyle(.onCardProminent)
    }

    private var isPreparing: Bool {
        if case .preparing = dictation.phase { true } else { false }
    }
}

/// A row of bars that follows the microphone level. The newest level sits in the middle and
/// older ones move outward, so speech reads as a moving shape rather than one block swelling.
private struct LevelMeter: View {
    let level: Float
    private static let bars = 31
    private static let center = bars / 2
    @State private var history = [Float](repeating: 0, count: center + 1)

    var body: some View {
        GeometryReader { geometry in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<Self.bars, id: \.self) { index in
                    Capsule()
                        .fill(.tint.opacity(0.75))
                        .frame(height: max(3, geometry.size.height * height(for: index)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.1), value: history)
        .onAppear { history = history.map { _ in level } }
        .onChange(of: level) { _, level in
            history.insert(level, at: 0)
            history.removeLast()
        }
        .accessibilityHidden(true)
    }

    private func height(for index: Int) -> CGFloat {
        let distance = abs(index - Self.center)
        let taper = 1 - Double(distance) / Double(Self.center) * 0.45
        return CGFloat(Double(history[distance]) * taper)
    }
}

extension DictationController.Phase {
    /// The dictation moments worth feeling: the microphone opening and closing (hold to talk is
    /// done looking at the Mac, not the panel) and a failure. Review and sending stay quiet, and
    /// so does cancelling, which the panel closing already shows.
    static func haptic(from old: Self, to new: Self) -> Haptic? {
        switch (old, new) {
        case (.listening, .listening), (.failed, .failed): nil
        case (_, .listening): .start
        case (.listening, .transcribing), (.listening, .review), (.listening, .paused): .stop
        case (_, .failed): .error
        default: nil
        }
    }
}

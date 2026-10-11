import SwiftUI
import VantageCore

/// Settings → Dictation: which engine transcribes what the iPad dictates, which engines this Mac
/// has, and the optional built-in Parakeet engine.
struct DictationSettingsTab: View {
    @Bindable var parakeet: ParakeetModel
    /// An engine's raw value, or empty for Automatic (`HostTranscriber.preferredEngineKey`).
    @AppStorage(HostTranscriber.preferredEngineKey) private var preferred = ""
    @State private var engines: [DictationEngineID]?

    private static let choices: [(DictationEngineID, String)] = [(.macWhisper, "MacWhisper"), (.parakeet, "Parakeet"), (.apple, "Apple Speech")]

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $preferred) {
                    // Says what Automatic comes to on this Mac, so "In use" below never surprises.
                    Text(automaticName.map { "Automatic (\($0))" } ?? "Automatic").tag("")
                    Divider()
                    ForEach(Self.choices, id: \.0) { engine, name in
                        Text(name).tag(engine.rawValue)
                    }
                }
            } header: {
                Text("Transcription")
            } footer: {
                Footer(choiceFooter)
            }

            Section("Engines on this Mac") {
                LabeledContent("MacWhisper") { engineBadge(.macWhisper, missing: "Not installed") }
                LabeledContent("Parakeet") { engineBadge(.parakeet, missing: parakeet.isEnabled ? "Not ready" : "Off") }
                LabeledContent("Apple Speech") { engineBadge(.apple, missing: "Unavailable") }
            }

            Section {
                Toggle(isOn: Binding(get: { parakeet.isEnabled }, set: { parakeet.setEnabled($0) })) {
                    Text("Parakeet")
                    Text(ParakeetModel.isInstalled ? "English and 24 other European languages"
                                                   : "Downloads about \(downloadSize) the first time you turn it on")
                }
                LabeledContent("Model") { modelRow }
            } header: {
                Text("Built-in transcription")
            } footer: {
                Footer("NVIDIA's Parakeet v3 model, running on this Mac's Neural Engine. Nothing is downloaded or sent anywhere while it's off.")
            }
        }
        .formStyle(.grouped)
        .task(id: parakeet.state) { engines = await HostTranscriber.availableEngines() }
    }

    private var preferredEngine: DictationEngineID? {
        preferred.isEmpty ? nil : DictationEngineID(rawValue: preferred)
    }

    /// The engine a dictation goes to right now (the iPad takes the Mac's first one).
    private var inUse: DictationEngineID? {
        guard let engines else { return nil }
        return HostTranscriber.order(requested: nil, preferred: preferredEngine).first(where: engines.contains)
    }

    private func name(of engine: DictationEngineID) -> String? {
        Self.choices.first(where: { $0.0 == engine })?.1
    }

    /// What Automatic picks on this Mac right now.
    private var automaticName: String? {
        guard let engines else { return nil }
        return HostTranscriber.order(requested: nil).first(where: engines.contains).flatMap(name(of:))
    }

    private var choiceFooter: String {
        var text = "Automatic picks the best engine this Mac has: MacWhisper when it's installed, then Parakeet, then Apple Speech. If an engine can't finish a recording, the next one takes over."
        if let preferredEngine, let engines, !engines.contains(preferredEngine), let name = name(of: preferredEngine) {
            text = "\(name) isn't available on this Mac right now, so the next engine takes over. " + text
        }
        if inUse == .apple {
            text += " With only Apple Speech, the iPad transcribes by itself: it has the same model."
        }
        return text
    }

    private var downloadSize: String {
        ParakeetModel.approximateDownloadSize.formatted(.byteCount(style: .file))
    }

    /// The model's state, its size on disk, and the one thing to do with it, all on the trailing
    /// edge like every other value in Settings.
    @ViewBuilder private var modelRow: some View {
        HStack(spacing: 10) {
            modelStatus
            if case .downloading = parakeet.state {
                Button("Cancel") { parakeet.cancelDownload() }
            } else if ParakeetModel.hasFilesOnDisk {
                Button("Remove", role: .destructive) { parakeet.remove() }
                    .help("Delete the downloaded model and its Neural Engine cache")
            } else if parakeet.isEnabled {
                Button("Download") { parakeet.download() }
            }
        }
    }

    @ViewBuilder private var modelStatus: some View {
        let size = parakeet.installedBytes.map { $0.formatted(.byteCount(style: .file)) }
        switch parakeet.state {
        case .notInstalled:
            Text("Not downloaded").foregroundStyle(.secondary)
        case .downloading(let fraction):
            if let fraction {
                ProgressView(value: fraction).frame(width: 100)
                Text(fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text("Downloading…").foregroundStyle(.secondary)
            }
        case .installed:
            Text(size.map { "Downloaded · \($0)" } ?? "Downloaded").foregroundStyle(.secondary)
        case .preparing:
            ProgressView().controlSize(.small)
            Text("Preparing…").foregroundStyle(.secondary)
        case .ready:
            Label(size.map { "Ready · \($0)" } ?? "Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .multilineTextAlignment(.trailing)
        }
    }

    private func engineBadge(_ engine: DictationEngineID, missing: String) -> some View {
        let available = engines?.contains(engine)
        return Group {
            if engine == inUse {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let available {
                Label(available ? "Available" : missing, systemImage: available ? "circle" : "minus.circle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

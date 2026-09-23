import SwiftUI
import VantageCore

/// Settings → Dictation: the optional built-in Parakeet engine and which other engines this Mac has.
struct DictationSettingsTab: View {
    @Bindable var parakeet: ParakeetModel
    @State private var engines: [DictationEngineID]?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { parakeet.isEnabled }, set: { parakeet.setEnabled($0) })) {
                    Text("Parakeet")
                    Text(ParakeetModel.isInstalled ? "NVIDIA Parakeet v3, running on this Mac's Neural Engine"
                                                   : "Downloads about \(downloadSize) the first time you turn it on")
                }
                LabeledContent("Status") { statusView }
                modelButtons
            } header: {
                Text("Built-in transcription")
            } footer: {
                Text("Transcribes what you dictate on the iPad right here on this Mac, using NVIDIA's Parakeet v3 model on the Neural Engine (English and 24 other European languages). Nothing is downloaded or sent anywhere while this is off. When MacWhisper is installed it's still used first, unless the iPad asks for Parakeet in Settings → Controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Engines on this Mac") {
                LabeledContent("MacWhisper") { engineBadge(.macWhisper, missing: "Not installed") }
                LabeledContent("Parakeet") { engineBadge(.parakeet, missing: parakeet.isEnabled ? "Not ready" : "Off") }
                LabeledContent("Apple Speech") { engineBadge(.apple, missing: "Unavailable") }
            }
        }
        .formStyle(.grouped)
        .task(id: parakeet.state) { engines = await HostTranscriber.availableEngines() }
    }

    private var downloadSize: String {
        ParakeetModel.approximateDownloadSize.formatted(.byteCount(style: .file))
    }

    @ViewBuilder private var statusView: some View {
        switch parakeet.state {
        case .notInstalled:
            Text("Not downloaded").foregroundStyle(.secondary)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 120)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").foregroundStyle(.secondary)
                }
            }
        case .installed:
            Text("Downloaded, off").foregroundStyle(.secondary)
        case .preparing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Preparing…").foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .labelStyle(.titleAndIcon)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder private var modelButtons: some View {
        HStack {
            if case .downloading = parakeet.state {
                Button("Cancel Download") { parakeet.cancelDownload() }
            } else if !ParakeetModel.isInstalled {
                Button("Download Model") { parakeet.download() }
                    .disabled(!parakeet.isEnabled)
            }
            Spacer()
            if ParakeetModel.hasFilesOnDisk {
                if let bytes = parakeet.installedBytes {
                    Text(bytes, format: .byteCount(style: .file)).foregroundStyle(.secondary)
                }
                Button("Remove Model", role: .destructive) { parakeet.remove() }
            }
        }
    }

    private func engineBadge(_ engine: DictationEngineID, missing: String) -> some View {
        let available = engines?.contains(engine)
        return Group {
            if let available {
                Label(available ? "Available" : missing,
                      systemImage: available ? "checkmark.circle.fill" : "minus.circle")
                    .foregroundStyle(available ? .green : .secondary)
                    .labelStyle(.titleAndIcon)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

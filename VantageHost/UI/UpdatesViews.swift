import SwiftUI

/// Settings › General › Updates: the version, where things stand, one button named for what it
/// does right now, and the switch.
struct UpdatesSection: View {
    @Bindable var updater: HostUpdater

    var body: some View {
        let row = updater.row
        Section {
            LabeledContent {
                control(row)
            } label: {
                Text("Casement Host \(HostUpdater.currentVersion)")
                Text(row.status)
            }
            if updater.isAvailable {
                Toggle("Install Updates Automatically", isOn: $updater.installsAutomatically)
            }
        } header: {
            Text("Updates")
        } footer: {
            if let footer = row.footer {
                Footer(footer)
            } else if updater.isAvailable, !updater.installsAutomatically {
                Footer("Casement Host contacts GitHub only when you choose Check for Updates.")
            }
        }
    }

    @ViewBuilder private func control(_ row: UpdateRow) -> some View {
        switch updater.stage {
        case .downloading(_, let fraction?):
            ProgressView(value: fraction)
                .frame(width: 90)
                .accessibilityLabel("Download progress")
        case .checking, .downloading, .preparing, .installing:
            ProgressView().controlSize(.small)
        default:
            if updater.isAvailable, row.action != .none {
                Button(row.action.label) { updater.perform(row.action) }
            }
        }
    }
}

/// The menu's row while an update is waiting for a restart, or has to be downloaded by hand.
struct UpdateMenuSection: View {
    let updater: HostUpdater

    var body: some View {
        if let prompt = UpdateRow.menu(for: updater.stage) {
            GroupedSection(title: "Update") {
                Button { updater.perform(prompt.action) } label: {
                    SettingsRow(prompt.title, symbol: "arrow.down.circle", color: .blue) {
                        RowAction(prompt.action == .restart ? "Restart" : "Download")
                    }
                }
                .help(prompt.action.label)
                .accessibilityHint(prompt.action.label)
            }
            .buttonStyle(.settingsRow)
        }
    }
}

import AppIntents
import SwiftUI
import WidgetKit

@main
struct VantageWidgetBundle: WidgetBundle {
    var body: some Widget {
        ConnectWidget()
        ConnectControl()
    }
}

/// A Home Screen shortcut to one Mac. Tapping hands the app a `vantage://connect/<id>` URL and the
/// session opens straight away — the widget itself never touches the network.
struct ConnectWidget: Widget {
    let kind = DeviceCatalog.widgetKind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectMacIntent.self, provider: ConnectProvider()) { entry in
            ConnectWidgetView(primary: entry.primary, others: entry.others, pinnedMacRemoved: entry.pinnedMacRemoved)
        }
        .configurationDisplayName("Connect to Mac")
        .description("One tap to your Mac. Choose which, or leave it on your most recent.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// Lets the widget be pinned to a particular Mac. Left empty, it follows whatever was used last.
struct SelectMacIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Mac"
    static let description = IntentDescription("Which Mac this widget connects to.")

    @Parameter(title: "Mac")
    var mac: MacEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Connect to \(\.$mac)")
    }
}

struct ConnectEntry: TimelineEntry {
    let date: Date
    let primary: DeviceCatalog.Mac?
    let others: [DeviceCatalog.Mac]
    var pinnedMacRemoved = false
}

/// The catalog is a small file the app rewrites whenever the device list changes, and the app
/// reloads timelines then, so one entry per timeline is enough.
struct ConnectProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ConnectEntry {
        ConnectEntry(date: .now,
                     primary: DeviceCatalog.Mac(id: UUID(), name: "Studio Mac", host: "studio.example.ts.net", lastConnected: .now),
                     others: [DeviceCatalog.Mac(id: UUID(), name: "MacBook Pro", host: "mbp.example.ts.net", lastConnected: nil)])
    }

    func snapshot(for configuration: SelectMacIntent, in context: Context) async -> ConnectEntry {
        context.isPreview ? placeholder(in: context) : entry(for: configuration)
    }

    func timeline(for configuration: SelectMacIntent, in context: Context) async -> Timeline<ConnectEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: SelectMacIntent) -> ConnectEntry {
        let recents = DeviceCatalog.recents()
        if let chosen = configuration.mac {
            // Pinned to one Mac. If it's gone, say so instead of silently switching the widget
            // to whatever was used last.
            guard let primary = recents.first(where: { $0.id == chosen.id }) else {
                return ConnectEntry(date: .now, primary: nil, others: [], pinnedMacRemoved: true)
            }
            return ConnectEntry(date: .now, primary: primary, others: recents.filter { $0.id != primary.id })
        }
        let primary = recents.first
        return ConnectEntry(date: .now, primary: primary, others: recents.filter { $0.id != primary?.id })
    }
}

/// Control Center, Lock Screen, and Action button: one tap to the most recently used Mac. The
/// label names that Mac when the catalog is readable here (App Group builds); otherwise it reads
/// "Connect to Mac" and the app still picks the recent Mac when the intent runs.
struct ConnectControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: DeviceCatalog.controlKind, provider: RecentMacProvider()) { macName in
            ControlWidgetButton(action: ConnectToRecentMacIntent()) {
                Label(macName ?? "Connect to Mac", systemImage: "laptopcomputer")
            }
        }
        .displayName("Connect to Mac")
        .description("Opens Porthole and connects to your most recent Mac.")
    }
}

struct RecentMacProvider: ControlValueProvider {
    var previewValue: String? { nil }

    func currentValue() async throws -> String? {
        DeviceCatalog.recents().first?.name
    }
}

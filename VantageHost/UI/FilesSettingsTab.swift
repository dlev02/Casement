import AppKit
import SwiftUI

/// Settings → Files: what happens when a file arrives from the iPad, where it's saved, and how the
/// Mac shows it while an iPad is watching (macOS hides banners then).
struct FilesSettingsTab: View {
    @AppStorage(FileArrivalSettings.Key.notify) private var notify = FileArrivalSettings().notify
    @AppStorage(FileArrivalSettings.Key.action) private var action = FileArrivalSettings().action
    @AppStorage(FileArrivalSettings.Key.showOnScreen) private var showOnScreen = FileArrivalSettings().showOnScreen
    /// Empty means Downloads.
    @AppStorage(FileArrivalSettings.Key.folder) private var folderPath = ""
    @State private var delivery: HostNotifications.Delivery?

    private enum FolderChoice: Hashable { case downloads, chosen, other }

    var body: some View {
        Form {
            arrivalSection
            folderSection
            watchingSection
        }
        .formStyle(.grouped)
        .task {
            // Follows changes made in System Settings while this is open.
            while !Task.isCancelled {
                delivery = await HostNotifications.shared.delivery()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    // MARK: When files arrive

    private var arrivalSection: some View {
        Section {
            Toggle(isOn: $notify) {
                Text("Show a notification")
                Text("“Received Report.pdf”, with Show in Finder")
            }
            if notify, delivery == .off {
                HStack {
                    Label("Notifications for Porthole Host are off in System Settings.", systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Turn On…") { HostNotifications.shared.openSystemSettings(forThisApp: true) }
                }
            }
            Picker("Then", selection: $action) {
                ForEach(FileArrivalAction.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.radioGroup)
        } header: {
            Text("When files arrive")
        } footer: {
            Text(actionFooter)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionFooter: String {
        switch action {
        case .nothing:
            "Files are saved quietly. They stay in the menu bar's Files list for a minute."
        case .showInFinder:
            "Files that arrive together are selected in one Finder window."
        case .open:
            "Documents, pictures, movies, music and PDFs open in their usual app. Anything else, like apps, scripts, installers, disk images and archives, is never opened automatically; it's shown in Finder instead, as are more than five files at once."
        }
    }

    // MARK: Save files to

    private var folderSection: some View {
        Section {
            Picker("Save files to", selection: folderChoice) {
                Label { Text(Self.name(of: HostFileStore.downloads)) } icon: { FolderIcon(url: HostFileStore.downloads) }
                    .tag(FolderChoice.downloads)
                if let chosen = chosenFolder {
                    Label { Text(Self.name(of: chosen)) } icon: { FolderIcon(url: chosen) }
                        .tag(FolderChoice.chosen)
                }
                Divider()
                Text("Other…").tag(FolderChoice.other)
            }
            .help(chosenFolder?.path(percentEncoded: false) ?? HostFileStore.downloads.path(percentEncoded: false))
            if let chosen = chosenFolder, !ReceiveFolder.isUsable(chosen) {
                Label("“\(chosen.lastPathComponent)” can't be found or isn't writable, so files go to Downloads until it's back.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("Applies from the next connection. Received files are marked as downloaded, so macOS checks apps and scripts before they first open.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chosenFolder: URL? {
        folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    private var folderChoice: Binding<FolderChoice> {
        Binding {
            folderPath.isEmpty ? .downloads : .chosen
        } set: { choice in
            switch choice {
            case .downloads: folderPath = ""
            case .chosen: break
            case .other: chooseFolder()
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose where files from your iPad are saved."
        panel.directoryURL = chosenFolder ?? HostFileStore.downloads
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let isDownloads = url.standardizedFileURL.path == HostFileStore.downloads.standardizedFileURL.path
            folderPath = isDownloads ? "" : url.path(percentEncoded: false)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }

    private static func name(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path(percentEncoded: false))
    }

    // MARK: While an iPad is watching

    private var watchingSection: some View {
        Section {
            Toggle(isOn: $showOnScreen) {
                Text("Show new files on the Mac's screen")
                Text("A small notice at the top right, with Show in Finder")
            }
            LabeledContent("Banners while sharing") {
                HStack(spacing: 10) {
                    deliveryLabel
                    Button("Notification Settings…") {
                        HostNotifications.shared.openSystemSettings(forThisApp: delivery == .off)
                    }
                }
            }
        } header: {
            Text("While an iPad is watching")
        } footer: {
            Text("macOS hides notification banners while the screen is shared, and an iPad watching through Porthole counts as sharing, so Porthole shows its own notice instead. To get banners too, turn on “Allow notifications when mirroring or sharing the display” in Notification Settings.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var deliveryLabel: some View {
        switch delivery {
        case .banners:
            Label("Shown", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Banners show even while the screen is shared.")
        case .hiddenWhileSharing:
            Label("Hidden", systemImage: "eye.slash")
                .foregroundStyle(.secondary)
                .help("macOS holds banners while an iPad is watching; they wait in Notification Center.")
        case .off:
            Label("Off", systemImage: "bell.slash")
                .foregroundStyle(.orange)
                .help("Notifications for Porthole Host are off in System Settings.")
        case .notAsked:
            Text("Not set up yet")
                .foregroundStyle(.secondary)
                .help("macOS asks whether to allow notifications when the first file arrives.")
        case nil:
            ProgressView().controlSize(.small)
        }
    }
}

/// A folder's Finder icon at menu size.
private struct FolderIcon: View {
    let url: URL

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
            .resizable()
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }
}

import Foundation

/// Where an update stands.
nonisolated enum UpdateStage: Equatable, Sendable {
    /// Nothing has been checked in this run.
    case idle
    /// Asking GitHub.
    case checking
    /// This is the newest version.
    case upToDate
    /// Fetching a newer one; the fraction is known only when someone asked for the check.
    case downloading(version: String, fraction: Double?)
    /// Downloaded; checking and unpacking it.
    case preparing(version: String)
    /// Verified and waiting; it installs at the next quiet moment, or when asked.
    case ready(version: String)
    /// Restarting into it.
    case installing(version: String)
    /// There's a newer one, but this copy can't replace itself: it has to be downloaded by hand.
    case manualOnly(version: String)
    /// The check or the download failed; the next check tries again.
    case failed(message: String)
}

/// What the Updates row's button does.
nonisolated enum UpdateRowAction: Equatable, Sendable {
    case none, check, tryAgain, restart, download

    var label: String {
        switch self {
        case .none: ""
        case .check: "Check for Updates"
        case .tryAgain: "Try Again"
        case .restart: "Restart to Update"
        case .download: "Download…"
        }
    }
}

/// The Updates row's wording for a stage. Pure, so every state is tested without a window.
nonisolated struct UpdateRow: Equatable, Sendable {
    /// The line under the version.
    var status: String
    /// What doesn't fit in that line, for the section's footer.
    var footer: String?
    /// The button.
    var action: UpdateRowAction

    static func `for`(_ stage: UpdateStage, automatic: Bool, lastCheck: Date?, now: Date = .now) -> UpdateRow {
        switch stage {
        case .checking:
            return UpdateRow(status: "Checking for updates…", action: .none)
        case .downloading(let version, let fraction):
            let percent = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            return UpdateRow(status: "Downloading version \(version)…\(percent)", action: .none)
        case .preparing(let version):
            return UpdateRow(status: "Preparing version \(version)…", action: .none)
        case .ready(let version):
            return UpdateRow(status: "Version \(version) is ready.",
                             footer: automatic ? "It installs by itself when no device is connected." : nil,
                             action: .restart)
        case .installing(let version):
            return UpdateRow(status: "Installing version \(version)…", action: .none)
        case .manualOnly(let version):
            return UpdateRow(status: "Version \(version) is out.",
                             footer: "Casement Host can't replace itself where it is, so download the new version from GitHub.",
                             action: .download)
        case .failed(let message):
            return UpdateRow(status: "Couldn't check for updates.", footer: message, action: .tryAgain)
        case .upToDate:
            let checked = lastCheck.map { " Last checked \(when($0, now: now))." } ?? ""
            return UpdateRow(status: "You're up to date.\(checked)", action: .check)
        case .idle:
            let status = lastCheck.map { "Last checked \(when($0, now: now))." }
                ?? (automatic ? "Checks for updates once a day." : "Automatic updates are off.")
            return UpdateRow(status: status, action: .check)
        }
    }

    /// The menu's row: only when there's something to do about an update.
    static func menu(for stage: UpdateStage) -> (title: String, action: UpdateRowAction)? {
        switch stage {
        case .ready(let version): ("Version \(version) is ready", .restart)
        case .manualOnly(let version): ("Version \(version) is out", .download)
        default: nil
        }
    }

    /// What restarting would interrupt, for the question asked before it; nil when nothing would.
    static func restartWarning(connectedDevices: [String], movingFiles: Int) -> String? {
        let devices: String? = switch connectedDevices.count {
        case 0: nil
        case 1: "\(connectedDevices[0]) disconnects for a moment, then reconnects by itself."
        default: "\(connectedDevices.count) devices disconnect for a moment, then reconnect by themselves."
        }
        let files: String? = switch movingFiles {
        case 0: nil
        case 1: "The file on its way picks up where it stopped."
        default: "The \(movingFiles) files on their way pick up where they stopped."
        }
        let parts = [devices, files].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func when(_ time: Date, now: Date) -> String {
        let calendar = Calendar.current
        let clock = time.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(time, inSameDayAs: now) { return "today at \(clock)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(time, inSameDayAs: yesterday) {
            return "yesterday at \(clock)"
        }
        return time.formatted(.dateTime.month(.wide).day())
    }
}

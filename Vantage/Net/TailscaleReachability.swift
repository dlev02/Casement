import Foundation
import Network
import VantageCore

/// Detects whether Tailscale appears to be active on this device by looking for a local interface
/// address inside Tailscale's CGNAT range. There is no public LocalAPI on iOS, so this is the
/// most reliable signal available to a third-party app.
@MainActor
@Observable
final class TailscaleReachability {
    private(set) var isActive = false
    /// This device's tailnet IPv4 address, when Tailscale is up.
    private(set) var address: String?
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "vantage.reachability")

    func start() {
        refresh()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        monitor.start(queue: queue)
    }

    func refresh() {
        let addresses = VantageNetwork.localTailscaleAddresses()
        isActive = !addresses.isEmpty
        address = addresses.first { !$0.contains(":") } ?? addresses.first
    }

    /// Tailscale for Mac: the standalone download (System Extension) or the App Store build.
    static let macTailscaleBundleIDs = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]

    static func openTailscaleApp() {
        #if canImport(UIKit)
        if let url = URL(string: "tailscale://") {
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        #elseif os(macOS)
        let workspace = NSWorkspace.shared
        if let app = macTailscaleBundleIDs.lazy.compactMap(workspace.urlForApplication(withBundleIdentifier:)).first {
            workspace.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        } else if let download = URL(string: "https://tailscale.com/download/mac") {
            workspace.open(download)
        }
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#elseif os(macOS)
import AppKit
#endif

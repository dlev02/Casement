import Foundation
import Network
import VantageCore

/// Detects whether Tailscale appears to be active on this iPad by looking for a local interface
/// address inside Tailscale's CGNAT range. There is no public LocalAPI on iOS, so this is the
/// most reliable signal available to a third-party app.
@MainActor
@Observable
final class TailscaleReachability {
    private(set) var isActive = false
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
        isActive = !VantageNetwork.localTailscaleAddresses().isEmpty
    }

    static func openTailscaleApp() {
        #if canImport(UIKit)
        if let url = URL(string: "tailscale://") {
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif

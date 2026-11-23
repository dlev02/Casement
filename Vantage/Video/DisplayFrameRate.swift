import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// How many frames a second this device's screen can show the remote picture at, which every
/// stream request asks the host for: 120 on a ProMotion iPhone, iPad or MacBook Pro, 90 on Vision
/// Pro, 60 elsewhere. Low Power Mode and a hot device ask for 60, since the screen is held to 60
/// then anyway and the extra frames would only cost battery. The host lowers it further to its
/// own display's refresh rate.
enum DisplayFrameRate {
    static func current() -> Int {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical { return 60 }
        return max(60, screenMaximum())
    }

    /// Posted when `current()` may have changed.
    static let changeNotifications: [Notification.Name] = [
        ProcessInfo.thermalStateDidChangeNotification, .NSProcessInfoPowerStateDidChange,
    ]

    private static func screenMaximum() -> Int {
        #if os(visionOS)
        return 90
        #elseif canImport(UIKit)
        let screens = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }
        return screens.map(\.maximumFramesPerSecond).max() ?? 60
        #elseif canImport(AppKit)
        return NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        #else
        return 60
        #endif
    }
}

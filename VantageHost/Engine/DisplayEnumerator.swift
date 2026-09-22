import CoreGraphics
import Foundation
import ScreenCaptureKit
import VantageCore

/// Enumerates capturable displays and converts them to the shared `DisplayInfo` model.
nonisolated enum DisplayEnumerator {
    /// A synthetic display used for headless testing (`--synthetic-capture`), sized to a 2x iPad.
    static func syntheticDisplay(pointWidth: Int = 1470, pointHeight: Int = 956) -> DisplayInfo {
        DisplayInfo(id: 1, name: "Vantage Synthetic Display",
                    pixelWidth: pointWidth * 2, pixelHeight: pointHeight * 2,
                    pointWidth: pointWidth, pointHeight: pointHeight, scale: 2,
                    originX: 0, originY: 0, isMain: true, isBuiltIn: false, isVirtual: true, refreshRate: 60)
    }

    /// Displays available to stream, as `DisplayInfo`. Uses synthetic data in synthetic mode so
    /// that listing never touches ScreenCaptureKit (which would require screen-recording TCC).
    static func availableDisplays() async throws -> [DisplayInfo] {
        if HostOptions.shared.syntheticCapture { return [syntheticDisplay()] }
        return try await shareableDisplays().map(\.info)
    }

    static func shareableDisplays() async throws -> [(display: SCDisplay, info: DisplayInfo)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let mainID = CGMainDisplayID()
        return content.displays.map { display in
            (display, info(for: display, mainID: mainID))
        }
    }

    static func info(for display: SCDisplay, mainID: CGDirectDisplayID) -> DisplayInfo {
        let id = display.displayID
        let mode = CGDisplayCopyDisplayMode(id)
        let pixelWidth = mode.map { $0.pixelWidth } ?? Int(display.frame.width)
        let pixelHeight = mode.map { $0.pixelHeight } ?? Int(display.frame.height)
        let pointWidth = mode.map { $0.width } ?? Int(display.frame.width)
        let pointHeight = mode.map { $0.height } ?? Int(display.frame.height)
        let scale = pointWidth > 0 ? Double(pixelWidth) / Double(pointWidth) : 2.0
        let refresh = mode.map { $0.refreshRate } ?? 60
        return DisplayInfo(
            id: id,
            name: displayName(id) ?? "Display \(id)",
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            pointWidth: pointWidth,
            pointHeight: pointHeight,
            scale: scale,
            originX: Double(display.frame.minX),
            originY: Double(display.frame.minY),
            isMain: id == mainID,
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            isVirtual: isVirtual(id),
            refreshRate: refresh == 0 ? 60 : refresh
        )
    }

    /// A display with no serial and no vendor is almost certainly a synthesized/virtual one.
    static func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(id) == 0 && CGDisplaySerialNumber(id) == 0 && CGDisplayVendorNumber(id) == 0xFFFFFFFF
    }

    static func displayName(_ id: CGDirectDisplayID) -> String? {
        // CoreDisplay/IODisplay localized names are private; fall back to a stable descriptive name.
        if CGDisplayIsBuiltin(id) != 0 { return "Built-in Display" }
        return nil
    }
}

import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import os

/// Holds a display-sleep-prevention assertion while a client session is active, and declares
/// remote user activity so the panel (and framebuffer) stays live for capture.
nonisolated final class PowerManager: @unchecked Sendable {
    private let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "power")
    private var assertionID: IOPMAssertionID = 0
    private var active = false

    func begin(reason: String = "Vantage remote session active") {
        guard !active else { return }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        if status == kIOReturnSuccess {
            assertionID = id
            active = true
            log.info("display-sleep assertion held")
        } else {
            log.error("failed to create power assertion: \(status)")
        }
    }

    /// Declares remote user activity so a sleeping display wakes for the remote client.
    func declareUserActivity() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Vantage remote input" as CFString, kIOPMUserActiveRemote, &id)
    }

    func end() {
        guard active else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        active = false
        log.info("display-sleep assertion released")
    }

    /// True when the Mac is running on AC power (informs "stay available while plugged in").
    static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return true
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String else { continue }
            if state == kIOPSACPowerValue { return true }
        }
        return false
    }
}

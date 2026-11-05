import Foundation
import Testing
@testable import VantageHostUpdates

/// An unattended install takes the host away from under anyone using it, so the rule for when it
/// may happen is pinned here: nothing going on, for five whole minutes, with the setting on.
struct UpdatePolicyTests {
    private let quiet = UpdatePolicy.quietBeforeInstall

    @Test func installsOnlyAfterFiveQuietMinutesWithTheSettingOn() {
        #expect(UpdatePolicy.mayInstallUnattended(automatic: true, activity: UpdateActivity(), quietFor: quiet))
        #expect(!UpdatePolicy.mayInstallUnattended(automatic: true, activity: UpdateActivity(), quietFor: quiet - 1))
        #expect(!UpdatePolicy.mayInstallUnattended(automatic: false, activity: UpdateActivity(), quietFor: quiet))
    }

    @Test(arguments: [
        UpdateActivity(connections: 1),
        UpdateActivity(activeTransfers: 1),
        UpdateActivity(showingPairingCode: true),
        UpdateActivity(windowOpen: true),
    ])
    func anythingGoingOnHoldsTheInstall(activity: UpdateActivity) {
        #expect(!activity.isClear)
        #expect(!UpdatePolicy.mayInstallUnattended(automatic: true, activity: activity, quietFor: quiet * 100))
    }

    @Test func settingOffMeansNoBackgroundCheckEver() {
        let now = Date.now
        #expect(!UpdatePolicy.shouldCheck(automatic: false, sinceLaunch: 1_000_000, lastCheck: nil, now: now))
        #expect(!UpdatePolicy.shouldCheck(automatic: false, sinceLaunch: 1_000_000, lastCheck: now.addingTimeInterval(-1_000_000), now: now))
    }

    @Test func checksTwoMinutesAfterLaunchThenDaily() {
        let now = Date.now
        let launched = UpdatePolicy.firstCheckDelay
        #expect(!UpdatePolicy.shouldCheck(automatic: true, sinceLaunch: launched - 1, lastCheck: nil, now: now))
        #expect(UpdatePolicy.shouldCheck(automatic: true, sinceLaunch: launched, lastCheck: nil, now: now))
        #expect(!UpdatePolicy.shouldCheck(automatic: true, sinceLaunch: launched, lastCheck: now.addingTimeInterval(-UpdatePolicy.checkInterval + 1), now: now))
        #expect(UpdatePolicy.shouldCheck(automatic: true, sinceLaunch: launched, lastCheck: now.addingTimeInterval(-UpdatePolicy.checkInterval), now: now))
        // A clock that moved back doesn't stop checks until it catches up.
        #expect(UpdatePolicy.shouldCheck(automatic: true, sinceLaunch: launched, lastCheck: now.addingTimeInterval(60), now: now))
    }

    @Test func aCopyThatCantBeReplacedIsSentToTheDownload() {
        func can(_ path: String = "/Applications/Casement Host.app", parent: Bool = true, bundle: Bool = true, readOnly: Bool = false) -> Bool {
            UpdatePolicy.canReplaceItself(bundlePath: path, parentIsWritable: parent, bundleIsWritable: bundle, volumeIsReadOnly: readOnly)
        }
        #expect(can())
        #expect(!can(parent: false))
        #expect(!can(bundle: false))
        #expect(!can(readOnly: true))
        #expect(!can("/private/var/folders/x/AppTranslocation/ABC/d/Casement Host.app"))
    }

    @Test func aRestartThatInterruptsNothingAsksNothing() {
        #expect(UpdateRow.restartWarning(connectedDevices: [], movingFiles: 0) == nil)
        #expect(UpdateRow.restartWarning(connectedDevices: ["iPad"], movingFiles: 0) != nil)
        #expect(UpdateRow.restartWarning(connectedDevices: [], movingFiles: 2) != nil)
    }
}

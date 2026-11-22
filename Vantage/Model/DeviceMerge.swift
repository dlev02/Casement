import Foundation

/// How the device list from another device folds into this one's (`DeviceStore.merge`), apart
/// from removals. Pure, so the rules can be checked without iCloud.
///
/// - The same entry (same id): the newer copy wins.
/// - The same computer under another id (saved separately on two devices: same address, or the
///   same verified host key): one entry under the lower id, with the newer copy's settings. Both
///   devices pick the same id without talking to each other, so after one round they agree, and
///   edits and secrets kept under that id line up.
/// - A computer only the other device knows: added.
enum DeviceMerge {
    struct Result: Equatable {
        var devices: [SavedDevice]
        /// Local entries that now go by another id (old, new): their secrets follow.
        var replaced: [Replacement]
        /// The other device's list still has a computer under the id this one dropped, or older
        /// settings for it: this list should go back to iCloud.
        var remoteNeedsUpdate: Bool
    }

    struct Replacement: Equatable {
        var old: SavedDevice
        var new: SavedDevice
    }

    static func merge(local: [SavedDevice], remote: [SavedDevice]) -> Result {
        var devices = local
        var replaced: [Replacement] = []
        var remoteNeedsUpdate = false
        for device in remote {
            if let index = devices.firstIndex(where: { $0.id == device.id }) {
                if isNewer(device, than: devices[index]) { devices[index] = device }
            } else if let index = devices.firstIndex(where: { isSameComputer($0, device) }) {
                let mine = devices[index]
                var kept = isNewer(device, than: mine) ? device : mine
                kept.id = min(device.id, mine.id, by: { $0.uuidString < $1.uuidString })
                if kept.id != mine.id { replaced.append(Replacement(old: mine, new: kept)) }
                devices[index] = kept
                if kept != device { remoteNeedsUpdate = true }
            } else {
                devices.append(device)
            }
        }
        return Result(devices: devices, replaced: replaced, remoteNeedsUpdate: remoteNeedsUpdate)
    }

    /// One computer: the same address however it was typed, or the same verified host key.
    static func isSameComputer(_ a: SavedDevice, _ b: SavedDevice) -> Bool {
        if let key = a.hostPublicKey, key == b.hostPublicKey { return true }
        return hasSameAddress(a, b)
    }

    static func hasSameAddress(_ a: SavedDevice, _ b: SavedDevice) -> Bool {
        a.port == b.port && normalizedHost(a.host) == normalizedHost(b.host)
    }

    static func normalizedHost(_ host: String) -> String {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    private static func isNewer(_ a: SavedDevice, than b: SavedDevice) -> Bool {
        (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
    }

    private static func min(_ a: UUID, _ b: UUID, by less: (UUID, UUID) -> Bool) -> UUID { less(b, a) ? b : a }
}

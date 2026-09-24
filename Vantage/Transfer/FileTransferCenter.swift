import Foundation
import Observation
import VantageCore

/// Every Mac's `FileLink`, for the whole app. Transfers belong to a Mac rather than a screen
/// session, so the device list, the session, and "Open in Vantage" all see the same queue, and
/// files keep moving after the session closes. (visionOS opens sessions in windows of their own;
/// they share this too.)
@MainActor
@Observable
final class FileTransferCenter {
    static let shared = FileTransferCenter()

    private(set) var links: [UUID: FileLink] = [:]
    private let identity: DeviceIdentity
    private let receiveDirectory: URL
    private let clientName: String
    private let clientModel: String

    init(identity: DeviceIdentity? = nil, receiveDirectory: URL = FileTransferController.defaultReceiveDirectory) {
        self.identity = identity
            ?? (try? KeychainStore(service: "com.benjaminlevinson.vantage.client").loadOrCreateIdentity())
            ?? DeviceIdentity()
        self.receiveDirectory = receiveDirectory
        self.clientName = ClientSession.localDeviceName
        self.clientModel = ClientSession.hardwareModel()
    }

    /// This Mac's link, made the first time it's asked for; kept up to date with the device.
    func link(for device: SavedDevice) -> FileLink {
        if let link = links[device.id] {
            link.update(device)
            return link
        }
        let link = FileLink(files: FileTransferController(receiveDirectory: receiveDirectory), identity: identity,
                            clientName: clientName, clientModel: clientModel)
        #if DEBUG
        if let millis = ClientOptions.slowFilesMillis { link.files.chunkDelayForTesting = .milliseconds(millis) }
        #endif
        link.update(device)
        links[device.id] = link
        return link
    }

    /// The transfers for a Mac, if anything has happened with it this run.
    func files(for deviceID: UUID) -> FileTransferController? {
        links[deviceID]?.files
    }

    /// Something is moving (or waiting to) with any Mac.
    var hasActiveTransfers: Bool { links.values.contains { $0.files.hasActiveTransfers } }

    /// Back in the foreground: every Mac with files waiting tries again now.
    func retryAll() {
        for link in links.values { link.retryNow() }
    }
}

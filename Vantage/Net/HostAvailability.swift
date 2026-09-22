import Foundation
import Network
import Observation
import VantageCore

enum HostAvailability: Equatable, Sendable {
    case checking, ready, online, pairingRequired, needsPermission, unavailable, incompatible
    var label: String {
        switch self {
        case .checking: "Checking…"
        case .ready: "Available"
        case .online: "Host online"
        case .pairingRequired: "Pair to connect"
        case .needsPermission: "Mac permission needed"
        case .unavailable: "Unavailable"
        case .incompatible: "Update needed"
        }
    }
}

@MainActor enum HostAvailabilityProbe {
    static func check(_ device: SavedDevice, identity: DeviceIdentity, timeout: Duration = .seconds(5)) async -> HostAvailability {
        guard !Task.isCancelled,
              let address = try? ConnectionAddress(host: device.host, port: String(device.port)),
              let port = NWEndpoint.Port(rawValue: address.port) else { return .unavailable }
        let channel = MessageChannel(connection: NWConnection(host: NWEndpoint.Host(address.host), port: port,
                                                              using: VantageNetwork.tcpParameters()))
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            await channel.close()
        }
        defer { timer.cancel() }
        let status: HostAvailability = await withTaskCancellationHandler {
            do {
                try await channel.start()
                try await channel.send(.hello(Hello(clientName: "Vantage availability", deviceModel: "client", appVersion: "1.0",
                    clientPublicKey: identity.publicKeyData, supportedCodecs: [.hevc, .h264], maxDecodeWidth: 0,
                    maxDecodeHeight: 0, viewport: nil, isReadinessProbe: true)))
                guard let response = try await channel.receive() else { return .unavailable }
                if case .authResult(let result) = response, result.status == .versionMismatch { return .incompatible }
                guard case .challenge(let challenge) = response else { return .unavailable }
                let signature = try identity.sign(AuthTranscript.bytes(nonce: challenge.nonce,
                    hostPublicKey: challenge.hostPublicKey, clientPublicKey: identity.publicKeyData))
                try await channel.send(.authenticate(Authenticate(signature: signature)))
                guard case .authResult(let result)? = try await channel.receive() else { return .unavailable }
                switch result.status {
                case .pairingRequired, .badPairingCode: return .pairingRequired
                case .denied: return .needsPermission
                case .versionMismatch: return .incompatible
                case .ok:
                    guard let readiness = result.readiness else { return .online }
                    return readiness.screenRecordingGranted && readiness.accessibilityGranted ? .ready : .needsPermission
                default: return .unavailable
                }
            } catch { return .unavailable }
        } onCancel: { Task { await channel.close() } }
        await channel.close()
        return status
    }
}

@MainActor @Observable final class HostAvailabilityStore {
    private(set) var statuses: [UUID: HostAvailability] = [:]
    private var generation = UUID()
    private let identity = (try? KeychainStore(service: "com.benjaminlevinson.vantage.client").loadOrCreateIdentity()) ?? DeviceIdentity()

    func monitor(_ devices: [SavedDevice]) async {
        let id = UUID()
        generation = id
        statuses = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, .checking) })
        defer { if generation == id { statuses = [:] } }
        while !Task.isCancelled {
            for start in stride(from: 0, to: devices.count, by: 4) {
                guard !Task.isCancelled else { return }
                let batch = Array(devices[start..<min(start + 4, devices.count)])
                await withTaskGroup(of: (UUID, HostAvailability).self) { group in
                    for device in batch {
                        group.addTask { [identity] in (device.id, await HostAvailabilityProbe.check(device, identity: identity)) }
                    }
                    for await (deviceID, status) in group {
                        guard !Task.isCancelled, generation == id else { return }
                        statuses[deviceID] = status
                    }
                }
            }
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
        }
    }
}

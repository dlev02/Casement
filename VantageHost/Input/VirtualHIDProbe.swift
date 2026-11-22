#if DEBUG
import CoreHID
import Foundation
import os

/// DEBUG `--virtual-hid`: tries to create the two virtual HID devices native touch and game
/// controllers would need (a five-finger touchscreen and a gamepad) and logs whether macOS
/// allowed it. `HIDVirtualDevice(properties:)` returns nil unless the app is signed with
/// `com.apple.developer.hid.virtual.device`, which Apple grants on request, so this is how to
/// check that the entitlement took once it's in the provisioning profile. Nothing is sent to the
/// devices and nothing in a session uses them yet; see docs/research/virtual-hid.md for the plan.
nonisolated enum VirtualHIDProbe {
    private static let log = Logger(subsystem: "com.benjaminlevinson.vantage.host", category: "virtualhid")
    /// Kept so the devices stay registered for the life of the process (a test can look for them
    /// in System Information or `hidutil list`).
    nonisolated(unsafe) private static var devices: [HIDVirtualDevice] = []

    static func run() {
        Task {
            for (name, properties) in [("touchscreen", touchscreen), ("gamepad", gamepad)] {
                guard let device = HIDVirtualDevice(properties: properties) else {
                    log.error("virtual \(name, privacy: .public): refused; the build lacks com.apple.developer.hid.virtual.device")
                    continue
                }
                await device.activate(delegate: Delegate())
                devices.append(device)
                log.info("virtual \(name, privacy: .public): created \(device.description, privacy: .public)")
            }
        }
    }

    /// Answers the system's get/set report requests with nothing: the probe only proves creation.
    private struct Delegate: HIDVirtualDeviceDelegate {
        func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType, id: HIDReportID?,
                              data: Data) async throws {}
        func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType, id: HIDReportID?,
                              maxSize: Int) async throws -> Data { Data() }
    }

    /// Not a real vendor: Casement's own test ID, never a Sony or Microsoft one (see the doc).
    private static let vendorID: UInt32 = 0xF0C5

    private static let touchscreen = HIDVirtualDevice.Properties(
        descriptor: Data(touchscreenDescriptor), vendorID: vendorID, productID: 0x0001, transport: .virtual,
        product: "Casement Touch", manufacturer: "Casement", uniqueID: "casement-virtual-touch")

    private static let gamepad = HIDVirtualDevice.Properties(
        descriptor: Data(gamepadDescriptor), vendorID: vendorID, productID: 0x0002, transport: .virtual,
        product: "Casement Gamepad", manufacturer: "Casement", uniqueID: "casement-virtual-gamepad")

    /// A touchscreen digitizer with five contacts (tip switch, contact ID, X, Y in 0…32767 each)
    /// and a contact count: report 1, 1 + 5 × 6 bytes.
    static let touchscreenDescriptor: [UInt8] = {
        let finger: [UInt8] = [
            0x09, 0x22,                   //   Usage (Finger)
            0xA1, 0x02,                   //   Collection (Logical)
            0x09, 0x42,                   //     Usage (Tip Switch)
            0x15, 0x00, 0x25, 0x01,       //     Logical 0…1
            0x75, 0x01, 0x95, 0x01,       //     1 bit × 1
            0x81, 0x02,                   //     Input (Data, Var, Abs)
            0x75, 0x07, 0x95, 0x01,       //     7 bits padding
            0x81, 0x03,                   //     Input (Const)
            0x09, 0x51,                   //     Usage (Contact Identifier)
            0x25, 0x0F, 0x75, 0x08,       //     Logical 0…15, 8 bits
            0x81, 0x02,                   //     Input (Data, Var, Abs)
            0x05, 0x01,                   //     Usage Page (Generic Desktop)
            0x26, 0xFF, 0x7F,             //     Logical max 32767
            0x75, 0x10, 0x95, 0x01,       //     16 bits × 1
            0x09, 0x30, 0x81, 0x02,       //     Usage (X), Input
            0x09, 0x31, 0x81, 0x02,       //     Usage (Y), Input
            0x05, 0x0D,                   //     Usage Page (Digitizers)
            0xC0,                         //   End Collection
        ]
        var descriptor: [UInt8] = [
            0x05, 0x0D,                   // Usage Page (Digitizers)
            0x09, 0x04,                   // Usage (Touch Screen)
            0xA1, 0x01,                   // Collection (Application)
            0x85, 0x01,                   //   Report ID 1
        ]
        for _ in 0 ..< 5 { descriptor += finger }
        descriptor += [
            0x09, 0x54,                   //   Usage (Contact Count)
            0x25, 0x05, 0x75, 0x08, 0x95, 0x01,
            0x81, 0x02,                   //   Input (Data, Var, Abs)
            0xC0,                         // End Collection
        ]
        return descriptor
    }()

    /// A gamepad: 16 buttons, a hat, two sticks (X, Y, Z, Rz) and two triggers (Rx, Ry), 8 bits
    /// each: report 1, 2 + 1 + 6 bytes.
    static let gamepadDescriptor: [UInt8] = [
        0x05, 0x01,                       // Usage Page (Generic Desktop)
        0x09, 0x05,                       // Usage (Game Pad)
        0xA1, 0x01,                       // Collection (Application)
        0x85, 0x01,                       //   Report ID 1
        0x05, 0x09,                       //   Usage Page (Button)
        0x19, 0x01, 0x29, 0x10,           //   Buttons 1…16
        0x15, 0x00, 0x25, 0x01,           //   Logical 0…1
        0x75, 0x01, 0x95, 0x10,           //   1 bit × 16
        0x81, 0x02,                       //   Input (Data, Var, Abs)
        0x05, 0x01,                       //   Usage Page (Generic Desktop)
        0x09, 0x39,                       //   Usage (Hat Switch)
        0x15, 0x00, 0x25, 0x07,           //   Logical 0…7
        0x35, 0x00, 0x46, 0x3B, 0x01,     //   Physical 0…315
        0x65, 0x14,                       //   Unit (degrees)
        0x75, 0x04, 0x95, 0x01,           //   4 bits × 1
        0x81, 0x42,                       //   Input (Data, Var, Abs, Null)
        0x65, 0x00,                       //   Unit (none)
        0x75, 0x04, 0x95, 0x01,           //   4 bits padding
        0x81, 0x03,                       //   Input (Const)
        0x15, 0x00, 0x26, 0xFF, 0x00,     //   Logical 0…255
        0x75, 0x08, 0x95, 0x06,           //   8 bits × 6
        0x09, 0x30, 0x09, 0x31,           //   X, Y (left stick)
        0x09, 0x32, 0x09, 0x35,           //   Z, Rz (right stick)
        0x09, 0x33, 0x09, 0x34,           //   Rx, Ry (triggers)
        0x81, 0x02,                       //   Input (Data, Var, Abs)
        0xC0,                             // End Collection
    ]
}
#endif

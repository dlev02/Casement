# Virtual HID: native touch and game controllers on the Mac

Checked 2026-11-22 against Xcode 27.2 (27B52), macOS 27.2 SDK. What Casement would need to give
a Mac real multi-finger touch (macOS 27 touchscreen behaviour) and a virtual DualSense or Xbox
controller from an iPad or iPhone, what exists in the SDK today, and the entitlement request.

## What the SDK has

**No public way to inject touches.** `CGEventType` has mouse, scroll, key, tablet pointer and
tablet proximity events and nothing for touch. macOS 27's touch support is in AppKit as things an
app *receives*:

- `NSScreen.touchCapabilities` → `NSScreen.TouchCapabilities.multiTouch` (`API_AVAILABLE(macos(27.0))`,
  `NSScreen.h`): whether a screen takes touch.
- `NSPanGestureRecognizer.minimumNumberOfTouches` / `maximumNumberOfTouches` (macos 27.0).
- `NSGestureRecognizer.cancellableByScrollGesture` (macos 27.0).
- `NSEvent.touchSwipeNavigationEnabled` (class property, macos 27).

Touches reach those APIs from a digitizer HID device. So the only route for a remote device's
fingers to arrive as touches (so controls and menus grow under them, as on a touch Mac) is a
**virtual HID digitizer**. The same holds for game controllers: Mac games read a controller as a
HID device, so the iPad's controller (or the iPad itself) has to show up as one.

**CoreHID virtual devices** (`CoreHID.framework`, macOS 15+, Swift only), from
`CoreHID.swiftmodule/arm64e-apple-macos.swiftinterface`:

```swift
@available(macOS 15, *)
public actor HIDVirtualDevice {
  public struct Properties: Sendable {
    public init(descriptor: Data, vendorID: UInt32, productID: UInt32? = nil, transport: HIDDeviceTransport? = nil,
                product: String? = nil, manufacturer: String? = nil, modelNumber: String? = nil, versionNumber: UInt64? = nil,
                serialNumber: String? = nil, uniqueID: String? = nil, locationID: UInt64? = nil,
                localizationCode: HIDDeviceLocalizationCode? = nil, extraProperties: [String: AnyObject]? = nil)
  }
  public init?(properties: HIDVirtualDevice.Properties)          // nil without the entitlement
  public func activate(delegate: any HIDVirtualDeviceDelegate)
  public func dispatchInputReport(data: Data, timestamp: SuspendingClock.Instant) async throws
  nonisolated public var hidDevice: IOHIDUserDevice? { get }     // macOS 26+
}

@available(macOS 15, *)
public protocol HIDVirtualDeviceDelegate: Sendable {
  func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
                        id: HIDReportID?, data: Data) async throws
  func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
                        id: HIDReportID?, maxSize: Int) async throws -> Data
}
```

`HIDDeviceTransport` has `.virtual`. The C API underneath is `IOHIDUserDeviceCreateWithProperties`
(`IOKit/hidsystem/IOHIDUserDevice.h`), whose header says: "In order to create the device, the
entitlement `com.apple.developer.hid.virtual.device` is required." Apple's DTS has said on the
forums that this is the key for the CoreHID API, that it is *not* a DriverKit entitlement, and that
`com.apple.developer.driverkit.family.hid.virtual.device` is defunct.

**Verified here**: a binary without the entitlement gets `nil` from `HIDVirtualDevice(properties:)`
(no crash, no prompt). `VirtualHIDProbe` (DEBUG host, `--virtual-hid`) creates the touchscreen and
gamepad below at launch and logs `virtual touchscreen: created …` or `refused`, which is the check
to run once the entitlement is in the profile.

## Game controllers: the catch

GameController.framework (`GCController.controllers()`, what most Mac games use) recognises
controllers it knows (`GCDualSenseGamepad`, `GCDualShockGamepad`, Xbox, MFi) by vendor and product
ID and their own report formats. A developer reported on the Apple forums (thread 859037, Aug 2026)
that a CoreHID virtual gamepad with a Game Pad descriptor is read fine by apps that read HID
directly (SDL, Steam, emulators), while GameController reports no controllers; that question has no
answer from Apple yet. So:

- A **generic HID gamepad** (Casement's own vendor ID, `VirtualHIDProbe.gamepadDescriptor`) reaches
  SDL/Steam-style games and is honest about what it is.
- Appearing to GameController as a **DualSense or Xbox controller** would mean presenting Sony's
  (0x054C/0x0CE6) or Microsoft's IDs and their report formats, i.e. impersonating their hardware.
  Don't do that without Drew deciding it, and expect App Review to ask.

## Plan, once the entitlement is granted

Wire (capability-gated like `stylusEvent`; golden vectors on both sides):

- `HostCapabilities.touch: Bool?` and `touchEvent` (binary, kind 126): up to 10 contacts, each
  `id u8 | phase u8 | x f32 | y f32 | majorRadius f32`, in display points. The client sends it for
  fingers in Direct Touch mode instead of the tap/pan translation when the host offers it.
- `HostCapabilities.gamepads: Bool?` and `gamepadState` (binary, kind 127): `slot u8 | buttons u32 |
  leftX/leftY/rightX/rightY i16 | leftTrigger/rightTrigger u8 | dpad u8`, sent on change and at
  60 Hz while anything is held. The client reads the iPad's own controllers with `GCController`
  (`.extendedGamepad`), which already covers DualSense, Xbox and MFi pads on iPadOS.

Host (behind `HostEnvironment`, with a synthetic adapter that only counts reports):

- `VirtualTouchscreen`: one `HIDVirtualDevice` per session with the digitizer descriptor
  (`VirtualHIDProbe.touchscreenDescriptor`: report 1, five contacts of tip switch, contact ID,
  X, Y in 0…32767, then contact count), placed over the streamed display; contacts scale from
  display points to 0…32767 of that display. Needs a device check of how macOS 27 maps a virtual
  digitizer to a screen (likely by matching size, else the main display).
- `VirtualGamepad`: one device per controller slot, created when the client first sends that slot
  and released with the session (released devices disappear from the system at once).
- Released on teardown and on `releaseAll`, like held keys.

Signing: add `com.apple.developer.hid.virtual.device = true` to `VantageHost/VantageHost.entitlements`
only after the App ID has it, or the Developer ID build won't sign. The Debug probe tells whether
the profile carries it.

## The entitlement request

Where: developer.apple.com → Certificates, Identifiers & Profiles → Identifiers →
`me.drewlevinson.casement.host` → **Capability Requests** → **HID Virtual Device**
(`com.apple.developer.hid.virtual.device`). Others report waits of months, so send it early.

- Team: 7BVMD7TA97
- Bundle ID: `me.drewlevinson.casement.host` (Casement Host for Mac, Developer ID, outside the App Store)
- Entitlement: `com.apple.developer.hid.virtual.device`

Suggested justification:

> Casement is a remote-desktop app: Casement Host runs on the user's own Mac and is controlled from
> their own iPad or iPhone over their private network (Tailscale, or their local network). Today it
> posts pointer, scroll, keyboard and Apple Pencil tablet events with CGEvent. We'd like to use
> CoreHID's HIDVirtualDevice for two input types CGEvent can't represent:
>
> 1. A virtual multi-touch digitizer, so fingers on the iPad arrive on the Mac as real touches,
>    with macOS 27's touch behaviour, instead of being translated into mouse clicks.
> 2. A virtual gamepad, so a game controller paired with the iPad drives games on the Mac.
>
> Devices are created only while a paired, authenticated device is connected, carry Casement's own
> identity (not another vendor's), are released when the session ends, and are only fed input from
> that device. Casement Host already requires the user's Accessibility grant to post events.

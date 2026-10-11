import IOKit.ps
import SwiftUI
import VantageCore

/// The menu-bar popover, in System Settings' language (see `HostMenuComponents`): a hero with
/// this Mac (and whoever is connected to it), its name and one line of status; anything that
/// needs fixing; grouped Devices (Paired Devices opens in place) and Files sections; and glass
/// Settings and More (Restart Safely, Quit) buttons at the foot. Pair a Device is a big glass
/// button until something has paired, then the last row of Devices; either opens into the pairing
/// panel (this Mac's tailnet name and the code) in its place. Controls are glass; the sections
/// they sit beside are not.
struct HostMenuView: View {
    @Bindable var controller: HostController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("menu.showsPairedDevices") private var showsPairedDevices = false

    var body: some View {
        VStack(spacing: 14) {
            hero
            if isFirstPairing { pairing }
            notices
            devicesSection
            if !isFirstPairing, controller.pairingCode != nil { pairing }
            HostFilesSection(controller: controller)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(width: 320)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: controller.pairingCode)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: controller.recentlyPaired)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: controller.connectedDevices.map(\.id))
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: showsPairedDevices)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: controller.trustedClients.map(\.id))
        .task {
            controller.refreshTailscale()
            while !Task.isCancelled {
                controller.refreshPermissions()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    // MARK: Hero

    private enum Readiness { case ready, connected, offline, off, error }

    private var readiness: Readiness {
        switch controller.status {
        case .error: .error
        case .idle: .off
        // A session counts once it has signed in, so an availability check never flashes it.
        case .listening, .connected:
            !controller.connectedDevices.isEmpty ? .connected : controller.tailscaleRunning ? .ready : .offline
        }
    }

    private var statusTint: Color {
        switch readiness {
        case .ready: .green
        case .connected: .accentColor
        case .offline: .orange
        case .off: .secondary
        case .error: .red
        }
    }

    /// "Ready for connections", with the state word in its colour.
    private var statusLine: Text {
        let tint = statusTint
        return switch readiness {
        case .ready: Text("\(Text("Ready").foregroundStyle(tint)) for connections")
        case .connected:
            controller.connectedDevices.count == 1
                ? Text("\(Text("Connected").foregroundStyle(tint)) to \(controller.connectedDevices[0].name)")
                : Text("\(Text("Connected").foregroundStyle(tint)) to \(controller.connectedDevices.count) devices")
        case .offline: Text("\(Text("Offline").foregroundStyle(tint)) until Tailscale is running")
        case .off: Text("Not accepting connections")
        case .error: Text("\(Text("Can't accept connections").foregroundStyle(tint))")
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            heroPicture
                .frame(height: 64)
            VStack(spacing: 3) {
                Text(controller.computerName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                statusLine
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
    }

    /// This Mac on a soft glow of the status colour; while someone's connected, their device sits
    /// beside it with dots running between them.
    private var heroPicture: some View {
        HStack(spacing: 12) {
            if let device = controller.connectedDevices.last {
                Image(systemName: device.symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                ConnectionDots()
                    .transition(.opacity)
            }
            Image(systemName: Self.thisMacSymbol)
                .font(.system(size: 50, weight: .thin))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .background {
                    Circle()
                        .fill(RadialGradient(colors: [statusTint.opacity(0.35), .clear], center: .center, startRadius: 2, endRadius: 46))
                        .frame(width: 110, height: 110)
                }
        }
        .accessibilityHidden(true)
    }

    /// A laptop when this Mac has a battery, else a desktop.
    private static let thisMacSymbol: String = {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        let hasBattery = sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source).takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
        return hasBattery ? "laptopcomputer" : "desktopcomputer"
    }()

    // MARK: Pairing

    /// Nothing has paired yet, so pairing is the one thing to do: a big button under the hero.
    /// After that it's the last row of Devices.
    private var isFirstPairing: Bool { controller.trustedClients.isEmpty }

    @ViewBuilder
    private var pairing: some View {
        if let code = controller.pairingCode {
            PairingCodePanel(code: code, address: controller.tailscaleSelfName, expiresAt: controller.pairingCodeExpiresAt,
                             onNewCode: { controller.generatePairingCode() },
                             onDone: { controller.cancelPairingCode() })
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        } else {
            // The iPad's pairing prompt and the Windows host call this Show Pairing Code.
            // Glass, not a tinted bar: pairing is occasional, so it shouldn't outshout the status.
            Button { controller.generatePairingCode() } label: {
                Label {
                    Text("Pair a Device")
                } icon: {
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help("Show Pairing Code: a one-time code to enter in Porthole on a new iPad, iPhone, or Mac")
            .accessibilityHint("Shows a one-time code to enter in Porthole")
        }
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        let needsScreen = !controller.hasScreenPermission, needsInput = !controller.hasInputPermission
        let failed: String? = if case .error(let message) = controller.status { message } else { nil }
        if failed != nil || !controller.tailscaleRunning || needsScreen || needsInput {
            GroupedSection(title: "Needs Attention") {
                if let failed {
                    SettingsRow("Can't accept connections", subtitle: failed, symbol: "exclamationmark.triangle.fill", color: .red)
                }
                if !controller.tailscaleRunning {
                    Button { controller.openTailscale() } label: {
                        SettingsRow("Tailscale isn't running", subtitle: "Your devices reach this Mac through it.",
                                    symbol: "network.slash", color: .orange) { RowAction("Open") }
                    }
                }
                if needsScreen {
                    Button { controller.requestScreenPermission() } label: {
                        SettingsRow("Allow Screen Recording", subtitle: "To show this Mac's screen.",
                                    symbol: "rectangle.dashed.badge.record", color: .orange) { RowAction("Allow") }
                    }
                }
                if needsInput {
                    Button { controller.requestInputPermission() } label: {
                        SettingsRow("Allow Accessibility", subtitle: "To click and type on this Mac.",
                                    symbol: "accessibility", color: .orange) { RowAction("Allow") }
                    }
                }
            }
            .buttonStyle(.settingsRow)
        }
    }

    // MARK: Devices

    private var devicesSection: some View {
        GroupedSection(title: "Devices") {
            if let name = controller.recentlyPaired {
                SettingsRow("Paired with \(name)", subtitle: "It can connect any time now.", symbol: "checkmark", color: .green)
                    .accessibilityElement(children: .combine)
            }
            ForEach(controller.connectedDevices) { device in
                SettingsRow(device.name, symbol: device.symbol, color: .accentColor) {
                    ConnectedBadge()
                }
                .accessibilityElement(children: .combine)
            }
            let clients = controller.trustedClients
            Button { showsPairedDevices.toggle() } label: {
                SettingsRow("Paired Devices", symbol: "ipad.and.iphone", color: .gray) {
                    HStack(spacing: 8) {
                        Text(clients.isEmpty ? "None" : "\(clients.count)")
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showsPairedDevices && !clients.isEmpty ? 90 : 0))
                    }
                }
            }
            .disabled(clients.isEmpty)
            .help(showsPairedDevices ? "Hide the devices that can connect" : "Show the devices that can connect")
            .accessibilityValue(clients.isEmpty ? "None" : "\(clients.count), \(showsPairedDevices ? "expanded" : "collapsed")")
            if showsPairedDevices {
                // Connected first, then newest first; a long list ends in Settings, not off screen.
                let connected = Set(controller.connectedDevices.map(\.fingerprint))
                let sorted = clients.sorted { (connected.contains($0.id) ? 1 : 0, $0.addedAt) > (connected.contains($1.id) ? 1 : 0, $1.addedAt) }
                ForEach(sorted.prefix(Self.pairedDevicesShown)) { client in
                    PairedDeviceRow(client: client, isConnected: connected.contains(client.id)) {
                        controller.revoke(client.fingerprint)
                    }
                    .transition(.opacity)
                }
                if sorted.count > Self.pairedDevicesShown {
                    Button { open(settingsTab: "devices") } label: {
                        HStack {
                            Text("Show All \(sorted.count) in Settings…")
                                .foregroundStyle(Color.accentColor)
                            Spacer()
                        }
                        .padding(.leading, 10 + MenuMetrics.iconSize + 10)
                        .padding(.trailing, 10)
                        .frame(minHeight: MenuMetrics.rowHeight)
                        .contentShape(.rect)
                    }
                    .transition(.opacity)
                }
            }
            if !isFirstPairing, controller.pairingCode == nil {
                // The iPad's pairing prompt and the Windows host call this Show Pairing Code.
                Button { controller.generatePairingCode() } label: {
                    SettingsRow("Pair a Device", symbol: "plus", color: .blue)
                }
                .help("Show Pairing Code: a one-time code to enter in Porthole on a new iPad, iPhone, or Mac")
                .accessibilityHint("Shows a one-time code to enter in Porthole")
            }
        }
        .buttonStyle(.settingsRow)
    }

    /// How many paired devices the opened row lists before handing over to Settings.
    private static let pairedDevicesShown = 5

    // MARK: Footer

    /// The version on the left; round glass Settings and More buttons on the right, like the
    /// system's own menu bar extras.
    private var footer: some View {
        HStack(spacing: 8) {
            Text("Porthole Host \(Self.version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 10)
            Spacer(minLength: 0)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button { open(settingsTab: nil) } label: {
                        Image(systemName: "gearshape")
                            .frame(width: 18, height: 18)
                    }
                    .keyboardShortcut(",")
                    .help("Settings (⌘,)")
                    .accessibilityLabel("Settings")
                    // A SwiftUI Menu draws its own label and drops the glass, so this is a glass
                    // button that pops a native menu.
                    Button(action: showMoreMenu) {
                        Image(systemName: "ellipsis")
                            .frame(width: 18, height: 18)
                    }
                    .help("More")
                    .accessibilityLabel("More")
                    .help("More")
                    .accessibilityLabel("More")
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
        }
        .background {
            // ⌘Q still quits while the popover is open, now that Quit lives in the More menu.
            Button("Quit", action: quit)
                .keyboardShortcut("q")
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Restart Safely (when it can) and Quit, under the pointer.
    private func showMoreMenu() {
        let menu = NSMenu()
        if controller.canRestartSafely {
            menu.addItem(closureMenuItem("Restart Safely…", symbol: "restart") { controller.restartSafely() })
            menu.addItem(.separator())
        }
        let quitItem = closureMenuItem("Quit Porthole Host", symbol: "power") { quit() }
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func open(settingsTab tab: String?) {
        if let tab { HostSettingsNavigation.shared.tab = tab }
        // A menu bar app isn't active, so its Settings window would open behind everything.
        NSApp.activate()
        openSettings()
    }
}

/// A menu item that runs a closure (the item holds its target, which `target` alone wouldn't).
private func closureMenuItem(_ title: String, symbol: String, handler: @escaping () -> Void) -> NSMenuItem {
    let target = MenuItemTarget(handler)
    let item = NSMenuItem(title: title, action: #selector(MenuItemTarget.run), keyEquivalent: "")
    item.target = target
    item.representedObject = target
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    return item
}

private final class MenuItemTarget: NSObject {
    let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}

/// A tailnet name in a capsule, with a copy button.
private struct AddressChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            CopyButton(text: name)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(.quinary, in: .capsule)
        .help("This Mac's name on your tailnet")
    }
}

/// Copies a string; the glyph turns into a checkmark for a moment.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .frame(width: 16, height: 16)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
        .help("Copy")
        .accessibilityLabel(copied ? "Copied" : "Copy tailnet name")
    }
}

/// The code on show, in place of the Pair a Device button: this Mac's tailnet name to add it by
/// (for an iPad without a Tailscale key, which can't list the tailnet), six big digits in two
/// groups of three, how long they last, a new code, and Done (which withdraws it, rather than
/// leaving a live code nobody can see).
private struct PairingCodePanel: View {
    let code: String
    /// This Mac's tailnet name; empty while Tailscale isn't running.
    let address: String
    let expiresAt: Date?
    let onNewCode: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if !address.isEmpty {
                VStack(spacing: 6) {
                    Text("In Porthole on your device, add this Mac")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    AddressChip(name: address)
                    Text("or choose it from your Tailscale devices.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(address.isEmpty ? "Enter this code in Porthole on your device" : "Then enter this code")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                digits(code.prefix(3))
                digits(code.dropFirst(3))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pairing code")
            .accessibilityValue(code.map(String.init).joined(separator: " "))
            HStack(spacing: 10) {
                expiry
                Spacer(minLength: 4)
                Button("New Code", action: onNewCode)
                    .buttonStyle(.glass)
                    .help("Replace this code with a new one")
                Button("Done", action: onDone)
                    .buttonStyle(.glassProminent)
                    .help("Hide the code; it stops working")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.quinary, in: .rect(cornerRadius: MenuMetrics.sectionRadius))
    }

    private func digits(_ group: Substring) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(group.enumerated()), id: \.offset) { _, digit in
                Text(String(digit))
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(width: 36, height: 48)
                    .background(.background.opacity(0.7), in: .rect(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            }
        }
    }

    @ViewBuilder
    private var expiry: some View {
        Group {
            if let expiresAt, expiresAt > .now {
                Label {
                    Text(timerInterval: Date.now...expiresAt, countsDown: true)
                } icon: {
                    Image(systemName: "timer")
                }
            } else if expiresAt == nil {
                Text("Test code")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .help("The code works once, for ten minutes")
    }
}

import AppKit
import SwiftUI

/// The first-run setup window: where the app lives (the menu bar), the two permissions it needs,
/// Start at Login and notifications, then how to pair. One window, every step visible at once,
/// each with a numbered badge that turns into a green check when it's done.
///
/// Opens by itself at launch until it has been finished once, again whenever Screen Recording
/// or Accessibility is missing at launch or goes missing later, and from More › Set Up Casement
/// Host… in the menu.
@MainActor
final class HostSetup: NSObject, NSWindowDelegate {
    static let shared = HostSetup()

    /// Set once the window has been closed (Done or the close button).
    static let completedKey = "setup.completed"

    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    private var window: NSWindow?
    private weak var controller: HostController?
    private var model: SetupModel?

    /// At launch: open if setup never finished or a required permission is missing.
    func showIfNeeded(_ controller: HostController) {
        controller.refreshPermissions()
        if !Self.isCompleted || !controller.hasScreenPermission || !controller.hasInputPermission {
            show(controller)
        }
    }

    /// `preview` (`--open-setup`) shows the window without saving anything when it closes.
    func show(_ controller: HostController, preview: Bool = false) {
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.controller = controller
        let model = SetupModel(startAtLogin: Self.isCompleted ? controller.loginItem.isEnabled : true, preview: preview)
        self.model = model
        let view = SetupView(controller: controller, model: model, onDone: { [weak self] in self?.window?.close() })
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Set Up Casement Host"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        position(window)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Just under the menu bar icon, so the window's first line ("Casement Host lives up here")
    /// points at it; centred when the icon can't be found (hidden behind the notch or overflow).
    private func position(_ window: NSWindow) {
        window.layoutIfNeeded()
        let size = window.frame.size
        let statusWindow = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") && $0.isVisible }
        guard let icon = statusWindow?.frame, icon.width > 0,
              let screen = statusWindow?.screen ?? NSScreen.main
        else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        var x = icon.midX - size.width / 2
        x = min(max(x, visible.minX + 12), visible.maxX - size.width - 12)
        let y = visible.maxY - size.height - 8
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowWillClose(_ notification: Notification) {
        if let model, !model.preview, let controller {
            UserDefaults.standard.set(true, forKey: Self.completedKey)
            if controller.loginItem.isEnabled != model.startAtLogin {
                controller.loginItem.setEnabled(model.startAtLogin)
            }
        }
        window = nil
        model = nil
    }
}

/// What the window holds that isn't the controller's: the Start at Login choice (applied when
/// the window closes, so it can be on by default without registering anything behind the
/// user's back) and the notification state.
@MainActor
@Observable
final class SetupModel {
    var startAtLogin: Bool
    var notifications: HostNotifications.Delivery?
    let preview: Bool

    init(startAtLogin: Bool, preview: Bool) {
        self.startAtLogin = startAtLogin
        self.preview = preview
    }
}

struct SetupView: View {
    @Bindable var controller: HostController
    @Bindable var model: SetupModel
    let onDone: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 18) {
                section("Allow access", footer: permissionFooter) {
                    StepRow(number: 1, title: "Screen Recording", subtitle: screenSubtitle, done: controller.hasScreenPermission) {
                        permissionAction(controller.hasScreenPermission) { controller.requestScreenPermission() }
                    }
                    StepRow(number: 2, title: "Accessibility", subtitle: inputSubtitle, done: controller.hasInputPermission) {
                        permissionAction(controller.hasInputPermission) { controller.requestInputPermission() }
                    }
                }
                section("Stay ready") {
                    StepRow(number: 3, title: "Start at login", subtitle: "Your devices reconnect after the Mac restarts.",
                            done: model.startAtLogin) {
                        Toggle("Start at login", isOn: $model.startAtLogin)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    StepRow(number: 4, title: "Notifications", subtitle: "A note when files arrive from your devices.",
                            done: model.notifications == .banners || model.notifications == .hiddenWhileSharing) {
                        notificationAction
                    }
                }
                section("Connect a device") {
                    StepRow(number: 5, title: tailscaleTitle, subtitle: tailscaleSubtitle, done: controller.tailscaleRunning) {
                        if !controller.tailscaleRunning {
                            Button(Self.tailscaleInstalled ? "Open Tailscale" : "Get Tailscale…") { controller.openTailscale() }
                                .buttonStyle(.glass)
                        }
                    }
                    StepRow(number: 6, title: "Pair a device",
                            subtitle: "In Casement on your iPad, iPhone, or Mac, add this Mac and enter the code it asks for.",
                            done: !controller.trustedClients.isEmpty) {
                        if controller.pairingCode == nil {
                            Button(controller.trustedClients.isEmpty ? "Show Code" : "Pair Another") { controller.generatePairingCode() }
                                .buttonStyle(.glass)
                                .help("Show Pairing Code: a one-time code to enter in Casement")
                        }
                    }
                    if let code = controller.pairingCode {
                        PairingCodePanel(code: code, address: controller.tailscaleSelfName, expiresAt: controller.pairingCodeExpiresAt,
                                         onNewCode: { controller.generatePairingCode() },
                                         onDone: { controller.cancelPairingCode() })
                            .padding(10)
                            .transition(.opacity)
                    }
                }
            }
            footer
                .padding(.top, 22)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .frame(width: 500)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: doneCount)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: controller.pairingCode)
        .task {
            controller.refreshTailscale()
            var tick = 0
            // Live while the window is open, so each step turns green as soon as macOS agrees.
            while !Task.isCancelled {
                controller.refreshPermissions()
                model.notifications = await HostNotifications.shared.delivery()
                if tick % 3 == 0 { controller.refreshTailscale() }
                tick += 1
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up Casement Host")
                    .font(.title.weight(.semibold))
                Text("Let your iPad, iPhone, or another Mac see and control this Mac over Tailscale.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                menuBarHint
                    .padding(.top, 4)
            }
        }
    }

    /// "Casement Host lives in the menu bar [icon]", with the live icon in a capsule.
    private var menuBarHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text("Find it in the menu bar:")
            Image(nsImage: StatusItemIcon.image(for: controller.status, activity: StatusItemIcon.Activity(controller.transfers)))
                .renderingMode(.template)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quinary, in: .capsule)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Casement Host lives in the menu bar")
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupedSection(title: title, content: content)
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .transition(.opacity)
            }
        }
    }

    private var screenSubtitle: String {
        controller.askedForScreenPermission && !controller.hasScreenPermission
            ? "Turn on Casement Host in the list. If macOS offers Quit & Reopen, choose it."
            : "To show this Mac's screen."
    }

    private var inputSubtitle: String {
        controller.askedForInputPermission && !controller.hasInputPermission
            ? "Turn on Casement Host in the list that opened."
            : "To click and type on this Mac."
    }

    private var permissionFooter: String? {
        controller.permissionStillMissingAfterAsking ? HostPermission.staleEntryHelp : nil
    }

    @ViewBuilder
    private func permissionAction(_ granted: Bool, request: @escaping () -> Void) -> some View {
        if granted {
            AllowedLabel(text: "Allowed")
        } else {
            Button("Allow…", action: request)
                .buttonStyle(.glass)
        }
    }

    @ViewBuilder
    private var notificationAction: some View {
        switch model.notifications {
        case .notAsked:
            Button("Allow…") {
                Task {
                    await HostNotifications.shared.requestPermission()
                    model.notifications = await HostNotifications.shared.delivery()
                }
            }
            .buttonStyle(.glass)
        case .off:
            Button("Turn On…") { HostNotifications.shared.openSystemSettings(forThisApp: true) }
                .buttonStyle(.glass)
        case .banners, .hiddenWhileSharing:
            AllowedLabel(text: "On")
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    private var tailscaleTitle: String {
        controller.tailscaleRunning ? "Tailscale is running" : "Tailscale"
    }

    private var tailscaleSubtitle: String {
        if controller.tailscaleRunning {
            return controller.tailscaleSelfName.isEmpty ? "Your devices reach this Mac through it." : controller.tailscaleSelfName
        }
        return Self.tailscaleInstalled
            ? "Open it and sign in here and on your device."
            : "Install it here and on your device, signed in to the same account."
    }

    private static var tailscaleInstalled: Bool {
        ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"].contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    // MARK: Footer

    private var doneCount: Int {
        [controller.hasScreenPermission, controller.hasInputPermission, model.startAtLogin,
         model.notifications == .banners || model.notifications == .hiddenWhileSharing,
         controller.tailscaleRunning, !controller.trustedClients.isEmpty].filter { $0 }.count
    }

    private var progressText: String {
        let missing = [controller.hasScreenPermission ? nil : "Screen Recording",
                       controller.hasInputPermission ? nil : "Accessibility"].compactMap { $0 }
        let needed = switch missing.count {
        case 0: ""
        case 1: " · \(missing[0]) is still needed"
        default: " · Screen Recording and Accessibility are needed"
        }
        return "\(doneCount) of 6 done" + needed
    }

    private var requiredDone: Bool { controller.hasScreenPermission && controller.hasInputPermission }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: Double(doneCount), total: 6)
                    .progressViewStyle(.linear)
                    .tint(.green)
                    .frame(width: 140)
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if requiredDone {
                Button("Done", action: onDone)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Later", action: onDone)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("Casement Host asks again next time it opens")
            }
        }
    }
}

/// One step: a numbered badge that becomes a green check, a title and one line under it, and
/// the step's control at the trailing edge.
private struct StepRow<Trailing: View>: View {
    let number: Int
    let title: String
    let subtitle: String
    let done: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            StepBadge(number: number, done: done)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(minHeight: 48)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title)\(done ? ", done" : "")")
    }
}

private struct StepBadge: View {
    let number: Int
    let done: Bool

    var body: some View {
        ZStack {
            if done {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: MenuMetrics.iconSize, height: MenuMetrics.iconSize)
                    .background(Color.green.gradient, in: .circle)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Text("\(number)")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: MenuMetrics.iconSize, height: MenuMetrics.iconSize)
                    .overlay(Circle().strokeBorder(.tertiary, lineWidth: 1.5))
                    .transition(.opacity)
            }
        }
        .accessibilityHidden(true)
    }
}

/// "✓ Allowed" in green at the end of a row.
private struct AllowedLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.green)
    }
}

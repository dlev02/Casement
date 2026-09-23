import SwiftUI
import VantageCore

struct SettingsScreen: View {
    var body: some View {
        List {
            Section {
                NavigationLink { AppearanceSettings() } label: { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                NavigationLink { ControlSettings() } label: { Label("Controls", systemImage: "keyboard") }
            }
            Section {
                NavigationLink { ConnectionSettings() } label: { Label("Connection", systemImage: "network") }
                NavigationLink { SecuritySettings() } label: { Label("Privacy & Security", systemImage: "lock") }
            }
            Section {
                NavigationLink { HelpScreen() } label: { Label("Help & FAQ", systemImage: "questionmark.circle") }
                NavigationLink { AboutScreen() } label: {
                    HStack {
                        Label("About Vantage", systemImage: "info.circle")
                        Spacer()
                        Text(AppInfo.versionString).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }
}

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—" }
    static var versionString: String { "\(version) (\(build))" }
    static let websiteURL = URL(string: "https://drewlevinson.me")!
    static let githubURL = URL(string: "https://github.com/dlev02")!
}

private struct AppearanceSettings: View {
    @AppStorage("vantage.appearance") private var appearance = AppAppearance.automatic
    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { choice in Text(choice.label).tag(choice) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Automatic follows the system setting. This changes Vantage's own screens and controls, not the Mac you're viewing.")
            }
        }
        .navigationTitle("Appearance")
    }
}

struct ControlSettings: View {
    @AppStorage("vantage.touchMode") private var touchMode = InputController.TouchMode.trackpad
    @AppStorage("vantage.trackpadSensitivity") private var sensitivity = 1.5
    @AppStorage("vantage.softwareKeyboardMode") private var keyboardMode = SoftwareKeyboardMode.unicode
    @AppStorage("vantage.toolbarDock") private var dock = ToolbarDock.bottomLeft
    @AppStorage("vantage.toolbarCollapsed") private var collapsed = false
    @AppStorage("vantage.pencilSqueeze") private var pencilSqueeze = PencilAction.collapseControls
    @AppStorage("vantage.pencilDoubleTap") private var pencilDoubleTap = PencilAction.rightClick
    @AppStorage("vantage.dictationEngine") private var dictationEngine = DictationEnginePreference.mac
    @AppStorage(DictationEnginePreference.macOffersParakeetKey) private var macOffersParakeet = false

    var body: some View {
        Form {
            #if os(visionOS)
            Section {
                LabeledContent("Click", value: "Look and pinch")
                LabeledContent("Drag", value: "Pinch and move")
                LabeledContent("Right-Click", value: "Pinch and hold")
            } header: {
                Text("Pointer")
            } footer: {
                Text("The Mac's pointer goes where you were looking when you pinch.")
            }
            #else
            Section {
                Picker("Touch", selection: $touchMode) {
                    ForEach(InputController.TouchMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Trackpad Sensitivity")
                        Spacer()
                        Text(sensitivity.formatted(.number.precision(.fractionLength(1))) + "×")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $sensitivity, in: 0.5...3, step: 0.1)
                        .accessibilityLabel("Trackpad sensitivity")
                }
            } header: {
                Text("Pointer")
            } footer: {
                Text("Trackpad moves the Mac's pointer like a laptop trackpad and taps to click. Direct Touch clicks exactly where you tap.")
            }
            #endif

            Section {
                Picker("On-Screen Keyboard", selection: $keyboardMode) {
                    ForEach(SoftwareKeyboardMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Unicode Text sends exactly what you type, including accents, emoji, and dictation. Keystrokes sends real key presses using the Mac's US layout, which some apps, games, terminals, and virtual machines require. Holding ⌘, ⌥, or ⌃ in the session controls always sends keystrokes, so ⌘C works from either mode. Hardware keyboards always send keystrokes.")
            }

            Section {
                Picker("Transcribe", selection: $dictationEngine) {
                    ForEach(DictationEnginePreference.choices(macOffersParakeet: macOffersParakeet, selection: dictationEngine)) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
            } header: {
                Text("Dictation")
            } footer: {
                Text(macOffersParakeet
                     ? "Hold the microphone button in the session controls to talk, or tap it to start and tap again to stop. MacWhisper transcribes with the model you chose in MacWhisper. Parakeet is Vantage Host's built-in model, turned on in Vantage Host Settings → Dictation. If the Mac doesn't have the one you pick, Vantage uses the other, then this iPad. On this iPad works offline and shows words as you speak."
                     : "Hold the microphone button in the session controls to talk, or tap it to start and tap again to stop. On the Mac, MacWhisper transcribes with the model you chose in MacWhisper; Vantage uses this iPad instead when the Mac doesn't have MacWhisper. On this iPad works offline and shows words as you speak. Macs without MacWhisper can turn on built-in transcription in Vantage Host Settings → Dictation.")
            }

            #if os(visionOS)
            Section {
                Toggle("Start Collapsed", isOn: $collapsed)
            } header: {
                Text("Session Controls")
            } footer: {
                Text("The controls sit below the session window.")
            }
            #else
            Section {
                Picker("Position", selection: $dock) {
                    ForEach(ToolbarDock.allCases) { position in
                        Label(position.label, systemImage: position.symbol).tag(position)
                    }
                }
                Toggle("Start Collapsed", isOn: $collapsed)
            } header: {
                Text("Session Controls")
            } footer: {
                Text("You can also drag the controls to any corner during a session.")
            }

            Section {
                Picker("Squeeze", selection: $pencilSqueeze) {
                    ForEach(PencilAction.allCases) { action in
                        Label(action.label, systemImage: action.symbol).tag(action)
                    }
                }
                Picker("Double-Tap", selection: $pencilDoubleTap) {
                    ForEach(PencilAction.allCases) { action in
                        Label(action.label, systemImage: action.symbol).tag(action)
                    }
                }
            } header: {
                Text("Apple Pencil")
            } footer: {
                Text("The Pencil always clicks exactly where it touches, and Pencil Pro moves the Mac's pointer while hovering. Squeeze needs Pencil Pro; double-tap works on Pencil (2nd generation) and later. Collapse Controls also brings hidden controls back.")
            }
            #endif
        }
        .navigationTitle("Controls")
    }
}

private struct ConnectionSettings: View {
    @Environment(TailscaleReachability.self) private var reachability
    @Environment(TailscaleAccount.self) private var account
    @AppStorage("vantage.availabilityChecks") private var availabilityChecks = true

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    TailscaleAccountScreen()
                } label: {
                    HStack {
                        Text("Tailscale Account")
                        Spacer()
                        Text(account.isSignedIn ? "Signed In" : "Not Signed In").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Sign in with a read-only key to add Macs straight from your tailnet's device list.")
            }
            Section {
                HStack {
                    Text("Tailscale")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(reachability.isActive ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(reachability.isActive ? "Connected" : "Not Connected")
                    }
                    .foregroundStyle(.secondary)
                }
                if let address = reachability.address {
                    HStack {
                        Text("This Device")
                        Spacer()
                        Text(address).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Button("Open Tailscale") { TailscaleReachability.openTailscaleApp() }
                Link("Manage Tailscale Devices", destination: URL(string: "https://login.tailscale.com/admin/machines")!)
            } header: {
                Text("Network")
            } footer: {
                Text("Vantage only connects to Macs on your tailnet. Traffic never leaves Tailscale's encrypted tunnel.")
            }

            Section {
                Toggle("Check Availability", isOn: $availabilityChecks)
            } header: {
                Text("Device List")
            } footer: {
                Text("Shows whether each saved Mac is reachable and ready while the list is open. Nothing from the Mac's screen is captured for this.")
            }
        }
        .navigationTitle("Connection")
    }
}

struct SecuritySettings: View {
    @AppStorage("vantage.requireBiometrics") private var requireBiometrics = false
    @Environment(DeviceStore.self) private var store

    var body: some View {
        let cloud = store.cloud
        Form {
            Section {
                Toggle("Require Face ID / Touch ID", isOn: $requireBiometrics)
            } footer: {
                Text("Unlock Vantage with biometrics or your device passcode after leaving the app. An open session resumes after you unlock.")
            }

            Section {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { cloud.isEnabled },
                    set: { store.setCloudSync($0) }
                ))
                if cloud.isEnabled, let explanation = cloud.deviceListAvailability.explanation {
                    Label(explanation, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Keeps your saved Macs, their passwords, and your Tailscale key the same on every iPhone, iPad, and Vision Pro signed into your iCloud account, so you set Vantage up once. Secrets travel through iCloud Keychain, end-to-end encrypted; Apple can't read them and neither can anyone else.")
            }
        }
        .navigationTitle("Privacy & Security")
    }
}

struct AboutScreen: View {

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    AppIconTile()
                        .padding(.bottom, 6)
                    Text("Vantage")
                        .font(.title.weight(.bold))
                    Text("Your Mac, wherever you are.")
                        .foregroundStyle(.secondary)
                    Text("Version \(AppInfo.versionString)")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                    Text("Designed and built by Drew Levinson")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                LinkRow(title: "Website", symbol: "globe", destination: AppInfo.websiteURL)
                LinkRow(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", destination: AppInfo.githubURL)
            }

            Section {
                NavigationLink { HelpScreen() } label: {
                    Label("Help & FAQ", systemImage: "questionmark.circle")
                }
            } footer: {
                Text("Vantage streams your Mac with ScreenCaptureKit and hardware video encoding, across your own Tailscale network only. There is no account and no relay server.")
            }
        }
        .navigationTitle("About")
    }
}

/// Answers the questions that come up when setting Vantage up or living with its limits.
/// Kept as plain text so it reads the same on iPhone, iPad, and Vision Pro.
struct HelpScreen: View {
    var body: some View {
        List {
            Section("Getting Connected") {
                FAQRow("What do I need on the Mac?") {
                    "Install Vantage Host, then grant it Screen Recording and Accessibility in System Settings → Privacy & Security. The host's menu-bar icon has a button for each. Tailscale has to be running on the Mac and on this device."
                }
                FAQRow("Why did it ask me to pair?") {
                    "Every device gets its own signing key. The first time you connect, the Mac shows a six-digit code to prove it's really you; after that the Mac remembers this device and connects straight away. A code works for ten minutes and stops working after five wrong tries, so if it's rejected, show a fresh one on the Mac."
                }
                FAQRow("Can I connect from Siri, Shortcuts, or a widget?") {
                    "Yes. Say \"Connect to Studio Mac in Vantage\" to Siri, search the Mac's name in Spotlight, add the Connect to Mac action to a Shortcut or the Action button, put the Connect widget on your Home Screen, or add the Connect to Mac control to Control Center (it opens the Mac you used last). If Vantage is locked with Face ID, the connection waits until you unlock."
                }
                FAQRow("Does Vantage work away from home?") {
                    "Yes. Vantage connects over Tailscale, so it works from any network — including cellular — as long as both the Mac and this device are on your tailnet."
                }
                FAQRow("Why does Vantage want a Tailscale key?") {
                    "Only to read your device list, so it can offer your Macs by name instead of making you type IP addresses. The key is read-only, lives in this device's Keychain, and is sent only to api.tailscale.com. Adding Macs by name or IP by hand works without one."
                }
            }

            Section("Controlling the Mac") {
                FAQRow("Trackpad or Direct Touch?") {
                    "Trackpad moves the Mac's pointer relative to your finger, like a laptop trackpad — better for precision on a big desktop. Direct Touch puts the pointer exactly where you tap. Switch in the session controls or in Settings → Controls."
                }
                FAQRow("How does it work on Apple Vision Pro?") {
                    "Each Mac opens in its own window that keeps the Mac's shape as you resize it, with the controls in a bar underneath. Look at something and pinch to click, pinch and drag to drag, and pinch and hold to right-click. A paired keyboard or trackpad works as it does on iPad."
                }
                FAQRow("How do I right-click or middle-click?") {
                    "Two-finger tap is a right-click and three-finger tap is a middle-click. With a mouse or trackpad attached, the real buttons work, including dragging with the right or middle button held."
                }
                FAQRow("Unicode Text or Keystrokes for the keyboard?") {
                    "Unicode Text sends exactly the characters you type, including emoji, accents, and dictation. Keystrokes sends real key presses using the Mac's US layout, which terminals, games, and virtual machines need. Hardware keyboards always send keystrokes."
                }
                FAQRow("Why can't I type into a password box?") {
                    "macOS turns on Secure Event Input whenever a password field has focus, at the lock screen, or when Terminal's Secure Keyboard Entry is on. While it's on, macOS drops keystrokes from apps, and Vantage shows a banner. Your saved password still gets through: tap the key button and Vantage types it using the Mac's own Screen Sharing, which macOS allows. Anything else you type waits until the field loses focus."
                }
                FAQRow("How does the key button type into password fields?") {
                    "Save your Mac's account name and password in the Mac's settings in Vantage. When macOS is blocking ordinary typing, the key button signs in to the Mac's built-in Screen Sharing over Tailscale, types the password and Return, then disconnects — the same way Screens does it. Turn on Screen Sharing in System Settings → General → Sharing and allow your account. The Mac may briefly show that someone is sharing its screen."
                }
                FAQRow("Can I dictate to the Mac?") {
                    "Yes. Tap the microphone in the session controls, speak, then Send (or Send + Return). Vantage can transcribe on the Mac with MacWhisper (using the model you've picked there) or with Vantage Host's built-in Parakeet model, which you turn on in Vantage Host Settings → Dictation; otherwise this device transcribes on its own with Apple's speech recognition. Choose in Settings → Controls. Audio is only used for that one transcript and isn't kept."
                }
            }

            Section("Video & Displays") {
                FAQRow("HEVC or H.264?") {
                    "HEVC looks better at the same bandwidth and is the default. Choose H.264 only if something in the path can't decode HEVC."
                }
                FAQRow("What does Virtual Display do?") {
                    "It asks the Mac for a BetterDisplay virtual screen shaped like this device, so the Mac's windows fit your screen instead of being letterboxed. With it off, Vantage streams the Mac's main display, which connects fastest."
                }
                FAQRow("Do I need BetterDisplay or MacWhisper?") {
                    "No. Without BetterDisplay, Vantage streams the Mac's main display. Without MacWhisper, dictation is transcribed on this device, or on the Mac by Vantage Host's optional built-in Parakeet model. Both are optional extras that Vantage uses when they're there."
                }
                FAQRow("The picture went soft for a moment.") {
                    "Vantage drops detail before it drops smoothness when the network narrows, then sharpens again within a second or two. Still images sharpen fastest because nothing is moving."
                }
            }

            Section("Restarts & Locked Macs") {
                FAQRow("What happens if my Mac restarts while I'm away?") {
                    "Vantage Host starts again once someone logs in, and this device reconnects on its own. With FileVault on, a restart stops at the FileVault unlock screen before macOS or Tailscale start, so nothing remote can reach the Mac until it's unlocked. To recover from afar, turn on Remote Login and keep a Tailscale subnet router on your home network (macOS 26 and later can unlock FileVault over SSH), or turn on automatic login on a Mac that never leaves home."
                }
                FAQRow("Can Vantage stop an accidental restart?") {
                    "Yes. While a device is connected, Vantage Host asks before the Mac restarts, shuts down, or logs out, including restarts started by Software Update, and you can cancel. Turn this off in Vantage Host's Settings → Reboot. It can't catch a crash, a power cut, or a restart forced from Terminal."
                }
                FAQRow("Can I unlock a locked Mac?") {
                    "If the Mac is asleep at its lock screen, tap the key button: Vantage types your saved password through Screen Sharing. That needs the account name and password saved for this Mac and Screen Sharing turned on."
                }
                FAQRow("How do I log in after a restart?") {
                    "At the login window the Mac's own Tailscale isn't running yet, so Vantage can't connect. Add the Mac's home network address (like 192.168.1.20) in its settings, keep a Tailscale subnet router at home (an always-on PC or Apple TV advertising your home network), then long-press the Mac in the list and choose Log In with Screen Sharing. Vantage types your password there, the Mac logs in, and a minute later you can connect as usual."
                }
                FAQRow("What does Restart Safely do?") {
                    "It's in Vantage Host's menu and settings, and it's offered when you restart while connected. You enter your Mac password once, FileVault unlocks by itself for that one restart, and the Mac comes back at the login window instead of the FileVault screen. From there, Log In with Screen Sharing gets you back in."
                }
            }

            Section("Privacy") {
                FAQRow("Does my screen go through a server?") {
                    "No. There is no Vantage account and no relay. Video and input travel directly between your own devices inside Tailscale's encrypted tunnel."
                }
                FAQRow("Can someone else connect to my Mac?") {
                    "Only a device on your tailnet that you've paired, using a key the Mac has already trusted. Vantage Host refuses connections from any address outside Tailscale's range."
                }
                FAQRow("What does Vantage store on this device?") {
                    "Your saved Macs and preferences, plus keys in the Keychain: this device's identity and, if you added them, your Tailscale key and Mac account name and password, readable only while this device is unlocked. Removing a device forgets its saved secrets too."
                }
                FAQRow("What does iCloud sync share?") {
                    "Your saved Macs, their passwords, and your Tailscale key — the things you'd otherwise set up again on each device. Passwords and keys go through iCloud Keychain, which is end-to-end encrypted. Each device keeps its own identity key, so a new device still pairs with the Mac once. Turn it on in Settings → Privacy & Security."
                }
            }
        }
        .navigationTitle("Help & FAQ")
    }
}

/// A question that expands to its answer. Collapsed by default so the list stays scannable.
private struct FAQRow: View {
    let question: String
    let answer: String
    @State private var isExpanded = false

    init(_ question: String, answer: () -> String) {
        self.question = question
        self.answer = answer()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(answer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        } label: {
            Text(question).font(.body)
        }
    }
}

private struct AppIconTile: View {
    var body: some View {
        Group {
            if let icon = Bundle.main.primaryIconName, let image = UIImage(named: icon) {
                Image(uiImage: image).resizable()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.18, green: 0.45, blue: 1.0), Color(red: 0.05, green: 0.2, blue: 0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "macbook.and.ipad")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .accessibilityHidden(true)
    }
}

private struct LinkRow: View {
    let title: String
    let symbol: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            HStack {
                Label(title, systemImage: symbol)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private extension Bundle {
    /// Name of the primary app icon set, if the bundle declares one.
    var primaryIconName: String? {
        guard let icons = infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String] else { return nil }
        return files.last
    }
}

#if canImport(UIKit)
import UIKit
#endif

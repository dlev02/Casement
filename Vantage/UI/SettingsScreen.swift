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

extension View {
    /// Mac forms read best as grouped boxes, like System Settings; iOS forms already are.
    @ViewBuilder func macGroupedForm() -> some View {
        #if os(macOS)
        formStyle(.grouped)
        #else
        self
        #endif
    }
}

/// Settings → Controls → Keyboard on the Mac, read by the session's keyboard capture.
enum MacKeyboardSettings {
    /// On (the default): while a session window is key, shortcuts go to the remote Mac, except
    /// ⌃⌥⌘ chords, which always stay with Vantage.
    static let captureShortcutsKey = "vantage.mac.captureShortcuts"
    /// Sends ⌃ for ⌘ and ⌘ for ⌃.
    static let swapCommandControlKey = "vantage.mac.swapCommandControl"
}

struct AppearanceSettings: View {
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
    @AppStorage(Haptic.settingKey) private var haptics = true
    @AppStorage(MacKeyboardSettings.captureShortcutsKey) private var captureShortcuts = true
    @AppStorage(MacKeyboardSettings.swapCommandControlKey) private var swapCommandControl = false

    var body: some View {
        Form {
            #if os(macOS)
            macKeyboardSection
            dictationSection
            Section {
                customizeLink
                Picker("Position", selection: $dock) {
                    ForEach(ToolbarDock.allCases) { position in
                        Label(position.label, systemImage: position.symbol).tag(position)
                    }
                }
                Toggle("Start Collapsed", isOn: $collapsed)
            } header: {
                Text("Session Controls")
            } footer: {
                Text("Choose which controls float over a session and in what order. A Mac or PC can have its own set, from its settings or the Session menu. You can also drag the controls to any corner of the window.")
            }
            #else
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

            dictationSection

            #if os(visionOS)
            Section {
                customizeLink
                Toggle("Start Collapsed", isOn: $collapsed)
            } header: {
                Text("Session Controls")
            } footer: {
                Text("The controls sit below the session window. Choose which ones show, and give a Mac its own set from its settings.")
            }
            #else
            Section {
                customizeLink
                Picker("Position", selection: $dock) {
                    ForEach(ToolbarDock.allCases) { position in
                        Label(position.label, systemImage: position.symbol).tag(position)
                    }
                }
                Toggle("Start Collapsed", isOn: $collapsed)
            } header: {
                Text("Session Controls")
            } footer: {
                Text("Choose which controls show and in what order. A Mac or PC can have its own set, from its settings or the session menu. You can also drag the controls to any corner during a session.")
            }

            if Haptics.isSupported {
                Section {
                    Toggle("Haptics", isOn: $haptics)
                        .accessibilityIdentifier("settings.haptics")
                } footer: {
                    Text("Light taps confirm held keys, dictation, moving the controls, and dropped connections.")
                }
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
            #endif
        }
        .navigationTitle("Controls")
    }

    private var dictationSection: some View {
        Section {
            Picker("Transcribe", selection: $dictationEngine) {
                ForEach(DictationEnginePreference.choices(macOffersParakeet: macOffersParakeet, selection: dictationEngine)) { engine in
                    Text(engine.label).tag(engine)
                }
            }
        } header: {
            Text("Dictation")
        } footer: {
            #if os(macOS)
            Text(macOffersParakeet
                 ? "Choose Dictate in the Session menu (⌃⌥⌘D), or hold the microphone button in the session controls to talk. MacWhisper transcribes with the model you chose in MacWhisper. Parakeet is Vantage Host's built-in model, turned on in Vantage Host Settings → Dictation. If the other Mac doesn't have the one you pick, Vantage uses the other, then this Mac, which works offline and shows words as you speak."
                 : "Choose Dictate in the Session menu (⌃⌥⌘D), or hold the microphone button in the session controls to talk. On the other Mac, MacWhisper transcribes with the model you chose in MacWhisper; Vantage uses this Mac instead when that one doesn't have MacWhisper. This Mac works offline and shows words as you speak. Macs without MacWhisper can turn on built-in transcription in Vantage Host Settings → Dictation.")
            #else
            Text(macOffersParakeet
                 ? "Hold the microphone button in the session controls to talk, or tap it to start and tap again to stop. MacWhisper transcribes with the model you chose in MacWhisper. Parakeet is Vantage Host's built-in model, turned on in Vantage Host Settings → Dictation. If the Mac doesn't have the one you pick, Vantage uses the other, then this iPad. On this iPad works offline and shows words as you speak."
                 : "Hold the microphone button in the session controls to talk, or tap it to start and tap again to stop. On the Mac, MacWhisper transcribes with the model you chose in MacWhisper; Vantage uses this iPad instead when the Mac doesn't have MacWhisper. On this iPad works offline and shows words as you speak. Macs without MacWhisper can turn on built-in transcription in Vantage Host Settings → Dictation.")
            #endif
        }
    }

    #if os(macOS)
    private var macKeyboardSection: some View {
        Section {
            Toggle("Send keyboard shortcuts to the Mac", isOn: $captureShortcuts)
                .accessibilityIdentifier("settings.captureShortcuts")
            Toggle("Swap ⌘ and ⌃", isOn: $swapCommandControl)
                .accessibilityIdentifier("settings.swapCommandControl")
        } header: {
            Text("Keyboard")
        } footer: {
            Text("While a session window is in front, shortcuts like ⌘Q, ⌘W, and ⌘C go to the Mac you're controlling. To reach Vantage instead, hold ⌃⌥⌘ with the key: ⌃⌥⌘W disconnects, and ⌃⌥⌘K turns this setting on or off. macOS keeps ⌘Tab and ⌘Space for itself; send them from the Session menu. Swap ⌘ and ⌃ presses Control when you press Command, and Command when you press Control, which suits a PC.")
        }
    }
    #endif

    private var customizeLink: some View {
        NavigationLink { ControlStripEditor() } label: {
            Text("Customize Controls")
        }
    }
}

struct ConnectionSettings: View {
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
                Text("Vantage only connects to Macs and PCs on your tailnet. Traffic never leaves Tailscale's encrypted tunnel.")
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
            #if os(macOS)
            Section {
                Toggle("Require Touch ID", isOn: $requireBiometrics)
                    .accessibilityIdentifier("settings.requireBiometrics")
            } footer: {
                Text("Vantage locks when this Mac's screen locks or it goes to sleep, and asks for Touch ID or your password when you're back. Sessions stay connected behind the lock.")
            }
            // iCloud sync stays off on the Mac until the app is signed for iCloud there: without
            // that, its Keychain can't hold synced secrets.
            #else
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
            #endif
        }
        .navigationTitle("Privacy & Security")
    }
}

struct AboutScreen: View {

    var body: some View {
        SettingsContainer {
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

/// A List on iOS and visionOS; a grouped Form on the Mac, where a List's section footers stay
/// on one line and rows lose their boxes.
private struct SettingsContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(macOS)
        Form { content }.formStyle(.grouped)
        #else
        List { content }
        #endif
    }
}

/// Answers the questions that come up when setting Vantage up or living with its limits.
/// Kept as plain text so it reads the same on iPhone, iPad, and Vision Pro. Searching matches
/// questions and answers and opens every match, since the words you type are often in the answer.
struct HelpScreen: View {
    @State private var query = ""

    var body: some View {
        List {
            ForEach(results) { section in
                Section(section.title) {
                    ForEach(section.entries) { entry in
                        // A new identity when search starts or ends, so rows open for results
                        // and fold back up afterwards.
                        FAQRow(entry, expanded: isSearching).id("\(entry.id)|\(isSearching)")
                    }
                }
            }
        }
        .overlay {
            if isSearching && results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Search Help")
        .navigationTitle("Help & FAQ")
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Every word of the query must appear somewhere in the question or answer, ignoring case
    /// and accents, so "password restart" finds the restart answers that mention passwords.
    private var results: [FAQSection] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Self.sections }
        return Self.sections.compactMap { section in
            let matches = section.entries.filter { entry in
                let text = entry.question + " " + entry.answer
                return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            return matches.isEmpty ? nil : FAQSection(section.title, matches)
        }
    }

    static let sections: [FAQSection] = [
        FAQSection("Getting Connected", [
            FAQEntry("What do I need on the Mac?",
                     "Install Vantage Host, then grant it Screen Recording and Accessibility in System Settings → Privacy & Security. The host's menu-bar icon has a button for each. Tailscale has to be running on the Mac and on this device."),
            FAQEntry("Can I control a Windows PC?",
                     "Yes, with Vantage Host for Windows running on the PC and Tailscale on both devices. A PC shows up in Add from Tailscale next to your Macs and pairs the same way. In a session, the controls offer Start, Search, Task View and Task Manager, with Ctrl, Alt and Win keys. Mac Audio, Type Password and the virtual display are Mac-only."),
            FAQEntry("Why did it ask me to pair?",
                     "Every device gets its own signing key. The first time you connect, the Mac shows a six-digit code to prove it's really you; after that the Mac remembers this device and connects straight away. A code works for ten minutes and stops working after five wrong tries, so if it's rejected, show a fresh one on the Mac."),
            siriEntry,
            FAQEntry("Does Vantage work away from home?",
                     "Yes. Vantage connects over Tailscale, so it works from any network — including cellular — as long as both the Mac and this device are on your tailnet."),
            FAQEntry("Why does Vantage want a Tailscale key?",
                     "Only to read your device list, so it can offer your Macs by name instead of making you type IP addresses. The key is read-only, lives in this device's Keychain, and is sent only to api.tailscale.com. Adding Macs by name or IP by hand works without one."),
        ]),
        FAQSection("Controlling the Mac", controllingTheMac),
        FAQSection("Video & Displays", [
            FAQEntry("HEVC or H.264?",
                     "HEVC looks better at the same bandwidth and is the default. Choose H.264 only if something in the path can't decode HEVC."),
            FAQEntry("What does Virtual Display do?",
                     "It asks the Mac for a BetterDisplay virtual screen shaped like this device, so the Mac's windows fit your screen instead of being letterboxed. With it off, Vantage streams the Mac's main display, which connects fastest."),
            FAQEntry("Do I need BetterDisplay or MacWhisper?",
                     "No. Without BetterDisplay, Vantage streams the Mac's main display. Without MacWhisper, dictation is transcribed on this device, or on the Mac by Vantage Host's optional built-in Parakeet model. Both are optional extras that Vantage uses when they're there."),
            FAQEntry("The picture went soft for a moment.",
                     "Vantage drops detail before it drops smoothness when the network narrows, then sharpens again within a second or two. Still images sharpen fastest because nothing is moving."),
        ]),
        FAQSection("Restarts & Locked Macs", [
            FAQEntry("What happens if my Mac restarts while I'm away?",
                     "Vantage Host starts again once someone logs in, and this device reconnects on its own. With FileVault on, a restart stops at the FileVault unlock screen before macOS or Tailscale start, so nothing remote can reach the Mac until it's unlocked. To recover from afar, turn on Remote Login and keep a Tailscale subnet router on your home network (macOS 26 and later can unlock FileVault over SSH), or turn on automatic login on a Mac that never leaves home."),
            FAQEntry("Can Vantage stop an accidental restart?",
                     "Yes. While a device is connected, Vantage Host asks before the Mac restarts, shuts down, or logs out, including restarts started by Software Update, and you can cancel. Turn this off in Vantage Host's Settings → Reboot. It can't catch a crash, a power cut, or a restart forced from Terminal."),
            FAQEntry("Can I unlock a locked Mac?",
                     "If the Mac is asleep at its lock screen, tap the key button: Vantage types your saved password through Screen Sharing. That needs the account name and password saved for this Mac and Screen Sharing turned on."),
            FAQEntry("How do I log in after a restart?",
                     "At the login window the Mac's own Tailscale isn't running yet, so Vantage can't connect. Add the Mac's home network address (like 192.168.1.20) in its settings, keep a Tailscale subnet router at home (an always-on PC or Apple TV advertising your home network), then \(logInGesture) and choose Log In with Screen Sharing. Vantage types your password there, the Mac logs in, and a minute later you can connect as usual."),
            FAQEntry("What does Restart Safely do?",
                     "It's in Vantage Host's menu and settings, and it's offered when you restart while connected. You enter your Mac password once, FileVault unlocks by itself for that one restart, and the Mac comes back at the login window instead of the FileVault screen. From there, Log In with Screen Sharing gets you back in."),
        ]),
        FAQSection("Privacy", [
            FAQEntry("Does my screen go through a server?",
                     "No. There is no Vantage account and no relay. Video and input travel directly between your own devices inside Tailscale's encrypted tunnel."),
            FAQEntry("Can someone else connect to my Mac?",
                     "Only a device on your tailnet that you've paired, using a key the Mac has already trusted. Vantage Host refuses connections from any address outside Tailscale's range."),
            FAQEntry("What does Vantage store on this device?",
                     "Your saved Macs and preferences, plus keys in the Keychain: this device's identity and, if you added them, your Tailscale key and Mac account name and password, readable only while this device is unlocked. Removing a device forgets its saved secrets too."),
            FAQEntry("What does iCloud sync share?",
                     "Your saved Macs, their passwords, and your Tailscale key — the things you'd otherwise set up again on each device. Passwords and keys go through iCloud Keychain, which is end-to-end encrypted. Each device keeps its own identity key, so a new device still pairs with the Mac once. Turn it on in Settings → Privacy & Security."),
        ]),
    ]
}

extension HelpScreen {
    #if os(macOS)
    private static let siriEntry = FAQEntry("Can I connect from Siri, Shortcuts, or Spotlight?",
                                           "Yes. Say \"Connect to Studio Mac in Vantage\" to Siri, search the Mac's name in Spotlight, or add the Connect to Mac action to a Shortcut. The Mac opens in a window of its own. If Vantage is locked with Touch ID, the connection waits until you unlock.")
    private static let logInGesture = "select the Mac in the sidebar"
    private static let controllingTheMac: [FAQEntry] = [
        FAQEntry("Which shortcuts go to the Mac?",
                 "While a session window is in front, almost all of them: ⌘Q, ⌘W, ⌘C and the rest act on the Mac you're controlling, not on Vantage. Hold ⌃⌥⌘ with a key to reach Vantage instead, for example ⌃⌥⌘W to disconnect. Turn this off in Settings → Controls to keep the usual shortcuts for Vantage."),
        FAQEntry("How do I send ⌘Tab or ⌘Space?",
                 "macOS keeps those for itself, so Vantage can't pass them along from the keyboard. Choose them from the Session menu's Mac submenu, or put Spotlight in the session controls."),
        FAQEntry("How do I right-click or scroll?",
                 "The same way as on this Mac: your mouse and trackpad buttons, gestures, and scrolling go straight through, and the other Mac's pointer follows yours inside the window."),
        FAQEntry("Why can't I type into a password box?",
                 "macOS turns on Secure Event Input whenever a password field has focus, at the lock screen, or when Terminal's Secure Keyboard Entry is on. While it's on, macOS drops keystrokes from apps, and Vantage shows a banner. Your saved password still gets through: choose Type Password in the Session menu (⌃⌥⌘P) and Vantage types it using the Mac's own Screen Sharing, which macOS allows. Anything else you type waits until the field loses focus."),
        FAQEntry("How does Type Password get into password fields?",
                 "Save the Mac's account name and password in its settings in Vantage. When macOS is blocking ordinary typing, Vantage signs in to the Mac's built-in Screen Sharing over Tailscale, types the password and Return, then disconnects — the same way Screens does it. Turn on Screen Sharing in System Settings → General → Sharing and allow your account. The Mac may briefly show that someone is sharing its screen."),
        FAQEntry("Can I change the buttons in the session controls?",
                 "Yes. Go to Settings → Controls → Customize Controls to choose which buttons show and drag them into the order you want. To give one Mac its own set, choose Customize Controls… in the Session menu, or the Controls row in that Mac's settings. Every control is also in the Session menu."),
        FAQEntry("Can I dictate to the Mac?",
                 "Yes. Choose Dictate in the Session menu (⌃⌥⌘D) or use the microphone in the session controls, speak, then Send (or Send + Return). Vantage can transcribe on the other Mac with MacWhisper (using the model you've picked there) or with Vantage Host's built-in Parakeet model, which you turn on in Vantage Host Settings → Dictation; otherwise this Mac transcribes on its own with Apple's speech recognition. Choose in Settings → Controls. Audio is only used for that one transcript and isn't kept."),
    ]
    #else
    private static let siriEntry = FAQEntry("Can I connect from Siri, Shortcuts, or a widget?",
                                           "Yes. Say \"Connect to Studio Mac in Vantage\" to Siri, search the Mac's name in Spotlight, add the Connect to Mac action to a Shortcut or the Action button, put the Connect widget on your Home Screen, or add the Connect to Mac control to Control Center (it opens the Mac you used last). If Vantage is locked with Face ID, the connection waits until you unlock.")
    private static let logInGesture = "long-press the Mac in the list"
    private static let controllingTheMac: [FAQEntry] = [
                FAQEntry("Trackpad or Direct Touch?",
                         "Trackpad moves the Mac's pointer relative to your finger, like a laptop trackpad — better for precision on a big desktop. Direct Touch puts the pointer exactly where you tap. Switch in the session controls or in Settings → Controls."),
                FAQEntry("How does it work on Apple Vision Pro?",
                         "Each Mac opens in its own window that keeps the Mac's shape as you resize it, with the controls in a bar underneath. Look at something and pinch to click, pinch and drag to drag, and pinch and hold to right-click. A paired keyboard or trackpad works as it does on iPad."),
                FAQEntry("How do I right-click or middle-click?",
                         "Two-finger tap is a right-click and three-finger tap is a middle-click. With a mouse or trackpad attached, the real buttons work, including dragging with the right or middle button held."),
                FAQEntry("Unicode Text or Keystrokes for the keyboard?",
                         "Unicode Text sends exactly the characters you type, including emoji, accents, and dictation. Keystrokes sends real key presses using the Mac's US layout, which terminals, games, and virtual machines need. Hardware keyboards always send keystrokes."),
                FAQEntry("Why can't I type into a password box?",
                         "macOS turns on Secure Event Input whenever a password field has focus, at the lock screen, or when Terminal's Secure Keyboard Entry is on. While it's on, macOS drops keystrokes from apps, and Vantage shows a banner. Your saved password still gets through: tap the key button and Vantage types it using the Mac's own Screen Sharing, which macOS allows. Anything else you type waits until the field loses focus."),
                FAQEntry("How does the key button type into password fields?",
                         "Save your Mac's account name and password in the Mac's settings in Vantage. When macOS is blocking ordinary typing, the key button signs in to the Mac's built-in Screen Sharing over Tailscale, types the password and Return, then disconnects — the same way Screens does it. Turn on Screen Sharing in System Settings → General → Sharing and allow your account. The Mac may briefly show that someone is sharing its screen."),
                FAQEntry("Can I change the buttons in the session controls?",
                         "Yes. Go to Settings → Controls → Customize Controls to choose which buttons show and drag them into the order you want. To give one Mac its own set, open Customize Controls… from the session menu, or the Controls row in that Mac's settings. The red button ends the session; reconnecting is one tap."),
                FAQEntry("Can I dictate to the Mac?",
                         "Yes. Tap the microphone in the session controls, speak, then Send (or Send + Return). Vantage can transcribe on the Mac with MacWhisper (using the model you've picked there) or with Vantage Host's built-in Parakeet model, which you turn on in Vantage Host Settings → Dictation; otherwise this device transcribes on its own with Apple's speech recognition. Choose in Settings → Controls. Audio is only used for that one transcript and isn't kept."),
    ]
    #endif
}

struct FAQSection: Identifiable {
    let title: String
    let entries: [FAQEntry]
    var id: String { title }
    init(_ title: String, _ entries: [FAQEntry]) {
        self.title = title
        self.entries = entries
    }
}

struct FAQEntry: Identifiable {
    let question: String
    let answer: String
    var id: String { question }
    init(_ question: String, _ answer: String) {
        self.question = question
        self.answer = answer
    }
}

/// A question that expands to its answer. Collapsed by default so the list stays scannable.
private struct FAQRow: View {
    let entry: FAQEntry
    @State private var isExpanded: Bool

    init(_ entry: FAQEntry, expanded: Bool) {
        self.entry = entry
        _isExpanded = State(initialValue: expanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(entry.answer)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        } label: {
            Text(entry.question).font(.body)
        }
    }
}

private struct AppIconTile: View {
    var body: some View {
        Group {
            #if os(macOS)
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable()
            #else
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
            #endif
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

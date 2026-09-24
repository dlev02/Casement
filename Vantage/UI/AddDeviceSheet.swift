import SwiftUI
import VantageCore

/// Adds or edits a device by MagicDNS name or Tailscale IP. No credentials required for v1.
struct AddDeviceSheet: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var existing: SavedDevice?
    @State private var name = ""
    @State private var host = ""
    @State private var port = String(VantageProtocol.defaultPort)
    @State private var codec: VideoCodec = .hevc
    @State private var naturalScroll = true
    @State private var useVirtualDisplay = false
    @State private var password = ""
    @State private var username = ""
    @State private var homeAddress = ""
    /// Kept here and saved with the rest, so Cancel also discards a controls change.
    @State private var controlStrip: ControlStripLayout?
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Device") {
                    TextField("Name", text: $name)
                    TextField("MagicDNS name or Tailscale IP", text: $host)
                        #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        #endif
                    TextField("Port", text: $port)
                        #if canImport(UIKit)
                        .keyboardType(.numberPad)
                        #endif
                    if let validationError {
                        Text(validationError).foregroundStyle(.red)
                    }
                }
                Section {
                    Picker("Codec", selection: $codec) {
                        Text("HEVC").tag(VideoCodec.hevc)
                        Text("H.264").tag(VideoCodec.h264)
                    }
                    #if !os(macOS) // a Mac's own mouse and trackpad already scroll the way it's set up
                    Toggle("Natural Scrolling", isOn: $naturalScroll)
                    #endif
                    NavigationLink {
                        ControlStripEditor(macName: name.isEmpty ? "This Mac" : name, layout: $controlStrip)
                    } label: {
                        LabeledContent("Controls", value: controlStrip == nil ? "Default" : "Custom")
                    }
                } header: {
                    Text("Preferences")
                } footer: {
                    Text(codec == .hevc
                         ? "HEVC looks better at the same bandwidth. Switch to H.264 if this Mac's video ever fails to decode."
                         : "H.264 decodes everywhere. HEVC looks better at the same bandwidth.")
                }

                Section {
                    Toggle("Virtual Display", isOn: $useVirtualDisplay)
                } footer: {
                    Text("Asks the Mac for a BetterDisplay virtual screen that matches this device. Off streams the Mac's main display, which connects fastest. Vantage connects only over your Tailscale network.")
                }

                Section {
                    TextField("Account Name", text: $username)
                        .textContentType(.username)
                        #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    SecureField("Mac Password", text: $password)
                        .textContentType(.password)
                        #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Home Network Address (optional)", text: $homeAddress)
                        #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numbersAndPunctuation)
                        #endif
                        .autocorrectionDisabled()
                } header: {
                    Text("Mac Sign-In")
                } footer: {
                    Text("Optional, kept in this device's Keychain. The key button types the password and Return. Where macOS blocks typing (password fields, the lock screen), Vantage types it through the Mac's Screen Sharing instead, so turn that on for this account. The home network address, like 192.168.1.20, lets Log In reach the Mac at its login window after a restart, through a Tailscale subnet router.")
                }
            }
            .navigationTitle(existing == nil ? "Add Device" : "Edit Device")
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.isEmpty || host.isEmpty)
                }
            }
            .onAppear(perform: populate)
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 640)
        #endif
    }

    private func populate() {
        guard let existing else { return }
        name = existing.name
        host = existing.host
        port = String(existing.port)
        codec = existing.preferredCodec ?? .hevc
        naturalScroll = existing.naturalScroll
        useVirtualDisplay = existing.useVirtualDisplay == true
        password = DeviceSecrets.password(for: existing) ?? ""
        username = DeviceSecrets.username(for: existing) ?? ""
        homeAddress = existing.homeAddress ?? ""
        controlStrip = existing.controlStrip
    }

    private func save() {
        let address: ConnectionAddress
        do {
            address = try ConnectionAddress(host: host, port: port)
        } catch {
            validationError = error.localizedDescription
            return
        }
        var device = existing ?? SavedDevice(name: name, host: address.host, port: address.port)
        device.name = name
        device.host = address.host
        device.port = address.port
        device.preferredCodec = codec
        device.naturalScroll = naturalScroll
        device.useVirtualDisplay = useVirtualDisplay
        let home = homeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        device.homeAddress = home.isEmpty ? nil : home
        device.controlStrip = controlStrip
        if existing != nil {
            store.update(device)
        } else {
            device = store.add(device)
        }
        DeviceSecrets.setPassword(password, for: device)
        if !password.isEmpty { DeviceSecrets.setUsername(username, for: device) }
        dismiss()
    }
}

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
                Section("Preferences") {
                    Picker("Codec", selection: $codec) {
                        Text("HEVC (better quality)").tag(VideoCodec.hevc)
                        Text("H.264 (max compatibility)").tag(VideoCodec.h264)
                    }
                    Toggle("Natural scrolling", isOn: $naturalScroll)
                }
                Section {
                    Text("Vantage connects only over your Tailscale network. Make sure Tailscale is running on both devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existing == nil ? "Add Device" : "Edit Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(name.isEmpty || host.isEmpty)
                }
            }
            .onAppear(perform: populate)
        }
    }

    private func populate() {
        guard let existing else { return }
        name = existing.name
        host = existing.host
        port = String(existing.port)
        codec = existing.preferredCodec ?? .hevc
        naturalScroll = existing.naturalScroll
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
        if existing != nil { store.update(device) } else { store.add(device) }
        dismiss()
    }
}

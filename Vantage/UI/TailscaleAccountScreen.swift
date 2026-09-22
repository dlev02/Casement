import SwiftUI

/// Connects Vantage to the Tailscale API so it can list the tailnet's devices. Tailscale has no
/// end-user sign-in for third-party apps, so this takes a read-only key from the admin console.
struct TailscaleAccountScreen: View {
    @Environment(TailscaleAccount.self) private var account
    var onSignedIn: (([TailscaleDevice]) -> Void)? = nil

    @State private var accessToken = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var deviceCount: Int?

    private static let keysURL = URL(string: "https://login.tailscale.com/admin/settings/keys")!
    private static let oauthURL = URL(string: "https://login.tailscale.com/admin/settings/oauth")!

    var body: some View {
        Form {
            if let credential = account.credential {
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text("Signed In")
                        }
                        .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Key")
                        Spacer()
                        Text(credential.summary).foregroundStyle(.secondary)
                    }
                    if let deviceCount {
                        HStack {
                            Text("Devices")
                            Spacer()
                            Text("\(deviceCount)").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Tailscale")
                } footer: {
                    Text("Vantage only reads the device list. It never changes your tailnet.")
                }
                Section {
                    Button("Sign Out", role: .destructive) {
                        account.signOut()
                        deviceCount = nil
                    }
                }
            } else {
                Section {
                    Text("Tailscale doesn't offer a sign-in flow for third-party apps, so Vantage uses a read-only key from your admin console to see which of your devices are Macs it can connect to.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    SecureField("tskey-api-…", text: $accessToken)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        #endif
                    Link("Generate an Access Token", destination: Self.keysURL)
                } header: {
                    Text("Option 1: API Access Token")
                } footer: {
                    Text("Admin console → Settings → Keys → Generate access token. Tokens last up to 90 days.")
                }
                Section {
                    TextField("Client ID", text: $clientID)
                        .autocorrectionDisabled()
                        #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Client secret (tskey-client-…)", text: $clientSecret)
                        .autocorrectionDisabled()
                        #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        #endif
                    Link("Create an OAuth Client", destination: Self.oauthURL)
                } header: {
                    Text("Option 2: OAuth Client")
                } footer: {
                    Text("Admin console → Settings → OAuth clients. Choose the devices:core:read scope. OAuth clients don't expire.")
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Text("Sign In")
                            if isWorking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isWorking || pendingCredential == nil)
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("The key is stored in this device's Keychain and sent only to api.tailscale.com.")
                }
            }
        }
        .navigationTitle("Tailscale Account")
    }

    private var pendingCredential: TailscaleCredential? {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { return .accessToken(token) }
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty, !secret.isEmpty { return .oauthClient(id: id, secret: secret) }
        return nil
    }

    private func signIn() async {
        guard let credential = pendingCredential else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let devices = try await account.signIn(credential)
            deviceCount = devices.count
            accessToken = ""
            clientID = ""
            clientSecret = ""
            onSignedIn?(devices)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

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
                    Text("Tailscale has no sign-in for third-party apps. Instead you create a read-only key in the Tailscale admin console and paste it here — then Vantage can list your tailnet and add Macs with one tap.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    SetupStep(1) { Text("Open the OAuth clients page and sign in to Tailscale.") }
                    Link(destination: Self.oauthURL) {
                        Label("Open Tailscale OAuth Clients", systemImage: "arrow.up.right.square")
                    }
                    SetupStep(2) { Text("Tap **Generate OAuth client…**") }
                    SetupStep(3) { Text("Give it a description — \(Text("Vantage").bold()) works.") }
                    SetupStep(4) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Under **Scopes**, find the **Devices** row and turn on **Read** under **Core**.")
                            Text("That is the only permission Vantage needs. Leave every other scope off — it can't change anything on your tailnet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    SetupStep(5) { Text("Tap **Generate client**, then copy the client ID and secret into the fields below. Tailscale shows the secret only once.") }
                } header: {
                    Text("Recommended: OAuth Client")
                } footer: {
                    Text("OAuth clients never expire, so you only do this once.")
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

                Section {
                    SetupStep(1) { Text("Open the keys page, then tap **Generate access token…**") }
                    Link(destination: Self.keysURL) {
                        Label("Open Tailscale Keys", systemImage: "arrow.up.right.square")
                    }
                    SetupStep(2) { Text("Copy the token that starts with `tskey-api-` and paste it here.") }
                    SecureField("tskey-api-…", text: $accessToken)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Or Use an Access Token")
                } footer: {
                    Text("Simpler to create, but Tailscale expires access tokens after 90 days at most, and you'll have to repeat this when it does.")
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

/// One numbered line of setup directions. The number badge keeps a long list of steps scannable
/// without turning the form row into a paragraph.
private struct SetupStep<Content: View>: View {
    let number: Int
    @ViewBuilder var content: Content

    init(_ number: Int, @ViewBuilder content: () -> Content) {
        self.number = number
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number, format: .number)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: .circle)
            content
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

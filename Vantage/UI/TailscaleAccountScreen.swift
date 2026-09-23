import SwiftUI

/// Connects Vantage to the Tailscale API so it can list the tailnet's devices. Tailscale has no
/// end-user sign-in for third-party apps, so this takes a read-only key from the admin console.
/// Signed out, it offers the two kinds of key; each has a page of its own so neither set of
/// steps hides the other below a long scroll.
struct TailscaleAccountScreen: View {
    @Environment(TailscaleAccount.self) private var account
    var onSignedIn: (([TailscaleDevice]) -> Void)? = nil

    @State private var deviceCount: Int?

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
                    NavigationLink {
                        TailscaleOAuthSetup(onSignedIn: signedIn)
                    } label: {
                        MethodRow(title: "OAuth Client", badge: "Recommended", systemImage: "key.horizontal",
                                  detail: "Never expires, so you only set it up once. Takes a few more taps.")
                    }
                    NavigationLink {
                        TailscaleTokenSetup(onSignedIn: signedIn)
                    } label: {
                        MethodRow(title: "Access Token", badge: nil, systemImage: "clock.badge.exclamationmark",
                                  detail: "Quickest to create, but expires within 90 days.")
                    }
                } header: {
                    Text("Choose a Key")
                } footer: {
                    Text("Either key is stored in this device's Keychain and sent only to api.tailscale.com.")
                }
            }
        }
        .navigationTitle("Tailscale Account")
    }

    private func signedIn(_ devices: [TailscaleDevice]) {
        deviceCount = devices.count
        onSignedIn?(devices)
    }
}

/// A sign-in method on the chooser: what it is and the one trade-off that matters.
private struct MethodRow: View {
    let title: String
    let badge: String?
    let systemImage: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold))
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(.tint)
                            .background(.tint.opacity(0.15), in: .capsule)
                    }
                }
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Step-by-step setup for an OAuth client, the key that never expires.
struct TailscaleOAuthSetup: View {
    var onSignedIn: (([TailscaleDevice]) -> Void)? = nil
    @State private var clientID = ""
    @State private var clientSecret = ""

    private static let oauthURL = URL(string: "https://login.tailscale.com/admin/settings/oauth")!

    var body: some View {
        Form {
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
                Text("Steps")
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
            } header: {
                Text("Paste Here")
            } footer: {
                Text("You can switch to Safari and back between the two — what you've pasted stays here.")
            }

            TailscaleSignInSection(credential: credential, onSignedIn: onSignedIn)
        }
        .navigationTitle("OAuth Client")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var credential: TailscaleCredential? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty || secret.isEmpty ? nil : .oauthClient(id: id, secret: secret)
    }
}

/// Setup for an API access token: quicker, but Tailscale expires it within 90 days.
struct TailscaleTokenSetup: View {
    var onSignedIn: (([TailscaleDevice]) -> Void)? = nil
    @State private var accessToken = ""

    private static let keysURL = URL(string: "https://login.tailscale.com/admin/settings/keys")!

    var body: some View {
        Form {
            Section {
                SetupStep(1) { Text("Open the keys page, then tap **Generate access token…**") }
                Link(destination: Self.keysURL) {
                    Label("Open Tailscale Keys", systemImage: "arrow.up.right.square")
                }
                SetupStep(2) { Text("Copy the token that starts with `tskey-api-` and paste it below.") }
            } header: {
                Text("Steps")
            } footer: {
                Text("Tailscale expires access tokens after 90 days at most, and you'll have to repeat this when it does. An OAuth client never expires.")
            }

            Section("Paste Here") {
                SecureField("tskey-api-…", text: $accessToken)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    #if canImport(UIKit)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            TailscaleSignInSection(credential: credential, onSignedIn: onSignedIn)
        }
        .navigationTitle("Access Token")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var credential: TailscaleCredential? {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : .accessToken(token)
    }
}

/// The Sign In button both setup pages share. On success it returns to the account screen,
/// which then shows the signed-in state (or, in Add from Tailscale, the device list).
private struct TailscaleSignInSection: View {
    @Environment(TailscaleAccount.self) private var account
    @Environment(\.dismiss) private var dismiss
    let credential: TailscaleCredential?
    var onSignedIn: (([TailscaleDevice]) -> Void)?

    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    Text("Sign In")
                    if isWorking { Spacer(); ProgressView() }
                }
            }
            .disabled(isWorking || credential == nil)
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func signIn() async {
        guard let credential else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let devices = try await account.signIn(credential)
            onSignedIn?(devices)
            dismiss()
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

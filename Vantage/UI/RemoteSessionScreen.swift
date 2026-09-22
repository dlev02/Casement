import SwiftUI
import VantageCore

/// Full-screen remote session: shows the video, hosts input capture, overlays the control strip
/// and connection status, and runs the periodic feedback/ping loop.
struct RemoteSessionScreen: View {
    let device: SavedDevice
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(DeviceStore.self) private var store

    @State private var session = ClientSession()
    @State private var video = VideoStreamController()
    @State private var input = InputController()
    @State private var stickyModifiers: KeyModifiers = []
    @State private var touchMode: InputController.TouchMode = .trackpad
    @State private var showKeyboard = false
    @State private var viewportSize = CGSize(width: 1210, height: 834)
    @Environment(\.displayScale) private var displayScale
    @AppStorage("vantage.trackpadSensitivity") private var trackpadSensitivity = 1.5
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if canImport(UIKit)
            if session.state == .connected {
                RemoteSessionRepresentable(input: input, video: video, stickyModifiers: stickyModifiers)
                    .ignoresSafeArea()
            }
            #endif

            if session.state != .connected {
                connectionOverlay
            }

            VStack {
                if let status = session.hostStatus, status.isScreenLocked || status.isSecureInputActive {
                    HostStatusBanner(status: status)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if session.state == .connected {
                    ControlStrip(
                        stickyModifiers: $stickyModifiers,
                        touchMode: $touchMode,
                        onKey: { keyCode, modifiers in input.tapChord(keyCode: keyCode, modifiers: modifiers) },
                        onShowKeyboard: { showKeyboard.toggle() },
                        onSendClipboard: {
                            #if canImport(UIKit)
                            let payload = ClipboardSync.currentPayload()
                            if !payload.isEmpty { session.send(.clipboard(payload)) }
                            #endif
                        },
                        onDisconnect: disconnect
                    )
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
        .onChange(of: session.state) { _, state in
            if state == .connected { store.markConnected(device) }
        }
        .onChange(of: session.activeConfig) { _, config in
            if let config {
                input.displayPointSize = CGSize(width: config.display.pointWidth, height: config.display.pointHeight)
            }
        }
        .onChange(of: touchMode) { _, newValue in input.mode = newValue }
        .onChange(of: scenePhase) { _, phase in if phase == .active { session.retryNow() } }
        .overlay(alignment: .top) { hiddenKeyboardField }
        .task { await startSession() }
        .onDisappear { teardown() }
    }

    private var connectionOverlay: some View {
        VStack(spacing: 16) {
            switch session.state {
            case .connecting, .authenticating:
                ProgressView().controlSize(.large).tint(.white)
                Text("Connecting to \(device.name)…").foregroundStyle(.white)
            case .reconnecting:
                ProgressView().controlSize(.large).tint(.white)
                Text("Reconnecting…").foregroundStyle(.white)
            case .pairingRequired:
                PairingPrompt { code in
                    session.connect(to: device, viewport: currentViewport(), pairingCode: code)
                }
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.white)
                    Text(message).foregroundStyle(.white)
                    Button("Retry") { Task { await startSession() } }.buttonStyle(.glassProminent)
                    Button("Close") { disconnect() }.buttonStyle(.glass)
                }
            default:
                EmptyView()
            }
            if case .failed = session.state {} else {
                Button("Close", action: disconnect).buttonStyle(.glass)
            }
        }
        .padding(32)
        .glassEffect(in: .rect(cornerRadius: 24))
    }

    @ViewBuilder
    private var hiddenKeyboardField: some View {
        if showKeyboard {
            RemoteKeyboardField(isPresented: $showKeyboard, onText: input.typeText, onKey: { keyCode in
                input.tapChord(keyCode: keyCode, modifiers: stickyModifiers)
                stickyModifiers = []
            })
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
    }

    private func startSession() async {
        session.onVideo = { message in video.consume(message) }
        session.onClipboard = { payload in
            #if canImport(UIKit)
            ClipboardSync.apply(payload)
            #endif
        }
        video.onNeedsKeyframe = {
            Task { @MainActor in session.send(.requestKeyframe) }
        }
        input.send = { message in session.send(message) }
        input.mode = touchMode
        input.naturalScroll = device.naturalScroll
        input.trackpadSensitivity = trackpadSensitivity

        session.connect(to: device, viewport: currentViewport(), pairingCode: ClientOptions.pairingCode)
        startFeedbackLoop()
    }

    private func startFeedbackLoop() {
        feedbackTask?.cancel()
        feedbackTask = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard session.state == .connected else { continue }
                session.ping()
                let feedback = video.snapshotStats(windowSeconds: 0.25, rttMillis: session.lastRTTMillis)
                session.sendFeedback(feedback)
            }
        }
    }

    private func disconnect() {
        teardown()
        dismiss()
    }

    private func teardown() {
        feedbackTask?.cancel()
        feedbackTask = nil
        session.disconnect()
    }

    private func currentViewport() -> Viewport {
        Viewport(widthPoints: Double(viewportSize.width), heightPoints: Double(viewportSize.height), scale: Double(displayScale))
    }
}

#if canImport(UIKit)
import UIKit
#endif

/// Explains why input may be ignored: the Mac is locked or a secure field has focus.
struct HostStatusBanner: View {
    let status: HostStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.isScreenLocked ? "lock.fill" : "key.fill")
            Text(status.message ?? (status.isScreenLocked ? "The Mac is locked" : "Typing is blocked by a secure field"))
                .font(.callout)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(in: .capsule)
        .frame(maxWidth: 520)
    }
}

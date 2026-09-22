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
    @State private var controlsVisible = true
    @State private var showKeyboard = false
    @State private var keyboardText = ""
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if canImport(UIKit)
            RemoteSessionRepresentable(input: input, video: video, stickyModifiers: stickyModifiers)
                .ignoresSafeArea()
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
                if controlsVisible {
                    ControlStrip(
                        stickyModifiers: $stickyModifiers,
                        touchMode: $touchMode,
                        onKey: { keyCode, modifiers in input.tapChord(keyCode: keyCode, modifiers: modifiers) },
                        onShowKeyboard: { showKeyboard = true },
                        onSendClipboard: {
                            #if canImport(UIKit)
                            let payload = ClipboardSync.currentPayload()
                            if !payload.isEmpty { session.send(.clipboard(payload)) }
                            #endif
                        },
                        onDisconnect: disconnect,
                        onToggleControls: { withAnimation { controlsVisible.toggle() } }
                    )
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .statusBarHidden()
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .persistentSystemOverlays(.hidden)
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
        }
        .padding(32)
        .glassEffect(in: .rect(cornerRadius: 24))
    }

    @ViewBuilder
    private var hiddenKeyboardField: some View {
        if showKeyboard {
            RemoteKeyboardField(text: $keyboardText, isPresented: $showKeyboard) { text in
                input.typeText(text)
            }
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
        video.onNeedsKeyframe = { session.send(.requestKeyframe) }
        input.send = { message in session.send(message) }
        input.mode = touchMode

        session.connect(to: device, viewport: currentViewport(), pairingCode: ClientOptions.pairingCode)
        store.markConnected(device)
        startFeedbackLoop()
        observeConnected()
    }

    private func observeConnected() {
        Task {
            // Wait until authenticated, then request the stream (fit to the iPad viewport).
            while !Task.isCancelled, session.state != .connected {
                if case .failed = session.state { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard session.state == .connected else { return }
            session.selectDisplay(.fitViewport(currentViewport()), targetFPS: 60, quality: .auto)

            // Then keep the input geometry in sync with the negotiated display size.
            while !Task.isCancelled {
                if let config = session.activeConfig {
                    input.displayPointSize = CGSize(width: config.display.pointWidth, height: config.display.pointHeight)
                }
                if session.state == .idle { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func startFeedbackLoop() {
        feedbackTask?.cancel()
        feedbackTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard session.state == .connected else { continue }
                session.ping()
                let feedback = video.snapshotStats(windowSeconds: 0.25, rttMillis: session.lastRTTMillis)
                session.sendFeedback(feedback)
            }
        }
    }

    private func disconnect() {
        session.disconnect()
        teardown()
        dismiss()
    }

    private func teardown() {
        feedbackTask?.cancel()
        feedbackTask = nil
        session.disconnect()
    }

    private func currentViewport() -> Viewport {
        #if canImport(UIKit)
        let screen = UIScreen.main.bounds.size
        let scale = UIScreen.main.scale
        return Viewport(widthPoints: Double(screen.width), heightPoints: Double(screen.height), scale: Double(scale))
        #else
        return Viewport(widthPoints: 1210, heightPoints: 834, scale: 2)
        #endif
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

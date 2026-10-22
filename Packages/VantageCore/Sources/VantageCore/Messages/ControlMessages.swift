import Foundation

public enum VideoCodec: String, Codable, Sendable, CaseIterable {
    case h264
    case hevc
}

public enum QualityPreset: String, Codable, Sendable, CaseIterable {
    /// Balance sharpness and motion automatically from client feedback.
    case auto
    /// Favor crisp text; fewer frames per second under pressure.
    case text
    /// Favor frame delivery; accept softer detail.
    case motion
    /// Maximum bitrate the link will carry.
    case maximum
}

/// A viewport the client can show, in points plus backing scale.
public struct Viewport: Codable, Sendable, Equatable {
    public var widthPoints: Double
    public var heightPoints: Double
    public var scale: Double

    public init(widthPoints: Double, heightPoints: Double, scale: Double) {
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.scale = scale
    }

    public var pixelWidth: Int { Int((widthPoints * scale).rounded()) }
    public var pixelHeight: Int { Int((heightPoints * scale).rounded()) }
}

public struct DisplayInfo: Codable, Sendable, Identifiable, Equatable, Hashable {
    /// CGDirectDisplayID on the host.
    public var id: UInt32
    public var name: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pointWidth: Int
    public var pointHeight: Int
    public var scale: Double
    public var originX: Double
    public var originY: Double
    public var isMain: Bool
    public var isBuiltIn: Bool
    public var isVirtual: Bool
    public var refreshRate: Double

    public init(id: UInt32, name: String, pixelWidth: Int, pixelHeight: Int, pointWidth: Int, pointHeight: Int, scale: Double, originX: Double, originY: Double, isMain: Bool, isBuiltIn: Bool, isVirtual: Bool, refreshRate: Double) {
        self.id = id
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.scale = scale
        self.originX = originX
        self.originY = originY
        self.isMain = isMain
        self.isBuiltIn = isBuiltIn
        self.isVirtual = isVirtual
        self.refreshRate = refreshRate
    }
}

// MARK: - Handshake

public struct Hello: Codable, Sendable {
    public var protocolVersion: UInt16
    public var clientName: String
    public var deviceModel: String
    public var appVersion: String
    /// Raw 32-byte Ed25519 public key identifying this client device.
    public var clientPublicKey: Data
    public var supportedCodecs: [VideoCodec]
    public var maxDecodeWidth: Int
    public var maxDecodeHeight: Int
    public var viewport: Viewport?
    /// Optional for compatibility with hosts/clients predating readiness checks.
    public var isReadinessProbe: Bool?
    /// Optional client abilities (dictation results, …). Absent from older clients.
    public var features: ClientFeatures?

    public init(protocolVersion: UInt16 = VantageProtocol.version, clientName: String, deviceModel: String, appVersion: String, clientPublicKey: Data, supportedCodecs: [VideoCodec], maxDecodeWidth: Int, maxDecodeHeight: Int, viewport: Viewport?, isReadinessProbe: Bool? = nil, features: ClientFeatures? = nil) {
        self.protocolVersion = protocolVersion
        self.clientName = clientName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.clientPublicKey = clientPublicKey
        self.supportedCodecs = supportedCodecs
        self.maxDecodeWidth = maxDecodeWidth
        self.maxDecodeHeight = maxDecodeHeight
        self.viewport = viewport
        self.isReadinessProbe = isReadinessProbe
        self.features = features
    }
}

/// The operating system a host runs. A string wrapper rather than an enum so a host on a platform
/// this build doesn't know still decodes. Hosts before this field send nothing, which means macOS:
/// read `hostPlatform ?? .macOS`.
public struct HostPlatform: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Vantage Host on a Mac.
    public static let macOS = HostPlatform(rawValue: "macos")
    /// A Windows PC running a Vantage-compatible host.
    public static let windows = HostPlatform(rawValue: "windows")

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public struct Challenge: Codable, Sendable {
    public var hostName: String
    public var hostVersion: String
    public var hostPublicKey: Data
    /// 32 random bytes the client must sign.
    public var nonce: Data
    /// True when the host already trusts the client's public key.
    public var isPaired: Bool
    /// Tailnet identity of the connecting peer, if the host could resolve it.
    public var peerTailnetName: String?
    /// What the host runs, known before authenticating (so a probe or the pairing prompt can
    /// tell a Mac from a PC). Nil from older hosts, which are all Macs.
    public var hostPlatform: HostPlatform?

    public init(hostName: String, hostVersion: String, hostPublicKey: Data, nonce: Data, isPaired: Bool, peerTailnetName: String? = nil,
                hostPlatform: HostPlatform? = nil) {
        self.hostName = hostName
        self.hostVersion = hostVersion
        self.hostPublicKey = hostPublicKey
        self.nonce = nonce
        self.isPaired = isPaired
        self.peerTailnetName = peerTailnetName
        self.hostPlatform = hostPlatform
    }
}

public struct Authenticate: Codable, Sendable {
    /// Ed25519 signature over `AuthTranscript.bytes(...)`.
    public var signature: Data
    /// One-time pairing code shown on the host, required when not yet paired.
    public var pairingCode: String?

    public init(signature: Data, pairingCode: String? = nil) {
        self.signature = signature
        self.pairingCode = pairingCode
    }
}

public enum AuthStatus: String, Codable, Sendable {
    case ok
    case pairingRequired
    case badPairingCode
    case badSignature
    case denied
    case versionMismatch
}

public struct HostCapabilities: Codable, Sendable, Equatable {
    public var codecs: [VideoCodec]
    public var canManageVirtualDisplay: Bool
    public var clipboard: Bool
    public var maxFPS: Int
    /// Engines that accept `dictationControl`/`micAudio`, best first. Nil from older hosts, which
    /// would drop the session on those kinds, so the client must not send them then.
    public var dictationEngines: [DictationEngineID]?
    /// The host can stream the Mac's audio (`audioRequest` → `audioConfig`/`audioPacket`). Nil
    /// from older hosts, which would drop the session on `audioRequest`.
    public var audio: Bool?
    /// The host accepts a file channel (`attachMedia` with the session token) and the file
    /// transfer kinds on it. Nil from older hosts.
    public var fileTransfer: Bool?
    /// The host accepts files-only sessions (`ClientFeatures.filesOnly`) and keeps a file channel
    /// running after the session that opened it ends, until the client closes it. Nil from older
    /// hosts, which close the file channel with the session.
    public var filesOnlySessions: Bool?
    /// What the host runs (also in `Challenge.hostPlatform`). Nil from older hosts, which are all
    /// Macs.
    public var platform: HostPlatform?
    /// For a client that said `ClientFeatures.localCursor`: the video leaves the pointer out, and
    /// the host sends `cursorShape` (at stream start and whenever the pointer's look changes) and
    /// `cursorPosition` (when it's shown or hidden). Nil from hosts that always draw the pointer
    /// into the video (every Mac: macOS has no public API for the system cursor's image).
    public var cursorShapes: Bool?

    public init(codecs: [VideoCodec], canManageVirtualDisplay: Bool, clipboard: Bool, maxFPS: Int, dictationEngines: [DictationEngineID]? = nil,
                audio: Bool? = nil, fileTransfer: Bool? = nil, filesOnlySessions: Bool? = nil, platform: HostPlatform? = nil, cursorShapes: Bool? = nil) {
        self.codecs = codecs
        self.canManageVirtualDisplay = canManageVirtualDisplay
        self.clipboard = clipboard
        self.maxFPS = maxFPS
        self.dictationEngines = dictationEngines
        self.audio = audio
        self.fileTransfer = fileTransfer
        self.filesOnlySessions = filesOnlySessions
        self.platform = platform
        self.cursorShapes = cursorShapes
    }
}

public struct AuthResult: Codable, Sendable {
    public var status: AuthStatus
    public var message: String?
    /// Opaque token the client's file channel presents in `attachMedia` to join this session.
    /// Single use, bound to this connection's peer address, and revoked when the session ends
    /// (a channel that already attached may outlive it, see `HostCapabilities.filesOnlySessions`).
    /// Only sent to a client whose `Hello.features.fileTransfer` is true.
    public var sessionToken: Data?
    public var displays: [DisplayInfo]?
    public var capabilities: HostCapabilities?
    public var readiness: HostReadiness?

    public init(status: AuthStatus, message: String? = nil, sessionToken: Data? = nil, displays: [DisplayInfo]? = nil, capabilities: HostCapabilities? = nil, readiness: HostReadiness? = nil) {
        self.status = status
        self.message = message
        self.sessionToken = sessionToken
        self.displays = displays
        self.capabilities = capabilities
        self.readiness = readiness
    }
}

public struct HostReadiness: Codable, Sendable {
    public var screenRecordingGranted: Bool
    public var accessibilityGranted: Bool
    public init(screenRecordingGranted: Bool, accessibilityGranted: Bool) {
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGranted = accessibilityGranted
    }
}

public struct AttachMedia: Codable, Sendable {
    public var sessionToken: Data
    public init(sessionToken: Data) { self.sessionToken = sessionToken }
}

// MARK: - Session control

public enum DisplaySelection: Codable, Sendable, Equatable {
    /// Stream a specific existing display.
    case display(UInt32)
    /// Ask the host to provide (or resize) a virtual display matching the viewport.
    case fitViewport(Viewport)
}

public struct SelectDisplay: Codable, Sendable {
    public var selection: DisplaySelection
    public var targetFPS: Int
    public var quality: QualityPreset
    public var preferredCodec: VideoCodec?
    /// When true, `.fitViewport` asks the host to provision a virtual display sized to the
    /// viewport (BetterDisplay). When false or absent the host streams its main display at once.
    public var useVirtualDisplay: Bool?

    public init(selection: DisplaySelection, targetFPS: Int, quality: QualityPreset, preferredCodec: VideoCodec? = nil, useVirtualDisplay: Bool? = nil) {
        self.selection = selection
        self.targetFPS = targetFPS
        self.quality = quality
        self.preferredCodec = preferredCodec
        self.useVirtualDisplay = useVirtualDisplay
    }
}

public struct DisplayList: Codable, Sendable {
    public var displays: [DisplayInfo]
    public init(displays: [DisplayInfo]) { self.displays = displays }
}

/// Host acknowledgement of the geometry actually being streamed.
public struct StreamConfig: Codable, Sendable, Equatable {
    public var display: DisplayInfo
    public var codec: VideoCodec
    public var fps: Int
    public var bitrateKbps: Int

    public init(display: DisplayInfo, codec: VideoCodec, fps: Int, bitrateKbps: Int) {
        self.display = display
        self.codec = codec
        self.fps = fps
        self.bitrateKbps = bitrateKbps
    }
}

public struct ViewportChanged: Codable, Sendable {
    public var viewport: Viewport
    public init(viewport: Viewport) { self.viewport = viewport }
}

public struct QualityFeedback: Codable, Sendable {
    public var rttMillis: Double
    public var decodeMillis: Double
    public var framesReceived: UInt64
    public var framesDropped: UInt64
    public var queueDepth: Int
    public var bytesReceived: UInt64
    public var windowSeconds: Double

    public init(rttMillis: Double, decodeMillis: Double, framesReceived: UInt64, framesDropped: UInt64, queueDepth: Int, bytesReceived: UInt64, windowSeconds: Double) {
        self.rttMillis = rttMillis
        self.decodeMillis = decodeMillis
        self.framesReceived = framesReceived
        self.framesDropped = framesDropped
        self.queueDepth = queueDepth
        self.bytesReceived = bytesReceived
        self.windowSeconds = windowSeconds
    }
}

public struct StreamStats: Codable, Sendable, Equatable {
    public var captureFPS: Double
    public var encodeMillis: Double
    public var bitrateKbps: Int
    public var targetBitrateKbps: Int
    public var framesSent: UInt64
    public var framesSkipped: UInt64

    public init(captureFPS: Double, encodeMillis: Double, bitrateKbps: Int, targetBitrateKbps: Int, framesSent: UInt64, framesSkipped: UInt64) {
        self.captureFPS = captureFPS
        self.encodeMillis = encodeMillis
        self.bitrateKbps = bitrateKbps
        self.targetBitrateKbps = targetBitrateKbps
        self.framesSent = framesSent
        self.framesSkipped = framesSkipped
    }
}

public struct ClipboardPayload: Codable, Sendable, Equatable {
    public var text: String?
    /// PNG-encoded image, if the clipboard held an image.
    public var imagePNG: Data?
    /// Rich text (RTF) alongside `text`, when available.
    public var rtf: Data?

    public init(text: String? = nil, imagePNG: Data? = nil, rtf: Data? = nil) {
        self.text = text
        self.imagePNG = imagePNG
        self.rtf = rtf
    }

    public var isEmpty: Bool { text == nil && imagePNG == nil && rtf == nil }
}

/// Which engine is producing frames and accepting input on the host.
public enum HostInputPath: String, Codable, Sendable {
    /// ScreenCaptureKit + CGEvent (normal, unlocked session).
    case native
    /// Apple Screen Sharing bridge (lock screen / login window; passes Secure Input).
    case screenSharingBridge
}

/// Host-side conditions the client should surface (locked screen, secure input, active path).
public struct HostStatus: Codable, Sendable, Equatable {
    public var isScreenLocked: Bool
    public var isSecureInputActive: Bool
    public var inputPath: HostInputPath
    public var message: String?
    /// The Mac's display is asleep, so there's no picture until it wakes. Nil from hosts that
    /// predate it (optional, so both sides decode the other's JSON either way).
    public var isDisplayAsleep: Bool?
    /// The display is awake but the host has had no picture of it for a few seconds (capture
    /// won't start); it keeps trying. Nil from hosts that predate it.
    public var isScreenUnavailable: Bool?

    public init(isScreenLocked: Bool, isSecureInputActive: Bool, inputPath: HostInputPath, message: String? = nil,
                isDisplayAsleep: Bool? = nil, isScreenUnavailable: Bool? = nil) {
        self.isScreenLocked = isScreenLocked
        self.isSecureInputActive = isSecureInputActive
        self.inputPath = inputPath
        self.message = message
        self.isDisplayAsleep = isDisplayAsleep
        self.isScreenUnavailable = isScreenUnavailable
    }
}

public enum HostCommand: String, Codable, Sendable {
    case lockScreen
    case sleepDisplay
    case wakeDisplay
    case releaseAllInput
    case refreshDisplays
    case restoreDisplays
}

public struct HostCommandMessage: Codable, Sendable {
    public var command: HostCommand
    public init(command: HostCommand) { self.command = command }
}

public struct Ping: Codable, Sendable {
    public var sentAtNanos: UInt64
    public init(sentAtNanos: UInt64) { self.sentAtNanos = sentAtNanos }
}

public struct Pong: Codable, Sendable {
    public var echoNanos: UInt64
    public init(echoNanos: UInt64) { self.echoNanos = echoNanos }
}

public struct DisconnectMessage: Codable, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

public struct ProtocolErrorMessage: Codable, Sendable, Error {
    public var code: String
    public var message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct TextInput: Codable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

/// Key modifier flags shared by both platforms (mirrors the meaningful CGEventFlags bits).
public struct KeyModifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let capsLock = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let option = KeyModifiers(rawValue: 1 << 3)
    public static let command = KeyModifiers(rawValue: 1 << 4)
    public static let function = KeyModifiers(rawValue: 1 << 5)
}

public struct ModifierState: Codable, Sendable, Equatable {
    public var modifiers: KeyModifiers
    public init(modifiers: KeyModifiers) { self.modifiers = modifiers }
}

// MARK: - Video configuration & cursor shape (JSON, infrequent)

public struct VideoConfig: Codable, Sendable, Equatable {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    /// Raw parameter set NAL units (VPS/SPS/PPS) without start codes or length prefixes.
    public var parameterSets: [Data]
    public var nalLengthSize: Int
    public var fps: Int

    public init(codec: VideoCodec, width: Int, height: Int, parameterSets: [Data], nalLengthSize: Int = 4, fps: Int) {
        self.codec = codec
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
        self.nalLengthSize = nalLengthSize
        self.fps = fps
    }
}

public struct CursorShape: Codable, Sendable, Equatable {
    public var pngData: Data
    public var widthPoints: Double
    public var heightPoints: Double
    public var hotspotX: Double
    public var hotspotY: Double
    public var scale: Double

    public init(pngData: Data, widthPoints: Double, heightPoints: Double, hotspotX: Double, hotspotY: Double, scale: Double) {
        self.pngData = pngData
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.scale = scale
    }
}

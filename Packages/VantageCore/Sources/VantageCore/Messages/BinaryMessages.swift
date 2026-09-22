import Foundation

/// One encoded access unit. NAL units use 4-byte big-endian length prefixes (AVCC/HVCC style).
public struct VideoFrame: Sendable, Equatable {
    public var sequence: UInt64
    /// Host capture time in nanoseconds on the host's monotonic clock.
    public var captureNanos: UInt64
    public var isKeyframe: Bool
    public var width: UInt32
    public var height: UInt32
    public var data: Data

    public init(sequence: UInt64, captureNanos: UInt64, isKeyframe: Bool, width: UInt32, height: UInt32, data: Data) {
        self.sequence = sequence
        self.captureNanos = captureNanos
        self.isKeyframe = isKeyframe
        self.width = width
        self.height = height
        self.data = data
    }

    func encode() -> Data {
        var writer = BinaryWriter(capacity: 32 + data.count)
        writer.write(sequence)
        writer.write(captureNanos)
        writer.write(isKeyframe)
        writer.write(width)
        writer.write(height)
        writer.writeRaw(data)
        return writer.data
    }

    static func decode(_ payload: Data) throws -> VideoFrame {
        var reader = BinaryReader(payload)
        let sequence = try reader.readUInt64()
        let captureNanos = try reader.readUInt64()
        let isKeyframe = try reader.readBool()
        let width = try reader.readUInt32()
        let height = try reader.readUInt32()
        let data = reader.readRemaining()
        return VideoFrame(sequence: sequence, captureNanos: captureNanos, isKeyframe: isKeyframe, width: width, height: height, data: data)
    }
}

/// Host → client cursor location in display points (origin top-left of the streamed display).
public struct CursorPosition: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var isVisible: Bool

    public init(x: Float, y: Float, isVisible: Bool) {
        self.x = x
        self.y = y
        self.isVisible = isVisible
    }

    func encode() -> Data {
        var writer = BinaryWriter(capacity: 9)
        writer.write(x)
        writer.write(y)
        writer.write(isVisible)
        return writer.data
    }

    static func decode(_ payload: Data) throws -> CursorPosition {
        var reader = BinaryReader(payload)
        return CursorPosition(x: try reader.readFloat(), y: try reader.readFloat(), isVisible: try reader.readBool())
    }
}

public enum PointerButton: UInt8, Sendable, Codable {
    case left = 0
    case right = 1
    case middle = 2
    case back = 3
    case forward = 4
}

public enum PointerAction: UInt8, Sendable {
    /// Move (or drag, when a button is held) to the given location.
    case move = 0
    case down = 1
    case up = 2
}

/// Client → host pointer event in display points of the streamed display.
public struct PointerEvent: Sendable, Equatable {
    public var action: PointerAction
    public var button: PointerButton
    public var x: Float
    public var y: Float
    public var clickCount: UInt8
    public var modifiers: KeyModifiers

    public init(action: PointerAction, button: PointerButton = .left, x: Float, y: Float, clickCount: UInt8 = 1, modifiers: KeyModifiers = []) {
        self.action = action
        self.button = button
        self.x = x
        self.y = y
        self.clickCount = clickCount
        self.modifiers = modifiers
    }

    func encode() -> Data {
        var writer = BinaryWriter(capacity: 16)
        writer.write(action.rawValue)
        writer.write(button.rawValue)
        writer.write(x)
        writer.write(y)
        writer.write(clickCount)
        writer.write(modifiers.rawValue)
        return writer.data
    }

    static func decode(_ payload: Data) throws -> PointerEvent {
        var reader = BinaryReader(payload)
        let action = try reader.readEnum(PointerAction.self)
        let button = try reader.readEnum(PointerButton.self)
        let x = try reader.readFloat()
        let y = try reader.readFloat()
        let clickCount = try reader.readUInt8()
        let modifiers = KeyModifiers(rawValue: try reader.readUInt32())
        return PointerEvent(action: action, button: button, x: x, y: y, clickCount: clickCount, modifiers: modifiers)
    }
}

public enum ScrollPhase: UInt8, Sendable {
    case none = 0
    case began = 1
    case changed = 2
    case ended = 3
    case cancelled = 4
}

public enum MomentumPhase: UInt8, Sendable {
    case none = 0
    case began = 1
    case changed = 2
    case ended = 3
}

/// Client → host scroll event.
///
/// Continuous (trackpad / touch) scrolls carry pixel deltas and gesture phases; the host
/// synthesizes momentum from `velocity` when the gesture ends. Discrete (wheel) scrolls
/// carry line deltas with `isContinuous == false`.
public struct ScrollEvent: Sendable, Equatable {
    public var phase: ScrollPhase
    public var momentum: MomentumPhase
    public var isContinuous: Bool
    public var deltaX: Float
    public var deltaY: Float
    public var x: Float
    public var y: Float
    /// Points per second at gesture end; zero otherwise.
    public var velocityX: Float
    public var velocityY: Float
    public var modifiers: KeyModifiers

    public init(phase: ScrollPhase, momentum: MomentumPhase = .none, isContinuous: Bool, deltaX: Float, deltaY: Float, x: Float, y: Float, velocityX: Float = 0, velocityY: Float = 0, modifiers: KeyModifiers = []) {
        self.phase = phase
        self.momentum = momentum
        self.isContinuous = isContinuous
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.x = x
        self.y = y
        self.velocityX = velocityX
        self.velocityY = velocityY
        self.modifiers = modifiers
    }

    func encode() -> Data {
        var writer = BinaryWriter(capacity: 32)
        writer.write(phase.rawValue)
        writer.write(momentum.rawValue)
        writer.write(isContinuous)
        writer.write(deltaX)
        writer.write(deltaY)
        writer.write(x)
        writer.write(y)
        writer.write(velocityX)
        writer.write(velocityY)
        writer.write(modifiers.rawValue)
        return writer.data
    }

    static func decode(_ payload: Data) throws -> ScrollEvent {
        var reader = BinaryReader(payload)
        let phase = try reader.readEnum(ScrollPhase.self)
        let momentum = try reader.readEnum(MomentumPhase.self)
        let isContinuous = try reader.readBool()
        let deltaX = try reader.readFloat()
        let deltaY = try reader.readFloat()
        let x = try reader.readFloat()
        let y = try reader.readFloat()
        let velocityX = try reader.readFloat()
        let velocityY = try reader.readFloat()
        let modifiers = KeyModifiers(rawValue: try reader.readUInt32())
        return ScrollEvent(phase: phase, momentum: momentum, isContinuous: isContinuous, deltaX: deltaX, deltaY: deltaY, x: x, y: y, velocityX: velocityX, velocityY: velocityY, modifiers: modifiers)
    }
}

/// Client → host key event using macOS virtual key codes.
public struct KeyEvent: Sendable, Equatable {
    public var keyCode: UInt16
    public var isDown: Bool
    public var modifiers: KeyModifiers
    public var isRepeat: Bool

    public init(keyCode: UInt16, isDown: Bool, modifiers: KeyModifiers, isRepeat: Bool = false) {
        self.keyCode = keyCode
        self.isDown = isDown
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }

    func encode() -> Data {
        var writer = BinaryWriter(capacity: 8)
        writer.write(keyCode)
        writer.write(isDown)
        writer.write(modifiers.rawValue)
        writer.write(isRepeat)
        return writer.data
    }

    static func decode(_ payload: Data) throws -> KeyEvent {
        var reader = BinaryReader(payload)
        let keyCode = try reader.readUInt16()
        let isDown = try reader.readBool()
        let modifiers = KeyModifiers(rawValue: try reader.readUInt32())
        let isRepeat = try reader.readBool()
        return KeyEvent(keyCode: keyCode, isDown: isDown, modifiers: modifiers, isRepeat: isRepeat)
    }
}

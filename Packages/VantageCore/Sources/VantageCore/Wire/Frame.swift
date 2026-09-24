import Foundation

/// Wire framing: every message is an 8-byte header followed by `length` payload bytes.
///
/// ```
/// 0      1      2        4                8
/// | 'V'  | kind | flags  | payload length |  payload...
/// ```
/// All integers are little-endian.
public enum Frame {
    public static let magic: UInt8 = 0x56 // "V"
    public static let headerLength = 8
    /// Hard cap on a single message. Keyframes at 4K stay far below this.
    public static let maxPayloadLength: UInt32 = 32 * 1024 * 1024

    public struct Header: Sendable, Equatable {
        public var kind: MessageKind
        public var flags: UInt16
        public var length: UInt32

        public init(kind: MessageKind, flags: UInt16 = 0, length: UInt32) {
            self.kind = kind
            self.flags = flags
            self.length = length
        }

        public func encoded() -> Data {
            var writer = BinaryWriter(capacity: Frame.headerLength)
            writer.write(Frame.magic)
            writer.write(kind.rawValue)
            writer.write(flags)
            writer.write(length)
            return writer.data
        }

        public static func decode(_ data: Data) throws -> Header {
            var reader = BinaryReader(data)
            let magic = try reader.readUInt8()
            guard magic == Frame.magic else { throw FrameError.badMagic(magic) }
            let rawKind = try reader.readUInt8()
            guard let kind = MessageKind(rawValue: rawKind) else { throw FrameError.unknownKind(rawKind) }
            let flags = try reader.readUInt16()
            let length = try reader.readUInt32()
            guard length <= Frame.maxPayloadLength else { throw FrameError.payloadTooLarge(length) }
            return Header(kind: kind, flags: flags, length: length)
        }
    }

    public static func encode(kind: MessageKind, payload: Data, flags: UInt16 = 0) -> Data {
        // One allocation of the final size: a video frame or file chunk is copied once, not
        // grown out of the 8-byte header.
        var out = Data(capacity: headerLength + payload.count)
        out.append(Header(kind: kind, flags: flags, length: UInt32(payload.count)).encoded())
        out.append(payload)
        return out
    }
}

public enum FrameError: Error, Sendable, Equatable {
    case badMagic(UInt8)
    case unknownKind(UInt8)
    case payloadTooLarge(UInt32)
}

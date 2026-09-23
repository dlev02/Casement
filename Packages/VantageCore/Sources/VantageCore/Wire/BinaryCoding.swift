import Foundation

/// Little-endian binary writer for hot-path messages.
public struct BinaryWriter: Sendable {
    public private(set) var data: Data

    public init(capacity: Int = 64) {
        data = Data(capacity: capacity)
    }

    public mutating func write(_ value: UInt8) {
        data.append(value)
    }

    public mutating func write(_ value: Bool) {
        data.append(value ? 1 : 0)
    }

    public mutating func write(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func write(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func write(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    public mutating func write(_ value: Int32) {
        write(UInt32(bitPattern: value))
    }

    public mutating func write(_ value: Float) {
        write(value.bitPattern)
    }

    public mutating func write(_ value: Double) {
        write(value.bitPattern)
    }

    /// Writes a length-prefixed (UInt32) blob.
    public mutating func write(_ value: Data) {
        write(UInt32(value.count))
        data.append(value)
    }

    /// Writes a length-prefixed UTF-8 string.
    public mutating func write(_ value: String) {
        write(Data(value.utf8))
    }

    public mutating func writeRaw(_ value: Data) {
        data.append(value)
    }
}

public enum BinaryDecodingError: Error, Sendable {
    case truncated(expected: Int, remaining: Int)
    case invalidUTF8
    case invalidEnum(String, UInt64)
}

/// Little-endian binary reader mirroring `BinaryWriter`.
public struct BinaryReader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }
    public var isAtEnd: Bool { remaining == 0 }

    private mutating func take(_ count: Int) throws -> Data {
        guard remaining >= count else {
            throw BinaryDecodingError.truncated(expected: count, remaining: remaining)
        }
        let slice = data[offset ..< offset + count]
        offset += count
        return slice
    }

    public mutating func readUInt8() throws -> UInt8 {
        try take(1).first!
    }

    public mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    public mutating func readUInt16() throws -> UInt16 {
        let bytes = try take(2)
        return bytes.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
    }

    public mutating func readUInt32() throws -> UInt32 {
        let bytes = try take(4)
        return bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    public mutating func readUInt64() throws -> UInt64 {
        let bytes = try take(8)
        return bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }

    public mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    public mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    public mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    public mutating func readData() throws -> Data {
        let count = Int(try readUInt32())
        return Data(try take(count))
    }

    public mutating func readString() throws -> String {
        guard let string = String(data: try readData(), encoding: .utf8) else {
            throw BinaryDecodingError.invalidUTF8
        }
        return string
    }

    /// Reads exactly `count` bytes with no length prefix.
    public mutating func readRaw(_ count: Int) throws -> Data {
        Data(try take(count))
    }

    public mutating func readRemaining() -> Data {
        let slice = data[offset...]
        offset = data.endIndex
        return Data(slice)
    }

    public mutating func readEnum<E: RawRepresentable>(_ type: E.Type) throws -> E where E.RawValue == UInt8 {
        let raw = try readUInt8()
        guard let value = E(rawValue: raw) else {
            throw BinaryDecodingError.invalidEnum(String(describing: type), UInt64(raw))
        }
        return value
    }
}

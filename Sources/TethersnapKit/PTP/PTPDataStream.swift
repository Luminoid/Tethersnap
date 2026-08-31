import Foundation

/// Little-endian reader for PTP datasets (device → host).
///
/// PTP strings are a 1-byte character count (including the null terminator,
/// 0 for empty) followed by UTF-16LE code units ending in 0x0000.
public struct PTPDataReader {
    private let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ data: Data) {
        bytes = [UInt8](data)
        offset = 0
    }

    public var remainingCount: Int { bytes.count - offset }

    public mutating func readU8() throws -> UInt8 {
        guard offset + 1 <= bytes.count else { throw MTPError.malformedData("out of bounds reading UInt8 at \(offset)") }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func readU16() throws -> UInt16 {
        guard offset + 2 <= bytes.count else { throw MTPError.malformedData("out of bounds reading UInt16 at \(offset)") }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    public mutating func readU32() throws -> UInt32 {
        guard offset + 4 <= bytes.count else { throw MTPError.malformedData("out of bounds reading UInt32 at \(offset)") }
        defer { offset += 4 }
        return (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    public mutating func readU64() throws -> UInt64 {
        guard offset + 8 <= bytes.count else { throw MTPError.malformedData("out of bounds reading UInt64 at \(offset)") }
        defer { offset += 8 }
        return (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }

    public mutating func readU16Array() throws -> [UInt16] {
        let count = try readU32()
        guard count <= 0xFFFF else { throw MTPError.malformedData("implausible UInt16 array count \(count)") }
        return try (0 ..< count).map { _ in try readU16() }
    }

    public mutating func readU32Array() throws -> [UInt32] {
        let count = try readU32()
        guard Int(count) * 4 <= remainingCount else {
            throw MTPError.malformedData("UInt32 array count \(count) exceeds remaining \(remainingCount) bytes")
        }
        return try (0 ..< count).map { _ in try readU32() }
    }

    public mutating func readString() throws -> String {
        let charCount = try Int(readU8())
        guard charCount > 0 else { return "" }
        guard offset + charCount * 2 <= bytes.count else {
            throw MTPError.malformedData("out of bounds reading \(charCount)-char string at \(offset)")
        }
        var units: [UInt16] = []
        units.reserveCapacity(charCount)
        for _ in 0 ..< charCount {
            try units.append(readU16())
        }
        // The count includes the terminator; tolerate devices that omit it.
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}

/// Little-endian writer, used for command payloads and test fixtures.
public struct PTPDataWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func append(_ other: Data) {
        data.append(other)
    }

    public mutating func appendU8(_ value: UInt8) {
        data.append(value)
    }

    public mutating func appendU16(_ value: UInt16) {
        data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    public mutating func appendU32(_ value: UInt32) {
        data.append(contentsOf: (0 ..< 4).map { UInt8((value >> (8 * $0)) & 0xFF) })
    }

    public mutating func appendU64(_ value: UInt64) {
        data.append(contentsOf: (0 ..< 8).map { UInt8((value >> (8 * $0)) & 0xFF) })
    }

    public mutating func appendU16Array(_ values: [UInt16]) {
        appendU32(UInt32(values.count))
        for value in values {
            appendU16(value)
        }
    }

    public mutating func appendU32Array(_ values: [UInt32]) {
        appendU32(UInt32(values.count))
        for value in values {
            appendU32(value)
        }
    }

    public mutating func appendString(_ string: String) {
        guard !string.isEmpty else {
            appendU8(0)
            return
        }
        // The count byte includes the terminator, so 254 payload units fit; a
        // truncation must never cut between the halves of a surrogate pair.
        var units = Array(string.utf16.prefix(254))
        if let last = units.last, UTF16.isLeadSurrogate(last) {
            units.removeLast()
        }
        units.append(0)
        appendU8(UInt8(units.count))
        for unit in units {
            appendU16(unit)
        }
    }
}

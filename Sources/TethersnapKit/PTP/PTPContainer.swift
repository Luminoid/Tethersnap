import Foundation

/// The 12-byte header that starts every PTP-over-USB container.
public struct PTPContainerHeader: Equatable, Sendable {
    public static let encodedSize = 12

    /// Total container length in bytes, header included.
    public let length: UInt32
    public let type: PTPContainerType
    /// Operation code (command/data) or response code (response).
    public let code: UInt16
    public let transactionID: UInt32

    public init(length: UInt32, type: PTPContainerType, code: UInt16, transactionID: UInt32) {
        self.length = length
        self.type = type
        self.code = code
        self.transactionID = transactionID
    }

    public var payloadLength: Int { Int(length) - Self.encodedSize }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count >= encodedSize else {
            throw MTPError.malformedData("container header needs \(encodedSize) bytes, got \(data.count)")
        }
        var reader = PTPDataReader(data.prefix(encodedSize))
        let length = try reader.readU32()
        let rawType = try reader.readU16()
        let code = try reader.readU16()
        let transactionID = try reader.readU32()
        guard let type = PTPContainerType(rawValue: rawType) else {
            throw MTPError.malformedData(String(format: "unknown container type 0x%04X", rawType))
        }
        guard length >= UInt32(encodedSize) else {
            throw MTPError.malformedData("container length \(length) below header size")
        }
        return Self(length: length, type: type, code: code, transactionID: transactionID)
    }

    public func encoded() -> Data {
        var writer = PTPDataWriter()
        writer.appendU32(length)
        writer.appendU16(type.rawValue)
        writer.appendU16(code)
        writer.appendU32(transactionID)
        return writer.data
    }
}

/// Container construction helpers.
public enum PTPContainer {
    /// Encode a command container with up to five UInt32 parameters.
    public static func command(_ operation: PTPOperationCode, transactionID: UInt32, parameters: [UInt32] = []) throws -> Data {
        guard parameters.count <= 5 else {
            throw MTPError.malformedData("PTP commands carry at most 5 parameters, got \(parameters.count)")
        }
        let header = PTPContainerHeader(
            length: UInt32(PTPContainerHeader.encodedSize + parameters.count * 4),
            type: .command,
            code: operation.rawValue,
            transactionID: transactionID
        )
        var writer = PTPDataWriter()
        writer.append(header.encoded())
        for parameter in parameters {
            writer.appendU32(parameter)
        }
        return writer.data
    }

    /// Decode the UInt32 parameters that follow a response header.
    public static func responseParameters(header: PTPContainerHeader, payload: Data) throws -> [UInt32] {
        let count = header.payloadLength / 4
        guard count >= 0, count <= 5, payload.count >= count * 4 else {
            throw MTPError.malformedData("response payload \(payload.count) bytes does not match header length \(header.length)")
        }
        var reader = PTPDataReader(payload)
        return try (0 ..< count).map { _ in try reader.readU32() }
    }
}

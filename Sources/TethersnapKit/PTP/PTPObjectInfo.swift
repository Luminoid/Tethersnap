import Foundation

/// Parsed ObjectInfo dataset (PIMA 15740 §5.3.1).
public struct PTPObjectInfo: Sendable {
    public let storageID: UInt32
    public let objectFormat: UInt16
    public let protectionStatus: UInt16
    public let compressedSize: UInt32
    public let thumbFormat: UInt16
    public let thumbCompressedSize: UInt32
    public let thumbPixWidth: UInt32
    public let thumbPixHeight: UInt32
    public let imagePixWidth: UInt32
    public let imagePixHeight: UInt32
    public let imageBitDepth: UInt32
    public let parentObject: UInt32
    public let associationType: UInt16
    public let associationDescription: UInt32
    public let sequenceNumber: UInt32
    public let filename: String
    public let captureDate: String
    public let modificationDate: String
    public let keywords: String

    public static func decode(_ data: Data) throws -> Self {
        var reader = PTPDataReader(data)
        return try Self(
            storageID: reader.readU32(),
            objectFormat: reader.readU16(),
            protectionStatus: reader.readU16(),
            compressedSize: reader.readU32(),
            thumbFormat: reader.readU16(),
            thumbCompressedSize: reader.readU32(),
            thumbPixWidth: reader.readU32(),
            thumbPixHeight: reader.readU32(),
            imagePixWidth: reader.readU32(),
            imagePixHeight: reader.readU32(),
            imageBitDepth: reader.readU32(),
            parentObject: reader.readU32(),
            associationType: reader.readU16(),
            associationDescription: reader.readU32(),
            sequenceNumber: reader.readU32(),
            filename: reader.readString(),
            captureDate: reader.readString(),
            modificationDate: reader.readString(),
            keywords: reader.readString()
        )
    }

    public var isAssociation: Bool {
        PTPObjectFormat.isAssociation(objectFormat)
    }

    /// Best-effort capture date: the dataset's CaptureDate, then ModificationDate,
    /// then the timestamp prefix Switch capture filenames carry.
    public var bestDate: Date? {
        PTPDateParser.parse(captureDate)
            ?? PTPDateParser.parse(modificationDate)
            ?? PTPDateParser.parseFilenameTimestamp(filename)
    }
}

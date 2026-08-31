import Foundation

/// Parsed StorageInfo dataset (PIMA 15740 §5.2.2).
public struct PTPStorageInfo: Sendable {
    public let storageType: UInt16
    public let filesystemType: UInt16
    public let accessCapability: UInt16
    public let maxCapacity: UInt64
    public let freeSpaceInBytes: UInt64
    public let freeSpaceInObjects: UInt32
    public let storageDescription: String
    public let volumeLabel: String

    public static func decode(_ data: Data) throws -> Self {
        var reader = PTPDataReader(data)
        return try Self(
            storageType: reader.readU16(),
            filesystemType: reader.readU16(),
            accessCapability: reader.readU16(),
            maxCapacity: reader.readU64(),
            freeSpaceInBytes: reader.readU64(),
            freeSpaceInObjects: reader.readU32(),
            storageDescription: reader.readString(),
            volumeLabel: reader.readString()
        )
    }

    /// Human-readable name preferring the volume label.
    public var displayName: String {
        if !volumeLabel.isEmpty { return volumeLabel }
        if !storageDescription.isEmpty { return storageDescription }
        return Bundle.module.localizedString(forKey: "storage.default", value: nil, table: nil)
    }
}

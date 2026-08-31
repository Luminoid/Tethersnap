import Foundation

/// Parsed DeviceInfo dataset (PIMA 15740 §5.1.1).
public struct PTPDeviceInfo: Sendable {
    public let standardVersion: UInt16
    public let vendorExtensionID: UInt32
    public let vendorExtensionVersion: UInt16
    public let vendorExtensionDescription: String
    public let functionalMode: UInt16
    public let operationsSupported: [UInt16]
    public let eventsSupported: [UInt16]
    public let devicePropertiesSupported: [UInt16]
    public let captureFormats: [UInt16]
    public let imageFormats: [UInt16]
    public let manufacturer: String
    public let model: String
    public let deviceVersion: String
    public let serialNumber: String

    public static func decode(_ data: Data) throws -> Self {
        var reader = PTPDataReader(data)
        return try Self(
            standardVersion: reader.readU16(),
            vendorExtensionID: reader.readU32(),
            vendorExtensionVersion: reader.readU16(),
            vendorExtensionDescription: reader.readString(),
            functionalMode: reader.readU16(),
            operationsSupported: reader.readU16Array(),
            eventsSupported: reader.readU16Array(),
            devicePropertiesSupported: reader.readU16Array(),
            captureFormats: reader.readU16Array(),
            imageFormats: reader.readU16Array(),
            manufacturer: reader.readString(),
            model: reader.readString(),
            deviceVersion: reader.readString(),
            serialNumber: reader.readString()
        )
    }

    public func supports(_ operation: PTPOperationCode) -> Bool {
        operationsSupported.contains(operation.rawValue)
    }
}

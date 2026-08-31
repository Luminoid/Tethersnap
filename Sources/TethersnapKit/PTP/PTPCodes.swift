import Foundation

/// PTP container types (PIMA 15740 / USB still-image class).
public enum PTPContainerType: UInt16, Sendable {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

/// Operations Tethersnap sends. Baseline PTP only: the Switch 2 exposes no MTP
/// vendor extension, so extension operations (GetObjectPropList etc.) are
/// deliberately absent.
public enum PTPOperationCode: UInt16, Sendable {
    case getDeviceInfo = 0x1001
    case openSession = 0x1002
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getStorageInfo = 0x1005
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case getObject = 0x1009
    case getThumb = 0x100A
    case getPartialObject = 0x101B
}

extension PTPOperationCode: CustomStringConvertible {
    public var description: String {
        let name = switch self {
        case .getDeviceInfo: "GetDeviceInfo"
        case .openSession: "OpenSession"
        case .closeSession: "CloseSession"
        case .getStorageIDs: "GetStorageIDs"
        case .getStorageInfo: "GetStorageInfo"
        case .getObjectHandles: "GetObjectHandles"
        case .getObjectInfo: "GetObjectInfo"
        case .getObject: "GetObject"
        case .getThumb: "GetThumb"
        case .getPartialObject: "GetPartialObject"
        }
        return "\(name)(\(String(format: "0x%04X", rawValue)))"
    }
}

/// Response codes arrive from the device, so unknown values must survive decoding.
public struct PTPResponseCode: RawRepresentable, Equatable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let ok = Self(rawValue: 0x2001)
    public static let generalError = Self(rawValue: 0x2002)
    public static let sessionNotOpen = Self(rawValue: 0x2003)
    public static let invalidTransactionID = Self(rawValue: 0x2004)
    public static let operationNotSupported = Self(rawValue: 0x2005)
    public static let parameterNotSupported = Self(rawValue: 0x2006)
    public static let incompleteTransfer = Self(rawValue: 0x2007)
    public static let invalidStorageID = Self(rawValue: 0x2008)
    public static let invalidObjectHandle = Self(rawValue: 0x2009)
    public static let storeNotAvailable = Self(rawValue: 0x2013)
    public static let specificationByFormatUnsupported = Self(rawValue: 0x2014)
    public static let invalidParentObject = Self(rawValue: 0x201A)
    public static let sessionAlreadyOpen = Self(rawValue: 0x201E)
    public static let transactionCancelled = Self(rawValue: 0x201F)

    public var isOK: Bool { self == .ok }
}

extension PTPResponseCode: CustomStringConvertible {
    public var description: String {
        let name: String? = switch self {
        case .ok: "OK"
        case .generalError: "GeneralError"
        case .sessionNotOpen: "SessionNotOpen"
        case .invalidTransactionID: "InvalidTransactionID"
        case .operationNotSupported: "OperationNotSupported"
        case .parameterNotSupported: "ParameterNotSupported"
        case .incompleteTransfer: "IncompleteTransfer"
        case .invalidStorageID: "InvalidStorageID"
        case .invalidObjectHandle: "InvalidObjectHandle"
        case .storeNotAvailable: "StoreNotAvailable"
        case .specificationByFormatUnsupported: "SpecificationByFormatUnsupported"
        case .invalidParentObject: "InvalidParentObject"
        case .sessionAlreadyOpen: "SessionAlreadyOpen"
        case .transactionCancelled: "TransactionCancelled"
        default: nil
        }
        let hex = String(format: "0x%04X", rawValue)
        return name.map { "\($0) (\(hex))" } ?? hex
    }
}

/// Object format codes (subset relevant to captures).
public enum PTPObjectFormat {
    public static let association: UInt16 = 0x3001

    public static func isAssociation(_ format: UInt16) -> Bool {
        format == association
    }
}

/// Well-known wildcard parameters for GetObjectHandles.
public enum PTPWildcard {
    /// "All storages" for the StorageID parameter.
    public static let allStorages: UInt32 = 0xFFFF_FFFF
    /// "All formats" / "all associations" zero parameter.
    public static let any: UInt32 = 0
    /// "Objects at the root" for the parent-association parameter.
    public static let rootParent: UInt32 = 0xFFFF_FFFF
}

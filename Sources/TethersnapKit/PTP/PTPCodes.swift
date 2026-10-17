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

    /// Capture kind from a STANDARD format code, for objects whose filename has
    /// no usable extension. Image codes are 0x38xx (EXIF/JPEG 0x3801, TIFF,
    /// PNG, JFIF, …); video codes are the PIMA AVI/MPEG/ASF set plus MTP's
    /// WMV/MP4/3GP. Vendor codes (0xB1xx) are deliberately nil: Canon CRW
    /// and Sony RAW reuse the same values.
    public static func captureKind(_ format: UInt16) -> CaptureItem.Kind? {
        switch format {
        case 0x3800 ... 0x38FF: .image
        case 0x300A, 0x300B, 0x300C, 0x300D, 0xB981, 0xB982, 0xB984: .video
        default: nil
        }
    }

    /// A file extension for a standard object format, used to name an object
    /// whose reported filename is unusable; nil for formats with no
    /// conventional extension.
    public static func preferredExtension(_ format: UInt16) -> String? {
        switch format {
        case 0x3801, 0x3808: "jpg"
        case 0x3802, 0x380D: "tif"
        case 0x3804: "bmp"
        case 0x3807: "gif"
        case 0x380B: "png"
        case 0x300A: "avi"
        case 0x300B: "mpg"
        case 0x300D: "mov"
        case 0xB981: "wmv"
        case 0xB982: "mp4"
        case 0xB984: "3gp"
        default: nil
        }
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

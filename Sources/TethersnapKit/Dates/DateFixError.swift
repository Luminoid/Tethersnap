import Foundation

/// Errors surfaced while fixing capture dates from filenames.
public enum DateFixError: Error {
    /// The path handed to the folder fixer is not a directory.
    case notAFolder(String)
    /// ImageIO could not copy the image with its new metadata (the detail is the CFError's description).
    case imageRewriteFailed(String)
    /// `AVAssetExportSession` could not be created for the file.
    case videoSessionUnavailable
    /// The container (by extension) cannot be re-muxed losslessly.
    case videoContainerUnsupported(String)
}

extension DateFixError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .notAFolder(path):
            String(format: Self.localized("error.datefix.not_a_folder"), path)
        case let .imageRewriteFailed(detail):
            String(format: Self.localized("error.datefix.image_rewrite"), detail)
        case .videoSessionUnavailable:
            Self.localized("error.datefix.video_session")
        case let .videoContainerUnsupported(container):
            String(format: Self.localized("error.datefix.video_container"), container)
        }
    }

    private static func localized(_ key: String) -> String {
        KitStrings.localized(key)
    }
}

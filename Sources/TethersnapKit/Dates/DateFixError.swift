import Foundation

/// Errors surfaced while fixing capture dates from filenames.
public enum DateFixError: Error {
    /// The path handed to the folder fixer is not a directory.
    case notAFolder(String)
    /// ImageIO could not copy the image with its new metadata (the detail is the CFError's description).
    case imageRewriteFailed(String)
    /// The movie (by filename) has no single `moov` box to rewrite, or a
    /// metadata box of a kind the patcher does not understand.
    case videoContainerUnsupported(String)
}

extension DateFixError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .notAFolder(path):
            String(format: Self.localized("error.datefix.not_a_folder"), path)
        case let .imageRewriteFailed(detail):
            String(format: Self.localized("error.datefix.image_rewrite"), detail)
        case let .videoContainerUnsupported(filename):
            String(format: Self.localized("error.datefix.video_container"), filename)
        }
    }

    private static func localized(_ key: String) -> String {
        KitStrings.localized(key)
    }
}

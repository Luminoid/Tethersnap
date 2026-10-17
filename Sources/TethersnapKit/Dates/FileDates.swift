import Foundation

/// The file-system dates Finder shows (Created / Modified).
enum FileDates {
    /// Sets both the creation and the modification date of the item at `url`.
    static func set(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }
}

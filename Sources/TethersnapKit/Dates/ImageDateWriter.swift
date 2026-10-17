import CoreGraphics
import Foundation
import ImageIO

/// Reads and writes the capture date of still images through ImageIO, copying the
/// encoded bitstream untouched (`CGImageDestinationCopyImageSource`): no re-encode.
enum ImageDateWriter {
    /// Metadata paths that carry a capture date, most specific first.
    /// Capture-date tags, in precedence order. TIFF `DateTime` (EXIF 0x0132) is
    /// deliberately absent: it is the file's modification time, which ImageIO
    /// surfaces as `xmp:ModifyDate`, and a file carrying only that (the
    /// original Switch's JPEGs) has no capture date yet, so it gains one.
    private static let datePaths = ["exif:DateTimeOriginal", "exif:DateTimeDigitized", "xmp:CreateDate", "photoshop:DateCreated"]

    /// The embedded capture date, or nil when no date tag is present.
    static func embeddedDate(at url: URL) throws -> Date? {
        let source = try openSource(url)
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            let offset = stringValue(metadata, "exif:OffsetTimeOriginal").flatMap(MetadataDate.offsetZone) ?? .current
            for path in datePaths {
                if let value = stringValue(metadata, path), !value.isEmpty {
                    return MetadataDate.parse(value, assuming: offset)
                }
            }
        }
        // Formats whose metadata ImageIO exposes only as a property dictionary.
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String, !value.isEmpty {
            return MetadataDate.parse(value)
        }
        return nil
    }

    /// Stamps `date` into the EXIF, TIFF, XMP, and Photoshop date tags of the image at `url`,
    /// rewriting the file in place through a sibling temp file.
    static func write(_ date: Date, to url: URL) throws {
        let source = try openSource(url)
        guard let type = CGImageSourceGetType(source) else {
            throw DateFixError.imageRewriteFailed("unknown image type")
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap(CGImageMetadataCreateMutableCopy) ?? CGImageMetadataCreateMutable()
        // A false return means the prefix is already registered.
        _ = CGImageMetadataRegisterNamespaceForPrefix(metadata, kCGImageMetadataNamespaceExif, kCGImageMetadataPrefixExif, nil)
        _ = CGImageMetadataRegisterNamespaceForPrefix(metadata, kCGImageMetadataNamespaceTIFF, kCGImageMetadataPrefixTIFF, nil)
        _ = CGImageMetadataRegisterNamespaceForPrefix(metadata, kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataPrefixXMPBasic, nil)
        _ = CGImageMetadataRegisterNamespaceForPrefix(metadata, kCGImageMetadataNamespacePhotoshop, kCGImageMetadataPrefixPhotoshop, nil)

        let exif = MetadataDate.exifString(date)
        let iso = MetadataDate.isoString(date, offsetColon: true)
        let tags: [(path: String, value: String, required: Bool)] = [
            ("exif:DateTimeOriginal", exif, true),
            ("exif:DateTimeDigitized", exif, true),
            ("tiff:DateTime", exif, true),
            ("xmp:CreateDate", iso, true),
            ("photoshop:DateCreated", iso, true),
            ("exif:OffsetTimeOriginal", MetadataDate.offsetString(for: date, colon: true), false),
        ]
        for tag in tags {
            let set = CGImageMetadataSetValueWithPath(metadata, nil, tag.path as CFString, tag.value as CFString)
            if !set, tag.required {
                throw DateFixError.imageRewriteFailed("could not set \(tag.path)")
            }
        }

        try AtomicRewrite.replace(url) { temp in
            guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else {
                throw DateFixError.imageRewriteFailed("could not create a destination for \(type)")
            }
            let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
            var error: Unmanaged<CFError>?
            guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
                let detail = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown ImageIO error"
                throw DateFixError.imageRewriteFailed(detail)
            }
        }
    }

    // MARK: - Helpers

    private static func openSource(_ url: URL) throws -> CGImageSource {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options), CGImageSourceGetCount(source) > 0 else {
            throw DateFixError.imageRewriteFailed("unreadable image")
        }
        return source
    }

    private static func stringValue(_ metadata: CGImageMetadata, _ path: String) -> String? {
        CGImageMetadataCopyStringValueWithPath(metadata, nil, path as CFString) as String?
    }
}

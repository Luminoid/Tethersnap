import CoreTransferable
import Foundation
import TethersnapKit
import UniformTypeIdentifiers

/// Drag-out payload: Finder receives a file promise and the captures download
/// lazily when the drop lands. Dragging one item promises a file of its real
/// type (derived from the filename, so PNG is not advertised as JPEG; anything
/// outside the explicit set, such as WebM or camera RAW, goes as plain data);
/// dragging a multi-selection promises one folder holding everything.
struct DraggedCapture: Transferable {
    let items: [CaptureItem]
    let service: SourceService
    /// The view mode at drag start: grouped means the dropped folder holds one
    /// subfolder per source folder, like an export.
    let groupedByFolder: Bool

    /// Types with a representation of their own, in declaration order below.
    /// `.heif` is separate because `UTType.heif` does not conform to `.heic`.
    private static let explicitTypes: [UTType] = [.jpeg, .png, .heic, .heif, .tiff, .mpeg4Movie, .quickTimeMovie]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .folder) { payload in
            try await SentTransferredFile(payload.temporaryExport(), allowAccessingOriginalFile: true)
        }
        .exportingCondition { $0.items.count > 1 }
        .suggestedFileName { _ in L10n.dragFolderName }

        single(.jpeg)
        single(.png)
        single(.heic)
        single(.heif)
        single(.tiff)
        single(.mpeg4Movie)
        single(.quickTimeMovie)

        FileRepresentation(exportedContentType: .data) { payload in
            try await SentTransferredFile(payload.temporaryExport(), allowAccessingOriginalFile: true)
        }
        .exportingCondition { $0.singleItemIsOther }
        .suggestedFileName { $0.items.first?.exportFilename }
    }

    /// One single-item representation: offered only when the dragged file
    /// really is of `type`, named after its export filename.
    private static func single(_ type: UTType) -> some TransferRepresentation<Self> {
        FileRepresentation(exportedContentType: type) { payload in
            try await SentTransferredFile(payload.temporaryExport(), allowAccessingOriginalFile: true)
        }
        .exportingCondition { $0.singleItemConforms(to: type) }
        .suggestedFileName { $0.items.first?.exportFilename }
    }

    private var singleItemType: UTType? {
        guard items.count == 1, let item = items.first else { return nil }
        return UTType(filenameExtension: (item.filename as NSString).pathExtension.lowercased())
    }

    /// The declared content type must match the real file; a mislabeled
    /// promise makes receivers mis-decode or rename the drop.
    private func singleItemConforms(to type: UTType) -> Bool {
        singleItemType?.conforms(to: type) ?? false
    }

    private var singleItemIsOther: Bool {
        items.count == 1 && !Self.explicitTypes.contains { singleItemConforms(to: $0) }
    }

    private func temporaryExport() async throws -> URL {
        try await service.exportToTemporary(items, groupedByFolder: groupedByFolder)
    }
}

import CoreTransferable
import Foundation
import TethersnapKit
import UniformTypeIdentifiers

/// Drag-out payload: Finder receives a file promise and the captures download
/// lazily when the drop lands. Dragging one item promises a file of its real
/// type (derived from the filename, so PNG is not advertised as JPEG); dragging
/// a multi-selection promises one folder holding everything.
struct DraggedCapture: Transferable {
    let items: [CaptureItem]
    let service: DeviceService

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .folder) { payload in
            try await SentTransferredFile(payload.temporaryExport(), allowAccessingOriginalFile: true)
        }
        .exportingCondition { $0.items.count > 1 }
        .suggestedFileName { _ in L10n.dragFolderName }

        FileRepresentation(exportedContentType: .jpeg) { payload in
            try await SentTransferredFile(payload.temporaryExport(), allowAccessingOriginalFile: true)
        }
        .exportingCondition { $0.singleItemConforms(to: .jpeg) }
        .suggestedFileName { $0.items.first?.exportFilename }

        FileRepresentation(exportedContentType: .png) { payload in
            try await SentTransferredFile(payload.temporaryExport(), allowAccessingOriginalFile: true)
        }
        .exportingCondition { $0.singleItemConforms(to: .png) }
        .suggestedFileName { $0.items.first?.exportFilename }

        FileRepresentation(exportedContentType: .mpeg4Movie) { payload in
            try await SentTransferredFile(payload.temporaryExport(), allowAccessingOriginalFile: true)
        }
        .exportingCondition { $0.singleItemConforms(to: .mpeg4Movie) }
        .suggestedFileName { $0.items.first?.exportFilename }

        FileRepresentation(exportedContentType: .quickTimeMovie) { payload in
            try await SentTransferredFile(payload.temporaryExport(), allowAccessingOriginalFile: true)
        }
        .exportingCondition { $0.singleItemConforms(to: .quickTimeMovie) }
        .suggestedFileName { $0.items.first?.exportFilename }
    }

    /// The declared content type must match the real file; a mislabeled
    /// promise makes receivers mis-decode or rename the drop.
    private func singleItemConforms(to type: UTType) -> Bool {
        guard items.count == 1, let item = items.first,
              let itemType = UTType(filenameExtension: (item.filename as NSString).pathExtension.lowercased())
        else { return false }
        return itemType.conforms(to: type)
    }

    private func temporaryExport() async throws -> URL {
        try await service.exportToTemporary(items)
    }
}

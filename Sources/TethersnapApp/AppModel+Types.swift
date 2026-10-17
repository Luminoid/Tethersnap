import Foundation
import TethersnapKit

/// The value types the model publishes: filters, grouping, sort orders, and
/// the progress/summary records the status bar renders.
extension AppModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case photos
        case videos

        var id: String { rawValue }

        var kind: CaptureItem.Kind? {
            switch self {
            case .all: nil
            case .photos: .image
            case .videos: .video
            }
        }

        var displayName: String {
            switch self {
            case .all: L10n.filterAll
            case .photos: L10n.filterPhotos
            case .videos: L10n.filterVideos
            }
        }
    }

    enum ViewMode: String, CaseIterable, Identifiable {
        /// One flat grid of everything.
        case all
        /// Sections per source folder (per game on a console or PS5 drive,
        /// per `100CANON` folder on a camera card).
        case byFolder

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: L10n.viewAll
            case .byFolder: L10n.viewByFolder
            }
        }
    }

    /// One by-folder section: the folder name and its visible items.
    struct FolderGroup: Identifiable, Equatable {
        let name: String
        let items: [CaptureItem]
        var id: String { name }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case newestFirst
        case oldestFirst
        case largestFirst

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .newestFirst: L10n.sortNewest
            case .oldestFirst: L10n.sortOldest
            case .largestFirst: L10n.sortLargest
            }
        }

        func sorted(_ items: [CaptureItem]) -> [CaptureItem] {
            switch self {
            // The kit's comparator, shared with the CLI listing, so the two
            // never disagree on ties or undated items.
            case .newestFirst: items.sortedNewestFirst()
            case .oldestFirst: items.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            case .largestFirst: items.sorted { $0.sizeInBytes > $1.sizeInBytes }
            }
        }
    }

    struct ExportProgress: Equatable {
        var completed: Int
        var total: Int
        var currentFraction: Double

        var overallFraction: Double {
            guard total > 0 else { return 0 }
            return min(1, (Double(completed) + currentFraction) / Double(total))
        }
    }

    struct DateFixProgress: Equatable {
        var completed: Int
        var total: Int

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(completed) / Double(total))
        }
    }

    /// One line for the status bar plus a folder to reveal; shared by exports
    /// and date-fix runs. `detail` is the chip's tooltip (the files a date fix
    /// could not update).
    struct ExportSummary: Equatable {
        let message: String
        let folder: URL?
        var detail: String?
    }
}

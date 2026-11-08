import Foundation

/// One source folder and how many of its items count: a game on a Switch 2
/// or a PS5 drive, a `100CANON` folder on a camera card, a date folder on a
/// Switch SD card.
public struct CaptureFolder: Sendable, Equatable, Identifiable {
    /// The items' `folderName`; nil for the items enumerated without a
    /// folder, which the app groups as "Other".
    public let name: String?
    public let count: Int

    public var id: String? { name }

    public init(name: String?, count: Int) {
        self.name = name
        self.count = count
    }
}

public extension [CaptureItem] {
    /// One entry per folder, the folder holding the newest capture first, so
    /// the game played last tops a console's list. Undated folders follow the
    /// dated ones, ties go by name, and the items without a folder come last.
    /// `count` counts only items of `kind` (nil: all), but the entries and
    /// their order do not depend on it: a filter changes the numbers, never
    /// moves a row. Shared by the app's sidebar and its folder scope.
    func folders(counting kind: CaptureItem.Kind? = nil) -> [CaptureFolder] {
        let newest = Dictionary(grouping: self, by: \.folderName)
            .mapValues { $0.compactMap(\.date).max() ?? .distantPast }
        let counts = Dictionary(grouping: matching(kind), by: \.folderName).mapValues(\.count)
        return newest
            .sorted { lhs, rhs in
                switch (lhs.key, rhs.key) {
                case (nil, _): false
                case (_, nil): true
                case let (lhsName?, rhsName?):
                    lhs.value == rhs.value
                        ? lhsName.localizedStandardCompare(rhsName) == .orderedAscending
                        : lhs.value > rhs.value
                }
            }
            .map { CaptureFolder(name: $0.key, count: counts[$0.key] ?? 0) }
    }

    /// The items in folder `name`, in their current order; nil keeps the
    /// items enumerated without a folder (the app's "Other"). Shared by the
    /// app's sidebar and its folder scope.
    func inFolder(_ name: String?) -> [CaptureItem] {
        filter { $0.folderName == name }
    }
}

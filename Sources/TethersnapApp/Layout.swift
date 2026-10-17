import CoreGraphics
import SwiftUI

/// Minimal token set (4pt grid); LumiKit is UIKit-only, so the Mac app keeps
/// its own small palette instead of magic numbers.
enum Layout {
    static let spacingXXS: CGFloat = 2
    static let spacingXS: CGFloat = 4
    static let spacingSmall: CGFloat = 8
    static let spacingMedium: CGFloat = 12
    static let spacingLarge: CGFloat = 16
    static let spacingXL: CGFloat = 20

    static let thumbnailSide: CGFloat = 200
    /// Cell placeholder shape; console captures are 16:9, camera frames letterbox into it.
    static let thumbnailAspectRatio: CGFloat = 16 / 9
    static let cornerRadius: CGFloat = 8
    static let selectionLineWidth: CGFloat = 3
    static let hoverLineWidth: CGFloat = 1

    /// Icon point sizes: selection checkmark / video badge / cell placeholder / state icons.
    static let iconSmall: CGFloat = 18
    static let iconMedium: CGFloat = 24
    static let iconPlaceholder: CGFloat = 28
    static let iconLarge: CGFloat = 44

    static let badgeOpacity: Double = 0.9
    static let badgeShadowRadius: CGFloat = 2
    static let statusDotSize: CGFloat = 8

    /// Rubber-band (drag-to-select) rectangle.
    static let rubberBandFillOpacity: Double = 0.15
    static let rubberBandStrokeOpacity: Double = 0.6
    static let rubberBandLineWidth: CGFloat = 1
    /// Pointer travel before a drag counts as a rubber band, not a click.
    static let rubberBandThreshold: CGFloat = 4

    static let textColumnWidth: CGFloat = 480
    static let progressBarWidth: CGFloat = 240
    static let previewMinWidth: CGFloat = 640
    static let previewMinHeight: CGFloat = 360
    static let windowMinWidth: CGFloat = 820
    static let windowMinHeight: CGFloat = 480
    static let windowDefaultSize = CGSize(width: 1040, height: 680)
    static let settingsWidth: CGFloat = 440
    static let sheetWidth: CGFloat = 440
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarIdealWidth: CGFloat = 220

    // MARK: - Colors

    /// Failure icons (open failed, preview failed): a warning, not an error red,
    /// because Retry is one click away.
    static let warningColor: Color = .orange
    /// Glyphs drawn over a thumbnail (video badge, selection checkmark).
    static let overlayGlyphColor: Color = .white
    /// Status dot per phase.
    static let statusIdleColor: Color = .gray
    static let statusBusyColor: Color = .orange
    static let statusReadyColor: Color = .green
    static let statusFailedColor: Color = .red
}

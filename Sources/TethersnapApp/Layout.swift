import CoreGraphics

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
    static let windowMinWidth: CGFloat = 720
    static let windowMinHeight: CGFloat = 480
    static let settingsWidth: CGFloat = 440
}

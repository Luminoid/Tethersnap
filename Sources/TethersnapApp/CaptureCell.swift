import AppKit
import SwiftUI
import TethersnapKit

/// One grid cell: thumbnail, date line, kind and size; click selects,
/// double-click previews, drag exports.
struct CaptureCell: View {
    @Environment(AppModel.self) private var model
    let item: CaptureItem
    let isSelected: Bool
    let onExport: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacingSmall) {
            ZStack {
                RoundedRectangle(cornerRadius: Layout.cornerRadius)
                    .fill(.quaternary)
                    .aspectRatio(Layout.thumbnailAspectRatio, contentMode: .fit)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
                } else {
                    Image(systemName: item.kind == .video ? "film" : "photo")
                        .font(.system(size: Layout.iconPlaceholder))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: Layout.iconMedium))
                        .foregroundStyle(Layout.overlayGlyphColor.opacity(Layout.badgeOpacity))
                        .shadow(radius: Layout.badgeShadowRadius)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: Layout.cornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: Layout.selectionLineWidth)
                } else if isHovering {
                    RoundedRectangle(cornerRadius: Layout.cornerRadius)
                        .strokeBorder(.tertiary, lineWidth: Layout.hoverLineWidth)
                }
            }
            .overlay(alignment: .topLeading) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Layout.iconSmall))
                        .foregroundStyle(Layout.overlayGlyphColor, Color.accentColor)
                        .padding(Layout.spacingXS)
                        .accessibilityHidden(true)
                }
            }
            VStack(alignment: .leading, spacing: Layout.spacingXXS) {
                Text(item.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? item.filename)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(L10n.kindName(item)) · \(CaptureFormat.size(item.sizeInBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: CellFramesKey.self, value: [item.id: geo.frame(in: .named(GridSpace.name))])
            }
        }
        .onHover { isHovering = $0 }
        .gesture(TapGesture(count: 2).onEnded {
            model.preview(item)
        })
        .simultaneousGesture(TapGesture().onEnded {
            model.select(item, modifiers: NSEvent.modifierFlags)
        })
        .draggable(model.makeDragPayload(for: item))
        .contextMenu {
            Button(L10n.preview) { model.preview(item) }
            Button(L10n.menuExport) { onExport() }
            if let url = item.fileURL {
                Divider()
                Button(L10n.showItemInFinder) { model.revealInFinder(url) }
            }
        }
        .task(id: ThumbnailRequest(id: item.id, generation: model.thumbnailGeneration)) {
            thumbnail = await model.thumbnail(for: item)
        }
        .help(item.filename)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L10n.kindName(item)), \(item.filename)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text(L10n.preview)) { model.preview(item) }
        .accessibilityAction(named: Text(L10n.menuExport)) { onExport() }
    }
}

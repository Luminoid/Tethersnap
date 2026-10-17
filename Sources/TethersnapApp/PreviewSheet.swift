import AppKit
import SwiftUI
import TethersnapKit

/// Preview for a PTP item, whose bytes live on the device: images are
/// fetched and downsampled on demand, videos have nothing to show until they
/// are exported. File-backed items use Quick Look instead (see `ContentView`).
struct PreviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: CaptureItem

    private enum LoadState {
        case loading
        case loaded(NSImage)
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: Layout.spacingMedium) {
            Group {
                if item.kind == .video {
                    videoContent
                } else {
                    imageContent
                }
            }
            .frame(minWidth: Layout.previewMinWidth, minHeight: Layout.previewMinHeight)
            HStack {
                Text(item.filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(item.filename)
                Spacer()
                Button(L10n.close) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Layout.spacingLarge)
        .task(id: attempt) { await load() }
    }

    private var videoContent: some View {
        VStack(spacing: Layout.spacingSmall) {
            Image(systemName: "film")
                .font(.system(size: Layout.iconLarge))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.previewVideoHint)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var imageContent: some View {
        switch state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .accessibilityLabel(item.filename)
        case let .failed(message):
            VStack(spacing: Layout.spacingSmall) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: Layout.iconLarge))
                    .foregroundStyle(Layout.warningColor)
                    .accessibilityHidden(true)
                Text(message)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: Layout.textColumnWidth)
                Button(L10n.retry) { attempt += 1 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        guard item.kind == .image else { return }
        state = .loading
        do {
            state = try await .loaded(model.fullImage(for: item))
        } catch is CancellationError {
            // Sheet dismissed mid-load; nothing to show.
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

import SwiftUI

/// The detail pane while nothing is open: what to connect, one hint per kind
/// of source (console names in descriptive use only), and a folder shortcut.
struct NoSourceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label(L10n.noSourceTitle, systemImage: "cable.connector")
        } description: {
            VStack(spacing: Layout.spacingLarge) {
                Text(L10n.noSourceMessage)
                VStack(alignment: .leading, spacing: Layout.spacingSmall) {
                    hint(L10n.noSourceHintSwitch, systemImage: "gamecontroller")
                    hint(L10n.noSourceHintCamera, systemImage: "camera")
                    hint(L10n.noSourceHintDrive, systemImage: "externaldrive")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: Layout.textColumnWidth, alignment: .leading)
            }
        } actions: {
            Button(L10n.menuOpenFolder) {
                model.openFolderCommand()
            }
            .disabled(model.isExporting || model.isPickingFolder)
        }
    }

    private func hint(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

/// Shown while a source opens; a USB handshake can take many seconds, so
/// Cancel goes back to no source without waiting for it.
struct OpeningView: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        VStack(spacing: Layout.spacingLarge) {
            ProgressView()
            Text(L10n.opening(name))
                .font(.title3)
            Button(L10n.cancel) {
                model.cancelOpen()
            }
            .keyboardShortcut(.cancelAction)
            .help(L10n.helpCancelOpening)
        }
        .padding(Layout.spacingXL)
    }
}

struct FailedView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(L10n.failedTitle)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Layout.warningColor)
            }
        } description: {
            Text(message)
                .frame(maxWidth: Layout.textColumnWidth)
        } actions: {
            Button(L10n.retry) {
                model.beginRetry()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

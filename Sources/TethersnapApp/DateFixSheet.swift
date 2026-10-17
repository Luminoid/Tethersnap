import SwiftUI
import TethersnapKit

/// Options for one "Fix Dates from Filenames" run on the folder the user
/// picked: subfolders on by default, overwriting embedded dates off.
struct DateFixSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var includeSubfolders = true
    @State private var overwrite = false

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacingLarge) {
            Text(L10n.dateFixTitle)
                .font(.title2)
            Text(L10n.dateFixExplainer)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(L10n.dateFixFolder) {
                HStack(spacing: Layout.spacingSmall) {
                    Text(folderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folderPath)
                    // Presents the folder panel as a sheet on this sheet, which
                    // macOS supports; dismissing first would need timing hacks.
                    Button(L10n.dateFixChangeFolder) {
                        model.chooseDateFixFolder()
                    }
                    .controlSize(.small)
                    .disabled(model.isPickingFolder)
                }
            }
            Toggle(L10n.dateFixIncludeSubfolders, isOn: $includeSubfolders)
            VStack(alignment: .leading, spacing: Layout.spacingXXS) {
                Toggle(L10n.dateFixOverwrite, isOn: $overwrite)
                Text(L10n.dateFixOverwriteHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L10n.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.dateFixRun) {
                    model.beginDateFix(options: CaptureDateFixer.Options(overwrite: overwrite, recursive: includeSubfolders))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Layout.spacingXL)
        .frame(width: Layout.sheetWidth)
    }

    private var folderPath: String {
        model.dateFixFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
    }
}

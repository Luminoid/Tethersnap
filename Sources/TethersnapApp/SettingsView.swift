import SwiftUI

/// The one persisted preference: the remembered export folder (set by the
/// first export; ⌘⇧E reuses it). Settings makes it inspectable and clearable.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            LabeledContent(L10n.settingsExportFolder) {
                VStack(alignment: .trailing, spacing: Layout.spacingSmall) {
                    Text(model.rememberedExportFolder?.path ?? L10n.settingsNoFolder)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.rememberedExportFolder?.path ?? L10n.settingsNoFolder)
                    HStack {
                        // The same panel as the export flow (preset to the
                        // current folder, can create one); fileImporter can do
                        // neither. Unsandboxed app: the URL is a plain path.
                        Button(L10n.chooseFolder) { model.chooseRememberedFolder() }
                            .disabled(model.isPickingFolder)
                        Button(L10n.settingsClear) { model.clearRememberedFolder() }
                            .disabled(model.rememberedExportFolder == nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.settingsWidth)
    }
}

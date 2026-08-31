import SwiftUI

/// The one persisted preference: the remembered export folder (set by the
/// first export; ⌘⇧E reuses it). Settings makes it inspectable and clearable.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var pickerPresented = false

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
                        Button(L10n.chooseFolder) { pickerPresented = true }
                        Button(L10n.settingsClear) { model.clearRememberedFolder() }
                            .disabled(model.rememberedExportFolder == nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.settingsWidth)
        .fileImporter(isPresented: $pickerPresented, allowedContentTypes: [.folder]) { result in
            guard case let .success(url) = result else { return }
            model.rememberFolder(url)
        }
    }
}

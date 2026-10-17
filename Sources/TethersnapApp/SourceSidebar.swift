import SwiftUI
import TethersnapKit

/// Devices, drives, and opened folders; selecting a row opens it.
struct SourceSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return List(selection: $model.activeSourceID) {
            if !model.deviceSources.isEmpty {
                Section(L10n.sidebarDevices) {
                    ForEach(model.deviceSources) { row($0) }
                }
            }
            if !model.volumeSources.isEmpty {
                Section(L10n.sidebarDrives) {
                    ForEach(model.volumeSources) { row($0) }
                }
            }
            if !model.folderSources.isEmpty {
                Section(L10n.sidebarFolders) {
                    ForEach(model.folderSources) { descriptor in
                        row(descriptor)
                            .contextMenu {
                                Button(L10n.sidebarRemoveFolder) { model.removeFolder(descriptor) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.sources.isEmpty {
                Text(L10n.sidebarEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(Layout.spacingLarge)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.openFolderCommand()
            } label: {
                Label(L10n.menuOpenFolder, systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderless)
            .disabled(model.isExporting || model.isPickingFolder)
            .padding(Layout.spacingMedium)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ descriptor: CaptureSourceDescriptor) -> some View {
        Label(descriptor.name, systemImage: descriptor.kind.symbolName)
            .lineLimit(1)
            .help(descriptor.detail ?? descriptor.name)
    }
}

// MARK: - Symbols

extension CaptureSourceDescriptor.Kind {
    var symbolName: String {
        switch self {
        case .console: "gamecontroller"
        case .camera: "camera"
        case .ptpDevice: "iphone"
        case .volume: "externaldrive"
        case .folder: "folder"
        }
    }
}

extension AppModel.ViewMode {
    var symbolName: String {
        switch self {
        case .all: "square.grid.2x2"
        case .byFolder: "folder"
        }
    }
}

import QuickLook
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        return NavigationSplitView {
            SourceSidebar()
                .navigationSplitViewColumnWidth(min: Layout.sidebarMinWidth, ideal: Layout.sidebarIdealWidth)
        } detail: {
            DetailView()
        }
        .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
        .task { model.start() }
        // PTP items: the custom sheet (their bytes are fetched on demand).
        .sheet(item: $model.previewItem) { item in
            PreviewSheet(item: item)
        }
        // File-backed items: Quick Look plays videos and renders RAW natively.
        .quickLookPreview($model.quickLookURL)
        .sheet(isPresented: $model.dateFixSheetPresented) {
            DateFixSheet()
        }
    }
}

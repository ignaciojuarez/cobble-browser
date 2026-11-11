import AppKit
import SwiftUI

struct DownloadFolderSettingsView: View {
    @Bindable var preferences: BrowserPreferences

    var body: some View {
        Section("Downloads") {
            LabeledContent {
                if preferences.downloadFolderName != nil {
                    Button("Use Downloads") { preferences.setDownloadFolder(nil) }
                }
                Button("Choose Folder…", action: chooseFolder)
            } label: {
                Label {
                    Text(verbatim: preferences.downloadFolderName ?? String(localized: "Downloads"))
                    Text("Cobble asks where to save each download, starting in this folder.")
                } icon: {
                    Image(systemName: "folder.fill").foregroundStyle(.blue)
                }
            }
        }
        .disabled(preferences.readError != nil)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose Folder")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        preferences.setDownloadFolder(folder)
    }
}

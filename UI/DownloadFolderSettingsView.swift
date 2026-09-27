import AppKit
import SwiftUI

struct DownloadFolderSettingsView: View {
    @Bindable var preferences: BrowserPreferences

    var body: some View {
        SettingsGroup("Download Folder") {
            SettingsRow("Default folder", detailVerbatim: preferences.downloadFolderName.map {
                String(format: String(localized: "Downloads open in %@ until you choose another location."), $0)
            } ?? String(localized: "Each download opens Save Download in Downloads.")) {
                Button("Choose Folder…") { chooseFolder() }
                if preferences.downloadFolderName != nil {
                    Button("Use Downloads") { preferences.setDownloadFolder(nil) }
                }
            }
            if let error = preferences.errorMessage { Text(error).font(.callout).foregroundStyle(.orange) }
        }
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

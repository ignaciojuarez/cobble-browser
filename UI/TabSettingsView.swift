import SwiftUI

struct TabSettingsView: View {
    @Bindable var preferences: BrowserPreferences
    var body: some View {
        SettingsGroup("Tabs") {
            SettingsRow("Open new tabs beside the active tab", detail: "When a pin or favorite is selected, new tabs go at the end of the temporary tabs.") {
                Toggle("Open new tabs beside the active tab", isOn: Binding(
                    get: { preferences.newTabsNextToActive },
                    set: { preferences.setNewTabsNextToActive($0) }
                )).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            SettingsRow("Cycle through all recently used tabs", detail: "Hold Control and press Tab to move through recent tabs. Release Control to finish. Your custom shortcuts still apply.") {
                Toggle("Cycle through all recently used tabs", isOn: Binding(
                    get: { preferences.cycleAllRecentTabs },
                    set: { preferences.setCycleAllRecentTabs($0) }
                )).labelsHidden().toggleStyle(.switch)
            }
            if let message = preferences.errorMessage { Text(message).foregroundStyle(.orange) }
        }
    }
}

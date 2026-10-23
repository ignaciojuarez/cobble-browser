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
            Divider()
            SettingsRow("Sleep inactive tabs", detail: "Unloads tabs you have not looked at for a while to save memory; they reload, with their back and forward history, when you return. Tabs playing audio or using the camera or microphone stay awake. When memory runs low, Cobble also sleeps hidden tabs. Unsaved form input in a sleeping tab is lost.") {
                Picker("Sleep inactive tabs", selection: Binding(
                    get: { preferences.tabSleepMinutes ?? 0 },
                    set: { preferences.setTabSleepMinutes($0 == 0 ? nil : $0) }
                )) {
                    Text("Never").tag(0)
                    Text("After 15 minutes").tag(15)
                    Text("After 30 minutes").tag(30)
                    Text("After 1 hour").tag(60)
                    Text("After 2 hours").tag(120)
                }.labelsHidden().fixedSize()
            }
            if let message = preferences.errorMessage { Text(message).foregroundStyle(.orange) }
        }
    }
}

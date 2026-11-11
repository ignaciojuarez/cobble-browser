import SwiftUI

struct TabSettingsView: View {
    @Bindable var preferences: BrowserPreferences
    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { preferences.newTabsNextToActive },
                                     set: { preferences.setNewTabsNextToActive($0) })) {
                    Text("Open new tabs beside the active tab")
                    Text("When a pin or favorite is selected, new tabs go at the end of the temporary tabs.")
                }
                Toggle(isOn: Binding(get: { preferences.cycleAllRecentTabs },
                                     set: { preferences.setCycleAllRecentTabs($0) })) {
                    Text("Cycle through all recently used tabs")
                    Text("Hold Control and press Tab to move through recent tabs. Release Control to finish. Your custom shortcuts still apply.")
                }
            }
            Section {
                Picker(selection: Binding(get: { preferences.tabSleepMinutes ?? 0 },
                                          set: { preferences.setTabSleepMinutes($0 == 0 ? nil : $0) })) {
                    Text("Never").tag(0)
                    Text("After 15 minutes").tag(15)
                    Text("After 30 minutes").tag(30)
                    Text("After 1 hour").tag(60)
                    Text("After 2 hours").tag(120)
                } label: {
                    Text("Sleep inactive tabs")
                    Text("Unloads tabs you haven’t looked at to save memory. They reload, with their history, when you return.")
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("Tabs playing audio or using the camera or microphone stay awake. When memory runs low, Cobble also sleeps hidden tabs. Unsaved form input in a sleeping tab is lost.")
            }
            SettingsMessage(text: preferences.errorMessage)
        }
        .disabled(preferences.readError != nil)
    }
}

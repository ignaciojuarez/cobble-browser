import SwiftUI

struct SyncSettingsView: View {
    @Bindable var app: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { app.sync.enabled }, set: { app.sync.setEnabled($0) })) {
                    Label {
                        Text("Sync across devices")
                        Text("Use your iCloud account to keep selected browser data on your Macs. Each Mac can choose its own web engine and window layout.")
                    } icon: {
                        Image(systemName: "icloud.fill").foregroundStyle(.blue)
                    }
                }
                if app.sync.enabled {
                    LabeledContent {
                        Button("Sync Now") { Task { await app.sync.syncNow() } }
                            .disabled(app.sync.isSyncing)
                    } label: {
                        Text(verbatim: app.sync.status)
                        if let lastSync = app.sync.lastSync {
                            Text(String(format: String(localized: "Last synced: %@"),
                                        lastSync.formatted(date: .abbreviated, time: .shortened)))
                        }
                    }
                }
                if let error = app.sync.errorMessage {
                    Text(verbatim: error).foregroundStyle(.orange)
                }
            } footer: {
                Text("Turning sync off on this Mac stops transfers. It does not erase data from iCloud or other devices.")
            }
            Section {
                ForEach(SyncModule.allCases, id: \.self) { module in
                    Toggle(isOn: Binding(get: { app.sync.modules.contains(module) },
                                         set: { app.sync.setModule(module, enabled: $0) })) {
                        Text(verbatim: module.title)
                        Text(verbatim: module.detail)
                    }
                    .disabled(module.requiresOrganization && !app.sync.modules.contains(.organization))
                }
            } header: {
                Text("Choose what syncs")
            } footer: {
                Text("Passwords, cookies, private tabs, and downloads stay on this Mac.")
            }
        }
    }
}

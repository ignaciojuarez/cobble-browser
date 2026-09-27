import SwiftUI

struct SyncSettingsView: View {
    @Bindable var app: AppModel

    var body: some View {
        SettingsPage {
            SettingsGroup("iCloud Sync") {
                SettingsRow("Sync across devices", detail: "Use your iCloud account to keep selected browser data on your Macs. Each Mac can choose its own web engine and window layout.") {
                    Toggle("Sync across devices", isOn: Binding(
                        get: { app.sync.enabled },
                        set: { app.sync.setEnabled($0) }
                    ))
                    .labelsHidden().toggleStyle(.switch)
                }
                Text("Turning sync off on this Mac stops transfers. It does not erase data from iCloud or other devices.")
                    .font(.callout).foregroundStyle(.secondary)
                if app.sync.enabled {
                    Divider()
                    HStack {
                        Text(verbatim: app.sync.status)
                            .foregroundStyle(app.sync.errorMessage == nil ? Color.secondary : Color.orange)
                        Spacer()
                        Button("Sync Now") { Task { await app.sync.syncNow() } }
                            .disabled(app.sync.isSyncing)
                    }
                    if let lastSync = app.sync.lastSync {
                        Text(String(format: String(localized: "Last synced: %@"),
                                    lastSync.formatted(date: .abbreviated, time: .shortened)))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error = app.sync.errorMessage {
                    Text(verbatim: error).font(.callout).foregroundStyle(.orange)
                }
            }

            SettingsGroup("Choose what syncs") {
                Text("Bookmarks, tabs, history, site zoom, and content blockers require Spaces, pins, and favorites.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(SyncModule.allCases, id: \.self) { module in
                    if module != .organization { Divider() }
                    SettingsRow(verbatim: module.title, detail: module.detail) {
                        Toggle(module.title, isOn: Binding(
                            get: { app.sync.modules.contains(module) },
                            set: { app.sync.setModule(module, enabled: $0) }
                        ))
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(module.requiresOrganization && !app.sync.modules.contains(.organization))
                    }
                }
                Text("Passwords, cookies, private tabs, and downloads stay on this Mac.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

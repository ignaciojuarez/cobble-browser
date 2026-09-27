import AppKit
import SwiftUI

struct ProfileSettingsView: View {
    @Bindable var app: AppModel
    @State private var newName = ""
    @State private var editingID: UUID?
    @State private var editName = ""
    @State private var deleting = false
    @State private var message: String?

    var body: some View {
        SettingsPage {
            SettingsGroup("Profiles") {
                Text("Profiles keep website logins, history, bookmarks, saved permissions, spaces, pins, favorites, and normal windows separate. Private windows are never saved.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("New profile name", text: $newName).textFieldStyle(.roundedBorder).onSubmit { create() }
                    Button("Add", action: create).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || deleting)
                }
                ForEach(app.profiles) { profile in
                    Divider()
                    if editingID == profile.id {
                        HStack {
                            TextField("Profile name", text: $editName).textFieldStyle(.roundedBorder).onSubmit { save(profile) }
                            Button("Save") { save(profile) }.disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Cancel") { editingID = nil }
                        }
                    } else {
                        SettingsRow(verbatim: profile.displayedName, detail: detail(for: profile)) {
                            Button("Open") { _ = app.selectProfile(profile.id) }
                            if profile.id == Profile.defaultID {
                                Text("Default").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            } else {
                                Button("Rename") { editingID = profile.id; editName = profile.name }
                                Button("Delete…", role: .destructive) { confirmDelete(profile) }.disabled(deleting)
                            }
                        }
                    }
                }
                if let message { Text(message).font(.callout).foregroundStyle(.orange) }
            }
        }
    }

    private func detail(for profile: Profile) -> String {
        profile.id == Profile.defaultID
            ? String(localized: "Uses your existing default WebKit website data. It cannot be deleted.")
            : String(localized: "Uses a separate persistent website-data store. Opening it focuses an existing window or creates a new empty window.")
    }

    private func create() {
        guard app.createProfile(name: newName) != nil else { return }
        newName = ""
        message = nil
    }

    private func save(_ profile: Profile) {
        guard app.renameProfile(id: profile.id, name: editName) else { return }
        editingID = nil
        message = nil
    }

    private func confirmDelete(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = String(format: String(localized: "Delete “%@”?"), profile.name)
        alert.informativeText = String(localized: "This closes this profile’s windows and permanently removes its website data, extensions, content-blocking rules, history, bookmarks, saved permissions, spaces, pins, favorites, and normal-window records. Unsaved page content will be lost. Finish or cancel downloads first. If cleanup fails, some data may already be removed.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleting = true
        Task {
            message = await app.deleteProfile(profile.id) ?? String(localized: "Profile deleted.")
            deleting = false
        }
    }
}

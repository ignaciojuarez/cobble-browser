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
        Form {
            Section {
                ForEach(app.profiles) { profile in
                    if editingID == profile.id {
                        HStack {
                            TextField("Profile name", text: $editName).labelsHidden().textFieldStyle(.roundedBorder).onSubmit { save(profile) }
                            Button("Save") { save(profile) }.disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Cancel") { editingID = nil }
                        }
                    } else {
                        LabeledContent {
                            Button("Open") { _ = app.selectProfile(profile.id) }
                            if profile.id != Profile.defaultID {
                                Menu {
                                    Button("Rename") { editingID = profile.id; editName = profile.name }
                                    Button("Delete…", role: .destructive) { confirmDelete(profile) }.disabled(deleting)
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                                .accessibilityLabel(String(format: String(localized: "More actions for %@"), profile.displayedName))
                            }
                        } label: {
                            Label {
                                HStack(spacing: 6) {
                                    Text(verbatim: profile.displayedName)
                                    if profile.id == Profile.defaultID {
                                        Text("Default").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text(detail(for: profile))
                            } icon: {
                                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.pink)
                            }
                        }
                    }
                }
                HStack {
                    TextField("New profile name", text: $newName, prompt: Text("New profile name")).labelsHidden().textFieldStyle(.roundedBorder).onSubmit { create() }
                    Button("Add", action: create).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || deleting)
                }
            } footer: {
                Text("Profiles keep website logins, history, bookmarks, saved permissions, spaces, pins, favorites, and normal windows separate. Private windows are never saved.")
            }
            SettingsMessage(text: message)
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

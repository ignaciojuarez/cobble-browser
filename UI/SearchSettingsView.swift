import SwiftUI

struct SearchSettingsView: View {
    @Bindable var preferences: BrowserPreferences
    @State private var managing = false

    var body: some View {
        SettingsGroup("Search") {
            SettingsRow("Default search engine", detail: "Search text stays local until you press Return.") {
                Picker("Default search engine", selection: Binding(
                    get: { preferences.defaultSearchEngine.id }, set: { preferences.setDefaultSearchEngine($0) }
                )) {
                    ForEach(preferences.searchEngines) { engine in Text(engine.name).tag(engine.id) }
                }
                .labelsHidden().frame(width: 190)
                .accessibilityLabel("Default search engine")
            }
            SettingsRow("Search engines", detail: "Use !bang followed by search terms to choose an engine for one search.") {
                Button("Manage Search Engines…") { managing = true }
            }
        }
        .sheet(isPresented: $managing) { SearchEngineEditor(preferences: preferences) }
    }
}

private struct SearchEngineEditor: View {
    @Bindable var preferences: BrowserPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = ""
    @State private var bang = ""
    @State private var editingID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search Engines").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(.horizontal, SettingsStyle.pageInset)
            .padding(.vertical, 16)
            Divider()
            SettingsPage(topPadding: 24) {
                SettingsGroup("Engines") {
                    ForEach(preferences.searchEngines) { engine in
                        engineRow(engine)
                        Divider()
                    }
                }
                SettingsGroup(editingID == nil ? "Add search engine" : "Edit search engine") {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search engine name")
                    TextField("https://example.com/search?q={searchTerms}", text: $template)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search URL template")
                    HStack {
                        TextField("Bang (for example, g)", text: $bang)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Search engine bang")
                        Button(editingID == nil ? "Add" : "Save") { save() }
                        if editingID != nil { Button("Cancel") { clear() } }
                    }
                    if let error = preferences.errorMessage { Text(error).font(.callout).foregroundStyle(.orange) }
                }
            }
        }
        .frame(width: 760, height: 680)
    }

    @ViewBuilder private func engineRow(_ engine: SearchEngine) -> some View {
        SettingsRow(verbatim: engine.name, detail: "!\(engine.bang) · \(engine.template)") {
            if isCustom(engine) {
                Button("Edit") { edit(engine) }
                Button("Remove", systemImage: "minus.circle") { preferences.removeSearchEngine(engine.id) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .accessibilityLabel(String(format: String(localized: "Remove %@"), engine.name))
            }
        }
    }

    private func isCustom(_ engine: SearchEngine) -> Bool { !SearchEngine.builtIns.contains(where: { $0.id == engine.id }) }
    private func edit(_ engine: SearchEngine) {
        editingID = engine.id; name = engine.name; template = engine.template; bang = engine.bang; preferences.errorMessage = nil
    }
    private func save() {
        let saved = editingID.map { preferences.updateSearchEngine(id: $0, name: name, template: template, bang: bang) }
            ?? preferences.addSearchEngine(name: name, template: template, bang: bang)
        if saved { clear() }
    }
    private func clear() { editingID = nil; name = ""; template = ""; bang = ""; preferences.errorMessage = nil }
}

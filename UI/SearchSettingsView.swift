import SwiftUI

struct SearchSettingsView: View {
    @Bindable var preferences: BrowserPreferences
    @State private var editor: SearchEngineEditor.Target?

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(get: { preferences.defaultSearchEngine.id },
                                          set: { preferences.setDefaultSearchEngine($0) })) {
                    ForEach(preferences.searchEngines) { engine in Text(engine.name).tag(engine.id) }
                } label: {
                    Text("Default search engine")
                    Text("Search text stays local until you press Return.")
                }
            }
            Section {
                ForEach(preferences.searchEngines) { engine in
                    LabeledContent {
                        if isCustom(engine) {
                            Button("Edit") { editor = .init(engine: engine) }
                            RemoveButton(String(format: String(localized: "Remove %@"), engine.name)) {
                                preferences.removeSearchEngine(engine.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(verbatim: engine.name)
                            Text(verbatim: "!\(engine.bang)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        }
                        Text(verbatim: engine.template).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Search Engine…") { editor = .init(engine: nil) }
                }
            } header: {
                Text("Search Engines")
            } footer: {
                Text("Use !bang followed by search terms to choose an engine for one search.")
            }
        }
        .disabled(preferences.readError != nil)
        .sheet(item: $editor) { target in SearchEngineEditor(preferences: preferences, engine: target.engine) }
    }

    private func isCustom(_ engine: SearchEngine) -> Bool { !SearchEngine.builtIns.contains(where: { $0.id == engine.id }) }
}

private struct SearchEngineEditor: View {
    struct Target: Identifiable {
        let id = UUID()
        let engine: SearchEngine?
    }
    @Bindable var preferences: BrowserPreferences
    let engine: SearchEngine?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = ""
    @State private var bang = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(engine == nil ? "Add search engine" : "Edit search engine") {
                    TextField("Name", text: $name)
                        .accessibilityLabel("Search engine name")
                    TextField("Search URL", text: $template, prompt: Text(verbatim: "https://example.com/search?q={searchTerms}"))
                        .accessibilityLabel("Search URL template")
                    TextField("Bang", text: $bang, prompt: Text("Bang (for example, g)"))
                        .accessibilityLabel("Search engine bang")
                    if let error = preferences.errorMessage { Text(error).foregroundStyle(.orange) }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { preferences.errorMessage = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button(engine == nil ? "Add" : "Save", action: save).keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
        .onAppear {
            preferences.errorMessage = nil
            name = engine?.name ?? ""; template = engine?.template ?? ""; bang = engine?.bang ?? ""
        }
    }

    private func save() {
        let saved = engine.map { preferences.updateSearchEngine(id: $0.id, name: name, template: template, bang: bang) }
            ?? preferences.addSearchEngine(name: name, template: template, bang: bang)
        if saved { dismiss() }
    }
}

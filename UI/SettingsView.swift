import SwiftUI
import UniformTypeIdentifiers

/// System Settings–style window: an icon sidebar of panes and a grouped form for the selected pane.
struct SettingsView: View {
    static let defaultBrowserSchemes = ["http", "https"]
    @Bindable var app: AppModel
    var extensionActionPage: (any BrowserPage)? = nil
    @State private var query = ""
    @State private var selectedProfile: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsSection?>(
                get: { app.settingsSection },
                set: { if let section = $0 { app.settingsSection = section } }
            )) {
                ForEach(SettingsSection.groups, id: \.self) { group in
                    let matches = group.filter(matches)
                    if !matches.isEmpty {
                        Section {
                            ForEach(matches) { section in
                                Label { Text(section.title) } icon: { SettingsIcon(section: section) }
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 220)
            .navigationSplitViewColumnWidth(220)
            .searchable(text: $query, placement: .sidebar, prompt: Text("Search"))
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane
                .navigationTitle(app.settingsSection.title)
                .safeAreaInset(edge: .top, spacing: 0) { SettingsRecoveryBanner(preferences: app.preferences) }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(minWidth: 760, minHeight: 520)
    }

    @ViewBuilder private var pane: some View {
        switch app.settingsSection {
        case .general: GeneralSettings(app: app)
        case .appearance: DesignSettingsView(preferences: app.preferences)
        case .tabs: TabSettingsView(preferences: app.preferences)
        case .search: SearchSettingsView(preferences: app.preferences)
        case .privacy: PrivacySettings(app: app, profileID: profileID)
        case .websites: WebsiteSettings(app: app, profileID: profileID)
        case .history: LibraryView(app: app, profileID: profileID) { url, profileID in
            _ = app.newWindow(url: url, profileID: profileID)
        }
        case .engines: EngineSettings(app: app)
        case .extensions: ExtensionSettingsView(app: app, actionPage: extensionActionPage, profileID: profileID)
        case .profiles: ProfileSettingsView(app: app)
        case .sync: SyncSettingsView(app: app)
        case .shortcuts: ShortcutSettingsView(preferences: app.preferences)
        case .automation: AutomationSettings(app: app)
        case .advanced: AdvancedSettings(app: app)
        }
    }

    /// One profile choice shared by every profile-scoped pane.
    private var profileID: Binding<UUID> {
        Binding(get: {
            if let selectedProfile, app.profiles.contains(where: { $0.id == selectedProfile }) { return selectedProfile }
            if let page = extensionActionPage?.contextID.profileID,
               app.profiles.contains(where: { $0.id == page }) { return page }
            return app.profiles[0].id
        }, set: { selectedProfile = $0 })
    }

    private func matches(_ section: SettingsSection) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || section.title.localizedCaseInsensitiveContains(text)
            || section.keywords.localizedCaseInsensitiveContains(text)
    }
}

extension SettingsSection {
    var tint: Color {
        switch self {
        case .general, .shortcuts, .advanced: .gray
        case .appearance: .purple
        case .tabs: .orange
        case .search: .teal
        case .privacy, .sync: .blue
        case .websites: .cyan
        case .history: .indigo
        case .engines: .red
        case .extensions: .green
        case .profiles: .pink
        case .automation: .mint
        }
    }

    /// Extra words the sidebar search matches.
    var keywords: String {
        switch self {
        case .general: String(localized: "default browser downloads folder updates version")
        case .appearance: String(localized: "theme design window style accent color font loading dark")
        case .tabs: String(localized: "new tab control tab recent sleep memory")
        case .search: String(localized: "search engine bang address bar")
        case .privacy: String(localized: "cookies website data cache clear content blocking trackers ads passwords passkeys keyboard")
        case .websites: String(localized: "permissions camera microphone screen sharing pop-ups browser identity user agent zoom")
        case .history: String(localized: "bookmarks import export retention clear")
        case .engines: String(localized: "webkit chromium engine per site login sharing")
        case .extensions: String(localized: "web extensions add-ons")
        case .profiles: String(localized: "accounts work personal")
        case .sync: String(localized: "icloud devices")
        case .shortcuts: String(localized: "shortcuts keys hotkeys")
        case .automation: String(localized: "apple events applescript agents mcp cli scripts")
        case .advanced: String(localized: "developer tools inspector diagnostics backup restore workspace reset")
        }
    }
}

/// The colored rounded-square icon used by System Settings.
struct SettingsIcon: View {
    let section: SettingsSection
    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(section.tint.gradient, in: .rect(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The profile picker for profile-scoped panes. Hidden with a single profile.
struct ProfileSection: View {
    let app: AppModel
    @Binding var profileID: UUID
    var body: some View {
        if app.profiles.count > 1 {
            Section {
                Picker(selection: $profileID) {
                    ForEach(app.profiles) { profile in Text(profile.displayedName).tag(profile.id) }
                } label: {
                    Text("Profile")
                    Text("Settings below apply to this profile.")
                }
            }
        }
    }
}

/// A status or error line at the end of a form.
struct SettingsMessage: View {
    let text: String?
    var isError = true
    var body: some View {
        if let text, !text.isEmpty {
            Section { Text(verbatim: text).foregroundStyle(isError ? Color.orange : Color.secondary) }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var app: AppModel
    @State private var message: String?
    @State private var settingDefaultBrowser = false
    @State private var isDefaultBrowser = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if isDefaultBrowser {
                        Label("Cobble is your default browser", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Set as Default", action: makeDefaultBrowser).disabled(settingDefaultBrowser)
                    }
                } label: {
                    Text("Default web browser")
                    Text("Open links from other apps in Cobble.")
                }
            }
            DownloadFolderSettingsView(preferences: app.preferences)
            Section("Software Update") {
                if app.updates.isEnabled {
                    Toggle(isOn: Binding(get: { app.updates.automaticChecks },
                                         set: { app.updates.setAutomaticChecks($0) })) {
                        Text("Check for updates automatically")
                        Text("Updates download from GitHub. You choose when to install and restart.")
                    }
                }
                LabeledContent {
                    Button("Check for Updates…", action: app.updates.checkForUpdates)
                        .disabled(!app.updates.canCheck)
                } label: {
                    Text(verbatim: Self.version)
                    if !app.updates.isEnabled, app.updates.errorMessage == nil {
                        Text("Automatic updates are available in Full release builds.")
                    }
                }
                if let error = app.updates.errorMessage { Text(error).foregroundStyle(.orange) }
            }
            SettingsMessage(text: app.persistenceMessage)
            SettingsMessage(text: message, isError: false)
        }
        .onAppear(perform: refreshDefaultBrowser)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return String(format: String(localized: "Cobble %@ (%@)"),
                      info?["CFBundleShortVersionString"] as? String ?? "–",
                      info?["CFBundleVersion"] as? String ?? "–")
    }

    private func refreshDefaultBrowser() {
        guard let url = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { isDefaultBrowser = false; return }
        isDefaultBrowser = handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    private func makeDefaultBrowser() {
        message = nil
        settingDefaultBrowser = true
        Task {
            defer { settingDefaultBrowser = false; refreshDefaultBrowser() }
            for scheme in SettingsView.defaultBrowserSchemes {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
                } catch {
                    message = String(format: String(localized: "Could not set Cobble for %@ links: %@"),
                                     scheme.uppercased(), error.localizedDescription)
                    return
                }
            }
        }
    }
}

/// Shown above every pane when the preferences file cannot be read; settings stay disabled until reset.
private struct SettingsRecoveryBanner: View {
    let preferences: BrowserPreferences
    @State private var message: String?
    var body: some View {
        if let readError = preferences.readError {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Browser Settings Recovery").font(.headline)
                    Text(readError).font(.callout)
                    Text("Reset browser preferences to restore settings changes. Cobble backs up the original settings file first.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error = preferences.errorMessage, error != readError {
                        Text(error).font(.callout).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 12)
                Button("Back Up and Reset Settings") {
                    if let backup = preferences.resetUnreadableSettings() {
                        message = String(format: String(localized: "Browser settings were reset. Original settings were backed up to %@."), backup.path)
                    } else {
                        message = preferences.errorMessage
                    }
                }
            }
            .padding(14)
            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
            .padding([.horizontal, .top], 20)
        } else if let message {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.secondary)
                .padding([.horizontal, .top], 20)
        }
    }
}

// MARK: - Web engines

private struct EngineSettings: View {
    @Bindable var app: AppModel
    @State private var ruleHost = ""
    @State private var ruleEngine: EngineID?

    var body: some View {
        let preferences = app.preferences
        Form {
            Section {
                let choices = app.engines.engines.map(\.id) + (app.engines.engine(preferences.defaultEngine) == nil ? [preferences.defaultEngine] : [])
                if choices.count > 1 {
                    Picker(selection: Binding(get: { preferences.defaultEngine }, set: { preferences.setDefaultEngine($0) })) {
                        ForEach(choices, id: \.self) { Text(app.engines.name(for: $0)).tag($0) }
                    } label: {
                        Text("Default engine")
                        Text("Websites set to Automatic open with this engine. Each Mac keeps its own choice.")
                    }
                } else {
                    LabeledContent {
                        Text(app.engines.name(for: preferences.defaultEngine))
                    } label: {
                        Text("Default engine")
                        Text("Websites set to Automatic open with this engine. Each Mac keeps its own choice.")
                    }
                }
                Picker(selection: Binding(get: { preferences.linkTabsKeepEngine }, set: { preferences.setLinkTabsKeepEngine($0) })) {
                    Text("Automatic").tag(false)
                    Text("Current Tab").tag(true)
                } label: {
                    Text("Links opened in new tabs")
                    Text("Automatic uses the website’s engine or the default. Current Tab keeps the engine of the tab you opened it from.")
                }
            } footer: {
                if app.engines.effectiveID(.chromium) == .webKit {
                    Text("Chromium is not included in this build. Chromium choices use WebKit for now and are remembered.")
                }
            }
            Section {
                ForEach(preferences.engineRules, id: \.host) { rule in
                    HStack(spacing: 10) {
                        TabEngineIcon.image(for: rule.engineID)
                            .resizable().scaledToFit().frame(width: 16, height: 16)
                            .accessibilityHidden(true)
                        Picker(selection: Binding<EngineID?>(get: { rule.engineID }, set: { setRule($0, host: rule.host) })) {
                            Text(String(format: String(localized: "Automatic (%@)"),
                                        app.engines.name(for: app.engines.effectiveID(preferences.defaultEngine)))).tag(EngineID?.none)
                            Divider()
                            ForEach(app.engines.engines, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                            if app.engines.engine(rule.engineID) == nil {
                                Text(app.engines.name(for: rule.engineID)).tag(Optional(rule.engineID))
                            }
                        } label: {
                            Text(verbatim: rule.host).lineLimit(1).truncationMode(.middle)
                        }
                        RemoveButton(String(format: String(localized: "Remove %@"), rule.host)) { setRule(nil, host: rule.host) }
                    }
                }
                HStack {
                    TextField("Website", text: $ruleHost, prompt: Text(verbatim: "example.com"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .onSubmit(addRule)
                    Picker("Engine", selection: Binding(
                        get: { ruleEngine.flatMap { app.engines.engine($0)?.id } ?? app.engines.engines.first?.id ?? .webKit },
                        set: { ruleEngine = $0 }
                    )) {
                        ForEach(app.engines.engines, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                    Button("Add", action: addRule)
                        .disabled(ruleHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Websites")
            } footer: {
                Text("Also set from a website’s site menu in the address bar. Covers subdomains and applies on the next load.")
            }
            Section("Compare Engines") {
                ForEach(app.engines.engines, id: \.id) { engine in
                    LabeledContent {
                        EmptyView()
                    } label: {
                        Label {
                            Text(engine.name)
                            Text(capabilitySummary(engine))
                        } icon: { TabEngineIcon(engine: engine) }
                    }
                }
            }
            Section {
                Toggle(isOn: Binding(get: { preferences.experimentalLoginSharing },
                                     set: { preferences.setExperimentalLoginSharing($0) })) {
                    Text("Cross-engine login sharing")
                    Text("Carries login cookies when you switch engines in the same profile. Existing cookies are kept unless you replace them. Private windows are excluded. Requires a compatible Full build.")
                }
                if preferences.experimentalLoginSharing, let status = app.loginSharingMessage {
                    Text(status).font(.callout).foregroundStyle(.secondary)
                        .accessibilityLabel(String(format: String(localized: "Login sharing status: %@"), status))
                }
            } header: {
                Text("Experimental")
            }
            SettingsMessage(text: preferences.errorMessage)
        }
        .disabled(preferences.readError != nil)
    }

    private func capabilitySummary(_ engine: any BrowserEngine) -> String {
        let capabilities = engine.capabilities
        var values: [String] = []
        if capabilities.pageOperations.contains(.find) { values.append(String(localized: "Find")) }
        if capabilities.pageOperations.contains(.zoom) { values.append(String(localized: "Zoom")) }
        values.append(capabilities.pageOperations.contains(.printPage) ? String(localized: "Print") : String(localized: "No printing"))
        values.append(capabilities.permissions.contains(.camera) ? String(localized: "Camera") : String(localized: "No camera"))
        values.append(capabilities.permissions.contains(.microphone) ? String(localized: "Microphone") : String(localized: "No microphone"))
        values.append(engine.contentBlocker == nil ? String(localized: "No content blocking") : String(localized: "Content blocking"))
        if capabilities.supportsWebsiteDataRemoval(categories: [.siteData, .cache], scope: .recordsAllTime) { values.append(String(localized: "Site data")) }
        if capabilities.supportsWebsiteDataRemoval(categories: [.cache], scope: .profileAllTime) { values.append(String(localized: "Cache clearing")) }
        if capabilities.pageOperations.contains(.muteAudio) { values.append(String(localized: "Tab mute")) }
        return values.isEmpty ? String(localized: "Basic browsing") : values.joined(separator: " · ")
    }
    private func addRule() {
        let host = ruleHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let engineID = ruleEngine.flatMap { app.engines.engine($0)?.id } ?? app.engines.engines.first?.id ?? .webKit
        guard let url = URL(string: host.contains("://") ? host : "https://\(host)"),
              app.preferences.setEngineRule(for: url, engineID: engineID) else { return }
        ruleHost = ""
    }
    private func setRule(_ engineID: EngineID?, host: String) {
        guard let url = URL(string: "https://\(host)") else { return }
        app.preferences.setEngineRule(for: url, engineID: engineID)
    }
}

/// A borderless minus button for removing a list row.
struct RemoveButton: View {
    let label: String
    let action: () -> Void
    init(_ label: String, action: @escaping () -> Void) { self.label = label; self.action = action }
    var body: some View {
        Button(action: action) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }
}

// MARK: - Privacy & Security

private struct PrivacySettings: View {
    @Bindable var app: AppModel
    @Binding var profileID: UUID
    @State private var managingData = false

    var body: some View {
        Form {
            ProfileSection(app: app, profileID: $profileID)
            Section {
                LabeledContent {
                    Button("Manage Website Data…") { managingData = true }
                } label: {
                    Text("Cookies and website data")
                    Text("See which sites store data, remove one site, or clear data by type and time range.")
                }
                let unavailable = app.engines.engines.filter {
                    !$0.capabilities.supportsWebsiteDataRemoval(categories: [.siteData, .cache], scope: .recordsAllTime)
                }
                if !unavailable.isEmpty {
                    Text(String(format: String(localized: "Website data controls are unavailable for %@. Their cookies and site storage are not shown or removed here."), unavailable.map(\.name).joined(separator: ", ")))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Website Data")
            } footer: {
                Text("Private windows keep their data only until they close.")
            }
            ContentBlockingSettings(app: app, profileID: profileID)
            Section {
                Toggle(isOn: Binding(get: { app.preferences.hidesCommandKeysFromPages },
                                     set: { app.preferences.setHidesCommandKeysFromPages($0) })) {
                    Text("Hide Command, Control and Option keys from websites")
                    Text("Websites can't see or block ⌘, ⌃ or ⌥ shortcuts. Cobble shortcuts and text fields keep working; Option characters and site shortcuts are hidden from pages.")
                }
                .disabled(app.preferences.readError != nil)
            } header: {
                Text("Keyboard")
            }
            PasswordSection(chromium: app.engines.engine(.chromium) != nil)
        }
        .sheet(isPresented: $managingData) {
            WebsiteDataSheet(app: app, profileID: profileID)
        }
    }
}

private struct PasswordSection: View {
    let chromium: Bool
    var body: some View {
        let passkeys = ApplePasskeys.status
        Section {
            LabeledContent {
                if passkeys == .denied {
                    Link("Open Settings", destination: ApplePasskeys.settingsURL)
                }
            } label: {
                Text("Passkeys")
                Text(statusText(passkeys))
            }
            LabeledContent {
                EmptyView()
            } label: {
                Text("Passwords")
                Text("Apple Passwords AutoFill is not available on WebKit pages in third-party macOS browsers. Cobble does not store passwords.")
            }
            if chromium {
                Text("Chromium Sign in with Apple uses the system WebKit sheet. Chromium password AutoFill still needs an SDK path. Cobble does not store passwords.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Passwords and Passkeys")
        }
    }

    private func statusText(_ status: ApplePasskeys.Status) -> LocalizedStringKey {
        switch status {
        case .unentitled: "Passkeys for arbitrary websites need Apple’s macOS browser passkey entitlement on a signed Cobble. This build cannot use iCloud Keychain passkeys."
        case .notDetermined: "macOS asks whether Cobble may use passkeys when the first page opens."
        case .denied: "Passkey access is off for Cobble. Turn it on in System Settings to use iCloud Keychain passkeys."
        case .notConfigured: "This Mac has no passkey provider. Turn on iCloud Keychain or another provider in System Settings → General → AutoFill & Passwords."
        case .ready: "This signed Cobble can use iCloud Keychain passkeys on WebKit pages."
        }
    }
}

/// Safari-style Manage Website Data sheet: searchable sites, per-site removal and bulk clearing.
private struct WebsiteDataSheet: View {
    @Bindable var app: AppModel
    let profileID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var siteData: [WebsiteDataGroup] = []
    @State private var request = 0
    @State private var clearing = false
    @State private var loading = true
    @State private var message: String?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Website Data").font(.headline)
                    Text(String(format: String(localized: "Profile: %@"), profileName))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search", text: $query, prompt: Text("Search websites"))
                    .textFieldStyle(.roundedBorder).frame(width: 200)
            }
            .padding(16)
            Divider()
            List(filtered) { site in
                HStack {
                    Image(systemName: "globe").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.displayName)
                        Text(siteEngineNames(site)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { remove(site) }.disabled(clearing)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .overlay {
                if loading { ProgressView() }
                else if filtered.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No Website Data" : "No Matches", systemImage: "globe")
                }
            }
            Divider()
            HStack {
                Menu("Clear Data…") {
                    Button("Cookies and Site Storage…") {
                        clear(categories: [.siteData], title: String(localized: "Clear Cookies and Site Storage?"),
                              action: String(localized: "Clear Cookies and Site Storage"))
                    }.disabled(!canRemove(categories: [.siteData], scope: .profileAllTime))
                    Button("Cached Resources…") {
                        clear(categories: [.cache], title: String(localized: "Clear Cached Resources?"),
                              action: String(localized: "Clear Cached Resources"))
                    }.disabled(!canRemove(categories: [.cache], scope: .profileAllTime))
                    Button("All Website Data…") {
                        clear(categories: [.siteData, .cache], title: String(localized: "Clear All Website Data?"),
                              action: String(localized: "Clear All Website Data"))
                    }.disabled(!canRemove(categories: [.siteData, .cache], scope: .profileAllTime))
                    Divider()
                    Button("Cached Resources from the Last Hour…") {
                        clear(categories: [.cache], modifiedSince: Date().addingTimeInterval(-3_600),
                              title: String(localized: "Clear Cached Resources from the Last Hour?"),
                              action: String(localized: "Clear Recent Cached Resources"))
                    }.disabled(!canRemove(categories: [.cache], scope: .profileSince))
                    Button("Cached Resources from the Last 24 Hours…") {
                        clear(categories: [.cache], modifiedSince: Date().addingTimeInterval(-86_400),
                              title: String(localized: "Clear Cached Resources from the Last 24 Hours?"),
                              action: String(localized: "Clear Recent Cached Resources"))
                    }.disabled(!canRemove(categories: [.cache], scope: .profileSince))
                    Button("Cached Resources from the Last 7 Days…") {
                        clear(categories: [.cache], modifiedSince: Date().addingTimeInterval(-604_800),
                              title: String(localized: "Clear Cached Resources from the Last 7 Days?"),
                              action: String(localized: "Clear Recent Cached Resources"))
                    }.disabled(!canRemove(categories: [.cache], scope: .profileSince))
                }
                .fixedSize()
                .disabled(clearing)
                if let message { Text(message).font(.callout).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 520)
        .onAppear(perform: refresh)
    }

    private var filtered: [WebsiteDataGroup] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? siteData : siteData.filter { $0.displayName.localizedCaseInsensitiveContains(text) }
    }
    private var profileName: String {
        app.profiles.first(where: { $0.id == profileID })?.displayedName ?? String(localized: "Profile")
    }
    private func siteEngineNames(_ site: WebsiteDataGroup) -> String {
        let ids = Set(site.members.map { $0.contextID.engineID })
        return app.engines.engines.filter { ids.contains($0.id) }.map(\.name).joined(separator: ", ")
    }
    private func refresh() {
        guard !clearing else { return }
        request += 1
        let current = request
        Task {
            let result = await app.websiteData(profileID: profileID)
            guard current == request else { return }
            siteData = result.sites
            message = result.error
            loading = false
        }
    }
    private func remove(_ site: WebsiteDataGroup) {
        clear(site: site, categories: [.siteData, .cache],
              title: String(format: String(localized: "Remove data for %@?"), site.displayName),
              action: String(localized: "Remove"))
    }
    private func canRemove(categories: Set<WebsiteDataCategory>, scope: WebsiteDataRemovalScopeKind) -> Bool {
        let engines = app.engines.engines.filter { !$0.capabilities.websiteDataRemoval.isEmpty }
        return !engines.isEmpty && engines.allSatisfy {
            $0.capabilities.supportsWebsiteDataRemoval(categories: categories, scope: scope)
        }
    }
    private func clear(site: WebsiteDataGroup? = nil, categories: Set<WebsiteDataCategory>, modifiedSince: Date? = nil,
                       title: String, action: String) {
        let categoryMessage: String
        if categories == [.cache] { categoryMessage = String(localized: "Cached resources will be removed. Cookies and site storage are preserved. ") }
        else if categories == [.siteData] { categoryMessage = String(localized: "Cookies and site storage will be removed. Cached resources are preserved. ") }
        else { categoryMessage = site == nil ? String(localized: "Cookies, site storage, and cached resources will be removed. ") : String(localized: "This signs you out of the site. Cached resources associated with this site will be removed. Shared transient caches may also be cleared; some process-wide cached resources require all-sites clearing. ") }
        let rangeMessage = modifiedSince == nil ? String(localized: "The selected range is all time. ") : String(localized: "Cached resources from the selected recent range will be removed. Transient in-memory caches may also be cleared. ")
        let alert = PagePresenter.alert(title: title,
            message: String(format: String(localized: "Profile: %@. "), profileName) + categoryMessage + rangeMessage
                + String(localized: "Normal pages will be unloaded. Unsaved content may be lost. History, library bookmarks and saved tabs are preserved."),
            buttons: [action, String(localized: "Cancel")])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        clearing = true
        request += 1
        let current = request
        Task {
            let removalMessage = await app.removeWebsiteData(profileID: profileID, site: site,
                categories: categories, modifiedSince: modifiedSince)
            let result = await app.websiteData(profileID: profileID)
            if current == request {
                siteData = result.sites
                message = [removalMessage, result.error].compactMap { $0 }.joined(separator: "\n")
                if message?.isEmpty == true { message = nil }
            }
            clearing = false
        }
    }
}

private struct ContentBlockingSettings: View {
    let app: AppModel
    let profileID: UUID
    @State private var selected: EngineID?
    var body: some View {
        let providers = app.engines.engines.filter { $0.contentBlocker != nil }
        if let provider = providers.first(where: { $0.id == selected }) ?? providers.first,
           let blocker = provider.contentBlocker {
            ContentBlockerSection(app: app, blocker: blocker, profileID: profileID,
                                  providers: providers, selected: Binding(get: { provider.id }, set: { selected = $0 }))
                .id(ContentBlockerIdentity(profileID: profileID, blocker: ObjectIdentifier(blocker)))
        } else {
            Section("Content Blocking") {
                Text("Content Blocking Unavailable").foregroundStyle(.secondary)
            }
        }
    }
}

private struct ContentBlockerIdentity: Hashable {
    let profileID: UUID
    let blocker: ObjectIdentifier
}

private struct ContentBlockerSection: View {
    @Bindable var app: AppModel
    let blocker: any EngineContentBlocker
    let profileID: UUID
    let providers: [any BrowserEngine]
    @Binding var selected: EngineID
    @State private var working = false
    @State private var message: String?
    @State private var source = ""

    var body: some View {
        let hasRules = blocker.hasRules(profileID: profileID)
        Section {
            if providers.count > 1 {
                Picker("Rule format", selection: $selected) {
                    ForEach(providers, id: \.id) { provider in
                        Text(String(format: String(localized: "%@ — %@"), provider.name, provider.contentBlocker!.formatName)).tag(provider.id)
                    }
                }
            }
            Toggle(isOn: Binding(get: { blocker.isEnabled(profileID: profileID) }, set: { enabled in
                let targetProfile = profileID
                working = true
                Task { await blocker.setEnabled(enabled, profileID: targetProfile); working = false }
            })) {
                Text("Enable rules")
                Text(hasRules ? "Also removes YouTube ads, including those in videos. Reload open pages after changing rules." : "Install or import rules first.")
            }
            .disabled(working || !hasRules)
            LabeledContent {
                Button("Install") { installBundledRules() }.disabled(working || hasRules)
            } label: {
                Text("Cobble Basic Tracker Rules")
                Text("A small original list that blocks three common third-party tracking or ad hosts. Not broad ad filtering.")
            }
            LabeledContent {
                Button("Import Rules…") { importRules() }.disabled(working)
            } label: {
                Text("Custom rules")
                Text(String(format: String(localized: "Import a local %@ rule file to replace the current rules."), blocker.formatName))
            }
            TextField(text: $source, prompt: Text("HTTPS JSON URL")) {
                Text("Update source")
                Text("Updates run only when you select Update Now. A failed update keeps the current rules.")
            }
            HStack {
                Spacer()
                Button("Save Source") { saveSource() }.disabled(working || !hasRules)
                Button("Update Now") { updateRules() }.disabled(working || source.isEmpty || !hasRules)
            }
        } header: {
            Text("Content Blocking")
        }
        Section {
            let exceptions = blocker.exceptions(profileID: profileID)
            if exceptions.isEmpty {
                Text("No sites are allowed through the blocker.").foregroundStyle(.secondary)
            }
            ForEach(exceptions, id: \.self) { origin in
                LabeledContent(origin) {
                    RemoveButton(String(localized: "Remove Exception")) {
                        guard let url = URL(string: origin) else { return }
                        let targetProfile = profileID
                        working = true
                        Task { await blocker.setException(origin: url, enabled: false, profileID: targetProfile); working = false }
                    }
                    .disabled(working)
                }
            }
            if let error = blocker.lastError ?? message { Text(error).foregroundStyle(.orange) }
        } header: {
            Text("Sites allowed through the blocker")
        } footer: {
            Text("Use Page Actions to allow a site through the blocker. Exceptions match an exact origin, including its port.")
        }
        .onAppear { source = blocker.updateSource(profileID: profileID)?.absoluteString ?? "" }
    }

    private func importRules() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_000_000 else { message = String(localized: "Choose a rule file smaller than 1 MB."); return }
            let json = try String(contentsOf: url, encoding: .utf8)
            let targetProfile = profileID
            working = true
            Task { await blocker.importRules(json: json, profileID: targetProfile); working = false }
        } catch { message = error.localizedDescription }
    }
    private func installBundledRules() {
        let targetProfile = profileID
        working = true
        Task { await blocker.installBundledRules(profileID: targetProfile); working = false }
    }
    private func saveSource() {
        let targetProfile = profileID
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || URL(string: text) != nil else {
            message = String(localized: "Enter an HTTPS JSON address or clear the field.")
            return
        }
        let url = text.isEmpty ? nil : URL(string: text)
        working = true
        Task { await blocker.setUpdateSource(url, profileID: targetProfile); working = false }
    }
    private func updateRules() {
        let targetProfile = profileID
        working = true
        Task { await blocker.updateRules(profileID: targetProfile); working = false }
    }
}

// MARK: - Websites

private struct WebsiteSettings: View {
    @Bindable var app: AppModel
    @Binding var profileID: UUID
    @State private var newOrigin = ""
    @State private var newIdentity: SiteBrowserIdentity = .iPhone

    var body: some View {
        Form {
            ProfileSection(app: app, profileID: $profileID)
            Section {
                let entries = app.siteSettings.summaries(profileID: profileID, engines: app.engines.engines)
                if entries.isEmpty {
                    Text("No remembered permissions").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(verbatim: entry.origin).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Forget") {
                                if confirm(), app.siteSettings.forget(origin: entry.origin, profileID: profileID) {
                                    for kind in [PermissionKind.camera, .microphone, .windowManagement] {
                                        app.engines.resetPermission(kind, origin: entry.origin, profileID: profileID)
                                    }
                                    unloadPages()
                                }
                            }
                        }
                        HStack(spacing: 14) {
                            permissionPicker("Camera", symbol: "camera", .camera, entry)
                            permissionPicker("Microphone", symbol: "mic", .microphone, entry)
                            permissionPicker("Window management", symbol: "macwindow.on.rectangle", .windowManagement, entry)
                            permissionPicker("Screen sharing", symbol: "rectangle.on.rectangle", .screenSharing, entry)
                            if case .some(let popups) = entry.popups { popupPicker(popups, entry) }
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if let error = app.siteSettings.lastError { Text(error).foregroundStyle(.orange) }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Saved decisions apply to normal windows. Private windows ask separately. Changing camera, microphone or screen decisions unloads normal pages to stop capture. Blocked sites still open pop-ups you click.")
            }
            Section {
                let unsupported = app.engines.engines.filter { !$0.capabilities.supportsBrowserIdentity }
                ForEach(unsupported, id: \.id) { engine in
                    Text("Browser identity rules are unavailable in \(engine.name).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(app.siteSettings.summaries(profileID: profileID, engines: app.engines.engines, includeIdentity: true)
                            .filter { $0.browserIdentity != .standard }) { entry in
                    Picker(selection: Binding(get: { entry.browserIdentity }, set: { setIdentity($0, for: entry.origin) })) {
                        ForEach(SiteBrowserIdentity.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        Text(verbatim: entry.origin).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack {
                    TextField("Website", text: $newOrigin, prompt: Text(verbatim: "https://example.com"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .onSubmit(addIdentity)
                    Picker("Browser identity", selection: $newIdentity) {
                        ForEach(SiteBrowserIdentity.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Button("Add", action: addIdentity)
                        .disabled(newOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newIdentity == .standard)
                }
            } header: {
                Text("Browser Identity")
            } footer: {
                Text("Choose a browser identity for an exact HTTP or HTTPS origin. Changes apply on the next navigation or reload. Page width stays unchanged.")
            }
            Section {
                let zooms = app.siteSettings.entries.filter { $0.profileID == profileID && $0.zoom != nil }
                    .sorted { ($0.origin, $0.engineID.rawValue) < ($1.origin, $1.engineID.rawValue) }
                if zooms.isEmpty {
                    Text("No sites have a custom zoom.").foregroundStyle(.secondary)
                }
                ForEach(zooms) { entry in
                    LabeledContent {
                        Text((entry.zoom ?? 1).formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit().foregroundStyle(.secondary)
                        RemoveButton(String(format: String(localized: "Reset zoom for %@"), entry.origin)) {
                            if let url = URL(string: entry.origin) {
                                app.siteSettings.setZoom(nil, origin: url, profileID: profileID, engineID: entry.engineID)
                            }
                        }
                    } label: {
                        Text(verbatim: entry.origin).lineLimit(1).truncationMode(.middle)
                        if app.engines.engines.count > 1 { Text(app.engines.name(for: entry.engineID)) }
                    }
                }
            } header: {
                Text("Page Zoom")
            } footer: {
                Text("Cobble remembers zoom for each site in normal windows. A reset applies the next time the site loads.")
            }
        }
    }

    /// Pop-ups are allowed or blocked; a blocked site still opens pop-ups you click.
    private func popupPicker(_ value: SitePermission?, _ entry: SiteSettingsStore.Summary) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "macwindow.badge.plus").foregroundStyle(.secondary).help(Text("Pop-ups")).accessibilityHidden(true)
            Picker("Pop-ups", selection: Binding(
                get: { value.map { $0 == .allow ? SitePermission.allow : .ask } },
                set: { if let next = $0 { app.siteSettings.updatePopups(origin: entry.origin, profileID: profileID, next, engines: app.engines.engines) } }
            )) {
                Text("Allow").tag(Optional(SitePermission.allow))
                Text("Block").tag(Optional(SitePermission.ask))
                Text("Mixed").tag(nil as SitePermission?).disabled(true)
            }
            .labelsHidden().fixedSize()
        }
    }

    @ViewBuilder private func permissionPicker(_ title: LocalizedStringKey, symbol: String, _ kind: PermissionKind,
                                               _ entry: SiteSettingsStore.Summary) -> some View {
        if let value = entry.permissions[kind] {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(.secondary).help(Text(title)).accessibilityHidden(true)
                // Screen sharing offers Ask and Deny only: its grants are never saved.
                Picker(title, selection: Binding(get: { value }, set: { if let next = $0 { update(entry, kind, next) } })) {
                    ForEach(SitePermission.allCases.filter { kind != .screenSharing || $0 != .allow }, id: \.self) {
                        Text(permissionTitle($0)).tag(Optional($0))
                    }
                    Text("Mixed").tag(nil as SitePermission?).disabled(true)
                }
                .labelsHidden().fixedSize()
            }
        }
    }
    private func permissionTitle(_ value: SitePermission) -> String {
        switch value {
        case .ask: String(localized: "Ask")
        case .allow: String(localized: "Allow")
        case .deny: String(localized: "Deny")
        }
    }
    private func confirm() -> Bool {
        let alert = NSAlert(); alert.messageText = String(localized: "Change site permissions?")
        alert.informativeText = String(localized: "Normal pages will be unloaded to stop active capture. Unsaved page content may be lost.")
        alert.addButton(withTitle: String(localized: "Change and Unload")); alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func unloadPages() { app.windows.filter { !$0.isPrivate && $0.record.profileID == profileID }.forEach { $0.unloadPages() } }
    private func update(_ original: SiteSettingsStore.Summary, _ kind: PermissionKind, _ value: SitePermission) {
        guard confirm() else { return }
        guard app.siteSettings.update(origin: original.origin, profileID: profileID, kind, value,
                                      engines: app.engines.engines) else { return }
        if value != .allow { app.engines.resetPermission(kind, origin: original.origin, profileID: profileID) }
        unloadPages()
    }
    private func addIdentity() {
        let text = newOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, newIdentity != .standard else { return }
        setIdentity(newIdentity, for: text)
        if app.siteSettings.lastError == nil { newOrigin = "" }
    }
    private func setIdentity(_ identity: SiteBrowserIdentity, for origin: String) {
        guard let url = URL(string: origin) else {
            app.siteSettings.lastError = String(localized: "Site rules require a valid HTTP or HTTPS origin.")
            return
        }
        _ = app.siteSettings.setBrowserIdentity(identity, for: url, profileID: profileID)
    }
}

// MARK: - Automation

/// Apple Event automation: a master switch, page reading, page use, private sites and the command-line tool.
private struct AutomationSettings: View {
    @Bindable var app: AppModel
    @State private var site = ""

    var body: some View {
        let preferences = app.preferences
        Form {
            Section {
                Toggle(isOn: Binding(get: { preferences.automationTabAccess }, set: { preferences.setAutomationTabAccess($0) })) {
                    Text("Let Apps Control Tabs")
                    Text("Apps you allow in Privacy & Security › Automation can list, open, navigate and close tabs in normal windows. Agents using the cobble tool open new tabs in an Agents space. Private windows are never shared.")
                }
                Toggle(isOn: Binding(get: { preferences.automationPageAccess }, set: { preferences.setAutomationPageAccess($0) })) {
                    Text("Let Apps Read Pages")
                    Text("Also lets them read page text, page outlines and page errors, and take screenshots. Local files are never shared.")
                }
                .disabled(!preferences.automationTabAccess)
                Toggle(isOn: Binding(get: { preferences.automationPageControl }, set: { preferences.setAutomationPageControl($0) })) {
                    Text("Let Apps Use Pages")
                    Text("Also lets them click, type, choose options and scroll in pages, as you would. Cobble marks tabs an app is using in the sidebar.")
                }
                .disabled(!preferences.automationPageAccess)
            }
            Section {
                ForEach(preferences.automationExcludedHosts, id: \.self) { host in
                    LabeledContent {
                        RemoveButton(String(format: String(localized: "Remove %@"), host)) {
                            if let url = URL(string: "https://\(host)") { preferences.setAutomationExcluded(url, excluded: false) }
                        }
                    } label: {
                        Label { Text(verbatim: host) } icon: { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                    }
                }
                HStack {
                    TextField("Website", text: $site, prompt: Text(verbatim: "bank.example"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .onSubmit(addSite)
                    Button("Add", action: addSite)
                        .disabled(site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Private Sites")
            } footer: {
                Text("Apps can't read or use these sites or their subdomains, and see only their address. Use it for banking, mail and health sites.")
            }
            Section {
                LabeledContent {
                    Button("Open Privacy Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } label: {
                    Text("Apps with access")
                    Text("macOS lists the apps that may control Cobble.")
                }
                if let tool = Bundle.main.url(forResource: "cobble", withExtension: nil) {
                    LabeledContent {
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(tool.path, forType: .string)
                        }
                    } label: {
                        Text("Command-line tool")
                        Text("Scripts and AI agents can run cobble for JSON output, or “cobble mcp” as an MCP server.")
                    }
                }
            }
        }
        .disabled(preferences.readError != nil)
    }

    private func addSite() {
        let text = site.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text.contains("://") ? text : "https://\(text)"),
              app.preferences.setAutomationExcluded(url, excluded: true) else { return }
        site = ""
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @Bindable var app: AppModel
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { app.preferences.webInspectorEnabled }, set: { app.setWebInspectorEnabled($0) })) {
                    Text("Enable Developer Tools")
                    Text("WebKit pages appear in Safari’s Develop menu. Chromium pages open from View > Open Developer Tools. Enable this only while debugging.")
                }
                .disabled(!app.engines.engines.contains {
                    !$0.capabilities.pageOperations.intersection([.inspect, .openDevTools]).isEmpty
                })
            } header: {
                Text("Developer")
            }
            Section {
                LabeledContent {
                    Button("Export…", action: exportWorkspace)
                    Button("Restore…", action: restoreWorkspace)
                } label: {
                    Text("Backup and restore")
                    Text("Includes normal windows, tabs, spaces, pins, and favorites. Website data and private windows stay on this Mac.")
                }
            } header: {
                Text("Workspace")
            }
            Section {
                LabeledContent {
                    Button("Export…", action: exportDiagnostics)
                } label: {
                    Text("Redacted diagnostics")
                    Text("Saves app and OS versions, the local data directory, the last persistence error, and registered engine names. No page URLs, cookies, or browsing history.")
                }
            } header: {
                Text("Diagnostics")
            }
            SettingsMessage(text: app.persistenceMessage)
            SettingsMessage(text: message, isError: false)
        }
    }

    private func restoreWorkspace() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 10_000_000 else {
                message = String(localized: "Choose a workspace file smaller than 10 MB."); return
            }
            let snapshot = try SessionSnapshot.decode(Data(contentsOf: url)).withoutLocalFileBookmarks()
            let alert = NSAlert(); alert.messageText = String(localized: "Restore this workspace?")
            alert.informativeText = String(format: String(localized: "This replaces your workspace with %@ spaces and %@ windows, and closes all existing pages, including private windows. Unsaved page content may be lost. Cookies, history, and bookmarks are not imported."), "\(snapshot.spaces.count)", "\(snapshot.windows.count)")
            alert.addButton(withTitle: String(localized: "Restore")); alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try app.replaceWorkspace(with: snapshot)
            message = String(localized: "Workspace restored. The previous workspace is retained in workspace-before-restore.json.")
        } catch { message = String(format: String(localized: "Could not restore the workspace: %@"), error.localizedDescription) }
    }
    private func exportWorkspace() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Cobble-workspace.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(app.workspaceExportSnapshot()).write(to: url, options: .atomic)
            message = String(localized: "Workspace exported.")
        } catch { message = error.localizedDescription }
    }
    private func exportDiagnostics() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Cobble-diagnostics.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try app.redactedDiagnosticsJSON().write(to: url, options: .atomic)
            message = String(localized: "Diagnostics exported.")
        } catch { message = error.localizedDescription }
    }
}

// MARK: - Extensions

private struct ExtensionSettingsView: View {
    @Bindable var app: AppModel
    var actionPage: (any BrowserPage)?
    @Binding var profileID: UUID
    @State private var selectedEngine: EngineID?
    @State private var working = false
    @State private var revision = 0
    @State private var message: String?
    @State private var siteDrafts: [UUID: String] = [:]

    private var engines: [any BrowserEngine] { app.engines.engines.filter { $0.extensionManager != nil } }
    private var engine: (any BrowserEngine)? {
        engines.first { $0.id == selectedEngine } ?? engines.first
    }

    var body: some View {
        if let engine, let manager = engine.extensionManager {
            Form {
                Section {
                    if engines.count > 1 {
                        Picker("Engine", selection: Binding(get: { selectedEngine ?? engine.id }, set: { selectedEngine = $0 })) {
                            ForEach(engines, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .disabled(working)
                    }
                    if app.profiles.count > 1 {
                        Picker("Profile", selection: $profileID) {
                            ForEach(app.profiles) { profile in Text(profile.displayedName).tag(profile.id) }
                        }
                        .disabled(working)
                    }
                    LabeledContent {
                        if working { ProgressView().controlSize(.small) }
                        Button("Install Extension…") { install(with: manager) }.disabled(working)
                    } label: {
                        Text(String(format: String(localized: "Extensions for %@"), engine.name))
                        Text(manager.capabilities.supportsProviderBundles
                             ? "Install a compatible web extension from a folder, bundle, or ZIP file."
                             : "Install a compatible web extension from an unpacked folder.")
                    }
                }
                let items = extensions(from: manager)
                if items.isEmpty {
                    Section {
                        ContentUnavailableView("No Extensions", systemImage: "puzzlepiece.extension")
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(items) { item in extensionSection(item, manager: manager) }
                SettingsMessage(text: message ?? manager.lastError)
            }
            .onAppear {
                for engine in engines { engine.extensionManager?.onChange = { revision += 1 } }
            }
        } else {
            ContentUnavailableView("Extensions Unavailable", systemImage: "puzzlepiece.extension",
                                   description: Text("None of the installed web engines support extensions."))
        }
    }

    private func extensions(from manager: any BrowserExtensionManaging) -> [BrowserExtensionInfo] {
        _ = revision
        return manager.extensions(profileID: profileID)
    }

    @ViewBuilder private func extensionSection(_ item: BrowserExtensionInfo, manager: any BrowserExtensionManaging) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { item.isEnabled },
                set: { enabled in perform { try await manager.setEnabled(enabled, id: item.id, profileID: item.profileID) } }
            )) {
                Label {
                    Text(verbatim: item.name)
                    Text(verbatim: String(format: String(localized: "Version %@"), item.version) + " · " + item.sourceURL.lastPathComponent)
                } icon: {
                    Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.green)
                }
            }
            .disabled(working)
            if item.hasAction {
                LabeledContent {
                    Button("Open") { openAction(item, manager: manager) }
                        .disabled(working || !item.isEnabled || actionPage == nil
                                  || actionPage?.contextID.engineID != engine?.id
                                  || actionPage?.contextID.profileID != profileID
                                  || (actionPage?.contextID.isPrivate == true && !item.allowsPrivateBrowsing))
                } label: {
                    Text("Extension action")
                    Text("Open this extension for the browser tab that opened Settings")
                }
            }
            if !item.requestedOrigins.isEmpty {
                if manager.capabilities.websiteAccess == .declaredPatterns {
                    ForEach(item.requestedOrigins, id: \.self) { origin in
                        Toggle(isOn: Binding(
                            get: { item.allowedOrigins.contains(origin) },
                            set: { allowed in
                                var origins = Set(item.allowedOrigins)
                                if allowed { origins.insert(origin) } else { origins.remove(origin) }
                                perform { try await manager.setAllowedOrigins(origins.sorted(), id: item.id, profileID: item.profileID) }
                            }
                        )) {
                            Text("Website access")
                            Text(verbatim: origin)
                        }
                        .disabled(working)
                    }
                } else {
                    LabeledContent {
                        EmptyView()
                    } label: {
                        Text("Website access")
                        Text(verbatim: String(format: String(localized: "Requested: %@"), item.requestedOrigins.joined(separator: ", ")))
                    }
                    ForEach(item.allowedOrigins, id: \.self) { origin in
                        LabeledContent(origin) {
                            Button("Remove Access") {
                                perform {
                                    try await manager.setAllowedOrigins(item.allowedOrigins.filter { $0 != origin },
                                                                        id: item.id, profileID: item.profileID)
                                }
                            }.disabled(working)
                        }
                    }
                    HStack {
                        TextField("Website", text: Binding(
                            get: { siteDrafts[item.id] ?? "" },
                            set: { siteDrafts[item.id] = $0 }
                        ), prompt: Text(verbatim: "https://example.com")).labelsHidden().textFieldStyle(.roundedBorder)
                        Button("Allow Website") { grantSite(item, manager: manager) }
                            .disabled(working || (siteDrafts[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            if !item.deniedPermissions.isEmpty {
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Unavailable permissions")
                    Text(verbatim: String(format: String(localized: "Cobble does not support: %@"), item.deniedPermissions.joined(separator: ", ")))
                }
            }
            ForEach(item.allowedOptionalPermissions, id: \.self) { permission in
                LabeledContent {
                    Button("Remove Access") {
                        perform {
                            try await manager.setAllowedOptionalPermissions(
                                item.allowedOptionalPermissions.filter { $0 != permission },
                                id: item.id, profileID: item.profileID)
                        }
                    }.disabled(working)
                } label: {
                    Text("Optional permissions")
                    Text(verbatim: permission)
                }
            }
            Toggle(isOn: Binding(
                get: { item.allowsPrivateBrowsing },
                set: { allowed in perform { try await manager.setPrivateBrowsingAllowed(allowed, id: item.id, profileID: item.profileID) } }
            )) {
                Text("Allow in Private Browsing")
                Text(manager.capabilities.supportsPrivateBrowsing
                     ? "Private tabs use separate browsing data."
                     : "This engine does not support extensions in private windows.")
            }
            .disabled(working || !manager.capabilities.supportsPrivateBrowsing)
            HStack {
                if let error = item.errorMessage { Text(error).font(.callout).foregroundStyle(.orange) }
                Spacer()
                Button("Remove Extension…", role: .destructive) { remove(item, manager: manager) }.disabled(working)
            }
        }
    }

    private func install(with manager: any BrowserExtensionManaging) {
        let panel = NSOpenPanel()
        panel.message = manager.capabilities.supportsProviderBundles
            ? String(localized: "Choose a compatible web extension folder, app extension bundle, or ZIP file.")
            : String(localized: "Choose an unpacked web extension folder.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = manager.capabilities.supportsProviderBundles
        if manager.capabilities.supportsProviderBundles {
            panel.allowedContentTypes = [.folder, .bundle, .zip]
        }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let targetProfile = profileID
        perform { try await manager.install(from: url, profileID: targetProfile) }
    }
    private func grantSite(_ item: BrowserExtensionInfo, manager: any BrowserExtensionManaging) {
        let draft = (siteDrafts[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.contains("*"), var components = URLComponents(string: draft.contains("://") ? draft : "https://" + draft),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false, components.user == nil, components.password == nil else {
            message = String(localized: "Enter an HTTP or HTTPS website address.")
            return
        }
        components.scheme = scheme
        components.path = ""; components.query = nil; components.fragment = nil
        guard let origin = components.url?.absoluteString else { return }
        perform {
            try await manager.setAllowedOrigins(Array(Set(item.allowedOrigins + [origin])).sorted(),
                                                id: item.id, profileID: item.profileID)
            siteDrafts[item.id] = nil
        }
    }
    private func openAction(_ item: BrowserExtensionInfo, manager: any BrowserExtensionManaging) {
        guard let page = actionPage else {
            message = String(localized: "Open Settings from a loaded browser tab to use this extension.")
            return
        }
        perform {
            guard page.state.lifecycle == .ready else {
                throw EngineError.notReady(String(localized: "The browser tab that opened Settings is no longer available. Return to a loaded tab and reopen Settings."))
            }
            try await manager.performAction(id: item.id, profileID: item.profileID, on: page)
        }
    }
    private func remove(_ item: BrowserExtensionInfo, manager: any BrowserExtensionManaging) {
        let alert = PagePresenter.alert(title: String(format: String(localized: "Remove %@?"), item.name),
                                        message: String(localized: "The extension and its saved settings will be removed from Cobble."),
                                        buttons: [String(localized: "Remove"), String(localized: "Cancel")])
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { try await manager.remove(id: item.id, profileID: item.profileID) }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        working = true
        message = nil
        Task {
            do { try await operation() } catch { message = error.localizedDescription }
            revision += 1
            working = false
        }
    }
}

// MARK: - History

private struct LibraryView: View {
    @Bindable var app: AppModel
    @Binding var profileID: UUID
    var openURL: (URL, UUID) -> Void
    @State private var query = ""
    @State private var bookmarksOnly = false
    @State private var retention = 90
    @State private var clearHours = 0
    @State private var entries: [LibraryEntry] = []
    @State private var message: String?
    @State private var editingBookmark: LibraryEntry?
    @State private var editingProfile = UUID()
    @State private var bookmarkTitle = ""
    @State private var bookmarkURL = ""
    @State private var editError: String?
    private var store: LibraryStore { app.library }

    var body: some View {
        Form {
            ProfileSection(app: app, profileID: $profileID)
            Section {
                Picker(selection: $retention) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                    Text("Until I clear it").tag(0)
                } label: {
                    Text("Keep history")
                    Text("Repeated visits update the last visit. Bookmarks are preserved.")
                }
                LabeledContent {
                    Picker("Clear", selection: $clearHours) {
                        Text("Last hour").tag(1)
                        Text("Last 24 hours").tag(24)
                        Text("Last 7 days").tag(168)
                        Text("All history").tag(0)
                    }
                    .labelsHidden().fixedSize()
                    Button("Clear History…", action: clearHistory)
                } label: {
                    Text("Clear history")
                    Text("Removes pages last visited in that period. Library bookmarks, pins and website data stay.")
                }
                LabeledContent {
                    Button("Import…", action: importBookmarks)
                    Button("Export…", action: exportBookmarks)
                } label: {
                    Text("Bookmarks")
                    Text("HTML bookmark files from Safari, Chrome and other browsers.")
                }
            }
            Section {
                ForEach(entries) { entry in
                    HStack {
                        Button {
                            if let url = URL(string: entry.urlString) { openURL(url, profileID) }
                        } label: {
                            Label {
                                Text(entry.title).lineLimit(1)
                                Text(entry.urlString).lineLimit(1)
                            } icon: {
                                Image(systemName: entry.isBookmark ? "bookmark.fill" : "clock").foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if !bookmarksOnly {
                            Text(entry.visitedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Edit…") {
                                editingProfile = profileID
                                bookmarkTitle = entry.title
                                bookmarkURL = entry.urlString
                                editError = nil
                                editingBookmark = entry
                            }
                        }
                        RemoveButton(bookmarksOnly ? String(localized: "Remove library bookmark; keep browsing history")
                                                   : String(localized: "Remove from history; keep library bookmark")) {
                            if bookmarksOnly { store.removeBookmark(id: entry.id, profileID: profileID) }
                            else { store.removeHistoryEntry(id: entry.id, profileID: profileID) }
                            refresh()
                        }
                    }
                }
                if entries.isEmpty {
                    Text(bookmarksOnly ? "No bookmarks" : "No history").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Picker("Show", selection: $bookmarksOnly) {
                        Text("History").tag(false)
                        Text("Bookmarks").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    TextField("Search", text: $query, prompt: Text(bookmarksOnly ? "Search bookmarks" : "Search history"))
                        .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 220)
                }
            } footer: {
                Text("Shows the 100 most recent matching pages.")
            }
            SettingsMessage(text: store.lastError ?? message, isError: false)
        }
        .onAppear { retention = store.retentionDays(profileID: profileID); refresh() }
        .onChange(of: profileID) { _, _ in
            retention = store.retentionDays(profileID: profileID)
            refresh()
        }
        .onChange(of: retention) { old, days in
            guard days != store.retentionDays(profileID: profileID) else { return }
            let alert = NSAlert(); alert.messageText = String(localized: "Change history retention?")
            alert.informativeText = days == 0
                ? String(localized: "History will remain until you clear it.")
                : String(format: String(localized: "History older than %@ days will be removed now and automatically as you browse. Bookmarks are preserved."), "\(days)")
            alert.addButton(withTitle: String(localized: "Change")); alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn {
                store.setRetentionDays(days, profileID: profileID)
                retention = store.retentionDays(profileID: profileID)
                refresh()
            }
            else { retention = old }
        }
        .onChange(of: store.revision) { _, _ in refresh() }
        .onChange(of: query) { _, _ in refresh() }
        .onChange(of: bookmarksOnly) { _, _ in refresh() }
        .sheet(item: $editingBookmark) { entry in
            VStack(spacing: 0) {
                Form {
                    Section("Edit Bookmark") {
                        TextField("Title", text: $bookmarkTitle)
                        TextField("Address", text: $bookmarkURL)
                        if let editError { Text(editError).foregroundStyle(.red) }
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button("Cancel") { editingBookmark = nil }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        if store.editBookmark(id: entry.id, profileID: editingProfile, urlString: bookmarkURL, title: bookmarkTitle) {
                            editingBookmark = nil
                            refresh()
                        } else { editError = store.lastError }
                    }.keyboardShortcut(.defaultAction)
                }
                .padding([.horizontal, .bottom], 20)
            }
            .frame(width: 460)
        }
    }
    private func refresh() { entries = store.search(query, profileID: profileID, bookmarksOnly: bookmarksOnly, historyOnly: !bookmarksOnly) }
    private func importBookmarks() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.html]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
            guard (attributes.fileSize ?? 0) <= 10_000_000 else { message = String(localized: "Choose a bookmark file smaller than 10 MB."); return }
            message = store.importBookmarks(from: try String(contentsOf: url, encoding: .utf8), profileID: profileID)?.message
            refresh()
        } catch { message = error.localizedDescription }
    }
    private func exportBookmarks() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.html]; panel.nameFieldStringValue = "Cobble-bookmarks.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportBookmarks(profileID: profileID).write(to: url, atomically: true, encoding: .utf8) }
        catch { message = error.localizedDescription }
    }
    private func clearHistory() {
        let alert = NSAlert(); alert.messageText = clearHours == 0
            ? String(localized: "Clear all browsing history?")
            : String(format: String(localized: "Clear history from the last %@ hours?"), "\(clearHours)")
        alert.informativeText = String(localized: "Bookmarks, saved tabs, and website data are preserved.")
        alert.addButton(withTitle: String(localized: "Clear History")); alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { store.clearHistory(profileID: profileID, since: clearHours == 0 ? .distantPast : Date().addingTimeInterval(-Double(clearHours) * 3600)); refresh() }
    }
}

// MARK: - Keyboard

struct ShortcutSettingsView: View {
    @Bindable var preferences: BrowserPreferences
    @State private var query = ""
    @State private var recording: BrowserCommand?

    var body: some View {
        Form {
            Section {
                TextField("Search", text: $query, prompt: Text("Search shortcuts")).labelsHidden().textFieldStyle(.roundedBorder)
            }
            Section {
                ForEach(BrowserCommand.allCases.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { command in
                    let shortcut = preferences.shortcut(for: command)
                    LabeledContent(command.title) {
                        Button {
                            preferences.errorMessage = nil; recording = command
                        } label: {
                            Text(shortcut.label)
                                .monospaced()
                                .foregroundStyle(shortcut.key.isEmpty ? .secondary : .primary)
                                .frame(minWidth: 90, minHeight: 22)
                                .padding(.horizontal, 6)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(format: String(localized: "Change shortcut for %@: %@"), command.title, shortcut.label))
                        RemoveButton(String(format: String(localized: "Clear shortcut for %@"), command.title)) {
                            preferences.set(BrowserShortcut(""), for: command)
                        }
                        .disabled(shortcut.key.isEmpty)
                    }
                }
            } footer: {
                HStack(alignment: .top) {
                    Text("Editing, Quit, Hide and Minimize use standard macOS shortcuts. Escape cancels; Return confirms dialogs.")
                    Spacer()
                    Button("Reset Shortcuts") { preferences.resetShortcuts() }
                }
            }
            SettingsMessage(text: preferences.errorMessage)
        }
        .sheet(item: $recording) { command in
            VStack(spacing: 16) {
                Text(command.title).font(.headline)
                Text("Press a shortcut with Command or Control.")
                Text("Escape cancels.").font(.caption).foregroundStyle(.secondary)
                ShortcutCapture { shortcut in
                    if let shortcut {
                        if preferences.set(shortcut, for: command) { recording = nil }
                    } else { recording = nil }
                }.frame(width: 1, height: 1).accessibilityHidden(true)
                if let error = preferences.errorMessage { Text(error).foregroundStyle(.orange) }
                Button("Cancel") { recording = nil }
            }.padding(24).frame(width: 390)
        }
    }
}

struct DownloadsView: View {
    @Bindable var store: DownloadStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Downloads").font(.title3.weight(.semibold))
                Spacer()
                Button("Clear") { store.removeCompleted() }
            }
            VStack(alignment: .leading) {
                List(store.entries) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(nsImage: fileIcon(item)).resizable().scaledToFit()
                            .frame(width: 32, height: 32).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.name).lineLimit(1).truncationMode(.middle).help(item.name)
                                if item.isPrivate { Image(systemName: "hand.raised").help("Private download") }
                                Spacer()
                                if item.status == .finished {
                                    Button("Open") { store.open(id: item.id) }
                                    Button("Reveal") { store.reveal(id: item.id) }
                                } else if item.status == .downloading {
                                    if item.isPausing { ProgressView().controlSize(.small) }
                                    else if store.canPause(id: item.id) { Button("Pause") { store.pause(id: item.id) } }
                                    Button("Cancel") { store.cancel(id: item.id) }
                                } else if item.status == .paused {
                                    if item.isResuming { ProgressView().controlSize(.small) }
                                    else { Button("Resume") { store.resume(id: item.id) }.disabled(!store.canResume(id: item.id)) }
                                    Button("Cancel") { store.cancel(id: item.id) }
                                } else if item.status == .failed {
                                    if item.isRetrying {
                                        Button("Cancel") { store.cancel(id: item.id) }
                                    } else {
                                        Button("Retry") { store.retry(id: item.id) }.disabled(!store.canRetry(id: item.id))
                                    }
                                } else if item.status == .choosingDestination {
                                    Button("Cancel") { store.cancel(id: item.id) }
                                }
                            }
                            if item.status == .downloading {
                                if let progress = item.progress { ProgressView(value: progress) }
                                else { ProgressView() }
                            }
                            Text(item.isRetrying ? String(localized: "Retrying…") : item.errorMessage ?? item.status.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .overlay(alignment: .bottom) { ChromeDivider().padding(.leading, 42) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay {
                    if store.entries.isEmpty {
                        Text("No downloads").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func fileIcon(_ item: DownloadItem) -> NSImage {
        if item.status == .finished, let url = item.destinationURL,
           FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
    }
}

struct DownloadsPanel: View {
    @Bindable var store: DownloadStore

    var body: some View {
        DownloadsView(store: store)
            .padding(20)
            .frame(width: 380, height: 380)
    }
}

private struct ShortcutCapture: NSViewRepresentable {
    var receive: (BrowserShortcut?) -> Void
    func makeNSView(context: Context) -> CaptureView { CaptureView(receive: receive) }
    func updateNSView(_ nsView: CaptureView, context: Context) { nsView.receive = receive }
    static func dismantleNSView(_ nsView: CaptureView, coordinator: ()) { nsView.stop() }

    final class CaptureView: NSView {
        var receive: (BrowserShortcut?) -> Void
        private var monitor: Any?
        init(receive: @escaping (BrowserShortcut?) -> Void) { self.receive = receive; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, event.window === self.window, self.window?.isKeyWindow == true else { return false }
                    if event.keyCode == 53 { self.receive(nil) }
                    else if let key = event.charactersIgnoringModifiers, !key.isEmpty {
                        self.receive(BrowserShortcut(key, event.modifierFlags))
                    }
                    return true
                }
                return handled ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    static let defaultBrowserSchemes = ["http", "https"]
    @Bindable var app: AppModel
    var extensionActionPage: (any BrowserPage)? = nil
    @State private var siteData: [WebsiteDataGroup] = []
    @State private var selectedWebsiteDataProfile: UUID?
    @State private var siteDataRequest = 0
    @State private var clearing = false
    @State private var message: String?
    @State private var settingDefaultBrowser = false
    @State private var ruleHost = ""
    @State private var ruleEngine: EngineID?

    var body: some View {
        Group {
            switch app.settingsSection {
            case .privacy, .blockers, .permissions: privacy
            case .history: LibraryView(app: app, openURL: { url, profileID in
                _ = app.newWindow(url: url, profileID: profileID)
            })
            case .shortcuts: ShortcutSettingsView(preferences: app.preferences)
            case .browsing: browsing
            case .design: DesignSettingsView(preferences: app.preferences)
            case .extensions: ExtensionSettingsView(app: app, actionPage: extensionActionPage)
            case .profiles: ProfileSettingsView(app: app)
            case .sync: SyncSettingsView(app: app)
            case .general: general
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(SettingsStyle.canvas)
    }

    private var general: some View {
        SettingsPage {
            if let readError = app.preferences.readError {
                SettingsGroup("Browser Settings Recovery") {
                    Text(readError).font(.callout).foregroundStyle(.orange)
                    Text("Reset browser preferences to restore settings changes. Cobble backs up the original settings file first.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Back Up and Reset Settings") {
                        if let backup = app.preferences.resetUnreadableSettings() {
                            message = String(format: String(localized: "Browser settings were reset. Original settings were backed up to %@."), backup.path)
                        } else {
                            message = app.preferences.errorMessage
                        }
                    }
                    if let error = app.preferences.errorMessage, error != readError {
                        Text(error).font(.callout).foregroundStyle(.orange)
                    }
                }
            }
            SettingsGroup("Updates") {
                if app.updates.isEnabled {
                    Toggle("Automatically check for updates", isOn: Binding(
                        get: { app.updates.automaticChecks },
                        set: { app.updates.setAutomaticChecks($0) }
                    ))
                    Text("Updates download from GitHub. You choose when to install and restart.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Automatic updates are available in Full release builds.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Check for Updates…", action: app.updates.checkForUpdates)
                    .disabled(!app.updates.canCheck)
                if let error = app.updates.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            }
            SettingsGroup("Browser") {
                SettingsRow("Default web engine", detail: "Used for new sites unless a site rule chooses another engine.") {
                    Picker("Default web engine", selection: Binding(
                        get: { app.preferences.defaultEngine },
                        set: { app.preferences.setDefaultEngine($0) }
                    )) {
                        ForEach(app.engines.engines, id: \.id) { Text($0.name).tag($0.id) }
                        if app.engines.engine(app.preferences.defaultEngine) == nil {
                            if app.engines.effectiveID(app.preferences.defaultEngine) == .webKit {
                                Text("Chromium (using WebKit)").tag(app.preferences.defaultEngine).disabled(true)
                            } else {
                                Text(String(format: String(localized: "Unavailable (%@)"), app.preferences.defaultEngine.rawValue)).tag(app.preferences.defaultEngine)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(app.preferences.readError != nil)
                }
                if app.engines.effectiveID(EngineID(rawValue: "chromium")) == .webKit {
                    Text("Chromium is not included in this build. Chromium tabs use WebKit temporarily; your engine preferences are remembered.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                SettingsRow("Experimental cross-engine login sharing", detail: "Attempts to carry login cookies when switching engines within the same profile. Existing cookies are kept unless you choose to replace them. Private windows are excluded. Some sites still require sign-in. Requires a compatible Full build.") {
                    Toggle("Experimental cross-engine login sharing", isOn: Binding(
                        get: { app.preferences.experimentalLoginSharing },
                        set: { app.preferences.setExperimentalLoginSharing($0) }
                    )).labelsHidden().toggleStyle(.switch)
                        .disabled(app.preferences.readError != nil)
                }
                if app.preferences.experimentalLoginSharing, let status = app.loginSharingMessage {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(String(format: String(localized: "Login sharing status: %@"), status))
                }
                Divider()
                SettingsRow("Default browser", detail: "Open web links from other apps in Cobble.") {
                    Button("Make Cobble the Default Browser") {
                        message = nil
                        settingDefaultBrowser = true
                        Task {
                            defer { settingDefaultBrowser = false }
                            for scheme in Self.defaultBrowserSchemes {
                                do {
                                    try await NSWorkspace.shared.setDefaultApplication(
                                        at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme)
                                } catch {
                                    message = String(format: String(localized: "Could not set Cobble for %@ links: %@"),
                                        scheme.uppercased(), error.localizedDescription)
                                    return
                                }
                            }
                            message = String(localized: "Cobble is the default for HTTP and HTTPS links.")
                        }
                    }.disabled(settingDefaultBrowser)
                }
            }
            SettingsGroup("Workspace") {
                SettingsRow("Backup and restore", detail: "Includes normal windows, tabs, spaces, pins, and favorites. Website data and private windows stay on this Mac.") {
                    Button("Export…") { exportWorkspace() }
                    Button("Restore…") { restoreWorkspace() }
                }
            }
            DownloadFolderSettingsView(preferences: app.preferences)
            SettingsGroup("Diagnostics") {
                SettingsRow("Redacted diagnostics", detail: "Saves app and OS versions, the local data directory, the last persistence error, and registered engine names. No page URLs, cookies, or browsing history.") {
                    Button("Export…") { exportDiagnostics() }
                }
            }
            if let text = app.persistenceMessage { Text(text).font(.callout).foregroundStyle(.orange) }
            else if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var browsing: some View {
        SettingsPage {
            SettingsGroup("Page Zoom") {
                Text("WebKit remembers zoom for each site in normal windows. Actual Size resets that site to 100%. Private-window zoom stays local. Forgetting permissions keeps zoom and browser identity.")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = app.siteSettings.lastError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            }
            SearchSettingsView(preferences: app.preferences)
            TabSettingsView(preferences: app.preferences)
            SettingsGroup("Page Tools") {
                SettingsRow("Developer Tools", detail: "WebKit pages appear in Safari’s Develop menu. Chromium pages open from View > Open Developer Tools. Enable this only while debugging.") {
                    Toggle("Enable Developer Tools", isOn: Binding(
                        get: { app.preferences.webInspectorEnabled },
                        set: { app.setWebInspectorEnabled($0) }
                    )).labelsHidden().toggleStyle(.switch)
                        .disabled(!app.engines.engines.contains {
                            !$0.capabilities.pageOperations.intersection([.inspect, .openDevTools]).isEmpty
                        })
                }
            }
            SettingsGroup("Engines") {
                ForEach(Array(app.engines.engines.enumerated()), id: \.element.id) { index, engine in
                    if index > 0 { Divider() }
                    SettingsRow(verbatim: engine.name, detail: capabilitySummary(engine)) {
                        if engine.id == app.preferences.defaultEngine {
                            Text("Default").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        } else {
                            Button("Make Default") { app.preferences.setDefaultEngine(engine.id) }
                        }
                    }
                }
            }
            SettingsGroup("Site Rules") {
                Text("Open matching websites with a specific engine. Rules apply to the exact host and take effect on the next navigation.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("example.com", text: $ruleHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addRule() }
                    Picker("Engine", selection: Binding(
                        get: { ruleEngine ?? app.preferences.defaultEngine },
                        set: { ruleEngine = $0 }
                    )) {
                        ForEach(app.engines.engines, id: \.id) { Text($0.name).tag($0.id) }
                        if app.engines.engine(app.preferences.defaultEngine) == nil {
                            Text(String(format: String(localized: "Unavailable (%@)"), app.preferences.defaultEngine.rawValue)).tag(app.preferences.defaultEngine)
                        }
                    }
                    .labelsHidden().frame(width: 170)
                    Button("Add") { addRule() }
                        .disabled(ruleHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || app.engines.engine(ruleEngine ?? app.preferences.defaultEngine) == nil)
                }
                ForEach(app.preferences.engineRules, id: \.host) { rule in
                    Divider()
                    SettingsRow(verbatim: rule.host) {
                        Text(app.engines.engine(rule.engineID)?.name ?? String(localized: "Unavailable"))
                            .foregroundStyle(.secondary)
                        Button("Remove", systemImage: "minus.circle") { removeRule(rule) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                Divider()
                SiteIdentityRulesView(app: app)
                if let error = app.preferences.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            }
        }
    }

    private var privacy: some View {
        VStack(spacing: 0) {
            Picker("Privacy area", selection: $app.settingsSection) {
                Text("Website Data").tag(SettingsSection.privacy)
                Text("Content Blocking").tag(SettingsSection.blockers)
                Text("Permissions").tag(SettingsSection.permissions)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 420)
            .padding(.top, 24)
            .padding(.bottom, 8)
            Group {
                switch app.settingsSection {
                case .blockers: ContentBlockingSettings(app: app)
                case .permissions: SitePermissionsView(app: app)
                default: websiteData
                }
            }
        }
        .background(SettingsStyle.canvas)
    }

    private var websiteData: some View {
        SettingsGroup("Website Data") {
            if app.profiles.count > 1 {
                Picker("Profile", selection: Binding(
                    get: { websiteDataProfileID },
                    set: { selectedWebsiteDataProfile = $0 }
                )) {
                    ForEach(app.profiles) { profile in Text(profile.displayedName).tag(profile.id) }
                }
                .frame(width: 220)
                .disabled(clearing)
            }
            Text("Website records are grouped by site. A registrable domain includes its subdomains; an IP address or internal hostname matches only itself. Remove clears cookies and site storage for that site, plus cached resources associated with it. Engines may also clear shared transient caches; some process-wide cached resources require all-sites clearing. Clear Data can remove profile data by category and time range. History visits are deleted in History settings. Cobble unloads affected pages first.")
                .font(.callout).foregroundStyle(.secondary)
            let unavailable = app.engines.engines.filter {
                !$0.capabilities.supportsWebsiteDataRemoval(categories: [.siteData, .cache], scope: .recordsAllTime)
            }
            if !unavailable.isEmpty {
                Text(String(format: String(localized: "Website data controls are unavailable for %@. Their cookies and site storage are not shown or removed here."), unavailable.map(\.name).joined(separator: ", ")))
                    .font(.callout).foregroundStyle(.secondary)
            }
            List(siteData) { site in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.displayName)
                        Text(siteEngineNames(site)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { remove(site) }.disabled(clearing)
                }
            }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Refresh") { refreshSites() }.disabled(clearing)
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
                }.disabled(clearing)
                Spacer()
                Text("Private browsing data is not listed.").font(.caption).foregroundStyle(.secondary)
            }
            if let message { Text(message).foregroundStyle(.orange) }
        }
        .settingsPane()
        .onAppear { refreshSites(profileID: websiteDataProfileID) }
        .onChange(of: websiteDataProfileID) { _, profileID in
            siteData = []
            message = nil
            refreshSites(profileID: profileID)
        }
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
        let engineID = ruleEngine ?? app.preferences.defaultEngine
        guard let url = URL(string: host.contains("://") ? host : "https://\(host)"),
              app.engines.engine(engineID) != nil,
              app.preferences.setEngineRule(for: url, engineID: engineID) else { return }
        ruleHost = ""
    }
    private func removeRule(_ rule: EngineRule) {
        guard let url = URL(string: "https://\(rule.host)") else { return }
        app.preferences.setEngineRule(for: url, engineID: nil)
    }
    private func siteEngineNames(_ site: WebsiteDataGroup) -> String {
        let ids = Set(site.members.map { $0.contextID.engineID })
        return app.engines.engines.filter { ids.contains($0.id) }.map(\.name).joined(separator: ", ")
    }
    private var websiteDataProfileID: UUID {
        if let selectedWebsiteDataProfile,
           app.profiles.contains(where: { $0.id == selectedWebsiteDataProfile }) {
            return selectedWebsiteDataProfile
        }
        return app.profiles[0].id
    }
    private func refreshSites(profileID: UUID? = nil) {
        guard !clearing else { return }
        let profileID = profileID ?? websiteDataProfileID
        siteDataRequest += 1
        let request = siteDataRequest
        Task {
            let result = await app.websiteData(profileID: profileID)
            guard request == siteDataRequest, profileID == websiteDataProfileID else { return }
            siteData = result.sites
            message = result.error
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
        let profileID = websiteDataProfileID
        let profileName = app.profiles.first(where: { $0.id == profileID })?.displayedName ?? String(localized: "Profile")
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
        siteDataRequest += 1
        let request = siteDataRequest
        Task {
            let removalMessage = await app.removeWebsiteData(profileID: profileID, site: site,
                categories: categories, modifiedSince: modifiedSince)
            let result = await app.websiteData(profileID: profileID)
            guard request == siteDataRequest, profileID == websiteDataProfileID else {
                if request == siteDataRequest { clearing = false }
                return
            }
            siteData = result.sites
            message = [removalMessage, result.error].compactMap { $0 }.joined(separator: "\n")
            if message?.isEmpty == true { message = nil }
            clearing = false
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

struct SettingsPage<Content: View>: View {
    var topPadding: CGFloat = 20
    let content: Content
    init(topPadding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.topPadding = topPadding
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) { content }
                .frame(maxWidth: SettingsStyle.contentWidth, alignment: .leading)
                .padding(.horizontal, SettingsStyle.pageInset)
                .padding(.top, topPadding)
                .padding(.bottom, 44)
                .frame(maxWidth: .infinity)
        }
        .background(SettingsStyle.canvas)
    }
}

struct SettingsGroup<Content: View>: View {
    let title: Text
    let content: Content
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.content = content()
    }
    init(verbatim title: String, @ViewBuilder content: () -> Content) {
        self.title = Text(verbatim: title)
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title
                .font(.title3.weight(.semibold))
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsStyle.groupBackground, in: RoundedRectangle(cornerRadius: SettingsStyle.groupCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsStyle.groupCornerRadius)
                        .stroke(SettingsStyle.groupBorder)
                }
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: Text
    var detail: Text?
    let accessory: Accessory
    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = Text(title)
        self.detail = detail.map { Text($0) }
        self.accessory = accessory()
    }
    init(_ title: LocalizedStringKey, detailVerbatim: String, @ViewBuilder accessory: () -> Accessory) {
        self.title = Text(title)
        self.detail = Text(verbatim: detailVerbatim)
        self.accessory = accessory()
    }
    init(verbatim title: String, detail: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = Text(verbatim: title)
        self.detail = detail.map { Text(verbatim: $0) }
        self.accessory = accessory()
    }
    var body: some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                title.font(.body.weight(.medium))
                if let detail {
                    detail
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 24)
            HStack(spacing: 8) { accessory }
                .controlSize(.regular)
        }
    }
}

enum SettingsStyle {
    static let contentWidth: CGFloat = 680
    static let pageInset: CGFloat = 32
    static let groupCornerRadius: CGFloat = 14
    static let canvas = Color(nsColor: .controlBackgroundColor)
    static let groupBackground = Color(nsColor: .controlBackgroundColor)
    static let groupBorder = Color.primary.opacity(0.10)
}

extension View {
    func settingsPane() -> some View {
        frame(maxWidth: SettingsStyle.contentWidth, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, SettingsStyle.pageInset)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SettingsStyle.canvas)
    }
}

private struct ExtensionSettingsView: View {
    @Bindable var app: AppModel
    var actionPage: (any BrowserPage)?
    @State private var selectedEngine: EngineID?
    @State private var selectedProfile: UUID?
    @State private var working = false
    @State private var revision = 0
    @State private var message: String?
    @State private var siteDrafts: [UUID: String] = [:]

    private var engines: [any BrowserEngine] { app.engines.engines.filter { $0.extensionManager != nil } }
    private var engine: (any BrowserEngine)? {
        engines.first { $0.id == selectedEngine } ?? engines.first
    }
    private var profileID: UUID {
        if let selectedProfile, app.profiles.contains(where: { $0.id == selectedProfile }) {
            return selectedProfile
        }
        if let actionProfile = actionPage?.contextID.profileID,
           app.profiles.contains(where: { $0.id == actionProfile }) {
            return actionProfile
        }
        return app.profiles[0].id
    }

    var body: some View {
        SettingsPage {
            if engines.isEmpty {
                ContentUnavailableView("Extensions Unavailable", systemImage: "puzzlepiece.extension",
                                       description: Text("None of the installed web engines support extensions."))
                    .frame(maxWidth: .infinity, minHeight: 360)
            } else if let engine, let manager = engine.extensionManager {
                HStack {
                    if engines.count > 1 {
                        Picker("Engine", selection: Binding(
                            get: { selectedEngine ?? engine.id },
                            set: { selectedEngine = $0 }
                        )) {
                            ForEach(engines, id: \.id) { Text($0.name).tag($0.id) }
                        }.frame(width: 220).disabled(working)
                    } else {
                        Text(String(format: String(localized: "Extensions for %@"), engine.name)).font(.headline)
                    }
                    if app.profiles.count > 1 {
                        Picker("Profile", selection: Binding(
                            get: { profileID },
                            set: { selectedProfile = $0 }
                        )) {
                            ForEach(app.profiles) { profile in Text(profile.displayedName).tag(profile.id) }
                        }.frame(width: 180).disabled(working)
                    }
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    Button("Install Extension…") { install(with: manager) }.disabled(working)
                }
                let items = extensions(from: manager)
                if items.isEmpty {
                    ContentUnavailableView("No Extensions", systemImage: "puzzlepiece.extension",
                                           description: Text(manager.capabilities.supportsProviderBundles
                                               ? "Install a compatible web extension from a folder, bundle, or ZIP file."
                                               : "Install a compatible web extension from an unpacked folder."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    ForEach(items) { item in extensionCard(item, manager: manager) }
                }
                if let error = message ?? manager.lastError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            }
        }
        .onAppear {
            for engine in engines {
                engine.extensionManager?.onChange = { revision += 1 }
            }
        }
    }

    private func extensions(from manager: any BrowserExtensionManaging) -> [BrowserExtensionInfo] {
        _ = revision
        return manager.extensions(profileID: profileID)
    }

    private func extensionCard(_ item: BrowserExtensionInfo, manager: any BrowserExtensionManaging) -> some View {
                SettingsGroup(verbatim: item.name) {
            SettingsRow(verbatim: String(format: String(localized: "Version %@"), item.version), detail: item.sourceURL.lastPathComponent) {
                if item.hasAction {
                    Button("Open") { openAction(item, manager: manager) }
                        .disabled(working || !item.isEnabled || actionPage == nil
                                  || actionPage?.contextID.engineID != engine?.id
                                  || actionPage?.contextID.profileID != profileID
                                  || (actionPage?.contextID.isPrivate == true && !item.allowsPrivateBrowsing))
                        .help("Open this extension for the browser tab that opened Settings")
                }
                Toggle("Enabled", isOn: Binding(
                    get: { item.isEnabled },
                    set: { enabled in perform { try await manager.setEnabled(enabled, id: item.id, profileID: item.profileID) } }
                )).toggleStyle(.switch).disabled(working)
            }
            if !item.requestedOrigins.isEmpty {
                Divider()
                Text("Website access").font(.callout.weight(.medium))
                if manager.capabilities.websiteAccess == .declaredPatterns {
                  ForEach(item.requestedOrigins, id: \.self) { origin in
                    Toggle(origin, isOn: Binding(
                        get: { item.allowedOrigins.contains(origin) },
                        set: { allowed in
                            var origins = Set(item.allowedOrigins)
                            if allowed { origins.insert(origin) } else { origins.remove(origin) }
                            perform { try await manager.setAllowedOrigins(origins.sorted(), id: item.id, profileID: item.profileID) }
                        }
                    )).disabled(working)
                }
                } else {
                    Text(verbatim: String(format: String(localized: "Requested: %@"), item.requestedOrigins.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(item.allowedOrigins, id: \.self) { origin in
                        SettingsRow(verbatim: origin) {
                            Button("Remove Access") {
                                perform {
                                    try await manager.setAllowedOrigins(item.allowedOrigins.filter { $0 != origin },
                                                                        id: item.id, profileID: item.profileID)
                                }
                            }.disabled(working)
                        }
                    }
                    HStack {
                        TextField("https://example.com", text: Binding(
                            get: { siteDrafts[item.id] ?? "" },
                            set: { siteDrafts[item.id] = $0 }
                        )).textFieldStyle(.roundedBorder)
                        Button("Allow Website") { grantSite(item, manager: manager) }
                            .disabled(working || (siteDrafts[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.disabled(working)
                }
            }
            if !item.deniedPermissions.isEmpty {
                Divider()
                SettingsRow("Unavailable permissions",
                            detailVerbatim: String(format: String(localized: "Cobble does not support: %@"), item.deniedPermissions.joined(separator: ", "))) { }
            }
            if !item.allowedOptionalPermissions.isEmpty {
                Divider()
                Text("Optional permissions").font(.callout.weight(.medium))
                ForEach(item.allowedOptionalPermissions, id: \.self) { permission in
                    SettingsRow(verbatim: permission) {
                        Button("Remove Access") {
                            perform {
                                try await manager.setAllowedOptionalPermissions(
                                    item.allowedOptionalPermissions.filter { $0 != permission },
                                    id: item.id, profileID: item.profileID)
                            }
                        }.disabled(working)
                    }
                }
            }
            Divider()
            let privateDetail: LocalizedStringKey = manager.capabilities.supportsPrivateBrowsing
                ? "Private tabs use separate browsing data."
                : "This engine does not support extensions in private windows."
            SettingsRow("Allow in Private Browsing", detail: privateDetail) {
                Toggle("Allow in Private Browsing", isOn: Binding(
                    get: { item.allowsPrivateBrowsing },
                    set: { allowed in perform { try await manager.setPrivateBrowsingAllowed(allowed, id: item.id, profileID: item.profileID) } }
                )).labelsHidden().toggleStyle(.switch).disabled(working || !manager.capabilities.supportsPrivateBrowsing)
            }
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
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.name).lineLimit(1)
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
                        }.padding(.vertical, 4)
                        .listRowBackground(Color.clear)
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
}

struct DownloadsPanel: View {
    @Bindable var store: DownloadStore

    var body: some View {
        DownloadsView(store: store)
            .padding(20)
            .frame(width: 380, height: 380)
    }
}

private struct LibraryView: View {
    @Bindable var app: AppModel
    var openURL: (URL, UUID) -> Void
    @State private var selectedProfile: UUID?
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
    private var profileID: UUID {
        if let selectedProfile, app.profiles.contains(where: { $0.id == selectedProfile }) {
            return selectedProfile
        }
        return app.profiles[0].id
    }
    var body: some View {
        SettingsGroup("Library") {
            HStack {
                if app.profiles.count > 1 {
                    Picker("Profile", selection: Binding(
                        get: { profileID },
                        set: { selectedProfile = $0 }
                    )) {
                        ForEach(app.profiles) { profile in Text(profile.displayedName).tag(profile.id) }
                    }.frame(width: 180)
                }
                TextField(bookmarksOnly ? "Search bookmarks" : "Search history", text: $query).textFieldStyle(.roundedBorder)
                Picker("Show", selection: $bookmarksOnly) {
                    Text("History").tag(false)
                    Text("Bookmarks").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            List(entries) { entry in
                HStack {
                    Button {
                        if let url = URL(string: entry.urlString) { openURL(url, profileID) }
                    } label: {
                        VStack(alignment: .leading) {
                            Label(entry.title, systemImage: entry.isBookmark ? "bookmark" : "clock").lineLimit(1)
                            Text(entry.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if !bookmarksOnly { Text(entry.visitedAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }.buttonStyle(.plain)
                    Spacer()
                    if bookmarksOnly {
                        Button("Edit…") {
                            editingProfile = profileID
                            bookmarkTitle = entry.title
                            bookmarkURL = entry.urlString
                            editError = nil
                            editingBookmark = entry
                        }
                    }
                    Button("Delete") {
                        if bookmarksOnly { store.removeBookmark(id: entry.id, profileID: profileID) }
                        else { store.removeHistoryEntry(id: entry.id, profileID: profileID) }
                        refresh()
                    }.help(bookmarksOnly ? "Remove library bookmark; keep browsing history" : "Remove from history; keep library bookmark")
                }
            }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Import…") { importBookmarks() }
                Button("Export…") { exportBookmarks() }
                Spacer()
                Picker("Clear", selection: $clearHours) {
                    Text("Last hour").tag(1)
                    Text("Last 24 hours").tag(24)
                    Text("Last 7 days").tag(168)
                    Text("All history").tag(0)
                }.frame(width: 200)
                Button("Clear History…") { clearHistory() }
            }
            HStack {
                Picker("Keep history", selection: $retention) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                    Text("Until I clear it").tag(0)
                }.frame(width: 270)
                Spacer()
            }
            Text("Shows the 100 most recent matching pages. Repeated visits update the last visit. Clearing a period removes pages last visited in that period; library bookmarks, pins and website data stay.")
                .font(.caption).foregroundStyle(.secondary)
            if let text = store.lastError ?? message { Text(text).font(.callout).foregroundStyle(.secondary) }
        }.settingsPane().onAppear { retention = store.retentionDays(profileID: profileID); refresh() }
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
                VStack(alignment: .leading, spacing: 16) {
                    Text("Edit Bookmark").font(.headline)
                    TextField("Title", text: $bookmarkTitle)
                    TextField("Address", text: $bookmarkURL)
                    if let editError { Text(editError).foregroundStyle(.red).font(.callout) }
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
                }.textFieldStyle(.roundedBorder).padding(24).frame(width: 440)
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

private struct SiteIdentityRulesView: View {
    @Bindable var app: AppModel
    @State private var selectedProfile: UUID?
    @State private var newOrigin = ""
    @State private var newIdentity: SiteBrowserIdentity = .iPhone

    private var profileID: UUID {
        if let selectedProfile, app.profiles.contains(where: { $0.id == selectedProfile }) {
            return selectedProfile
        }
        return app.profiles[0].id
    }

    var body: some View {
        Text("Choose a browser identity for an exact HTTP or HTTPS origin. Changes apply on the next navigation or reload. Page width stays unchanged.")
            .font(.callout).foregroundStyle(.secondary)
        ForEach(app.engines.engines.filter { !$0.capabilities.supportsBrowserIdentity }, id: \.id) { engine in
            Text("Browser identity rules are unavailable in \(engine.name).")
                .font(.callout).foregroundStyle(.secondary)
        }
        if app.profiles.count > 1 {
            Picker("Profile", selection: Binding(
                get: { profileID },
                set: { selectedProfile = $0 }
            )) {
                ForEach(app.profiles) { profile in Text(profile.displayedName).tag(profile.id) }
            }.frame(width: 220)
        }
        HStack {
            TextField("https://example.com", text: $newOrigin)
                .textFieldStyle(.roundedBorder)
                .onSubmit { add() }
            Picker("Browser identity", selection: $newIdentity) {
                ForEach(SiteBrowserIdentity.allCases, id: \.self) { identity in
                    Text(identity.title).tag(identity)
                }
            }.frame(width: 180)
            Button("Add") { add() }
                .disabled(newOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newIdentity == .standard)
        }
        ForEach(app.siteSettings.summaries(profileID: profileID, engines: app.engines.engines, includeIdentity: true)) { entry in
            SettingsRow(verbatim: entry.origin) {
                Picker("Browser identity", selection: Binding(
                    get: { entry.browserIdentity },
                    set: { set($0, for: entry.origin) }
                )) {
                    ForEach(SiteBrowserIdentity.allCases, id: \.self) { identity in
                        Text(identity.title).tag(identity)
                    }
                }.frame(width: 180)
            }
        }
        if let error = app.siteSettings.lastError {
            Text(error).font(.callout).foregroundStyle(.orange)
        }
    }

    private func add() {
        let text = newOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, newIdentity != .standard else { return }
        set(newIdentity, for: text)
        if app.siteSettings.lastError == nil { newOrigin = "" }
    }

    private func set(_ identity: SiteBrowserIdentity, for origin: String) {
        guard let url = URL(string: origin) else {
            app.siteSettings.lastError = String(localized: "Site rules require a valid HTTP or HTTPS origin.")
            return
        }
        _ = app.siteSettings.setBrowserIdentity(identity, for: url, profileID: profileID)
    }
}

private struct SitePermissionsView: View {
    @Bindable var app: AppModel
    @State private var selectedProfile: UUID?
    private var profileID: UUID {
        if let selectedProfile, app.profiles.contains(where: { $0.id == selectedProfile }) {
            return selectedProfile
        }
        return app.profiles[0].id
    }
    var body: some View {
        SettingsGroup("Saved Website Permissions") {
            if app.profiles.count > 1 {
                Picker("Profile", selection: Binding(
                    get: { profileID },
                    set: { selectedProfile = $0 }
                )) {
                    ForEach(app.profiles) { profile in Text(profile.displayedName).tag(profile.id) }
                }.frame(width: 220)
            }
            Text("Saved decisions apply to normal windows. Private windows ask separately. The address-bar site control can mute or stop capture on the current page without unloading it. Changing a remembered decision here unloads normal pages to stop capture; unsaved page content may be lost.")
                .font(.callout).foregroundStyle(.secondary)
            Text(BrowserEntitlements.hasWebBrowser
                 ? "This signed Cobble can offer system Apple Passwords and credential-provider AutoFill in WebKit fields. Cobble does not store passwords."
                 : "Apple Passwords AutoFill for arbitrary sites needs Apple’s web-browser entitlement on a signed Cobble after Account Holder approval. This build does not include it. Cobble does not store passwords.")
                .font(.callout).foregroundStyle(.secondary)
            Text(BrowserEntitlements.hasPasskeys
                 ? "This signed Cobble can use iCloud Keychain passkeys on WebKit pages."
                 : "Passkeys for arbitrary websites need Apple’s macOS browser passkey entitlement on a signed Cobble. This build cannot use iCloud Keychain passkeys.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Chromium Sign in with Apple uses the system WebKit sheet. Chromium password AutoFill still needs an SDK path. Cobble does not store passwords.")
                .font(.callout).foregroundStyle(.secondary)
            let entries = app.siteSettings.summaries(profileID: profileID, engines: app.engines.engines)
            if entries.isEmpty {
                Label("No remembered permissions", systemImage: "camera")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.origin).font(.headline)
                        HStack {
                            Picker("Camera", selection: Binding(get: { entry.camera }, set: { if let value = $0 { update(entry, camera: value) } })) {
                                ForEach(SitePermission.allCases, id: \.self) { Text(permissionTitle($0)).tag(Optional($0)) }
                                Text("Mixed").tag(nil as SitePermission?).disabled(true)
                            }.disabled(!app.engines.engines.contains { $0.capabilities.permissions.contains(.camera) })
                            Picker("Microphone", selection: Binding(get: { entry.microphone }, set: { if let value = $0 { update(entry, microphone: value) } })) {
                                ForEach(SitePermission.allCases, id: \.self) { Text(permissionTitle($0)).tag(Optional($0)) }
                                Text("Mixed").tag(nil as SitePermission?).disabled(true)
                            }.disabled(!app.engines.engines.contains { $0.capabilities.permissions.contains(.microphone) })
                            Button("Forget") {
                                if confirm(), app.siteSettings.forget(origin: entry.origin, profileID: profileID) { unloadPages() }
                            }
                        }
                    }.padding(.vertical, 6)
                }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if let error = app.siteSettings.lastError { Text(error).foregroundStyle(.orange) }
        }.settingsPane()
    }
    private func confirm() -> Bool {
        let alert = NSAlert(); alert.messageText = String(localized: "Change site permissions?")
        alert.informativeText = String(localized: "Normal pages will be unloaded to stop active capture. Unsaved page content may be lost.")
        alert.addButton(withTitle: String(localized: "Change and Unload")); alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func unloadPages() { app.windows.filter { !$0.isPrivate && $0.record.profileID == profileID }.forEach { $0.unloadPages() } }
    private func permissionTitle(_ value: SitePermission) -> String {
        switch value {
        case .ask: String(localized: "Ask")
        case .allow: String(localized: "Allow")
        case .deny: String(localized: "Deny")
        }
    }
    private func update(_ original: SiteSettingsStore.Summary, camera: SitePermission? = nil, microphone: SitePermission? = nil) {
        guard confirm() else { return }
        if app.siteSettings.update(origin: original.origin, profileID: profileID,
            camera: camera, microphone: microphone, engines: app.engines.engines) { unloadPages() }
    }
}

private struct ContentBlockingSettings: View {
    let app: AppModel
    @State private var selected: EngineID?
    @State private var selectedProfile: UUID?
    private var providers: [any BrowserEngine] { app.engines.engines.filter { $0.contentBlocker != nil } }
    private var profileID: UUID {
        if let selectedProfile, app.profiles.contains(where: { $0.id == selectedProfile }) {
            return selectedProfile
        }
        return app.profiles[0].id
    }
    var body: some View {
        VStack {
            if app.profiles.count > 1 {
                Picker("Profile", selection: Binding(
                    get: { profileID },
                    set: { selectedProfile = $0 }
                )) {
                    ForEach(app.profiles) { profile in Text(profile.displayedName).tag(profile.id) }
                }.frame(width: 220).padding(.top, 12)
            }
            if providers.count > 1 {
                Picker("Rule format", selection: Binding(get: { selected ?? providers[0].id }, set: { selected = $0 })) {
                    ForEach(providers, id: \.id) { provider in Text(String(format: String(localized: "%@ — %@"), provider.name, provider.contentBlocker!.formatName)).tag(provider.id) }
                }.frame(width: 320).padding(.top, 12)
            }
            if let provider = providers.first(where: { $0.id == selected }) ?? providers.first,
               let blocker = provider.contentBlocker {
                ContentBlockerView(app: app, blocker: blocker, profileID: profileID)
                    .id(ContentBlockerIdentity(profileID: profileID, blocker: ObjectIdentifier(blocker)))
            }
            else { ContentUnavailableView("Content Blocking Unavailable", systemImage: "hand.raised") }
        }
    }
}

private struct ContentBlockerIdentity: Hashable {
    let profileID: UUID
    let blocker: ObjectIdentifier
}

private struct ContentBlockerView: View {
    @Bindable var app: AppModel
    let blocker: any EngineContentBlocker
    let profileID: UUID
    @State private var working = false
    @State private var message: String?
    @State private var source = ""
    var body: some View {
        SettingsGroup("Content Blocking") {
            Text("Cobble Basic Tracker Rules block three common third-party tracking or ad hosts. They are a limited original baseline, not broad ad or annoyance filtering. Reload open pages after changing rules.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Install Cobble Basic Tracker Rules") { installBundledRules() }
                .disabled(working || blocker.hasRules(profileID: profileID))
            Text(String(format: String(localized: "Import a local %@ rule file to replace the current rules."), blocker.formatName))
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Enable rules", isOn: Binding(get: { blocker.isEnabled(profileID: profileID) }, set: { enabled in
                let targetProfile = profileID
                working = true
                Task { await blocker.setEnabled(enabled, profileID: targetProfile); working = false }
            })).disabled(working || !blocker.hasRules(profileID: profileID))
            Button("Import Rules…") { importRules() }.disabled(working)
            SettingsRow("Update source", detail: "Updates run only when you select Update Now. HTTPS JSON only; a failed update keeps the current rules.") {
                TextField("HTTPS JSON URL", text: $source).textFieldStyle(.roundedBorder).frame(minWidth: 240)
                Button("Save Source") { saveSource() }.disabled(working || !blocker.hasRules(profileID: profileID))
                Button("Update Now") { updateRules() }.disabled(working || source.isEmpty || !blocker.hasRules(profileID: profileID))
            }
            Text("Sites allowed through the blocker").font(.headline)
            List(blocker.exceptions(profileID: profileID), id: \.self) { origin in
                HStack {
                    Text(origin); Spacer()
                    Button("Remove Exception") {
                        guard let url = URL(string: origin) else { return }
                        let targetProfile = profileID
                        working = true
                        Task { await blocker.setException(origin: url, enabled: false, profileID: targetProfile); working = false }
                    }.disabled(working)
                }
            }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 10))
            Text("Use Page Actions to allow a site through the blocker. Exceptions match an exact origin, including its port.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = blocker.lastError ?? message { Text(error).foregroundStyle(.orange) }
        }
        .settingsPane()
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

struct ShortcutSettingsView: View {
    @Bindable var preferences: BrowserPreferences
    @State private var query = ""
    @State private var recording: BrowserCommand?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcuts")
                .font(.title3.weight(.semibold))
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            TextField("Search shortcuts", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(BrowserCommand.allCases.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { command in
                        HStack {
                            Text(command.title)
                            Spacer()
                            Button {
                                preferences.errorMessage = nil; recording = command
                            } label: {
                                Text(preferences.shortcut(for: command).label)
                                    .monospaced()
                                    .frame(minWidth: 110, minHeight: 24)
                                    .padding(.horizontal, 6)
                                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                                .accessibilityLabel(String(format: String(localized: "Change shortcut for %@: %@"), command.title, preferences.shortcut(for: command).label))
                            Button { preferences.set(BrowserShortcut(""), for: command) } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                                .disabled(preferences.shortcut(for: command).key.isEmpty)
                                .accessibilityLabel(String(format: String(localized: "Clear shortcut for %@"), command.title))
                        }.padding(.vertical, 8).padding(.horizontal, 12).accessibilityElement(children: .contain)
                        Divider().padding(.horizontal, 12)
                    }
                }
            }.frame(maxHeight: .infinity)
                .background(SettingsStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).stroke(SettingsStyle.groupBorder)
                }
            HStack {
                Text("Editing, Quit, Hide and Minimize use standard macOS shortcuts. Escape cancels; Return confirms dialogs.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset Shortcuts") { preferences.resetShortcuts() }
            }
            if let error = preferences.errorMessage { Text(error).foregroundStyle(.orange).font(.callout) }
        }.settingsPane()
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

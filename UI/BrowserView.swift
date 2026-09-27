import SwiftUI

struct BrowserView: View {
    @Bindable var window: BrowserWindowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedAddressSuggestion: String?
    @FocusState private var addressFocused: Bool
    @FocusState private var findFocused: Bool
    @State private var siteControlOpen = false
    @State private var addressHovered = false
    private var theme: BrowserThemeStyle {
        BrowserThemeStyle(provider: window.app.preferences.themeTemplate,
                          accent: Color(nsColor: window.app.preferences.themeAccentColor))
    }

    var body: some View {
        GeometryReader { geometry in
            let maximumWidth = min(440.0, max(260.0, Double(geometry.size.width) - 360))
            let sidebarWidth = min(maximumWidth, max(260, window.record.sidebarWidth ?? 280))
            let pinned = window.sidebarVisible
            let showing = pinned || window.sidebarPeeked
            let overlaying = showing && !pinned
            let windowStyle = window.app.preferences.windowStyle
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if pinned {
                        Color.clear.frame(width: sidebarWidth)
                    }
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: windowStyle.cornerRadius))
                        .padding(.vertical, windowStyle.contentInset)
                        .padding(.trailing, windowStyle.contentInset)
                        .padding(.leading, pinned ? 0 : windowStyle.contentInset)
                }
                .background { ZStack { SidebarMaterial(); theme.chromeBackground } }
                .disabled(window.commandBarPresented)
                .accessibilityHidden(window.commandBarPresented)
                if showing {
                    sidebarColumn(width: sidebarWidth, overlaying: overlaying)
                        .disabled(window.commandBarPresented)
                        .accessibilityHidden(window.commandBarPresented)
                    if !window.commandBarPresented {
                        SidebarResizeHandle(width: sidebarWidth, maximum: maximumWidth) {
                            window.record.sidebarWidth = $0
                        }
                        .frame(width: 32)
                        .offset(x: sidebarWidth - 16)
                    }
                }
                if !pinned {
                    SidebarPeekTracker(peeked: window.sidebarPeeked, sidebarWidth: sidebarWidth) {
                        window.sidebarPeeked = $0
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                }
                if window.commandBarPresented {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .onTapGesture { window.commandBarPresented = false }
                    CommandOverlay(window: window)
                        .frame(maxWidth: 560)
                        .padding(40)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .environment(\.font, window.app.preferences.browserChromeFont.swiftUIFont)
        .environment(\.browserTheme, theme)
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: window.sidebarVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: window.sidebarPeeked)
        .task(id: window.selectedTab?.id) { window.activateSelected() }
        .onChange(of: window.findPresented) { _, visible in
            if !visible { findFocused = false }
        }
        .onChange(of: window.findFocusRequest) { _, _ in
            Task { @MainActor in
                await Task.yield()
                guard window.findPresented else { return }
                findFocused = true
                await Task.yield()
                if findFocused, window.findPresented,
                   NSApp.keyWindow === window.selectedPage?.nativeView.window,
                   let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
                    editor.selectAll(nil)
                }
            }
        }
        .onChange(of: window.addressFocusRequest) { _, _ in
            window.revealSidebarChrome()
            addressFocused = true
            let focusWindow = NSApp.keyWindow
            Task { @MainActor in
                await Task.yield()
                if addressFocused, NSApp.keyWindow === focusWindow,
                   let editor = focusWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
                    editor.selectAll(nil)
                }
            }
        }
        .onChange(of: window.isEditingAddress) { _, editing in addressFocused = editing }
        .onChange(of: addressFocused) { _, focused in
            window.isEditingAddress = focused
            selectedAddressSuggestion = nil
        }
        .onChange(of: window.addressDraft) { _, _ in selectedAddressSuggestion = nil }
        .onChange(of: window.selectedTab?.id) { _, _ in
            window.findPresented = false
            siteControlOpen = false
        }
    }

    private func sidebarColumn(width: Double, overlaying: Bool) -> some View {
        VStack(spacing: 0) {
            navigationChrome
            if let message = window.app.persistenceMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.yellow.opacity(0.12))
            }
            if let message = window.app.contentBlocker?.lastError {
                Label(message, systemImage: "shield.slash").font(.callout).foregroundStyle(.orange).padding(8)
            }
            if let message = window.addressError {
                Text(message).foregroundStyle(.red).padding(8)
            }
            if window.isPrivate {
                Label("Private Window — browsing activity is not saved", systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            }
            SidebarView(window: window) { addressFocused = false }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .foregroundStyle(theme.primary)
        .transformEnvironment(\.colorScheme) { if theme.configuration.darkSidebar { $0 = .dark } }
        .transition(.move(edge: .leading).combined(with: .opacity))
        .overlay(alignment: .topLeading) { windowButtons }
        .background {
            ZStack {
                if overlaying { SidebarMaterial(blending: .withinWindow) }
                theme.sidebarBackground
            }
        }
    }

    private var windowButtons: some View {
        SidebarWindowControls().frame(width: 68, height: 28)
            .padding(.leading, ThemeMetrics.spacing * 2)
            .padding(.top, 11)
    }

    private var navigationChrome: some View {
        navigationBar.zIndex(1)
    }

    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    private func moveAddressSuggestion(_ offset: Int) -> KeyPress.Result {
        guard !hasMarkedText else { return .ignored }
        let suggestions = window.bangSuggestions.map { "bang:\($0.id)" }
            + window.addressSuggestions.map { "library:\($0.id)" }
        guard !suggestions.isEmpty else { return .ignored }
        if let selectedAddressSuggestion, let index = suggestions.firstIndex(of: selectedAddressSuggestion) {
            self.selectedAddressSuggestion = suggestions[min(suggestions.count - 1, max(0, index + offset))]
        } else {
            selectedAddressSuggestion = offset > 0 ? suggestions.first : suggestions.last
        }
        return .handled
    }

    private var navigationBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 68, height: 28)
                SidebarItemButton(systemImage: theme.symbol(.sidebar), help: "Toggle Sidebar",
                                  role: .toolbar) {
                    window.sidebarVisible.toggle()
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    let backDisabled = window.selectedPage?.canGoBack != true
                    let forwardDisabled = window.selectedPage?.canGoForward != true
                    if !theme.configuration.controls.navigation.hideWhenDisabled || !backDisabled || !forwardDisabled {
                        ThemeControlGroup(configuration: theme.configuration.groups.navigation) {
                            HStack(spacing: 0) {
                                SidebarItemButton(systemImage: theme.symbol(.back), help: "Back",
                                                  disabled: backDisabled, role: .navigation) { window.perform(.back) }
                                SidebarItemButton(systemImage: theme.symbol(.forward), help: "Forward",
                                                  disabled: forwardDisabled, role: .navigation) { window.perform(.forward) }
                            }
                        }
                    }
                    SidebarItemButton(
                        systemImage: theme.symbol(window.selectedPage?.isLoading == true ? .stop : .reload),
                        help: window.selectedPage?.isLoading == true ? "Stop" : "Reload",
                        disabled: window.selectedPage == nil && window.selectedTab?.urlString.isEmpty != false,
                        role: .toolbar
                    ) {
                        if window.selectedPage?.isLoading == true { window.perform(.stop) }
                        else { window.perform(.reload) }
                    }
                }
            }
            .frame(height: 34)
            .background(SidebarDragArea())
            HStack(spacing: 2) {
                TextField("Search or enter address", text: $window.addressDraft)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .onSubmit {
                        guard !hasMarkedText else { return }
                        submitSelectedAddressSuggestion()
                        addressFocused = window.isEditingAddress
                    }
                    .onKeyPress(.downArrow) { moveAddressSuggestion(1) }
                    .onKeyPress(.upArrow) { moveAddressSuggestion(-1) }
                    .onExitCommand {
                        guard !hasMarkedText else { return }
                        window.cancelAddressEditing(); addressFocused = false
                    }
                    .accessibilityLabel("Address and search")
                SidebarItemButton(systemImage: "link", help: "Copy Link",
                                  disabled: !window.canPerform(.copyURL)) { window.perform(.copyURL) }
                    .opacity(addressHovered ? 1 : 0)
                if let tabID = window.selectedTab?.id, window.showsMuteControl(tabID) {
                    SidebarItemButton(
                        systemImage: window.isAudioMuted(tabID) ? "speaker.slash" : "speaker.wave.2",
                        help: window.isAudioMuted(tabID)
                            ? "Unmute Tab"
                            : "Mute Tab — silence audio while playback continues"
                    ) { window.toggleMute(tabID) }
                }
                siteControlButton
                    .opacity(addressHovered || siteControlOpen || siteControlUrgent ? 1 : 0)
            }
            .onHover { addressHovered = $0 }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .frame(height: 36)
            .background(theme.pin, in: RoundedRectangle(cornerRadius: theme.controlCornerRadius))
            .overlay(alignment: .top) {
                if addressFocused, !window.bangSuggestions.isEmpty || !window.addressSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(window.bangSuggestions) { engine in
                            Button {
                                window.submitBangSuggestion(engine.id)
                                addressFocused = window.isEditingAddress
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.circle")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("!\(engine.bang) — \(engine.name)").lineLimit(1)
                                        Text(engine.template).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .contentShape(Rectangle())
                                .background(selectedAddressSuggestion == "bang:\(engine.id)" ? theme.selectedTab : .clear,
                                            in: RoundedRectangle(cornerRadius: theme.innerCornerRadius(inset: 4)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(format: String(localized: "Use !%@ for %@"), engine.bang, engine.name))
                            .accessibilityAddTraits(selectedAddressSuggestion == "bang:\(engine.id)" ? [.isSelected] : [])
                        }
                        ForEach(window.addressSuggestions) { entry in
                            Button {
                                window.submitAddressSuggestion(entry.id)
                                addressFocused = window.isEditingAddress
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: entry.isBookmark ? "bookmark" : "clock")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title.isEmpty ? entry.urlString : entry.title).lineLimit(1)
                                        Text(entry.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .contentShape(Rectangle())
                                .background(selectedAddressSuggestion == "library:\(entry.id)" ? theme.selectedTab : .clear,
                                            in: RoundedRectangle(cornerRadius: theme.innerCornerRadius(inset: 4)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(format: String(localized: "Open %@ in current tab"), entry.title.isEmpty ? entry.urlString : entry.title))
                            .accessibilityAddTraits(selectedAddressSuggestion == "library:\(entry.id)" ? [.isSelected] : [])
                        }
                    }
                    .padding(4)
                    .background {
                        RoundedRectangle(cornerRadius: theme.controlCornerRadius)
                            .fill(.ultraThickMaterial)
                            .overlay(RoundedRectangle(cornerRadius: theme.controlCornerRadius).fill(Color.black.opacity(0.42)))
                    }
                    .overlay(RoundedRectangle(cornerRadius: theme.controlCornerRadius).strokeBorder(Color.white.opacity(0.16)))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: 42)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Local address suggestions")
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, ThemeMetrics.spacing)
        .padding(.top, ThemeMetrics.spacing)
        .padding(.bottom, ThemeMetrics.spacing)
        .zIndex(1)
    }

    private func submitSelectedAddressSuggestion() {
        guard let id = selectedAddressSuggestion else { window.submitAddress(); return }
        if id.hasPrefix("bang:") {
            window.submitBangSuggestion(String(id.dropFirst(5)))
        } else if id.hasPrefix("library:"), let entryID = Int64(id.dropFirst(8)) {
            window.submitAddressSuggestion(entryID)
        } else {
            window.submitAddress()
        }
    }

    private var siteControlButton: some View {
        SidebarItemButton(systemImage: siteControlSymbol, help: "Site settings",
                          disabled: window.selectedTab?.url == nil, tint: siteControlColor) {
            siteControlOpen.toggle()
        }
        .accessibilityLabel(siteControlAccessibility)
        .overlay {
            SiteControlAnchor(tabID: window.selectedTab?.id,
                              contextID: window.selectedPage?.contextID,
                              isEnabled: !window.commandBarPresented && !siteControlOpen) { tabID, contextID in
                window.selectedTab?.id == tabID && window.selectedPage?.contextID == contextID
                    && !window.commandBarPresented && !siteControlOpen
            }
            .frame(width: 22, height: 22)
            .allowsHitTesting(false)
        }
        .frame(width: 22, height: 22)
        .popover(isPresented: $siteControlOpen, arrowEdge: .bottom) {
            SiteControlPopover(window: window) { siteControlOpen = false }
        }
    }

    private var siteControlSymbol: String {
        switch window.pageConnection {
        case .insecure, .mixed: return "exclamationmark.triangle.fill"
        default: return "shield"
        }
    }

    private var siteControlColor: Color {
        switch window.pageConnection {
        case .insecure, .mixed: return .orange
        default: return .secondary
        }
    }

    private var siteControlUrgent: Bool { siteControlColor != .secondary }

    private var siteControlAccessibility: String {
        var parts = [String(localized: "Site settings")]
        switch window.pageConnection {
        case .insecure: parts.append(String(localized: "not secure"))
        case .mixed: parts.append(String(localized: "mixed content"))
        case .secure: parts.append(String(localized: "connection is secure"))
        case .unknown, .empty: break
        }
        return parts.joined(separator: ", ")
    }

    private var findBar: some View {
        let state = window.selectedPage?.state
        let showMatchControls = !window.findText.isEmpty && state?.findMatchFound != false
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.white.opacity(0.72))
            TextField("Find in page", text: $window.findText)
                .textFieldStyle(.plain)
                .focusEffectDisabled()
                .focused($findFocused)
                .frame(minWidth: 96, maxWidth: .infinity)
                .onSubmit { if !hasMarkedText { window.perform(.findNext) } }
                .onChange(of: window.findText) { _, text in
                    guard !hasMarkedText else { return }
                    window.selectedPage?.find(text, backwards: false)
                }
                .accessibilityLabel("Find in page")
            if showMatchControls {
                SidebarItemButton(systemImage: "chevron.up", help: "Previous Match",
                                  tint: Color.white.opacity(0.86), pointSize: 14, side: 26) {
                    window.perform(.findPrevious)
                }
                SidebarItemButton(systemImage: "chevron.down", help: "Next Match",
                                  tint: Color.white.opacity(0.86), pointSize: 14, side: 26) {
                    window.perform(.findNext)
                }
            } else if state?.findQuery == window.findText, state?.findMatchFound == false {
                Text("No matches")
                    .foregroundStyle(.secondary)
            }
            SidebarItemButton(systemImage: "xmark", help: "Done",
                              tint: Color.white.opacity(0.86), pointSize: 14, side: 26) {
                dismissFind()
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 320, height: 44)
        .background {
            RoundedRectangle(cornerRadius: theme.controlCornerRadius)
                .fill(.ultraThickMaterial)
                .overlay(RoundedRectangle(cornerRadius: theme.controlCornerRadius).fill(Color.black.opacity(0.42)))
        }
        .overlay(RoundedRectangle(cornerRadius: theme.controlCornerRadius).strokeBorder(Color.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .environment(\.colorScheme, .dark)
        .onExitCommand { if !hasMarkedText { dismissFind() } }
    }

    private func dismissFind() {
        window.findPresented = false
        window.selectedPage?.find("", backwards: false)
        window.selectedPage?.focus()
    }

    @ViewBuilder private var page: some View {
        if let host = window.selectedPage {
            ZStack {
                BrowserPageView(host: host)
                if let message = host.errorMessage {
                    ContentUnavailableView {
                        Label(host.isCrashed ? "This tab stopped responding" : "Couldn’t open this page", systemImage: "globe.badge.chevron.backward")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { window.perform(.reload) }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                }
                if let link = host.state.hoveredLink {
                    Text(link)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Link destination")
                        .accessibilityValue(link)
                }
                if window.findPresented {
                    findBar
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        } else if let tab = window.selectedTab, let message = window.addressError {
            ContentUnavailableView {
                Label("Couldn’t open this page", systemImage: "globe.badge.chevron.backward")
            } description: { Text(message) } actions: {
                Button("Try Again") { window.reloadSelected() }
                if window.app.engines.engine(tab.engineID) == nil,
                   let alternative = window.app.engines.engine(window.app.preferences.defaultEngine) ?? window.app.engines.engines.first {
                    Button(String(format: String(localized: "Reopen with %@"), alternative.name)) { window.setEngine(alternative.id, for: tab.id) }
                }
            }
        } else {
            Color.clear
        }
    }
}

struct CommandOverlay: View {
    @Bindable var window: BrowserWindowModel
    @Environment(\.browserTheme) private var theme
    @FocusState private var queryFocused: Bool
    @State private var libraryMatches: [LibraryEntry] = []
    @State private var selection: Choice?

    private enum Choice: Hashable {
        case navigate, tab(UUID), library(Int64), command(BrowserCommand)
    }

    var matchingTabs: [Tab] {
        window.record.tabs.filter {
            $0.spaceID == window.record.selectedSpaceID &&
                (window.commandQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(window.commandQuery)
                    || $0.urlString.localizedCaseInsensitiveContains(window.commandQuery))
        }
    }

    private var hasQuery: Bool {
        !window.commandQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var matchingCommands: [BrowserCommand] { BrowserCommand.matching(window.commandQuery) }

    private var queryHasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    private var choices: [Choice] {
        (hasQuery ? [.navigate] : []) + matchingTabs.map { .tab($0.id) }
            + libraryMatches.prefix(8).map { .library($0.id) }
            + matchingCommands.filter { window.canPerform($0) }.map { .command($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search or enter a URL", text: $window.commandQuery)
                    .textFieldStyle(.plain)
                    .font(window.app.preferences.browserChromeFont.font(for: .title3))
                    .focused($queryFocused)
                    .onSubmit { if !queryHasMarkedText { activate(selection) } }
                    .onKeyPress(.downArrow) {
                        guard !queryHasMarkedText else { return .ignored }
                        moveSelection(1); return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !queryHasMarkedText else { return .ignored }
                        moveSelection(-1); return .handled
                    }
                    .accessibilityLabel("Search, URL, or open tab")
                Button("Close Search", systemImage: "xmark") { window.commandBarPresented = false }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(20)
            if let message = window.addressError {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            Color.white.opacity(0.16).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if hasQuery {
                            choiceButton(.navigate) {
                                Label(String(format: String(localized: "Open “%@” in a new tab"), window.commandQuery), systemImage: "arrow.up.right")
                            }
                        }
                        if !matchingTabs.isEmpty {
                            heading(String(localized: "OPEN TABS"))
                            ForEach(matchingTabs) { tab in
                                choiceButton(.tab(tab.id)) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "globe").foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(tab.displayedTitle).lineLimit(1)
                                            if !tab.urlString.isEmpty {
                                                Text(tab.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        if window.selectedTab?.id == tab.id {
                                            Image(systemName: "checkmark").foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        if !libraryMatches.isEmpty {
                            heading(String(localized: "HISTORY & BOOKMARKS"))
                            ForEach(libraryMatches.prefix(8)) { entry in
                                choiceButton(.library(entry.id)) {
                                    Label(entry.title.isEmpty ? entry.urlString : entry.title, systemImage: entry.isBookmark ? "bookmark" : "clock")
                                        .lineLimit(1)
                                }
                                .accessibilityLabel(String(format: String(localized: "Open %@ in a new tab"), entry.title.isEmpty ? entry.urlString : entry.title))
                            }
                        }
                        Color.white.opacity(0.16).frame(height: 1).padding(.vertical, 4)
                        if !matchingCommands.isEmpty {
                            heading(String(localized: "ACTIONS"))
                            ForEach(matchingCommands) { command in
                                choiceButton(.command(command)) {
                                    HStack {
                                        Text(command.title)
                                        Spacer()
                                        Text(window.app.preferences.shortcut(for: command).label)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .disabled(!window.canPerform(command))
                                .accessibilityLabel(command.title)
                                .help(command.explanation ?? command.title)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(maxHeight: 350)
                .onChange(of: selection) { _, choice in
                    if let choice { proxy.scrollTo(choice) }
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: theme.controlCornerRadius)
                .fill(.ultraThickMaterial)
                .overlay(RoundedRectangle(cornerRadius: theme.controlCornerRadius).fill(Color.black.opacity(0.42)))
        }
        .overlay(RoundedRectangle(cornerRadius: theme.controlCornerRadius).strokeBorder(Color.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .onAppear { refreshSuggestions() }
        .task {
            await Task.yield()
            queryFocused = true
        }
        .onChange(of: window.commandQuery) { _, _ in
            window.addressError = nil
            selection = nil
            refreshSuggestions()
        }
        .onChange(of: window.app.library.revision) { _, _ in refreshSuggestions() }
        .onChange(of: window.record.profileID) { _, _ in refreshSuggestions() }
        .onExitCommand { if !queryHasMarkedText { window.commandBarPresented = false } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Search and tabs"))
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(10)
    }

    private func choiceButton<Content: View>(_ choice: Choice, @ViewBuilder content: () -> Content) -> some View {
        Button { activate(choice) } label: {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .contentShape(Rectangle())
                .background(selection == choice ? theme.hover : Color.clear,
                            in: RoundedRectangle(cornerRadius: theme.controlCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == choice ? [.isSelected] : [])
        .id(choice)
    }

    private func moveSelection(_ offset: Int) {
        let options = choices
        guard !options.isEmpty else { return }
        if let selection, let position = options.firstIndex(of: selection) {
            self.selection = options[min(options.count - 1, max(0, position + offset))]
        } else {
            selection = offset > 0 ? options.first : options.last
        }
    }

    private func activate(_ choice: Choice?) {
        switch choice {
        case .tab(let id) where matchingTabs.contains(where: { $0.id == id }):
            window.select(id)
            window.commandBarPresented = false
        case .library(let id):
            guard !window.isPrivate,
                  let entry = window.app.library.search(window.commandQuery, profileID: window.record.profileID)
                    .prefix(8).first(where: { $0.id == id }), let url = URL(string: entry.urlString) else { return }
            window.addTab(url: url)
            window.commandBarPresented = false
        case .command(let command):
            guard matchingCommands.contains(command), window.canPerform(command) else { return }
            window.commandBarPresented = false
            window.dispatch(command)
        case .navigate, .tab, nil:
            window.submitCommand()
        }
    }

    private func refreshSuggestions() {
        libraryMatches = window.isPrivate ? [] : window.app.library.search(window.commandQuery, profileID: window.record.profileID)
        if let selection, !choices.contains(selection) { self.selection = nil }
    }
}

struct SiteControlPopover: View {
    @Bindable var window: BrowserWindowModel
    @State private var connectionDetails: PageConnectionDetails?
    @State private var connectionDetailsError: String?
    @State private var connectionDetailsHeight: CGFloat = 180
    var dismiss: () -> Void = {}
    private var origin: String? {
        window.selectedTab?.url.flatMap(AddressResolver.canonicalOrigin)
    }
    private var engine: (any BrowserEngine)? {
        window.app.engines.engine(window.selectedPage?.contextID.engineID
            ?? window.app.engines.effectiveID(window.selectedTab?.engineID ?? window.app.preferences.defaultEngine))
    }
    private var setting: SiteSetting? {
        guard !window.isPrivate, let url = window.selectedTab?.url else { return nil }
        return window.app.siteSettings.setting(origin: url, profileID: window.record.profileID,
            engineID: engine?.id ?? window.app.preferences.defaultEngine)
    }
    private var capabilities: EngineCapabilities {
        window.selectedPageCapabilities
    }
    var showsCombinedCaptureControl: Bool {
        capabilities.captureControls.contains(.stopAllUserMedia)
            && window.selectedPage.map { $0.state.camera != .none || $0.state.microphone != .none } == true
    }
    var combinedCaptureDisclosure: String? {
        guard showsCombinedCaptureControl, !window.isPrivate else { return nil }
        return String(localized: "Permission changes apply to the next request. Stop Camera and Microphone ends the current capture.")
    }
    var showsDisplayCapture: Bool { window.selectedPage?.state.isDisplayCapturing == true }
    var displayCaptureDisclosure: String? {
        showsDisplayCapture
            ? String(localized: "Cobble can show that this page is sharing your screen, but cannot stop or change it here.")
            : nil
    }
    private var target: (UUID?, String?, EngineID?) { (window.selectedTab?.id, origin, engine?.id) }
    var body: some View {
        let displayedTarget = target
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SiteShareButton(isEnabled: window.canPerform(.sharePage)) { button in
                    guard target == displayedTarget else { return }
                    let event = NSApp.currentEvent
                    let mouseDown = event?.type == .leftMouseDown && event?.window === button.window
                        && button.bounds.contains(button.convert(event?.locationInWindow ?? .zero, from: nil))
                    window.sharePage(from: mouseDown ? button : nil)
                }
                .frame(width: 44, height: 32)
                if capabilities.pageOperations.contains(.snapshot) {
                    action(.screenshot, symbol: "camera")
                }
                action(.copyURL, symbol: "link")
                Spacer(minLength: 0)
            }
            if window.selectedPage?.state.blockedPopup == true {
                Label("A popup was blocked.", systemImage: "macwindow.badge.plus")
                    .font(.callout).foregroundStyle(.orange)
            }
            if !capabilities.permissions.isEmpty || (setting != nil && capabilities.supportsPopupPolicy) || showsDisplayCapture {
                VStack(spacing: 8) {
                    if capabilities.permissions.contains(.camera) {
                        permissionRow(String(localized: "Camera"), symbol: "video.fill", kind: .camera,
                            capture: window.selectedPage?.state.camera ?? .none, value: setting?.camera ?? .ask)
                    }
                    if capabilities.permissions.contains(.microphone) {
                        permissionRow(String(localized: "Microphone"), symbol: "mic.fill", kind: .microphone,
                            capture: window.selectedPage?.state.microphone ?? .none, value: setting?.microphone ?? .ask)
                    }
                    if showsDisplayCapture {
                        settingsRow(String(localized: "Screen sharing"), detail: String(localized: "In use"),
                                    symbol: "rectangle.on.rectangle", editable: false)
                        Text(displayCaptureDisclosure ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if showsCombinedCaptureControl {
                        if let combinedCaptureDisclosure {
                            Text(combinedCaptureDisclosure).font(.caption).foregroundStyle(.secondary)
                        }
                        Button(String(localized: "Stop Camera and Microphone")) {
                            guard target == displayedTarget else { return }
                            window.selectedPage?.stopMediaCapture()
                        }
                        .buttonStyle(SiteActionButtonStyle())
                    }
                    if let setting, capabilities.supportsPopupPolicy {
                        settingsRow(String(localized: "Popups"), detail: permissionName(setting.popups), symbol: "macwindow.on.rectangle")
                            .overlay {
                                permissionMenu(String(localized: "Popups"), value: setting.popups) { permission in
                                    guard target == displayedTarget else { return }
                                    window.setPopups(permission)
                                }
                            }
                            .help(String(localized: "Ask uses a click. Allow lets this site open windows on its own. Deny keeps only clicked links."))
                    }
                }
            }
            if window.isPrivate {
                Label("Private window · Permissions aren’t saved", systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = window.app.siteSettings.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack {
                Label(connectionTitle, systemImage: connectionSymbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle([.mixed, .insecure].contains(window.pageConnection) ? Color.orange : Color.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help(connectionText)
                    .accessibilityLabel(connectionText)
                Spacer()
                Menu {
                    pageActions
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .help(String(localized: "Page Actions")).accessibilityLabel(String(localized: "Page Actions"))
            }
            if let details = connectionDetails,
               details.certificate != nil || !details.certificateChain.isEmpty
                || details.certificateChainTruncated || !connectionIssues(details).isEmpty {
                connectionDetailsView(details)
            }
            if let connectionDetailsError {
                Text(connectionDetailsError).font(.caption).foregroundStyle(.red)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 280, alignment: .leading)
        .padding(14)
        .task(id: window.selectedPage?.state.connectionDetailsRevision) {
            await loadConnectionDetails()
        }
    }

    @ViewBuilder private func connectionDetailsView(_ details: PageConnectionDetails) -> some View {
        let issues = connectionIssues(details)
        ScrollView {
            connectionDetailsContent(details, issues: issues)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    connectionDetailsHeight = height
                }
        }
        .frame(height: min(connectionDetailsHeight, 180))
    }

    @ViewBuilder private func connectionDetailsContent(_ details: PageConnectionDetails,
                                                        issues: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let certificate = details.certificate {
                Text("Certificate").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(certificate.subject).font(.caption).lineLimit(2)
                    .help(certificate.subject).textSelection(.enabled)
                let issuer = String(format: String(localized: "Issued by %@"), certificate.issuer)
                Text(issuer).font(.caption).lineLimit(2)
                    .help(issuer).textSelection(.enabled)
                if let from = certificate.validFrom, let until = certificate.validUntil {
                    Text(String(format: String(localized: "Valid %@ – %@"),
                        from.formatted(date: .abbreviated, time: .omitted),
                        until.formatted(date: .abbreviated, time: .omitted))).font(.caption)
                }
            }
            if !details.certificateChain.isEmpty || details.certificateChainTruncated {
                DisclosureGroup {
                    ForEach(Array(details.certificateChain.enumerated()), id: \.offset) { index, certificate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(index == 0 ? String(localized: "Leaf certificate")
                                : String(format: String(localized: "Certificate %@"), "\(index + 1)"))
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(certificate.subject).font(.caption).lineLimit(2)
                                .help(certificate.subject).textSelection(.enabled)
                            let issuer = String(format: String(localized: "Issued by %@"), certificate.issuer)
                            Text(issuer).font(.caption).lineLimit(2)
                                .help(issuer).textSelection(.enabled)
                            if let from = certificate.validFrom, let until = certificate.validUntil {
                                Text(String(format: String(localized: "Valid %@ – %@"),
                                    from.formatted(date: .abbreviated, time: .omitted),
                                    until.formatted(date: .abbreviated, time: .omitted))).font(.caption)
                            }
                        }
                    }
                } label: {
                    Text("Certificate Chain").font(.caption.weight(.semibold))
                }
                if details.certificateChainTruncated {
                    Text("Some certificate details aren’t shown.")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Some certificate details aren’t shown.")
                }
            }
            ForEach(issues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2).help(issue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadConnectionDetails() async {
        connectionDetails = nil
        connectionDetailsError = nil
        guard let host = window.selectedPage,
              host.state.connectionDetailsReady, let expectedURL = window.selectedTab?.url else { return }
        do {
            let details = try await host.connectionDetails()
            guard !Task.isCancelled, window.selectedPage === host,
                  window.selectedTab?.url == expectedURL,
                  details?.url == expectedURL else { return }
            connectionDetails = details
        } catch {
            guard !Task.isCancelled, window.selectedPage === host,
                  window.selectedTab?.url == expectedURL else { return }
            connectionDetailsError = String(format: String(localized: "Connection details unavailable: %@"),
                error.localizedDescription)
        }
    }

    private func connectionIssues(_ details: PageConnectionDetails) -> [String] {
        var issues = details.certificateErrors
        if details.connection == .mixed && !details.mixedContent.hasIssues {
            issues.append(String(localized: "Insecure content was detected"))
        }
        if details.mixedContent.ran { issues.append(String(localized: "Ran insecure content")) }
        if details.mixedContent.displayed { issues.append(String(localized: "Displayed insecure content")) }
        if details.mixedContent.containedForm { issues.append(String(localized: "Contains an insecure form")) }
        if details.mixedContent.ranWithCertificateErrors {
            issues.append(String(localized: "Ran content with certificate errors"))
        }
        if details.mixedContent.displayedWithCertificateErrors {
            issues.append(String(localized: "Displayed content with certificate errors"))
        }
        return issues
    }

    private func action(_ command: BrowserCommand, symbol: String) -> some View {
        Button { run(command) } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 32)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!window.canPerform(command))
        .help(command == .screenshot ? String(localized: "Save the visible page as a screenshot") : command.title)
        .accessibilityLabel(command.title)
    }

    private func run(_ command: BrowserCommand) {
        let tabID = window.selectedTab?.id
        let page = window.selectedPage
        let url = window.selectedTab?.urlString
        dismiss()
        Task { @MainActor in
            await Task.yield()
            guard window.selectedTab?.id == tabID, window.selectedPage === page,
                  window.selectedTab?.urlString == url, page?.nativeView.window?.attachedSheet == nil else { return }
            window.perform(command)
        }
    }

    @ViewBuilder private var pageActions: some View {
        let displayedTarget = target
        Button("Find in Page…") { run(.find) }.disabled(!window.canPerform(.find))
        Button("Zoom In") { window.perform(.zoomIn) }.disabled(!window.canPerform(.zoomIn))
        Button("Zoom Out") { window.perform(.zoomOut) }.disabled(!window.canPerform(.zoomOut))
        Button("Actual Size") { window.perform(.zoomReset) }.disabled(!window.canPerform(.zoomReset))
        Button("Reload from Origin") { run(.reloadFromOrigin) }.disabled(!window.canPerform(.reloadFromOrigin))
            .help(BrowserCommand.reloadFromOrigin.explanation!)
        Divider()
        Button(window.selectedPage?.state.isAudioMuted == true ? String(localized: "Unmute Tab") : String(localized: "Mute Tab")) {
            window.perform(.muteTab)
        }.disabled(!window.canPerform(.muteTab))
        Button("Allow This Site Through Content Blocker") {
            if target == displayedTarget, let url = window.selectedTab?.url {
                let host = window.selectedPage
                let blocker = engine?.contentBlocker
                let profileID = window.record.profileID
                Task {
                    await blocker?.setException(origin: url, enabled: true, profileID: profileID)
                    guard window.selectedPage === host, window.selectedTab?.url == url else { return }
                    host?.reload()
                }
            }
        }.disabled(window.isPrivate || origin == nil || engine?.contentBlocker == nil)
        Button("Add Library Bookmark") { window.perform(.bookmark) }.disabled(!window.canPerform(.bookmark))
        Divider()
        Button("Unload Tab") { run(.unload) }.disabled(!window.canPerform(.unload))
            .help(BrowserCommand.unload.explanation!)
    }

    private var connectionTitle: String {
        switch window.pageConnection {
        case .secure: String(localized: "Secure")
        case .mixed: String(localized: "Mixed content")
        case .insecure: String(localized: "Not secure")
        case .unknown: String(localized: "Unknown")
        case .empty: String(localized: "Local page")
        }
    }
    private var connectionSymbol: String {
        switch window.pageConnection {
        case .secure: "lock.fill"
        case .mixed, .insecure: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        case .empty: "doc"
        }
    }
    private var connectionText: String {
        switch window.pageConnection {
        case .secure: String(localized: "Connection is secure")
        case .mixed: String(localized: "Not fully secure — this page mixed HTTPS with insecure content")
        case .insecure: String(localized: "Not secure")
        case .unknown: String(localized: "This page’s connection has not been verified")
        case .empty: String(localized: "No web page")
        }
    }

    private func permissionName(_ value: SitePermission) -> String {
        switch value {
        case .allow: String(localized: "Allowed")
        case .deny: String(localized: "Blocked")
        case .ask: String(localized: "Ask Each Time")
        }
    }
    private func settingsRow(_ title: String, detail: String, symbol: String, editable: Bool = true) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                .frame(width: 34, height: 34)
                .background(.primary.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if editable { Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    private func permissionMenu(_ title: String, value: SitePermission, choose: @escaping (SitePermission) -> Void) -> some View {
        SiteMenuAnchor(label: "\(title), \(permissionName(value))", entries: SitePermission.allCases.map { permission in
            (permissionName(permission), value == permission, { choose(permission) })
        })
    }
    private func permissionRow(_ title: String, symbol: String, kind: PermissionKind, capture: PageCapture, value: SitePermission) -> some View {
        let displayedTarget = target
        let detail = window.isPrivate ? String(localized: "Ask Each Time") : permissionName(value)
        return VStack(alignment: .leading, spacing: 7) {
            if !window.isPrivate {
                settingsRow(title, detail: detail, symbol: symbol)
                    .overlay {
                        permissionMenu(title, value: value) { permission in
                            guard target == displayedTarget else { return }
                            window.setSitePermission(kind, permission)
                        }
                    }
            } else {
                settingsRow(title, detail: detail, symbol: symbol, editable: false)
            }
            if capture != .none {
                HStack(spacing: 8) {
                    Text(capture == .active ? String(localized: "In use") : String(localized: "Muted"))
                        .font(.caption.weight(.medium)).foregroundStyle(capture == .active ? Color.orange : Color.secondary)
                    Spacer()
                    if capabilities.captureControls.contains(.mute(kind)) {
                        Button(capture == .active ? String(localized: "Mute") : String(localized: "Unmute")) {
                            guard target == displayedTarget else { return }
                            window.selectedPage?.setCapture(kind, capture == .active ? .muted : .active)
                        }.accessibilityLabel(String(format: String(localized: "%@ %@"), capture == .active ? String(localized: "Mute") : String(localized: "Unmute"), title))
                    }
                    if capabilities.captureControls.contains(.stop(kind)) {
                        Button(String(localized: "Stop")) {
                            guard target == displayedTarget else { return }
                            window.selectedPage?.setCapture(kind, .none)
                        }
                            .accessibilityLabel(String(format: String(localized: "Stop %@"), title))
                    }
                }
                .buttonStyle(SiteActionButtonStyle())
                .padding(.leading, 44)
            }
        }
    }
}

// SwiftUI's macOS Menu flattens a multi-line label into a native popup title.
// Keep the rendered row and use a transparent native menu target above it.
private struct SiteMenuAnchor: NSViewRepresentable {
    var label: String
    var entries: [(title: String, selected: Bool, action: () -> Void)]
    func makeNSView(context: Context) -> MenuView { MenuView() }
    func updateNSView(_ view: MenuView, context: Context) {
        view.setAccessibilityLabel(label)
        view.entries = entries
    }
    final class MenuView: NSView {
        var entries: [(title: String, selected: Bool, action: () -> Void)] = []
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityRole(.popUpButton)
            focusRingType = .none
        }
        required init?(coder: NSCoder) { nil }
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { showMenu() }
        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               [36, 49, 125].contains(event.keyCode) { showMenu() }
            else { super.keyDown(with: event) }
        }
        override func accessibilityPerformPress() -> Bool { showMenu(); return true }
        override func accessibilityPerformShowMenu() -> Bool { showMenu(); return true }
        private func showMenu() {
            guard window != nil else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for entry in entries {
                let action = MenuAction(entry.action)
                let item = NSMenuItem(title: entry.title, action: #selector(MenuAction.choose), keyEquivalent: "")
                item.target = action
                item.representedObject = action
                item.state = entry.selected ? .on : .off
                menu.addItem(item)
            }
            menu.popUp(positioning: menu.items.first { $0.state == .on },
                at: NSPoint(x: bounds.maxX - 8, y: bounds.midY), in: self)
        }
    }
    final class MenuAction: NSObject {
        let run: () -> Void
        init(_ action: @escaping () -> Void) { run = action }
        @objc func choose() { run() }
    }
}

// The system sharing picker requires a mouse-down action and a live native anchor.
private struct SiteShareButton: NSViewRepresentable {
    var isEnabled: Bool
    var share: (NSButton) -> Void
    func makeNSView(context: Context) -> ShareButton { ShareButton() }
    func updateNSView(_ view: ShareButton, context: Context) {
        view.isEnabled = isEnabled
        view.share = share
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShareButton, context: Context) -> CGSize? {
        CGSize(width: 44, height: 32)
    }
    final class ShareButton: NSButton {
        var share: ((NSButton) -> Void)?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let label = String(localized: "Share Page…")
            title = label
            image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
            imagePosition = .imageOnly
            contentTintColor = .labelColor
            isBordered = false
            setButtonType(.momentaryChange)
            target = self
            action = #selector(showSharing)
            sendAction(on: [.leftMouseDown])
            setAccessibilityLabel(label)
            toolTip = label
        }
        required init?(coder: NSCoder) { nil }
        override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 32) }
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
        @objc private func showSharing() { share?(self) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.2 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            super.draw(dirtyRect)
        }
    }
}

// Separate native AppKit button instances: NSWindow cannot reposition these during titlebar updates.
private struct SidebarWindowControls: NSViewRepresentable {
    func makeNSView(context: Context) -> ControlsView { ControlsView() }
    func updateNSView(_ view: ControlsView, context: Context) {}

    final class ControlsView: NSView {
        private let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        private var buttons: [NSButton] = []
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let actions = [#selector(NSWindow.performClose(_:)), #selector(NSWindow.performMiniaturize(_:)), #selector(NSWindow.toggleFullScreen(_:))]
            for (index, kind) in kinds.enumerated() {
                guard let button = NSWindow.standardWindowButton(kind, for: [.titled, .closable, .miniaturizable, .resizable]) else { continue }
                button.identifier = NSUserInterfaceItemIdentifier("sidebar.window.\(index)")
                button.action = actions[index]
                button.autoresizingMask = []
                addSubview(button); buttons.append(button)
            }
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for kind in kinds { window?.standardWindowButton(kind)?.isHidden = true }
            buttons.forEach { $0.target = window }
            needsLayout = true
        }
        override func layout() {
            super.layout()
            for (index, button) in buttons.enumerated() {
                button.setFrameOrigin(NSPoint(x: CGFloat(index) * 22, y: (bounds.height - button.frame.height) / 2))
            }
        }
    }
}

// AppKit owns the whole 32-point boundary, including its cursor and drag sequence.
// A SwiftUI hover cursor can be overwritten by the adjacent engine view.
struct SidebarResizeHandle: NSViewRepresentable {
    var width: Double
    var maximum: Double
    var setWidth: (Double?) -> Void

    func makeNSView(context: Context) -> ResizeView { ResizeView() }
    func updateNSView(_ view: ResizeView, context: Context) {
        view.width = width
        view.maximum = maximum
        view.setWidth = setWidth
    }

    final class ResizeView: NSView {
        var width = 280.0
        var maximum = 440.0
        var setWidth: ((Double?) -> Void)?
        private var dragStart: (x: Double, width: Double)?
        private var hovering = false
        private var tracking: NSTrackingArea?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            setAccessibilityElement(true)
            setAccessibilityRole(.splitter)
            setAccessibilityLabel(String(localized: "Sidebar width"))
            setAccessibilityOrientation(.vertical)
            toolTip = String(localized: "Drag to resize sidebar. Double-click to reset.")
        }
        required init?(coder: NSCoder) { nil }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
        override func updateTrackingAreas() {
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self)
            addTrackingArea(area)
            tracking = area
            super.updateTrackingAreas()
        }
        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseMoved(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseEntered(with event: NSEvent) {
            hovering = true
            NSCursor.resizeLeftRight.set()
        }
        override func mouseExited(with event: NSEvent) {
            hovering = false
            if dragStart == nil { NSCursor.arrow.set() }
        }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                dragStart = nil
                width = min(maximum, 280)
                setWidth?(nil)
            } else {
                dragStart = (event.locationInWindow.x, width)
            }
            NSCursor.resizeLeftRight.set()
        }
        override func mouseDragged(with event: NSEvent) {
            guard let dragStart else { return }
            changeWidth(dragStart.width + event.locationInWindow.x - dragStart.x)
            NSCursor.resizeLeftRight.set()
        }
        override func mouseUp(with event: NSEvent) {
            dragStart = nil
            hovering = bounds.contains(convert(event.locationInWindow, from: nil))
            (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }
        override func accessibilityValue() -> Any? { "\(Int(width)) points" }
        override func accessibilityPerformIncrement() -> Bool { changeWidth(width + 20); return true }
        override func accessibilityPerformDecrement() -> Bool { changeWidth(width - 20); return true }
        private func changeWidth(_ proposed: Double) {
            width = min(maximum, max(260, proposed))
            setWidth?(width)
        }
    }
}

private struct SidebarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

private struct SidebarMaterial: NSViewRepresentable {
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.blendingMode = blending
    }
}

// ponytail: monitor instead of SwiftUI hover; the page view eats tracking-area mouseMoved. Hide immediately; menus that open outside the sidebar dismiss the overlay.
private struct SidebarPeekTracker: NSViewRepresentable {
    var peeked: Bool
    var sidebarWidth: CGFloat
    var setPeeked: (Bool) -> Void

    func makeNSView(context: Context) -> Tracker {
        let view = Tracker()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: Tracker, context: Context) {
        view.peeked = peeked
        view.sidebarWidth = sidebarWidth
        view.setPeeked = setPeeked
        if !peeked { view.armed = false }
    }

    final class Tracker: NSView {
        var peeked = false
        var sidebarWidth: CGFloat = 280
        var setPeeked: ((Bool) -> Void)?
        var armed = false
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = true
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.track(event) }
                return event
            }
        }

        private func track(_ event: NSEvent) {
            if peeked, event.window !== window {
                setPeeked?(false)
                return
            }
            guard event.window === window, NSEvent.pressedMouseButtons == 0 else { return }
            let x = convert(event.locationInWindow, from: nil).x
            if peeked {
                if x <= sidebarWidth + 12 {
                    armed = true
                } else {
                    armed = false
                    setPeeked?(false)
                }
            } else if x <= 10 {
                armed = true
                setPeeked?(true)
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    static func dismantleNSView(_ nsView: Tracker, coordinator: ()) { nsView.stop() }
}

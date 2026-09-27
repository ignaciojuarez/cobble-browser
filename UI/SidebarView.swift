import AppKit
import SwiftUI

private struct TabLeadingIcon: View {
    var camera: PageCapture
    var microphone: PageCapture
    var display = false
    var audioOnly = false
    var isLoading = false
    var favicon: NSImage?
    var emptyURL = false
    var loadingIndicator = TabLoadingIndicatorStyle.system

    var captureLabel: String {
        [camera == .active ? String(localized: "Camera in use") : (camera == .muted ? String(localized: "Camera muted") : nil),
         microphone == .active ? String(localized: "Microphone in use") : (microphone == .muted ? String(localized: "Microphone muted") : nil),
         display ? String(localized: "Screen in use") : nil,
         camera == .none && microphone == .none && audioOnly ? String(localized: "Playing audio") : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 5) {
            if camera == .active {
                Circle().fill(.red).frame(width: 7, height: 7)
            } else if camera == .muted {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            } else if microphone == .active {
                Image(systemName: "mic.fill")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.orange)
            } else if microphone == .muted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            } else if display {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.orange)
            } else if audioOnly {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            Group {
                if isLoading, favicon == nil {
                    TabLoadingIndicator(style: loadingIndicator)
                } else if let favicon {
                    Image(nsImage: favicon).resizable().scaledToFit()
                } else {
                    Image(systemName: emptyURL ? "circle.dotted" : "globe")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
        }
        .accessibilityHidden(true)
    }
}

private struct TabEngineIcon: View {
    let engine: any BrowserEngine

    private var image: Image {
        switch engine.id {
        case .webKit: Image("SafariEngine")
        case EngineID(rawValue: "chromium"): Image("ChromeEngine")
        default: Image(systemName: "gearshape.2")
        }
    }

    var body: some View {
        image.resizable().scaledToFit().frame(width: 16, height: 16).foregroundStyle(.secondary)
    }
}

private struct FolderGlyph: View {
    let color: FolderColor
    var size: CGFloat? = nil
    @Environment(\.browserTheme) private var theme

    var body: some View {
        Image(systemName: theme.symbol(.folder))
            .font(.system(size: size ?? theme.configuration.folderIconSize))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color == .theme ? theme.folderColor : color.tint)
    }
}

private extension FolderColor {
    var name: LocalizedStringKey {
        switch self {
        case .theme: "Theme"
        case .blue: "Blue"
        case .teal: "Teal"
        case .green: "Green"
        case .yellow: "Yellow"
        case .orange: "Orange"
        case .pink: "Pink"
        case .purple: "Purple"
        case .gray: "Gray"
        }
    }

    var tint: Color {
        switch self {
        case .theme: .primary
        case .blue: Color(red: 0.12, green: 0.60, blue: 0.90)
        case .teal: .teal
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .pink: .pink
        case .purple: .purple
        case .gray: .gray
        }
    }
}

struct SidebarView: View {
    @Bindable var window: BrowserWindowModel
    var dismissAddressSuggestions: () -> Void = {}
    @Environment(\.browserTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredID: UUID?
    @State private var hoveredSpaceHeader = false
    @State private var hoveredNewTab = false
    @FocusState private var focusedRowAction: UUID?
    @State private var swipeTranslation = 0.0
    @State private var settlingSwipe: UUID?
    @State private var swipe: SidebarSwipeSession?
    @State private var swipeDirection = 1
    @State private var swipeTopRequest = 0
    @State private var textEdit: SidebarTextEdit?
    @State private var organizationEdit: SidebarOrganizationEdit?
    @State private var dropSession = SidebarDropSession()
    @State private var downloadsPresented = false

    private struct FolderOutline: Identifiable {
        let folder: Folder
        let depth: Int
        var id: UUID { folder.id }
    }

    var body: some View {
        let favorites = window.favorites
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - ThemeMetrics.spacing * 2)
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 0).id("sidebar.top")
                            pinGrid(favorites, width: contentWidth, kind: .favorite, group: .favorites, trackDrop: swipe == nil)
                                .padding(.bottom, ThemeMetrics.spacing * 2)
                            spacePages(width: contentWidth, translation: swipeTranslation)
                        }
                        .frame(width: contentWidth, alignment: .leading)
                        .padding(.horizontal, ThemeMetrics.spacing)
                        #if DEBUG
                        .padding(.bottom, 48)
                        #else
                        .padding(.bottom, 16)
                        #endif
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: window.app.savedItems.map(\.id) + window.app.folders.map(\.id) + window.record.tabs.map(\.id))
                    }
                    .contentShape(Rectangle())
                    .sidebarDropTarget(session: dropSession, commit: commitSpaceDrop)
                    .onChange(of: window.selectedTab?.id) { _, _ in
                        if swipe == nil { revealSelection(using: proxy) }
                    }
                    .onChange(of: swipeTopRequest) { _, _ in
                        var transaction = Transaction(); transaction.disablesAnimations = true
                        withTransaction(transaction) { proxy.scrollTo("sidebar.top", anchor: .top) }
                    }
                }
                if let reminder = window.app.updates.reminder {
                    Button(action: window.app.updates.checkForUpdates) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.circle.fill").font(.title3)
                            Text(reminder).font(.callout.weight(.semibold))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(theme.primary)
                        .padding(10)
                        .background(theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .disabled(!window.app.updates.canCheck)
                    .help("Check for Updates…")
                    .padding(.horizontal, ThemeMetrics.spacing)
                    .padding(.bottom, 8)
                }
                Divider()
                    #if DEBUG
                    .overlay(alignment: .bottomLeading) {
                        ResourceMemoryBadge(model: window.app.resources, windowID: window.id)
                            .padding(.leading, 12).padding(.bottom, 10)
                    }
                    #endif
                sidebarFooter
            }
            .background(SidebarSwipeView(window: window, active: swipe != nil, dismissAddressSuggestions: dismissAddressSuggestions, progress: { translation, intent in
                updateSwipe(translation: translation, intent: intent, width: geometry.size.width)
            }, finish: { cancelled in
                finishSwipe(cancelled: cancelled)
            }, invalidate: { resetSwipe() }))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: window.record.collapsedFolderIDs)
        .onChange(of: window.record.selectedSpaceID) { _, _ in invalidateExternalSelection(); dropSession.resetSpaceRows() }
        .onChange(of: window.record.selectedTabID) { _, _ in invalidateExternalSelection() }
        .onChange(of: window.spaces.map(\.id)) { _, _ in resetSwipe() }
        .onChange(of: window.commandBarPresented) { _, _ in resetSwipe() }
        .onChange(of: textEdit?.id) { _, _ in resetSwipe() }
        .onChange(of: organizationEdit?.id) { _, _ in resetSwipe() }
        .onDisappear { resetSwipe() }
        .onChange(of: window.organizationEditor, initial: true) { _, request in
            guard let request else { return }
            window.revealSidebarChrome()
            switch request {
            case .newSpace: createSpace()
            case .newFolder: createFolder()
            case .rename:
                if let item = window.app.savedItems.first(where: { $0.id == window.selectedTab?.savedItemID }) {
                    edit(String(localized: "Rename Pin"), value: item.title) { window.app.renameSavedItem(id: item.id, title: $0) }
                }
            case .editSpace:
                if let space = window.selectedSpace { editSpace(space) }
            }
            window.organizationEditor = nil
        }
        .sheet(item: $textEdit) { edit in
            SidebarTextEditor(edit: edit)
        }
        .sheet(item: $organizationEdit) { edit in
            SidebarOrganizationEditor(edit: edit)
        }
        .overlay(alignment: .top) {
            Color.clear
                .frame(height: 18)
                .contentShape(Rectangle())
                .offset(y: -18)
                .allowsHitTesting(dropSession.payload != nil)
                .onDrop(
                    of: [.utf8PlainText, .plainText],
                    delegate: SidebarDropDelegate(
                        session: dropSession,
                        forcedTarget: .insert(before: nil, group: .favorites, y: 0, indent: false),
                        commit: commitSpaceDrop
                    )
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser Sidebar")
    }

    private func revealSelection(using proxy: ScrollViewProxy) {
        let id = window.selectedTab?.savedItemID ?? window.record.selectedTabID
        if let id { proxy.scrollTo(id) }
    }

    // Panel identities stay anchored to the gesture while the active page changes.
    private func spacePages(width: Double, translation: Double) -> some View {
        let current = swipe.flatMap { gesture in window.spaces.first { $0.id == gesture.sourceSpaceID } } ?? window.selectedSpace
        let direction = swipeDirection
        let neighbor = swipe.flatMap { gesture in
            gesture.neighbor(offset: direction).flatMap { id in window.spaces.first { $0.id == id } }
        }
        let distance = Double(direction) * (swipe?.width ?? width)
        let fraction = min(1, abs(translation) / max(1, swipe?.width ?? width))
        return ZStack(alignment: .topLeading) {
            if let current {
                spaceContent(current, trackDrop: swipe == nil)
                    .offset(x: reduceMotion ? 0 : translation)
                    .opacity(reduceMotion ? 1 - fraction : 1)
            }
            if let neighbor {
                spaceContent(neighbor, trackDrop: false)
                    .offset(x: reduceMotion ? 0 : translation + distance)
                    .opacity(reduceMotion ? fraction : 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .allowsHitTesting(swipe == nil)
    }

    private func updateSwipe(translation: Double, intent: Double, width: Double) {
        guard settlingSwipe == nil else { return }
        var gesture = swipe ?? SidebarSwipeSession(window: window, width: width)
        guard gesture.matchesSelection(in: window) else { resetSwipe(); return }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            gesture.update(translation: intent)
            swipe = gesture
            if translation != 0 { swipeDirection = translation < 0 ? 1 : -1 }
            if gesture.neighbor(offset: translation < 0 ? 1 : -1) == nil {
                swipeTranslation = max(-24, min(24, translation * 0.15))
            } else {
                swipeTranslation = max(-gesture.width, min(gesture.width, translation))
            }
        }
    }

    private func finishSwipe(cancelled: Bool) {
        guard var gesture = swipe, settlingSwipe == nil else { return }
        guard gesture.matchesSelection(in: window) else { resetSwipe(); return }
        let completes = !cancelled && gesture.activeOffset != nil
        if cancelled { gesture.cancel() }
        swipe = gesture
        if completes { swipeTopRequest += 1 }
        if reduceMotion {
            if completes { gesture.commit(in: window) }
            resetSwipe()
            return
        }
        let settledGesture = gesture
        let token = UUID()
        settlingSwipe = token
        withAnimation(.spring(duration: 0.25, bounce: 0), completionCriteria: .removed) {
            swipeTranslation = -Double(gesture.activeOffset ?? 0) * gesture.width
        } completion: {
            guard settlingSwipe == token else { return }
            if completes && settledGesture.matchesSelection(in: window) {
                var committed = settledGesture
                committed.commit(in: window)
            }
            resetSwipe()
            if completes { swipeTopRequest += 1 }
        }
        guard completes else { return }
        Task { @MainActor in
            // Give the swipe a frame's head start before page creation can block the main thread.
            try? await Task.sleep(for: .milliseconds(16))
            guard settlingSwipe == token, settledGesture.matchesSelection(in: window) else { return }
            var committed = settledGesture
            committed.commit(in: window)
            swipe = committed
        }
    }

    private func invalidateExternalSelection() {
        if let swipe, !swipe.matchesSelection(in: window) { resetSwipe() }
    }

    private func resetSwipe() {
        guard swipe != nil || settlingSwipe != nil || swipeTranslation != 0 else { return }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { swipeTranslation = 0; settlingSwipe = nil; swipe = nil }
    }

    @ViewBuilder
    private func spaceContent(_ space: Space, trackDrop: Bool) -> some View {
        let pins = window.pins(in: space.id)
        let tabs = window.record.tabs.filter { $0.spaceID == space.id && $0.savedItemID == nil }
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                if let icon = space.icon {
                    Text(icon).font(.headline)
                }
                Text(space.displayedName)
                    .font(window.app.preferences.browserChromeFont.font(for: .headline))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    spaceActions
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .sidebarItemControl()
                .help("Space Actions")
                .accessibilityLabel("Space Actions")
                .opacity(hoveredSpaceHeader ? 1 : 0)
                .allowsHitTesting(hoveredSpaceHeader)
            }
            .padding(.horizontal, 9)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hoveredSpaceHeader = $0 }
            .contextMenu { spaceActions }
            .onGeometryChange(for: CGFloat.self) {
                $0.frame(in: .named(SidebarDrop.spaceName)).midY
            } action: { midY in
                if trackDrop { dropSession.favoritesActivationMaxY = midY }
            }
            ForEach(pins.filter { $0.folderID == nil }) { item in savedRow(item, trackDrop: trackDrop) }
            ForEach(folderOutline(in: space.id)) { entry in
                folderRow(entry.folder, depth: entry.depth, trackDrop: trackDrop)
            }
            Divider().padding(.horizontal, -ThemeMetrics.spacing).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .sidebarDropFrame(
                    trackDrop ? SidebarDropRow(id: SidebarDrop.pinsEndID, kind: .pinsEnd, frame: .zero) : nil,
                    session: dropSession
                )
            newTabRow(trackDrop: trackDrop)
            ForEach(tabs) { tab in tabRow(tab, trackDrop: trackDrop) }
        }
    }

    private func newTabRow(trackDrop: Bool) -> some View {
        Button {
            window.openCommandBar()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus").font(.system(size: 16))
                Text("New Tab")
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background { rowHighlight(selected: false, hovered: hoveredNewTab) }
        .onHover { hoveredNewTab = $0 }
        .sidebarDropFrame(
            trackDrop ? SidebarDropRow(id: SidebarDrop.newTabID, kind: .newTab, frame: .zero) : nil,
            session: dropSession
        )
    }

    private func pinGrid(_ pins: [SavedItem], width: CGFloat, kind: SidebarDropKind, group: SidebarDropGroup, trackDrop: Bool) -> some View {
        let ids = pinGridIDs(pins.map(\.id), group: group)
        let displayed = ids.isEmpty && dropSession.emptyFavoritesExpanded ? [SidebarDrop.pinPlaceholderID] : ids
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ThemeMetrics.spacing),
                                        count: SidebarDrop.pinGridColumnCount(displayed.count, fitting: width, spacing: ThemeMetrics.spacing)),
                         spacing: ThemeMetrics.spacing) {
            ForEach(displayed, id: \.self) { id in
                if id == SidebarDrop.pinPlaceholderID { pinDropPlaceholder(labeled: pins.isEmpty) }
                else if let item = pins.first(where: { $0.id == id }) { pinTile(item, kind: kind, trackDrop: trackDrop) }
            }
        }
        .frame(width: width, alignment: .leading)
        .sidebarDropFrame(
            trackDrop ? SidebarDropRow(id: SidebarDrop.favoritesEndID, kind: .favoritesEnd, frame: .zero) : nil,
            session: dropSession
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: displayed)
    }

    private func pinGridIDs(_ ids: [UUID], group: SidebarDropGroup) -> [UUID] {
        guard case .insert(let before, let targetGroup, _, _) = dropSession.visibleTarget, targetGroup == group,
              let payload = dropSession.payload else { return ids }
        switch payload {
        case .tab, .saved: break
        default: return ids
        }
        var result = ids
        if case .saved(let id) = payload { result.removeAll { $0 == id } }
        let index = before.flatMap { result.firstIndex(of: $0) } ?? result.endIndex
        result.insert(SidebarDrop.pinPlaceholderID, at: index)
        return result
    }

    @ViewBuilder
    private func pinDropPlaceholder(labeled: Bool) -> some View {
        if labeled {
            VStack(spacing: 2) {
                Image(systemName: "star")
                Text("Add Favorites")
                    .font(window.app.preferences.browserChromeFont.font(for: .caption))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58)
            .background {
                RoundedRectangle(cornerRadius: theme.controlCornerRadius)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    .foregroundStyle(Color.primary.opacity(0.12))
            }
            .accessibilityLabel("Add Favorites")
        } else {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46)
                .accessibilityHidden(true)
        }
    }

    private func pinTile(_ item: SavedItem, kind: SidebarDropKind, trackDrop: Bool) -> some View {
        let selected = window.selectedTab?.savedItemID == item.id
        let favorite = kind == .favorite
        let loaded = window.isSavedItemLoaded(item.id)
        let tab = window.record.tabs.first { $0.savedItemID == item.id }
        let captureState = tab.map { window.captureState(for: $0.id) } ?? (camera: .none, microphone: .none, display: false)
        let capturing = tab.map { window.isCapturing($0.id) } ?? false
        let icon = tab.map { window.icon(for: $0.id) } ?? window.icon(for: item)
        let capture = TabLeadingIcon(camera: captureState.camera, microphone: captureState.microphone, display: captureState.display,
            audioOnly: !capturing && tab.map { window.isPlayingAudio($0.id) || window.isAudioMuted($0.id) } == true,
            isLoading: tab.map { window.isLoading($0.id) } == true, favicon: icon, emptyURL: item.urlString.isEmpty,
            loadingIndicator: window.app.preferences.tabLoadingIndicator)
        return ZStack(alignment: .topTrailing) {
            Button { activateSavedItem(item.id) } label: {
                capture
                    .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46)
                    .contentShape(RoundedRectangle(cornerRadius: theme.controlCornerRadius))
            }
            .buttonStyle(.plain)
            .help(item.urlString)
            .accessibilityLabel(String(format: String(localized: "%@: %@, %@"),
                favorite ? String(localized: "Favorite") : String(localized: "Pinned tab"), item.title,
                loaded ? String(localized: "loaded") : String(localized: "unloaded")))
            .accessibilityValue(capture.captureLabel)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            if let tab, window.showsMuteControl(tab.id) {
                Button { window.toggleMute(tab.id) } label: {
                    Image(systemName: window.isAudioMuted(tab.id) ? "speaker.slash" : "speaker.wave.2")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel(String(format: String(localized: window.isAudioMuted(tab.id) ? "Unmute %@" : "Mute %@"), item.title))
            }
        }
        .background(selected || hoveredID == item.id ? theme.selectedPin : theme.pin,
                    in: RoundedRectangle(cornerRadius: theme.controlCornerRadius))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: theme.controlCornerRadius).strokeBorder(theme.selectedPinStroke) }
        }
        .onHover { hoveredID = $0 ? item.id : (hoveredID == item.id ? nil : hoveredID) }
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Copy Link") { window.copyPageURL(urlString: tab?.urlString ?? item.urlString) }
                .disabled((tab?.urlString ?? item.urlString).isEmpty)
            Button("Share") { window.sharePage(url: tab?.url ?? item.url) }
                .disabled((tab?.url ?? item.url) == nil)
            if let tab { engineActions(for: tab) }
            Divider()
            Button("Duplicate") { if let tab { window.duplicateTab(tab.id) } else if let url = item.url { window.addTab(url: url) } }
            if window.isSavedItemLoaded(item.id) {
                Button("Unload Page") { window.unloadSavedItem(item.id) }
            }
            savedDestinations(item)
            Divider()
            Button("Rename…") { edit(String(localized: "Rename Pin"), value: item.title) { window.app.renameSavedItem(id: item.id, title: $0) } }
            Button("Remove Pin", role: .destructive) { window.app.removeSavedItem(item.id) }
        }
        .opacity(dropSession.draggedID == item.id ? 0.35 : 1)
        .draggable("saved:\(item.id.uuidString)") { dropSession.ghostPreview(payload: .saved(item.id), title: item.title, icon: icon) }
        .id(dropSession.generation)
        .sidebarDropFrame(trackDrop ? SidebarDropRow(id: item.id, kind: kind, frame: .zero) : nil, session: dropSession)
        .id(item.id)
    }

    private func savedRow(_ item: SavedItem, favorite: Bool = false, trackDrop: Bool = false) -> some View {
        let selected = window.selectedTab?.savedItemID == item.id
        let loaded = window.isSavedItemLoaded(item.id)
        let tab = window.record.tabs.first { $0.savedItemID == item.id }
        let captureState = tab.map { window.captureState(for: $0.id) } ?? (camera: .none, microphone: .none, display: false)
        let capturing = tab.map { window.isCapturing($0.id) } ?? false
        let capture = TabLeadingIcon(camera: captureState.camera, microphone: captureState.microphone, display: captureState.display,
            audioOnly: !capturing && tab.map { window.isPlayingAudio($0.id) || window.isAudioMuted($0.id) } == true,
            isLoading: tab.map { window.isLoading($0.id) } == true,
            favicon: tab.map { window.icon(for: $0.id) } ?? window.icon(for: item),
            emptyURL: item.urlString.isEmpty,
            loadingIndicator: window.app.preferences.tabLoadingIndicator)
        return HStack(spacing: 0) {
            Button {
                activateSavedItem(item.id)
            } label: {
                HStack(spacing: 9) {
                    capture
                    Text(item.title).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(9)
                .contentShape(Rectangle())
            }
            .accessibilityAction { reopenSavedItem(item.id) }
            .buttonStyle(.plain)
            .help(item.urlString)
            .accessibilityLabel(String(format: String(localized: "%@: %@, %@"), favorite ? String(localized: "Favorite") : String(localized: "Pinned tab"), item.title, loaded ? String(localized: "loaded") : String(localized: "unloaded")))
            .accessibilityValue(capture.captureLabel)
            HStack(spacing: 2) {
                if let tab, window.showsMuteControl(tab.id) {
                    SidebarItemButton(
                        systemImage: window.isAudioMuted(tab.id) ? "speaker.slash" : "speaker.wave.2",
                        help: window.isAudioMuted(tab.id) ? String(localized: "Unmute Tab") : String(localized: "Mute Tab — silence audio while playback continues")
                    ) { window.toggleMute(tab.id) }
                    .accessibilityLabel(String(format: String(localized: window.isAudioMuted(tab.id) ? "Unmute %@" : "Mute %@"), item.title))
                }
                if let tab { engineButton(for: tab) }
                SidebarItemButton(
                    systemImage: loaded ? "minus" : "xmark",
                    help: loaded ? String(localized: "Unload Page (keeps pin; unsaved page content will be lost)") : String(format: String(localized: "Remove %@"), favorite ? String(localized: "Favorite") : String(localized: "Pin"))
                ) {
                    if loaded { window.unloadSavedItem(item.id) }
                    else { window.removeUnloadedSavedItem(item.id) }
                }
                .focused($focusedRowAction, equals: item.id)
                .opacity(hoveredID == item.id || focusedRowAction == item.id ? 1 : 0)
                .accessibilityLabel(String(format: String(localized: loaded ? "Unload %@" : "Remove %@"), item.title))
            }
            .padding(.trailing, 5)
        }
        .contentShape(Rectangle())
        .background { rowHighlight(selected: selected, hovered: hoveredID == item.id) }
        .onHover { hoveredID = $0 ? item.id : (hoveredID == item.id ? nil : hoveredID) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {
            Button("Copy Link") { window.copyPageURL(urlString: tab?.urlString ?? item.urlString) }
                .disabled((tab?.urlString ?? item.urlString).isEmpty)
            Button("Share") { window.sharePage(url: tab?.url ?? item.url) }
                .disabled((tab?.url ?? item.url) == nil)
            if let tab {
                engineActions(for: tab)
            }
            Divider()
            Button("Duplicate") {
                if let tab { window.duplicateTab(tab.id) }
                else if let url = item.url { window.addTab(url: url) }
            }
            savedDestinations(item)
            Divider()
            Button("Rename…") {
                edit(String(format: String(localized: "Rename %@"), favorite ? String(localized: "Favorite") : String(localized: "Pin")), value: item.title) {
                    window.app.renameSavedItem(id: item.id, title: $0)
                }
            }
            Button(String(format: String(localized: "Remove %@"), favorite ? String(localized: "Favorite") : String(localized: "Pin")), role: .destructive) {
                window.app.removeSavedItem(item.id)
            }
        }
        .geometryGroup()
        .opacity(dropSession.draggedID == item.id ? 0.4 : 1)
        .animation(nil, value: dropSession.draggedID)
        .draggable("saved:\(item.id.uuidString)") {
            dropSession.ghostPreview(payload: .saved(item.id), title: item.title, icon: window.icon(for: item))
        }
        .id(dropSession.generation)
        .sidebarDropFrame(
            trackDrop
                ? SidebarDropRow(
                    id: item.id,
                    kind: favorite ? .favorite : item.folderID.map { .folderChild(folderID: $0) } ?? .pin,
                    frame: .zero
                )
                : nil,
            session: dropSession
        )
        .id(item.id)
    }

    private func folderOutline(in spaceID: UUID, parentID: UUID? = nil, depth: Int = 0) -> [FolderOutline] {
        window.folders(in: spaceID, parentID: parentID).flatMap { folder in
            let entry = FolderOutline(folder: folder, depth: depth)
            guard !window.record.collapsedFolderIDs.contains(folder.id) else { return [entry] }
            return [entry] + folderOutline(in: spaceID, parentID: folder.id, depth: depth + 1)
        }
    }

    private func folderRow(_ folder: Folder, depth: Int, trackDrop: Bool = false) -> some View {
        let collapsed = window.record.collapsedFolderIDs.contains(folder.id)
        let highlighted = dropSession.visibleTarget?.highlightedFolder == folder.id
        let children = window.pins(in: folder.spaceID).filter { $0.folderID == folder.id }
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                window.toggleFolder(folder.id)
            } label: {
                HStack(spacing: 9) {
                    FolderGlyph(color: folder.color).frame(width: 16, height: 16)
                    Text(folder.name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background { rowHighlight(selected: highlighted, hovered: hoveredID == folder.id) }
            .onHover { hoveredID = $0 ? folder.id : (hoveredID == folder.id ? nil : hoveredID) }
            .accessibilityLabel(String(format: String(localized: "%@, level %@, %@ folder"), folder.name,
                                       String(depth + 1), collapsed ? String(localized: "collapsed") : String(localized: "expanded")))
            .accessibilityHint(String(localized: "Shows or hides this folder’s contents"))
            .contextMenu {
                Button("New Subfolder…") { createFolder(parentID: folder.id, spaceID: folder.spaceID) }
                Button("Edit Folder…") { editFolder(folder) }
                if folder.parentID != nil {
                    Button("Move to Space Root") { _ = window.app.moveFolder(id: folder.id, spaceID: folder.spaceID) }
                }
                Menu("Move to Folder") {
                    ForEach(window.app.folders.filter { $0.id != folder.parentID && $0.spaceID == folder.spaceID && window.app.canMoveFolder(id: folder.id, to: $0.id) }) { target in
                        Button(target.name) { _ = window.app.moveFolder(id: folder.id, parentID: target.id) }
                    }
                }
                Button("Delete Folder", role: .destructive) { window.app.deleteFolder(folder.id) }
            }
            .draggable("folder:\(folder.id.uuidString)") {
                dropSession.ghostPreview(
                    payload: .folder(folder.id),
                    title: folder.labeledName,
                    icon: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                )
            }
            .id(dropSession.generation)
            .sidebarDropFrame(
                trackDrop ? SidebarDropRow(id: folder.id,
                    kind: .folderHeader(parentID: folder.parentID, depth: depth, collapsed: collapsed), frame: .zero) : nil,
                session: dropSession
            )
            if !collapsed {
                ForEach(children) { item in
                    savedRow(item, trackDrop: trackDrop).padding(.leading, 16)
                }
            }
        }
        .id(folder.id)
        .padding(.leading, CGFloat(depth) * 16)
        .geometryGroup()
        .opacity(dropSession.draggedID == folder.id ? 0.4 : 1)
        .animation(nil, value: dropSession.draggedID)
    }

    private func tabRow(_ tab: Tab, trackDrop: Bool = false) -> some View {
        let selected = window.isTemporaryTabSelected(tab.id) || window.selectedTab?.id == tab.id
        let captureState = window.captureState(for: tab.id)
        let capturing = window.isCapturing(tab.id)
        let capture = TabLeadingIcon(camera: captureState.camera, microphone: captureState.microphone, display: captureState.display,
            audioOnly: !capturing && (window.isPlayingAudio(tab.id) || window.isAudioMuted(tab.id)),
            isLoading: window.isLoading(tab.id), favicon: window.icon(for: tab.id), emptyURL: tab.urlString.isEmpty,
            loadingIndicator: window.app.preferences.tabLoadingIndicator)
        return HStack(spacing: 0) {
            Button {
                activateTab(tab.id)
            } label: {
                HStack(spacing: 9) {
                    capture
                    Text(tab.displayedTitle).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 9)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .accessibilityAction { selectTemporaryTabForAccessibility(tab.id) }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.displayedTitle)
            .accessibilityValue(capture.captureLabel)
            HStack(spacing: 2) {
                if window.showsMuteControl(tab.id) {
                    SidebarItemButton(
                        systemImage: window.isAudioMuted(tab.id) ? "speaker.slash" : "speaker.wave.2",
                        help: window.isAudioMuted(tab.id)
                            ? String(localized: "Unmute Tab")
                            : String(localized: "Mute Tab — silence audio while playback continues")
                    ) {
                        window.toggleMute(tab.id)
                    }
                    .accessibilityLabel(String(format: String(localized: window.isAudioMuted(tab.id) ? "Unmute %@" : "Mute %@"), tab.displayedTitle))
                }
                engineButton(for: tab)
                SidebarItemButton(systemImage: "xmark", help: String(localized: "Close Tab")) {
                    window.closeTab(tab.id)
                }
                .focused($focusedRowAction, equals: tab.id)
                .opacity(hoveredID == tab.id || focusedRowAction == tab.id ? 1 : 0)
                .accessibilityLabel(String(format: String(localized: "Close %@"), tab.displayedTitle))
            }
            .padding(.trailing, 5)
        }
        .contentShape(Rectangle())
        .background { rowHighlight(selected: selected, hovered: hoveredID == tab.id) }
        .onHover { hoveredID = $0 ? tab.id : (hoveredID == tab.id ? nil : hoveredID) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {
            Button("Copy Link") { window.copyPageURL(urlString: tab.urlString) }
                .disabled(tab.urlString.isEmpty)
            Button("Share") { window.sharePage(url: tab.url) }
                .disabled(tab.url == nil)
            engineActions(for: tab)
            Divider()
            if window.isTemporaryTabSelected(tab.id), window.selectedTemporaryTabs.count > 1 {
                Menu("Move Selected to") {
                    ForEach(window.spaces) { space in
                        Button(space.labeledName) { window.moveSelectedTemporaryTabs(to: space.id) }
                    }
                }
                Button("Close Selected Tabs", role: .destructive) { window.closeSelectedTemporaryTabs() }
            } else {
                Button("Duplicate") { window.duplicateTab(tab.id) }
                Menu("Move to") {
                    ForEach(window.spaces) { space in
                        Button(space.labeledName) { window.moveTab(tab.id, to: space.id) }
                    }
                }
                Button("Archive Tab") { window.closeTab(tab.id) }
            }
            Divider()
            Button("Rename…") {
                edit(String(localized: "Rename Tab"), value: tab.displayedTitle) { window.renameTab(tab.id, title: $0) }
            }
        }
        .geometryGroup()
        .opacity(dropSession.draggedID == tab.id ? 0.4 : 1)
        .animation(nil, value: dropSession.draggedID)
        .draggable("tab:\(tab.id.uuidString)") { tabDragPreview(tab) }
        .id(dropSession.generation)
        .sidebarDropFrame(
            trackDrop ? SidebarDropRow(id: tab.id, kind: .tab, frame: .zero) : nil,
            session: dropSession
        )
        .id(tab.id)
    }

    @ViewBuilder
    private func engineActions(for tab: Tab) -> some View {
        Menu("Engine") {
            engineChoices(for: tab)
        }
        .disabled(tab.url == nil)
    }

    @ViewBuilder
    private func engineButton(for tab: Tab) -> some View {
        if let engine = window.nonDefaultEngine(for: tab) {
            Menu {
                engineChoices(for: tab)
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(String(format: String(localized: "Using %@ — change engine"), engine.name))
            .accessibilityLabel(String(format: String(localized: "Using %@ — change engine"), engine.name))
            .sidebarItemControl(disabled: tab.url == nil)
            .overlay { TabEngineIcon(engine: engine).allowsHitTesting(false) }
        }
    }

    @ViewBuilder
    private func engineChoices(for tab: Tab) -> some View {
        Button {
            window.setEngine(nil, for: tab.id)
        } label: {
            if tab.engineOverride == nil { Label("Automatic", systemImage: "checkmark") }
            else { Text("Automatic") }
        }
        Divider()
        ForEach(window.app.engines.engines, id: \.id) { engine in
            Button {
                window.setEngine(engine.id, for: tab.id)
            } label: {
                if tab.engineOverride == engine.id { Label(engine.name, systemImage: "checkmark") }
                else { Text(engine.name) }
            }
        }
    }

    @ViewBuilder
    private var spaceActions: some View {
        Button("New Folder…") { createFolder() }
        if let space = window.selectedSpace {
            Button("Edit Space…") { editSpace(space) }
            Menu("Move to") {
                Button("Left") { window.app.moveSpace(id: space.id, offset: -1) }
                Button("Right") { window.app.moveSpace(id: space.id, offset: 1) }
            }
            Divider()
            Button("Delete Space", role: .destructive) { window.app.deleteSpace(space.id) }
                .disabled(window.spaces.count < 2)
        }
    }

    private func activateTab(_ id: UUID) {
        selectTemporaryTab(id)
    }

    private func selectTemporaryTab(_ id: UUID) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        selectTemporaryTab(id, modifiers: modifiers)
    }

    private func selectTemporaryTabForAccessibility(_ id: UUID) {
        selectTemporaryTab(id, modifiers: [])
    }

    private func selectTemporaryTab(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        guard !modifiers.intersection([.command, .shift]).isEmpty
                || window.record.selectedTabID != id
                || window.selectedTemporaryTabIDs != [id]
                || window.selectedTab?.isUnloaded == true
                || window.selectedPage == nil else { return }
        window.selectTemporaryTab(id, modifiers: modifiers)
    }

    private func tabDragPreview(_ tab: Tab) -> some View {
        dropSession.ghostPreview(
            payload: .tab(tab.id), title: tab.displayedTitle,
            icon: window.icon(for: tab.id), empty: tab.urlString.isEmpty
        ) {
            let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            guard !modifiers.intersection([.command, .shift]).isEmpty else { return }
            selectTemporaryTab(tab.id, modifiers: modifiers)
        }
    }

    private func activateSavedItem(_ id: UUID) {
        reopenSavedItem(id)
    }

    private func reopenSavedItem(_ id: UUID) {
        guard window.selectedTab?.savedItemID != id || window.selectedTab?.isUnloaded == true || window.selectedPage == nil else { return }
        window.openSavedItem(id)
    }

    @ViewBuilder private func rowHighlight(selected: Bool, hovered: Bool) -> some View {
        if selected {
            Color.clear.modifier(ThemeSurface(configuration: theme.configuration.selectedTabSurface, tint: theme.accent))
        } else if hovered {
            Color.clear.modifier(ThemeSurface(configuration: theme.configuration.hoveredTabSurface, tint: theme.accent))
        }
    }

    private func savedDestinations(_ item: SavedItem) -> some View {
        Menu("Move to") {
            Button("Favorites") { window.app.moveSavedItem(id: item.id, spaceID: nil, folderID: nil) }
            ForEach(window.spaces) { space in
                Button(space.labeledName) { window.app.moveSavedItem(id: item.id, spaceID: space.id, folderID: nil) }
            }
            if !window.folders.isEmpty {
                Divider()
                ForEach(window.folders) { folder in
                    Button(String(format: String(localized: "Folder: %@"), folder.name)) {
                        window.app.moveSavedItem(id: item.id, spaceID: folder.spaceID, folderID: folder.id)
                    }
                }
            }
        }
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Button { downloadsPresented.toggle() } label: {
                Group {
                    if window.app.downloads.activeCount > 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: theme.symbol(.downloads))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .sidebarItemControl(role: .toolbar)
            .help(String(localized: "Downloads"))
            .accessibilityLabel(String(localized: "Downloads"))
            .popover(isPresented: $downloadsPresented, arrowEdge: .bottom) {
                DownloadsPanel(store: window.app.downloads)
            }
            spacePicker
                .frame(maxWidth: .infinity)
            newMenu
        }
        .padding(ThemeMetrics.spacing)
    }

    private var spacePicker: some View {
        let spaceIDs = window.spaces.map(\.id)
        let dots = theme.configuration.spacePreview.mode == .dots
        let height: CGFloat = dots ? 22.5 : 30
        let spacing: CGFloat = dots ? -1 : SidebarDrop.spacePickerSpacing
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    Color.clear.frame(width: SidebarDrop.spacePickerInset, height: height)
                    ForEach(window.spaces) { space in
                        let selected = window.selectedSpace?.id == space.id
                        let title = space.icon ?? String(space.displayedName.prefix(1)).uppercased()
                        Button {
                            if dropSession.payload != nil { return }
                            window.selectSpace(space.id)
                        } label: {
                            SpacePickerChip(
                                title: title,
                                selected: selected,
                                highlighted: dropSession.visibleTarget?.spaceID == space.id
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .accessibilityLabel(String(format: String(localized: "%@ space"), space.labeledName))
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                        .help(space.labeledName)
                        .opacity(dropSession.draggedID == space.id ? 0 : 1)
                        .animation(nil, value: dropSession.draggedID)
                        .offset(x: spacePickerOffset(space.id, ids: spaceIDs, spacing: spacing))
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                            if dropSession.spaceWidths[space.id] != width { dropSession.spaceWidths[space.id] = width }
                        }
                        .onDisappear {
                            if dropSession.spaceWidths[space.id] != nil { dropSession.spaceWidths[space.id] = nil }
                        }
                        .draggable("space:\(space.id.uuidString)") {
                            dropSession.spaceChipGhost(id: space.id, title: title, selected: selected)
                        }
                        .id(dropSession.generation)
                        .id(space.id)
                    }
                    Color.clear.frame(width: SidebarDrop.spacePickerInset, height: height)
                }
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.05), value: dropSession.visibleTarget)
                // ponytail: drop moves now. Hover-switch while dragging needs a source that outlives the space list (AppKit overlay like SidebarSwipeView) if SwiftUI cancels.
                .onDrop(
                    of: [.utf8PlainText, .plainText],
                    delegate: SidebarDropDelegate(
                        session: dropSession,
                        spaceIDs: spaceIDs,
                        spaceSpacing: spacing,
                        commit: commitSpaceDrop
                    )
                )
            }
            .defaultScrollAnchor(.center, for: .alignment)
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.08),
                    .init(color: .black, location: 0.92),
                    .init(color: .clear, location: 1)
                ],
                               startPoint: .leading, endPoint: .trailing)
            }
            .frame(maxWidth: CGFloat(spaceIDs.count) * theme.configuration.controls.space.side
                   + CGFloat(spaceIDs.count + 1) * spacing + SidebarDrop.spacePickerInset * 2)
            .modifier(ThemeSurface(configuration: theme.configuration.groups.spaces))
            .onAppear { centerSelectedSpace(using: proxy) }
            .onChange(of: window.record.selectedSpaceID) { _, _ in centerSelectedSpace(using: proxy) }
            .onChange(of: window.spaces.map(\.id)) { _, _ in centerSelectedSpace(using: proxy) }
        }
    }

    private var newMenu: some View {
        Menu {
            Button("Create Space") { createSpace() }
            Button("Create Folder") { createFolder() }
            Divider()
            Button("New Tab") { window.openCommandBar() }
        } label: {
            Image(systemName: theme.symbol(.add))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .sidebarItemControl(role: .toolbar)
        .help(String(localized: "New"))
        .accessibilityLabel(String(localized: "New"))
    }

    private func centerSelectedSpace(using proxy: ScrollViewProxy) {
        guard dropSession.payload == nil else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            proxy.scrollTo(window.record.selectedSpaceID, anchor: .center)
        }
    }

    private func spacePickerOffset(_ id: UUID, ids: [UUID], spacing: CGFloat) -> CGFloat {
        guard let dragged = dropSession.draggedID, ids.contains(dragged),
              case .spaceInsert(let before) = dropSession.visibleTarget else { return 0 }
        return SidebarDrop.spacePickerOffset(
            for: id,
            ids: ids,
            dragged: dragged,
            before: before,
            gap: (dropSession.spaceWidths[dragged] ?? 30) + spacing
        )
    }

    private func createSpace() {
        organizationEdit = SidebarOrganizationEdit(
            kind: .space,
            title: String(localized: "New Space"),
            name: "",
            icon: "",
            color: .theme
        ) { name, icon, _ in
            window.app.addSpace(name: name, profileID: window.record.profileID, icon: icon)
        }
    }

    private func createFolder(parentID: UUID? = nil, spaceID: UUID? = nil) {
        guard let spaceID = spaceID ?? window.selectedSpace?.id else { return }
        organizationEdit = SidebarOrganizationEdit(
            kind: .folder,
            title: parentID == nil ? String(localized: "New Folder") : String(localized: "New Subfolder"),
            name: "",
            icon: "",
            color: .theme
        ) { name, _, color in
            window.app.addFolder(name: name, spaceID: spaceID, parentID: parentID, color: color)
        }
    }

    private func editSpace(_ space: Space) {
        organizationEdit = SidebarOrganizationEdit(
            kind: .space,
            title: String(localized: "Edit Space"),
            name: space.name,
            icon: space.icon ?? "",
            color: .theme
        ) { name, icon, _ in
            window.app.updateSpace(id: space.id, name: name, icon: icon)
        }
    }

    private func editFolder(_ folder: Folder) {
        organizationEdit = SidebarOrganizationEdit(
            kind: .folder,
            title: String(localized: "Edit Folder"),
            name: folder.name,
            icon: "",
            color: folder.color
        ) { name, _, color in
            window.app.updateFolder(id: folder.id, name: name, color: color)
        }
    }

    private func edit(_ title: String, value: String, allowEmpty: Bool = false,
                      save: @escaping (String) -> Void) {
        textEdit = SidebarTextEdit(title: title, value: value, allowEmpty: allowEmpty, save: save)
    }

    private func commitSpaceDrop(_ payload: SidebarDropPayload, _ target: SidebarDropTarget) -> Bool {
        if case .space = payload {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            return withTransaction(transaction) { commitDrop(payload, target) }
        }
        return withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
            commitDrop(payload, target)
        }
    }

    private func commitDrop(_ payload: SidebarDropPayload, _ target: SidebarDropTarget) -> Bool {
        switch payload {
        case .saved(let id):
            switch target {
            case .ontoFolder(let folderID):
                guard let folder = window.app.folders.first(where: { $0.id == folderID }) else { return false }
                window.app.moveSavedItem(id: id, spaceID: folder.spaceID, folderID: folder.id)
                window.expandFolder(folder.id)
                return true
            case .space(let spaceID):
                window.app.moveSavedItem(id: id, spaceID: spaceID, folderID: nil)
                return true
            case .spaceInsert:
                return false
            case .insert(let before, let group, _, _):
                switch group {
                case .tabs:
                    window.unpinSavedItem(id, before: before)
                    return true
                case .favorites:
                    window.app.moveSavedItem(id: id, spaceID: nil, folderID: nil, before: before)
                    return true
                case .rootPins:
                    window.app.moveSavedItem(id: id, spaceID: window.record.selectedSpaceID, folderID: nil, before: before)
                    return true
                case .folder(let folderID):
                    guard let folder = window.app.folders.first(where: { $0.id == folderID }) else { return false }
                    window.app.moveSavedItem(id: id, spaceID: folder.spaceID, folderID: folder.id, before: before)
                    return true
                case .folders:
                    return false
                }
            }
        case .tab(let id):
            switch target {
            case .ontoFolder(let folderID):
                window.pinTab(id, folderID: folderID)
                let pinned = window.record.tabs.contains { $0.id == id && $0.savedItemID != nil }
                if pinned { window.expandFolder(folderID) }
                return pinned
            case .space(let spaceID):
                window.moveTab(id, to: spaceID)
                return true
            case .spaceInsert:
                return false
            case .insert(let before, let group, _, _):
                switch group {
                case .tabs:
                    window.moveTab(id, before: before)
                    return true
                case .favorites:
                    window.pinTab(id, favorite: true, before: before)
                    return window.record.tabs.contains { $0.id == id && $0.savedItemID != nil }
                case .rootPins:
                    window.pinTab(id, favorite: false, before: before)
                    return window.record.tabs.contains { $0.id == id && $0.savedItemID != nil }
                case .folder(let folderID):
                    window.pinTab(id, folderID: folderID, before: before)
                    return window.record.tabs.contains { $0.id == id && $0.savedItemID != nil }
                case .folders:
                    return false
                }
            }
        case .folder(let id):
            switch target {
            case .ontoFolder(let folderID):
                let moved = window.app.moveFolder(id: id, parentID: folderID)
                if moved { window.expandFolder(folderID) }
                return moved
            case .space(let spaceID):
                return window.app.moveFolder(id: id, spaceID: spaceID)
            case .spaceInsert:
                return false
            case .insert(let before, .folders(let parentID), _, _):
                return window.app.moveFolder(id: id, spaceID: parentID == nil ? window.record.selectedSpaceID : nil,
                                             parentID: parentID, before: before)
            default:
                return false
            }
        case .space(let id):
            guard case .spaceInsert(let before) = target else { return false }
            window.app.moveSpace(id: id, before: before)
            return true
        }
    }
}

private struct SidebarTextEdit: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    var allowEmpty = false
    let save: (String) -> Void
}

private struct SidebarTextEditor: View {
    let edit: SidebarTextEdit
    @State private var value = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(edit.title).font(.headline)
            TextField("Name", text: $value)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!edit.allowEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 330)
        .onAppear { value = edit.value; focused = true }
    }

    private func save() {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard edit.allowEmpty || !name.isEmpty else { return }
        edit.save(name)
        dismiss()
    }
}

private struct SidebarOrganizationEdit: Identifiable {
    enum Kind { case space, folder }

    let id = UUID()
    let kind: Kind
    let title: String
    let name: String
    let icon: String
    let color: FolderColor
    let save: (String, String?, FolderColor) -> Void
}

private struct SidebarOrganizationEditor: View {
    let edit: SidebarOrganizationEdit
    @State private var name = ""
    @State private var icon = ""
    @State private var color: FolderColor = .theme
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.browserTheme) private var theme

    private enum Field: Hashable { case name, icon }

    private let suggestedIcons = ["🏠", "💼", "📚", "🎮", "✈️", "🌙"]
    private var validatedIcon: String? { Space.validatedIcon(icon) }
    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 18) {
            preview
                .frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                SettingsRow("Name") {
                    TextField(edit.kind == .space ? "Space name" : "Folder name", text: $name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .focused($focusedField, equals: .name)
                        .frame(maxWidth: 220)
                        .onSubmit { save() }
                }
                .padding(.vertical, 11)

                Divider()

                if edit.kind == .space {
                    SettingsRow("Icon") { iconChoices }
                        .padding(.vertical, 9)
                } else {
                    SettingsRow("Color") { colorChoices }
                        .padding(.vertical, 9)
                }
            }
            .padding(.horizontal, 14)
            .background(SettingsStyle.groupBackground,
                        in: RoundedRectangle(cornerRadius: theme.controlCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: theme.controlCornerRadius)
                    .stroke(SettingsStyle.groupBorder)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(edit.name.isEmpty ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }

            if edit.kind == .space {
                TextField("Emoji", text: $icon)
                    .focused($focusedField, equals: .icon)
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            name = edit.name
            icon = edit.icon
            color = edit.color
            focusedField = .name
        }
    }

    private var iconChoices: some View {
        HStack(spacing: 5) {
            ForEach(suggestedIcons, id: \.self) { choice in
                Button { icon = choice } label: {
                    Text(choice).frame(width: 26, height: 26)
                        .background(validatedIcon == choice ? theme.selectedPin : .clear,
                                    in: RoundedRectangle(cornerRadius: theme.innerCornerRadius(inset: 5)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(format: String(localized: "Use %@ as space icon"), choice))
            }
            Button { openEmojiPicker() } label: {
                Image(systemName: "plus").frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: theme.innerCornerRadius(inset: 5)))
            }
            .buttonStyle(.plain)
            .help(String(localized: "Choose Emoji"))
            .accessibilityLabel(String(localized: "Choose Emoji"))
        }
    }

    private var colorChoices: some View {
        HStack(spacing: 7) {
            ForEach(FolderColor.allCases.filter { $0 != .teal }, id: \.self) { choice in
                Button { color = choice } label: {
                    Circle()
                        .fill(choice == .theme ? theme.folderColor : choice.tint)
                        .frame(width: 18, height: 18)
                        .padding(4)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.primary.opacity(color == choice ? 0.55 : 0), lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(choice.name))
                .accessibilityAddTraits(color == choice ? [.isSelected] : [])
            }
        }
    }

    private var preview: some View {
        Group {
            if edit.kind == .folder {
                FolderGlyph(color: color, size: 36)
            } else if let validatedIcon {
                Text(validatedIcon).font(.system(size: 34))
            } else {
                Image(systemName: "square.on.square")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 56)
        .accessibilityLabel(edit.title)
    }

    private func openEmojiPicker() {
        focusedField = .icon
        Task { @MainActor in
            await Task.yield()
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor {
                editor.selectAll(nil)
            }
            NSApp.orderFrontCharacterPalette(nil)
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit.save(trimmed, edit.kind == .space ? validatedIcon : nil, color)
        dismiss()
    }
}

@MainActor
struct SidebarSwipeSession {
    let sourceSpaceID: UUID
    let sourceTabID: UUID?
    let width: Double
    private let previousSpaceID: UUID?
    private let nextSpaceID: UUID?
    private var expectedSpaceID: UUID
    private var expectedTabID: UUID?
    private(set) var activeOffset: Int?

    init(window: BrowserWindowModel, width: Double) {
        sourceSpaceID = window.record.selectedSpaceID
        sourceTabID = window.record.selectedTabID
        expectedSpaceID = sourceSpaceID
        expectedTabID = sourceTabID
        self.width = max(1, width)
        let spaces = window.spaces
        let index = spaces.firstIndex { $0.id == window.record.selectedSpaceID }
        previousSpaceID = index.flatMap { $0 > 0 ? spaces[$0 - 1].id : nil }
        nextSpaceID = index.flatMap { $0 + 1 < spaces.count ? spaces[$0 + 1].id : nil }
    }

    func neighbor(offset: Int) -> UUID? { offset == 1 ? nextSpaceID : previousSpaceID }

    func matchesSelection(in window: BrowserWindowModel) -> Bool {
        window.record.selectedSpaceID == expectedSpaceID && window.record.selectedTabID == expectedTabID
    }

    // Preview the destination while fingers are down; selecting here would load its page too early.
    mutating func update(translation: Double) {
        let proposed = SidebarSwipeTracker.destination(translation: translation, width: width)
        activeOffset = proposed.flatMap { neighbor(offset: $0) == nil ? nil : $0 }
    }

    mutating func commit(in window: BrowserWindowModel) {
        guard let activeOffset, let id = neighbor(offset: activeOffset) else { return }
        window.selectSpace(id)
        expectedSpaceID = window.record.selectedSpaceID
        expectedTabID = window.record.selectedTabID
    }

    mutating func cancel() {
        activeOffset = nil
    }
}

// Axis lock avoids stealing vertical scrolls; page switching is driven by displacement.
struct SidebarSwipeTracker {
    static let commitFraction = 0.30
    static let maximumSpeed = 2_400.0
    private var horizontal = 0.0
    private var visualHorizontal = 0.0
    private var vertical = 0.0
    private var axis: Bool?
    private var lastTimestamp: TimeInterval?
    mutating func reset() { self = Self() }
    static func destination(translation: Double, width: Double) -> Int? {
        abs(translation) >= max(1, width) * commitFraction ? (translation < 0 ? 1 : -1) : nil
    }
    static func distanceDelta(_ value: Double) -> Double {
        let magnitude = abs(value)
        guard magnitude > 4 else { return value }
        let softened = 4 + sqrt(magnitude - 4)
        return (magnitude * 0.75 + softened * 0.25) * (value < 0 ? -1 : 1)
    }
    mutating func update(x: Double, y: Double, timestamp: TimeInterval? = nil) -> (consume: Bool, translation: Double, intent: Double) {
        horizontal += Self.distanceDelta(x); vertical += Self.distanceDelta(y)
        if axis == nil, max(abs(horizontal), abs(vertical)) >= 8 {
            if abs(horizontal) > abs(vertical) * 2 { axis = true }
            else if abs(vertical) >= abs(horizontal) { axis = false }
        } else if axis == true, abs(vertical) > abs(horizontal) {
            axis = false
        }
        guard axis == true else { return (false, 0, horizontal) }
        let target = horizontal / 2
        if let timestamp {
            let elapsed = lastTimestamp.map { min(1.0 / 30, max(0, timestamp - $0)) } ?? 1.0 / 120
            let limit = Self.maximumSpeed * elapsed
            visualHorizontal += max(-limit, min(limit, target - visualHorizontal))
            lastTimestamp = timestamp
        } else {
            visualHorizontal = target
        }
        return (true, visualHorizontal, horizontal)
    }
}

struct SidebarSwipeView: NSViewRepresentable {
    let window: BrowserWindowModel
    var active: Bool
    var dismissAddressSuggestions: () -> Void
    var progress: (Double, Double) -> Void
    var finish: (Bool) -> Void
    var invalidate: () -> Void
    func makeNSView(context: Context) -> SwipeView {
        SwipeView(model: window, dismissAddressSuggestions: dismissAddressSuggestions,
                  progress: progress, finish: finish, invalidate: invalidate)
    }
    func updateNSView(_ nsView: SwipeView, context: Context) {
        nsView.dismissAddressSuggestions = dismissAddressSuggestions
        nsView.progress = progress; nsView.finish = finish; nsView.invalidate = invalidate
        if !active { nsView.stopTracking() }
    }
    static func dismantleNSView(_ nsView: SwipeView, coordinator: ()) { nsView.stop() }

    final class SwipeView: NSView {
        let model: BrowserWindowModel
        var dismissAddressSuggestions: () -> Void
        var progress: (Double, Double) -> Void
        var finish: (Bool) -> Void
        var invalidate: () -> Void
        private var monitor: Any?
        private var tracker = SidebarSwipeTracker()
        private var tracking = false
        private var hasProgress = false
        private var expectedSpaceID: UUID?
        private var expectedTabID: UUID?
        private var resignObserver: Any?
        init(model: BrowserWindowModel, dismissAddressSuggestions: @escaping () -> Void,
             progress: @escaping (Double, Double) -> Void, finish: @escaping (Bool) -> Void, invalidate: @escaping () -> Void) {
            self.model = model; self.dismissAddressSuggestions = dismissAddressSuggestions
            self.progress = progress; self.finish = finish; self.invalidate = invalidate; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateTracking() }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) == nil }
                return consumed ? nil : event
            }
        }
        func stopTracking() {
            guard hasProgress else { return }
            tracking = false; hasProgress = false; tracker.reset(); expectedSpaceID = nil; expectedTabID = nil
        }
        private func invalidateTracking() {
            tracking = false; hasProgress = false; tracker.reset(); expectedSpaceID = nil; expectedTabID = nil
            invalidate()
        }
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window else { return event }
            if event.type == .leftMouseDown, bounds.contains(convert(event.locationInWindow, from: nil)) {
                dismissAddressSuggestions()
            }
            guard event.type == .scrollWheel else {
                if tracking || hasProgress { invalidateTracking() }
                return event
            }
            guard event.momentumPhase.isEmpty else { return event }
            guard window?.attachedSheet == nil,
                  !model.commandBarPresented, model.spaces.count > 1,
                  event.hasPreciseScrollingDeltas else { invalidateTracking(); return event }
            if event.phase.contains(.began) {
                invalidateTracking()
                tracking = bounds.contains(convert(event.locationInWindow, from: nil))
                expectedSpaceID = model.record.selectedSpaceID
                expectedTabID = model.record.selectedTabID
            }
            guard tracking else { return event }
            guard expectedSpaceID == model.record.selectedSpaceID, expectedTabID == model.record.selectedTabID else {
                invalidateTracking(); return event
            }
            let result = tracker.update(x: event.scrollingDeltaX, y: event.scrollingDeltaY, timestamp: event.timestamp)
            if hasProgress, !result.consume {
                invalidateTracking()
                return event
            }
            if result.consume, !event.phase.contains(.cancelled) {
                hasProgress = true
                progress(result.translation, result.intent)
            }
            expectedSpaceID = model.record.selectedSpaceID
            expectedTabID = model.record.selectedTabID
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                tracking = false; hasProgress = false; tracker.reset(); expectedSpaceID = nil; expectedTabID = nil
                finish(event.phase.contains(.cancelled))
            }
            return result.consume ? nil : event
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
            tracking = false; hasProgress = false; tracker.reset(); expectedSpaceID = nil; expectedTabID = nil
        }
    }
}

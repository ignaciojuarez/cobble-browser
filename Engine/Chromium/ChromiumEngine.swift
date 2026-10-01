import AppKit
import CobbleChromium

#if COBBLE_CHROMIUM_ABI10
let chromiumPageOperations: Set<PageOperation> = [
    .find, .zoom, .muteAudio, .printPage, .reloadFromOrigin, .snapshot, .localFile,
    .savePage, .pageDOM, .openDevTools, .detach
]
#elseif COBBLE_CHROMIUM_ABI4
let chromiumPageOperations: Set<PageOperation> = [
    .find, .zoom, .muteAudio, .printPage, .reloadFromOrigin, .snapshot, .savePage, .pageDOM, .openDevTools, .detach
]
#else
let chromiumPageOperations: Set<PageOperation> = [.find, .zoom]
#endif

private let chromiumLegacyDataRemoval: Set<WebsiteDataRemovalCapability> = [
    .init(categories: [.siteData, .cache], scope: .recordsAllTime),
    .init(categories: [.cache], scope: .profileAllTime),
]
#if COBBLE_CHROMIUM_ABI13
private let chromiumDataRemoval: Set<WebsiteDataRemovalCapability> = [
    .init(categories: [.siteData], scope: .recordsAllTime),
    .init(categories: [.cache], scope: .recordsAllTime),
    .init(categories: [.siteData, .cache], scope: .recordsAllTime),
    .init(categories: [.siteData], scope: .profileAllTime),
    .init(categories: [.cache], scope: .profileAllTime),
    .init(categories: [.siteData, .cache], scope: .profileAllTime),
    .init(categories: [.cache], scope: .profileSince),
]
#else
private let chromiumDataRemoval = chromiumLegacyDataRemoval
#endif

#if COBBLE_CHROMIUM_ABI4
let chromiumPermissions: Set<PermissionKind> = [.camera, .microphone]
let chromiumCaptureControls: Set<PageCaptureControl> = [.stopAllUserMedia]
let chromiumSupportsPopupPolicy = true
private let chromiumSupportsProfileDeletion = true
#else
let chromiumPermissions: Set<PermissionKind> = []
let chromiumCaptureControls: Set<PageCaptureControl> = []
let chromiumSupportsPopupPolicy = false
private let chromiumSupportsProfileDeletion = false
#endif

#if COBBLE_CHROMIUM_ABI14
private let chromiumSupportsCookieTransfer = true
#else
private let chromiumSupportsCookieTransfer = false
#endif

#if COBBLE_CHROMIUM_ABI16
private let chromiumSupportsBrowserIdentity = true

extension SiteBrowserIdentity {
    var chromiumIdentity: ChromiumBrowserIdentity {
        switch self {
        case .standard: .standard
        case .androidPhone: .androidPhone
        case .androidTablet: .androidTablet
        case .iPhone: .iPhone
        case .iPad: .iPad
        }
    }
}
#else
private let chromiumSupportsBrowserIdentity = false
#endif

/// The Chromium runtime is assembled by the outer launcher. This adapter does
/// not register it with the app until that launcher and its framework are
/// packaged together.
@MainActor final class ChromiumEngine: BrowserEngine {
    let id = EngineID(rawValue: "chromium")
    let name = "Chromium"
    let capabilities = EngineCapabilities(pageOperations: chromiumPageOperations, requiresCloseConfirmation: true,
                                          permissions: chromiumPermissions, captureControls: chromiumCaptureControls,
                                          websiteDataRemoval: chromiumDataRemoval, supportsPopupPolicy: chromiumSupportsPopupPolicy,
                                          supportsProfileDeletion: chromiumSupportsProfileDeletion,
                                          supportsCookieTransfer: chromiumSupportsCookieTransfer,
                                          supportsBrowserIdentity: chromiumSupportsBrowserIdentity)
    #if COBBLE_CHROMIUM_ABI4
    lazy var chromiumContentBlocker = ChromiumContentBlocker(
        engine: self, runtime: runtime, directory: extensionDirectory)
    var contentBlocker: (any EngineContentBlocker)? { chromiumContentBlocker }
    #else
    var contentBlocker: (any EngineContentBlocker)? { nil }
    #endif

    private let runtime: ChromiumRuntime
    private let extensionDirectory: URL
    private var pages: [ObjectIdentifier: ChromiumPage] = [:]
    #if COBBLE_CHROMIUM_ABI15
    private var extensionInstallAlerts: [UInt64: (page: ObjectIdentifier, window: NSWindow, alert: NSAlert)] = [:]
    #endif
    #if COBBLE_CHROMIUM_ABI4
    private var mediaRequestIDs: [UInt64: UUID] = [:]
    private var javaScriptDialogIDs: [UInt64: UUID] = [:]
    private var httpAuthRequestIDs: [UInt64: UUID] = [:]
    private var fileChooserIDs: [UInt64: UUID] = [:]
    private var externalProtocolIDs: [UInt64: UUID] = [:]
    #if COBBLE_CHROMIUM_ABI12
    private var clientCertificateIDs: [UInt64: UUID] = [:]
    #endif
    #endif
    private var normalContexts: [UUID: ChromiumContext] = [:]
    private lazy var chromiumExtensionManager = ChromiumExtensionManager(
        engine: self, runtime: runtime, directory: extensionDirectory)
    var extensionManager: (any BrowserExtensionManaging)? { chromiumExtensionManager }

    init(runtime: ChromiumRuntime, directory: URL) {
        self.runtime = runtime
        extensionDirectory = directory
        #if COBBLE_CHROMIUM_ABI17
        runtime.onPopupWithDisposition = { [weak self] parent, child, disposition in
            self?.receivePopup(parent: parent, child: child, activate: Self.activatesPopup(disposition))
        }
        #else
        runtime.onPopup = { [weak self] parent, child in
            self?.receivePopup(parent: parent, child: child, activate: true)
        }
        #endif
        #if COBBLE_CHROMIUM_ABI15
        runtime.extensionInstallRequested = { [weak self] request in
            self?.receiveExtensionInstall(request)
        }
        runtime.extensionInstallCancelled = { [weak self] id in
            self?.cancelExtensionInstall(id, resolve: false)
        }
        #endif
        #if COBBLE_CHROMIUM_ABI4
        runtime.popupPolicy = { [weak self] request in self?.allowsPopup(request) ?? false }
        runtime.onMediaPermissionRequest = { [weak self] request in self?.receiveMediaPermission(request) }
        runtime.onJavaScriptDialog = { [weak self] request in self?.receiveJavaScriptDialog(request) }
        runtime.onHTTPAuthRequest = { [weak self] request in self?.receiveHTTPAuth(request) }
        runtime.onFileChooserRequest = { [weak self] request in self?.receiveFileChooser(request) }
        runtime.onExternalProtocolRequest = { [weak self] request in self?.receiveExternalProtocol(request) }
        #if COBBLE_CHROMIUM_ABI12
        runtime.onClientCertificateRequest = { [weak self] request in self?.receiveClientCertificate(request) }
        #endif
        #endif
        runtime.onDownload = { [weak self] page, download in
            self?.receiveDownload(page: page, download: download)
        }
    }

    func makeContext(profile: Profile, id: BrowsingContextID,
                     siteSettings: SiteSettingsStore) throws -> any EngineContext {
        guard id.engineID == self.id else { throw EngineError.unavailable(id.engineID) }
        if !id.isPrivate, let context = normalContexts[profile.id], !context.isClosed {
            context.attach(siteSettings: siteSettings)
            return context
        }
        let context = ChromiumContext(runtime: runtime, id: id,
                                          profileKey: chromiumProfileKey(profile.id),
                                          privateWindowKey: id.privateWindowID?.uuidString,
                                          siteSettings: siteSettings, engine: self)
        if !id.isPrivate { normalContexts[profile.id] = context }
        return context
    }

    func preflightProfileDeletion(_ profile: Profile) async throws {
        #if COBBLE_CHROMIUM_ABI4
        guard case .named = profile.storeBinding else { return }
        try await runtime.waitUntilReady()
        try await runtime.preflightProfileDeletion(key: chromiumProfileKey(profile.id))
        #else
        throw EngineError.notReady("Chromium profile deletion is unavailable in this build.")
        #endif
    }

    func removeProfile(_ profile: Profile) async throws {
        #if COBBLE_CHROMIUM_ABI4
        guard case .named = profile.storeBinding else { return }
        try await runtime.waitUntilReady()
        try await runtime.scheduleProfileDeletion(key: chromiumProfileKey(profile.id))
        try chromiumExtensionManager.removeProfile(profile.id)
        try await chromiumContentBlocker.removeProfile(profile.id)
        #else
        throw EngineError.notReady("Chromium profile deletion is unavailable in this build.")
        #endif
    }

    func shutdown() async {
        #if COBBLE_CHROMIUM_ABI15
        for id in Array(extensionInstallAlerts.keys) { cancelExtensionInstall(id, resolve: true) }
        #endif
        // A manager may have opened a normal context before the user created a
        // Chromium tab. Those contexts are not in EngineRegistry, so close all
        // retained hosts here before the launcher tears down Chromium.
        let contexts = Array(normalContexts.values)
        for context in contexts { await context.close() }
        pages.removeAll()
        #if COBBLE_CHROMIUM_ABI4
        mediaRequestIDs.removeAll()
        javaScriptDialogIDs.removeAll()
        httpAuthRequestIDs.removeAll()
        fileChooserIDs.removeAll()
        externalProtocolIDs.removeAll()
        #if COBBLE_CHROMIUM_ABI12
        clientCertificateIDs.removeAll()
        #endif
        #endif
        normalContexts.removeAll()
    }

    func remember(_ page: ChromiumPage, source: CobbleChromium.ChromiumPage) {
        pages[ObjectIdentifier(source)] = page
    }

    func forget(_ source: CobbleChromium.ChromiumPage) {
        #if COBBLE_CHROMIUM_ABI15
        let page = ObjectIdentifier(source)
        for id in extensionInstallAlerts.keys.filter({ extensionInstallAlerts[$0]?.page == page }) {
            cancelExtensionInstall(id, resolve: true)
        }
        #endif
        pages.removeValue(forKey: ObjectIdentifier(source))
    }

    func normalContext(_ profileID: UUID) -> ChromiumContext? {
        normalContexts[profileID]
    }

    /// Extension management owns a normal context on demand. Later tab
    /// activation reuses this same host through `makeContext`.
    func extensionContext(_ profileID: UUID) async throws -> (host: ChromiumContext, context: CobbleChromium.ChromiumContext) {
        let host: ChromiumContext
        if let existing = normalContexts[profileID], !existing.isClosed {
            host = existing
        } else {
            let contextID = BrowsingContextID(engineID: id, profileID: profileID, privateWindowID: nil)
            host = ChromiumContext(runtime: runtime, id: contextID,
                                       profileKey: chromiumProfileKey(profileID),
                                       privateWindowKey: nil, siteSettings: nil, engine: self)
            normalContexts[profileID] = host
        }
        return (host, try await host.extensionContext())
    }

    fileprivate func contextOpened(_ context: ChromiumContext, native: CobbleChromium.ChromiumContext) {
        guard !context.isPrivate else { return }
        #if COBBLE_CHROMIUM_ABI15
        let profileID = context.id.profileID
        native.onExtensionsChanged = { [weak self, weak native] in
            guard let self, let native else { return }
            Task { await self.chromiumExtensionManager.refreshFromNative(
                profileID: profileID, context: native) }
        }
        #endif
        Task { await chromiumExtensionManager.refreshFromNative(profileID: context.id.profileID, context: native) }
    }

    #if COBBLE_CHROMIUM_ABI15
    private func receiveExtensionInstall(_ request: ChromiumExtensionInstallRequest) {
        guard let host = pages[ObjectIdentifier(request.page)], host.source === request.page,
              host.state.lifecycle == .ready, !host.closing, !host.contextID.isPrivate,
              !request.page.isClosed, !request.page.isClosing,
              let window = request.page.nativeView.window,
              let controller = window.windowController as? BrowserWindowController,
              controller.model.nativeWindow === window,
              controller.model.selectedPage === host,
              NSApp.isActive, window.isVisible, window.isKeyWindow, window.attachedSheet == nil,
              let source = request.sourceURL, source.scheme == "https",
              source.host == "chromewebstore.google.com",
              source.user == nil, source.password == nil,
              source.port == nil || source.port == 443,
              !request.requestsHostPermissions || request.canWithholdHostPermissions,
              request.extensionID.range(of: "^[a-p]{32}$", options: .regularExpression) != nil,
              extensionInstallAlerts[request.id] == nil else {
            runtime.resolveExtensionInstall(request.id, accept: false)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Add \(request.name) to Cobble?"
        alert.informativeText = ([request.title, request.permissionsHeading]
            + request.permissionWarnings).filter { !$0.isEmpty }.joined(separator: "\n")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Add Extension")
        extensionInstallAlerts[request.id] = (ObjectIdentifier(request.page), window, alert)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.extensionInstallAlerts.removeValue(forKey: request.id) != nil else { return }
            self.runtime.resolveExtensionInstall(request.id,
                accept: response == .alertSecondButtonReturn
                    && controller.model.selectedPage === host)
        }
    }

    private func cancelExtensionInstall(_ id: UInt64, resolve: Bool) {
        guard let pending = extensionInstallAlerts.removeValue(forKey: id) else { return }
        if pending.window.attachedSheet === pending.alert.window {
            pending.window.endSheet(pending.alert.window, returnCode: .cancel)
        }
        if resolve { runtime.resolveExtensionInstall(id, accept: false) }
    }
    #endif

    fileprivate func contextDidClose(_ context: ChromiumContext) {
        guard let current = normalContexts[context.id.profileID], current === context else { return }
        normalContexts.removeValue(forKey: context.id.profileID)
        #if COBBLE_CHROMIUM_ABI4
        chromiumContentBlocker.contextDidClose(context.id.profileID)
        #endif
        chromiumExtensionManager.contextDidClose(context)
    }

    /// Chromium's initial profile is already created during startup. Keep
    /// Cobble's stable default ID on that profile; additional Cobble profiles
    /// receive separate named Chromium profile directories.
    private func chromiumProfileKey(_ profileID: UUID) -> String {
        profileID == Profile.defaultID ? "" : profileID.uuidString
    }

    #if COBBLE_CHROMIUM_ABI17
    static func activatesPopup(_ disposition: ChromiumPopupRequest.Disposition) -> Bool {
        disposition != .newBackgroundTab
    }
    #endif

    private func receivePopup(parent: CobbleChromium.ChromiumPage?, child: CobbleChromium.ChromiumPage,
                              activate: Bool) {
        guard let parent, let parentHost = pages[ObjectIdentifier(parent)],
              parentHost.state.lifecycle == .ready, !parentHost.closing else {
            // There is no Cobble page host to restore if a before-unload
            // handler refuses the close. Orphaned popups must be retired.
            child.forceClose()
            return
        }
        do {
            if child.hostWindowID != parentHost.windowID {
                try child.move(toHostWindowID: parentHost.windowID)
            }
        } catch {
            child.forceClose()
            parentHost.state.errorMessage = "Chromium could not show this popup in the current window."
            return
        }
        guard parentHost.state.lifecycle == .ready, !parentHost.closing else {
            child.forceClose()
            return
        }
        let host = ChromiumPage(tabID: UUID(), context: parentHost.context,
                                    windowID: parentHost.windowID, engine: self)
        guard parentHost.state.lifecycle == .ready, !parentHost.closing,
              parentHost.events.onCreatePage?(host, activate) == true else {
            child.forceClose()
            return
        }
        host.attach(child)
    }

    #if COBBLE_CHROMIUM_ABI4
    private func allowsPopup(_ request: ChromiumPopupRequest) -> Bool {
        guard let host = pages[ObjectIdentifier(request.opener)], host.state.lifecycle == .ready,
              !host.closing, host.source === request.opener,
              let pageURL = URL(string: host.state.urlString),
              let pageOrigin = AddressResolver.canonicalOrigin(pageURL),
              let topLevelURL = request.topLevelURL,
              AddressResolver.canonicalOrigin(topLevelURL) == pageOrigin,
              let requestingOrigin = request.requestingOrigin,
              AddressResolver.canonicalOrigin(requestingOrigin) != nil,
              [.newForegroundTab, .newBackgroundTab, .newPopup, .newWindow].contains(request.disposition) else {
            return false
        }
        let setting = host.context.siteSettings?.setting(origin: requestingOrigin,
                profileID: host.contextID.profileID, engineID: id).popups ?? .ask
        let allowed = SiteSettingsStore.allowsPopup(setting: setting,
            isPrivate: host.contextID.isPrivate, userGesture: request.userGesture)
        if !allowed { host.state.blockedPopup = true }
        return allowed
    }

    private func receiveMediaPermission(_ request: ChromiumMediaPermissionRequest) {
        guard request.isPending,
              let host = pages[ObjectIdentifier(request.page)], host.source === request.page,
              host.state.lifecycle == .ready, !request.frameToken.isEmpty,
              request.frameProcessID >= 0, request.frameRoutingID >= 0,
              AddressResolver.canonicalOrigin(request.requestingOrigin) != nil,
              AddressResolver.canonicalOrigin(request.embeddingOrigin) != nil,
              mediaRequestIDs[request.id] == nil else {
            request.deny()
            return
        }
        var kinds: Set<PermissionKind> = []
        if request.kinds.contains(.camera) { kinds.insert(.camera) }
        if request.kinds.contains(.microphone) { kinds.insert(.microphone) }
        guard !kinds.isEmpty, host.capabilities.permissions.isSuperset(of: kinds),
              let publish = host.events.onMediaPermissionRequest else {
            request.deny()
            return
        }
        let id = UUID()
        let nativeID = request.id
        mediaRequestIDs[nativeID] = id
        let shared = PageMediaPermissionRequest(id: id, tabID: host.tabID, contextID: host.contextID,
            windowID: host.windowID, documentID: request.frameToken,
            frameID: "\(request.frameProcessID):\(request.frameRoutingID)", kinds: kinds,
            requestingOrigin: request.requestingOrigin, embeddingOrigin: request.embeddingOrigin) { [weak self, weak host, weak request] decision in
                guard let self, self.mediaRequestIDs.removeValue(forKey: nativeID) == id else { return }
                guard let request, request.isPending else { return }
                if decision == .allow {
                    guard let host, !host.closing else { request.deny(); return }
                    host.state.grantedMediaKinds.formUnion(kinds)
                    request.allow()
                } else { request.deny() }
            }
        request.onCancel = { [weak self, weak host, weak request] in
            guard let self, let request,
                  self.mediaRequestIDs.removeValue(forKey: nativeID) == id else { return }
            host?.events.onPromptCancelled?(id)
            shared.resolve(.deny)
        }
        publish(shared)
    }

    private func receiveJavaScriptDialog(_ request: ChromiumJavaScriptDialogRequest) {
        guard request.isPending, let host = promptHost(request.page),
              var identity = promptIdentity(host: host,
                  requestingOrigin: request.requestingOrigin, topLevelOrigin: request.topLevelOrigin,
                  documentID: request.frameToken,
                  frameID: "\(request.frameProcessID):\(request.frameRoutingID)"),
              request.frameProcessID >= 0, request.frameRoutingID >= 0,
              javaScriptDialogIDs[request.id] == nil,
              let publish = host.events.onJavaScriptDialog else {
            request.cancel()
            return
        }
        if request.kind == .beforeUnload {
            guard let committedOrigin = host.committedOrigin,
                  identity.topLevelOrigin.flatMap(AddressResolver.canonicalOrigin) == committedOrigin,
                  let visibleURL = URL(string: host.state.urlString),
                  AddressResolver.canonicalOrigin(visibleURL) != nil else {
                request.cancel()
                return
            }
            identity.visiblePageOrigin = visibleURL
        }
        #if COBBLE_CHROMIUM_ABI11
        if request.kind == .formRepost && !request.isReload {
            request.cancel()
            return
        }
        #endif
        let kind: PageJavaScriptDialogKind = switch request.kind {
        case .alert: .alert
        case .confirm: .confirm
        case .prompt: .prompt
        case .beforeUnload: .beforeUnload
        #if COBBLE_CHROMIUM_ABI11
        case .formRepost: .formRepost
        #endif
        }
        let id = UUID()
        let nativeID = request.id
        javaScriptDialogIDs[nativeID] = id
        let shared = PageJavaScriptDialogRequest(id: id, identity: identity,
            prompt: PageJavaScriptDialog(kind: kind, message: request.message,
                defaultText: kind == .prompt ? request.defaultText : nil, isReload: request.isReload)) {
                [weak self, weak request] result in
                guard let self, self.javaScriptDialogIDs.removeValue(forKey: nativeID) == id else { return }
                guard let request, request.isPending else { return }
                switch result {
                case .accept(let text): request.accept(promptText: text)
                case .cancel: request.cancel()
                }
            }
        request.onCancel = { [weak self, weak host, weak request] in
            guard let self, let request,
                  self.javaScriptDialogIDs.removeValue(forKey: nativeID) == id else { return }
            host?.events.onPromptCancelled?(id)
            shared.resolve(.cancel)
        }
        publish(shared)
    }

    private func receiveHTTPAuth(_ request: ChromiumHTTPAuthRequest) {
        guard request.isPending, let host = promptHost(request.page), let requestURL = request.requestURL,
              let requestOrigin = AddressResolver.canonicalOrigin(requestURL),
              let challengerURL = URL(string: request.challengerOrigin),
              let challengerOrigin = AddressResolver.canonicalOrigin(challengerURL),
              request.isProxy || challengerOrigin == requestOrigin,
              (request.networkProcessID == 0 && request.networkRequestID <= -2)
                || (request.networkProcessID > 0 && request.networkRequestID >= 0),
              httpAuthRequestIDs[request.id] == nil,
              let publish = host.events.onHTTPAuthRequest else {
            request.cancel()
            return
        }
        let topLevelOrigin: String
        var visiblePageOrigin: URL?
        if request.primaryMainFrameNavigation {
            topLevelOrigin = requestOrigin
            guard let visibleURL = URL(string: host.state.urlString),
                  AddressResolver.canonicalOrigin(visibleURL) != nil else { request.cancel(); return }
            visiblePageOrigin = visibleURL
        } else { topLevelOrigin = request.topLevelOrigin }
        guard var identity = promptIdentity(host: host,
                requestingOrigin: request.challengerOrigin, topLevelOrigin: topLevelOrigin,
                documentID: request.documentFrameToken,
                frameID: "\(request.networkProcessID):\(request.networkRequestID)") else {
            request.cancel()
            return
        }
        identity.visiblePageOrigin = visiblePageOrigin
        let id = UUID()
        let nativeID = request.id
        httpAuthRequestIDs[nativeID] = id
        let shared = PageHTTPAuthRequest(id: id, identity: identity,
            prompt: PageHTTPAuthChallenge(requestURL: requestURL, scheme: request.scheme,
                realm: request.realm.isEmpty ? nil : request.realm, isProxy: request.isProxy,
                firstAttempt: request.firstAttempt, primaryNavigation: request.primaryMainFrameNavigation)) {
                [weak self, weak request] credential in
                guard let self, self.httpAuthRequestIDs.removeValue(forKey: nativeID) == id else { return }
                guard let request, request.isPending else { return }
                if let credential {
                    request.submit(username: credential.username, password: credential.password)
                } else { request.cancel() }
            }
        request.onCancel = { [weak self, weak host, weak request] in
            guard let self, let request,
                  self.httpAuthRequestIDs.removeValue(forKey: nativeID) == id else { return }
            host?.events.onPromptCancelled?(id)
            shared.resolve(nil)
        }
        publish(shared)
    }

    private func receiveFileChooser(_ request: ChromiumFileChooserRequest) {
        guard request.isPending, let host = promptHost(request.page),
              let identity = promptIdentity(host: host,
                  requestingOrigin: request.requestingOrigin, topLevelOrigin: request.topLevelOrigin,
                  documentID: request.frameToken,
                  frameID: "\(request.frameProcessID):\(request.frameRoutingID)"),
              request.frameProcessID >= 0, request.frameRoutingID >= 0,
              fileChooserIDs[request.id] == nil,
              let publish = host.events.onFileChooserRequest else {
            request.cancel()
            return
        }
        let mode: PageFileChooserMode = switch request.mode {
        case .open: .open
        case .openMultiple: .openMultiple
        case .uploadFolder: .uploadFolder
        case .openDirectory: .openDirectory
        case .save: .save
        }
        let id = UUID()
        let nativeID = request.id
        fileChooserIDs[nativeID] = id
        let shared = PageFileChooserRequest(id: id, identity: identity,
            prompt: PageFileChooser(mode: mode,
                title: request.title.isEmpty ? nil : request.title,
                defaultFilename: request.defaultFilename.isEmpty ? nil : request.defaultFilename,
                acceptedTypes: request.acceptedTypes)) { [weak self, weak request] urls in
                guard let self, self.fileChooserIDs.removeValue(forKey: nativeID) == id else { return }
                guard let request, request.isPending else { return }
                if let urls { request.select(urls) } else { request.cancel() }
            }
        request.onCancel = { [weak self, weak host, weak request] in
            guard let self, let request,
                  self.fileChooserIDs.removeValue(forKey: nativeID) == id else { return }
            host?.events.onPromptCancelled?(id)
            shared.resolve(nil)
        }
        publish(shared)
    }

    private func receiveExternalProtocol(_ request: ChromiumExternalProtocolRequest) {
        let forbiddenSchemes: Set<String> = [
            "http", "https", "file", "filesystem", "about", "data", "javascript", "blob",
            "chrome", "devtools"
        ]
        guard request.isPending, let host = promptHost(request.page),
              let scheme = request.targetURL.scheme?.lowercased(), !scheme.isEmpty,
              !forbiddenSchemes.contains(scheme),
              !scheme.hasPrefix("chrome-"),
              request.targetURL.absoluteString.utf8.count <= 8192,
              request.userGesture, request.isPrimaryMainFrame, !request.isFencedFrame,
              request.frameProcessID >= 0, request.frameRoutingID >= 0,
              let identity = promptIdentity(host: host,
                  requestingOrigin: request.requestingOrigin, topLevelOrigin: request.topLevelOrigin,
                  documentID: request.frameToken,
                  frameID: "\(request.frameProcessID):\(request.frameRoutingID)"),
              externalProtocolIDs[request.id] == nil,
              let publish = host.events.onExternalProtocolRequest else {
            request.deny()
            return
        }
        let id = UUID()
        let nativeID = request.id
        externalProtocolIDs[nativeID] = id
        let shared = PageExternalProtocolRequest(id: id, identity: identity,
            prompt: PageExternalProtocolPrompt(targetURL: request.targetURL,
                userGesture: request.userGesture, primaryMainFrame: request.isPrimaryMainFrame,
                fencedFrame: request.isFencedFrame)) { [weak self, weak host, weak request] allowed in
                guard let self, self.externalProtocolIDs.removeValue(forKey: nativeID) == id else { return }
                guard let request, request.isPending else { return }
                if allowed {
                    if request.allow() { host?.events.onExternalURL?(request.targetURL) }
                } else { request.deny() }
            }
        request.onCancel = { [weak self, weak host, weak request] in
            guard let self, let request,
                  self.externalProtocolIDs.removeValue(forKey: nativeID) == id else { return }
            host?.events.onPromptCancelled?(id)
            shared.resolve(false)
        }
        publish(shared)
    }

    #if COBBLE_CHROMIUM_ABI12
    private func receiveClientCertificate(_ request: ChromiumClientCertificateRequest) {
        guard request.isPending, let host = promptHost(request.page),
              let challengerURL = URL(string: request.challengerOrigin),
              challengerURL.scheme?.lowercased() == "https",
              AddressResolver.canonicalOrigin(challengerURL) != nil,
              clientCertificateIDs[request.id] == nil,
              !request.choices.isEmpty,
              Set(request.choices.map(\.id)).count == request.choices.count,
              request.choices.allSatisfy({ $0.id != 0 }),
              let publish = host.events.onClientCertificateRequest else {
            request.cancel()
            return
        }
        let topLevelURL = URL(string: request.topLevelOrigin).flatMap {
            AddressResolver.canonicalOrigin($0) == nil ? nil : $0
        }
        let visibleURL = URL(string: request.visiblePageOrigin).flatMap {
            AddressResolver.canonicalOrigin($0) == nil ? nil : $0
        }
        let context: PageClientCertificateContext
        let documentID: String
        let frameID: String
        switch request.context {
        case .document(let processID, let routingID, let token):
            guard processID >= 0, routingID >= 0, !token.isEmpty,
                  topLevelURL != nil, visibleURL != nil else { request.cancel(); return }
            documentID = token
            frameID = "\(processID):\(routingID)"
            context = .document(documentID: documentID, frameID: frameID)
        case .navigation(let navigationID):
            guard navigationID > 0,
                  request.primaryMainFrame || (topLevelURL != nil && visibleURL != nil) else {
                request.cancel()
                return
            }
            documentID = ""
            frameID = ""
            context = .navigation(navigationID: String(navigationID),
                                  primaryMainFrame: request.primaryMainFrame)
        }
        var identity = PagePromptIdentity(tabID: host.tabID, contextID: host.contextID,
            windowID: host.windowID, documentID: documentID, frameID: frameID,
            requestingOrigin: challengerURL, topLevelOrigin: topLevelURL)
        identity.visiblePageOrigin = visibleURL
        let mappings: [(PageClientCertificateChoice, UInt64)] = request.choices.map { choice in
            (PageClientCertificateChoice(id: UUID(),
                certificate: PageCertificateDetails(subject: Self.clientCertificateText(choice.subject),
                    issuer: Self.clientCertificateText(choice.issuer), validFrom: choice.validFrom,
                    validUntil: choice.validUntil),
                serialNumber: choice.serialNumber.isEmpty ? nil : choice.serialNumber), choice.id)
        }
        let nativeIDs: [UUID: UInt64] = Dictionary(
            uniqueKeysWithValues: mappings.map { ($0.0.id, $0.1) })
        let id = UUID()
        let nativeID = request.id
        clientCertificateIDs[nativeID] = id
        let shared = PageClientCertificateRequest(id: id, identity: identity,
            prompt: PageClientCertificatePrompt(choices: mappings.map(\.0),
                choicesTruncated: request.choicesTruncated, context: context)) {
                [weak self, weak request] choiceID in
                guard let self, self.clientCertificateIDs.removeValue(forKey: nativeID) == id else { return }
                guard let request, request.isPending else { return }
                guard let choiceID, let nativeChoiceID = nativeIDs[choiceID] else {
                    request.cancel()
                    return
                }
                if !request.select(choiceID: nativeChoiceID) { request.cancel() }
            }
        request.onCancel = { [weak self, weak host, weak request] in
            guard let self, let request,
                  self.clientCertificateIDs.removeValue(forKey: nativeID) == id else { return }
            host?.events.onPromptCancelled?(id)
            shared.resolve(nil)
        }
        publish(shared)
    }

    private static func clientCertificateText(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? String(localized: "Unknown") : text
    }
    #endif

    private func promptHost(_ page: CobbleChromium.ChromiumPage) -> ChromiumPage? {
        guard let host = pages[ObjectIdentifier(page)], host.source === page,
              host.state.lifecycle == .ready else { return nil }
        return host
    }

    private func promptIdentity(host: ChromiumPage, requestingOrigin: String,
                                topLevelOrigin: String, documentID: String,
                                frameID: String) -> PagePromptIdentity? {
        guard !documentID.isEmpty, !frameID.isEmpty,
              let requestingURL = URL(string: requestingOrigin),
              AddressResolver.canonicalOrigin(requestingURL) != nil,
              let topLevelURL = URL(string: topLevelOrigin),
              AddressResolver.canonicalOrigin(topLevelURL) != nil else { return nil }
        return PagePromptIdentity(tabID: host.tabID, contextID: host.contextID,
            windowID: host.windowID, documentID: documentID, frameID: frameID,
            requestingOrigin: requestingURL, topLevelOrigin: topLevelURL)
    }
    #endif

    private func receiveDownload(page: CobbleChromium.ChromiumPage, download: ChromiumDownload) {
        guard let host = pages[ObjectIdentifier(page)], host.state.lifecycle == .ready else {
            download.cancel { download.release() }
            return
        }
        guard let receive = host.events.onDownload else {
            download.cancel { download.release() }
            return
        }
        receive(ChromiumEngineDownload(download, window: host.nativeView.window))
    }

}

@MainActor final class ChromiumContext: EngineContext {
    let id: BrowsingContextID
    static func capabilities(isPrivate: Bool) -> EngineCapabilities {
        EngineCapabilities(pageOperations: chromiumPageOperations, requiresCloseConfirmation: true,
                           permissions: chromiumPermissions, captureControls: chromiumCaptureControls,
                           websiteDataRemoval: isPrivate ? [] : chromiumDataRemoval,
                           supportsPopupPolicy: chromiumSupportsPopupPolicy, supportsProfileDeletion: false,
                           supportsCookieTransfer: !isPrivate && chromiumSupportsCookieTransfer,
                           supportsBrowserIdentity: chromiumSupportsBrowserIdentity)
    }
    var capabilities: EngineCapabilities { Self.capabilities(isPrivate: isPrivate) }
    private let runtime: ChromiumRuntime
    private let profileKey: String
    private let privateWindowKey: String?
    private(set) var siteSettings: SiteSettingsStore?
    private unowned let engine: ChromiumEngine
    private var opening: Task<CobbleChromium.ChromiumContext, Error>?
    private var context: CobbleChromium.ChromiumContext?
    private var websiteDataRecords: [UUID: String] = [:]
    private var closed = false
    private var closing = false

    var isPrivate: Bool { privateWindowKey != nil }
    var isClosed: Bool { closed }
    var isAvailable: Bool { !closed && !closing }

    init(runtime: ChromiumRuntime, id: BrowsingContextID, profileKey: String,
         privateWindowKey: String?, siteSettings: SiteSettingsStore?, engine: ChromiumEngine) {
        self.runtime = runtime
        self.id = id
        self.profileKey = profileKey
        self.privateWindowKey = privateWindowKey
        self.siteSettings = siteSettings
        self.engine = engine
    }

    func attach(siteSettings: SiteSettingsStore) { self.siteSettings = siteSettings }

    #if COBBLE_CHROMIUM_ABI14
    func exportCookies(for url: URL) async throws -> CookieTransferSnapshot {
        guard isAvailable else { throw EngineError.closed }
        guard !isPrivate else { throw EngineError.unsupported("private login sharing") }
        let host = try EngineCookie.host(for: url)
        let native = try await nativeContext()
        let snapshot = try await native.cookies(forHTTPSHost: host)
        guard isAvailable else { throw EngineError.closed }
        var result = CookieTransferSnapshot(cookies: [], skipped: snapshot.skipped)
        for cookie in snapshot.cookies {
            guard let sameSite = EngineCookie.SameSite(rawValue: cookie.sameSite.rawValue) else {
                result.skipped += 1; continue
            }
            let record = EngineCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                                      expires: cookie.expires, secure: cookie.secure, httpOnly: cookie.httpOnly, sameSite: sameSite)
            do { try record.validate(for: url); result.cookies.append(record) }
            catch { result.skipped += 1 }
        }
        return result
    }

    func replaceCookies(_ cookies: [EngineCookie], for url: URL) async throws -> Int {
        guard isAvailable else { throw EngineError.closed }
        guard !isPrivate else { throw EngineError.unsupported("private login sharing") }
        let host = try EngineCookie.host(for: url)
        let records = try cookies.map { cookie in
            try cookie.validate(for: url)
            guard let sameSite = ChromiumCookie.SameSite(rawValue: cookie.sameSite.rawValue) else {
                throw EngineError.unsupported("these login cookies")
            }
            return ChromiumCookie(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                                  expires: cookie.expires, secure: cookie.secure, httpOnly: cookie.httpOnly, sameSite: sameSite)
        }
        let native = try await nativeContext()
        guard isAvailable else { throw EngineError.closed }
        let result = try await native.replaceCookies(records, forHTTPSHost: host)
        guard isAvailable else { throw EngineError.closed }
        return result.rejected
    }
    #endif

    func makePage(tabID: UUID, windowID: UUID) throws -> any BrowserPage {
        guard isAvailable else { throw EngineError.closed }
        return ChromiumPage(tabID: tabID, context: self, windowID: windowID, engine: engine)
    }

    func websiteData() async throws -> [WebsiteDataRecord] {
        guard isAvailable else { throw EngineError.closed }
        guard !isPrivate else { throw EngineError.unsupported("private website data") }
        let context = try await nativeContext()
        let domains = try await context.websiteDataSites()
        guard isAvailable else { throw EngineError.closed }
        var current: [UUID: String] = [:]
        let result = domains.map { domain in
            let id = websiteDataRecords.first { $0.value == domain }?.key ?? UUID()
            current[id] = domain
            return WebsiteDataRecord(id: id, displayName: domain)
        }
        websiteDataRecords = current
        return result
    }

    func removeWebsiteData(_ request: WebsiteDataRemovalRequest) async throws {
        guard isAvailable else { throw EngineError.closed }
        guard !isPrivate else { throw EngineError.unsupported("private website data") }
        guard chromiumDataRemoval.contains(request.capability), !request.categories.isEmpty else {
            throw EngineError.unsupported("this website data range")
        }
        if case .profile(let modifiedSince?) = request.scope {
            let seconds = modifiedSince.timeIntervalSince1970
            guard seconds.isFinite, seconds >= 0, modifiedSince <= Date() else {
                throw EngineError.notReady(String(localized: "Choose a valid website data time range."))
            }
        }
        let context = try await nativeContext()
        #if COBBLE_CHROMIUM_ABI13
        var nativeCategories: ChromiumWebsiteDataCategories = []
        if request.categories.contains(.siteData) { nativeCategories.insert(.siteData) }
        if request.categories.contains(.cache) { nativeCategories.insert(.cache) }
        switch request.scope {
        case .records(let ids):
            let selected = try ids.map { id in
                guard let domain = websiteDataRecords[id] else {
                    throw EngineError.notReady("Website data changed. Refresh and try again.")
                }
                return (id, domain)
            }
            for (id, domain) in selected {
                try await context.removeWebsiteData(categories: nativeCategories, for: domain)
                websiteDataRecords.removeValue(forKey: id)
            }
        case .profile(let modifiedSince):
            try await context.removeWebsiteData(categories: nativeCategories, modifiedSince: modifiedSince)
            websiteDataRecords.removeAll()
        }
        #else
        switch request.scope {
        case .records(let ids):
            let selected = try ids.map { id in
                guard let domain = websiteDataRecords[id] else {
                    throw EngineError.notReady("Website data changed. Refresh and try again.")
                }
                return (id, domain)
            }
            for (id, domain) in selected {
                try await context.removeWebsiteData(for: domain)
                websiteDataRecords.removeValue(forKey: id)
            }
        case .profile:
            try await context.clearCache()
            websiteDataRecords.removeAll()
        }
        #endif
    }

    func close() async {
        guard !closed, !closing else { return }
        closing = true
        let opened: CobbleChromium.ChromiumContext?
        if let context { opened = context }
        else if let opening { opened = try? await opening.value }
        else { opened = nil }
        guard let opened else {
            context = nil
            opening = nil
            websiteDataRecords.removeAll()
            closed = true
            closing = false
            engine.contextDidClose(self)
            return
        }
        // A refused before-unload keeps the native context, its profile lease,
        // and this host associated. A later activation must reuse it instead
        // of opening a second context for the same Cobble profile.
        guard await opened.close() else {
            closing = false
            return
        }
        context = nil
        opening = nil
        websiteDataRecords.removeAll()
        closed = true
        closing = false
        engine.contextDidClose(self)
    }

    func makeNativePage(hostWindowID: UUID) async throws -> CobbleChromium.ChromiumPage {
        guard isAvailable else { throw EngineError.closed }
        let context = try await nativeContext()
        guard isAvailable else { throw EngineError.closed }
        return try context.makePage(hostWindowID: hostWindowID)
    }

    func extensionContext() async throws -> CobbleChromium.ChromiumContext {
        guard isAvailable else { throw EngineError.closed }
        guard !isPrivate else { throw EngineError.unsupported("private extensions") }
        return try await nativeContext()
    }

    private func nativeContext() async throws -> CobbleChromium.ChromiumContext {
        if let context {
            guard isAvailable else { throw EngineError.closed }
            return context
        }
        let task: Task<CobbleChromium.ChromiumContext, Error>
        if let opening {
            task = opening
        } else {
            let openingTask = Task { @MainActor [weak self] in
                guard let self else { throw EngineError.closed }
                let opened = try await self.runtime.openContext(profileKey: self.profileKey,
                                                                privateWindowKey: self.privateWindowKey)
                guard self.isAvailable else {
                    await opened.close()
                    throw EngineError.closed
                }
                #if COBBLE_CHROMIUM_ABI16
                opened.identityResolver = { [weak self] url in
                    guard let self, let siteSettings = self.siteSettings else { return .standard }
                    return siteSettings.browserIdentity(for: url, profileID: self.id.profileID).chromiumIdentity
                }
                #endif
                self.context = opened
                self.engine.contextOpened(self, native: opened)
                return opened
            }
            opening = openingTask
            task = openingTask
        }
        do {
            _ = try await task.value
            opening = nil
            guard isAvailable, let context else { throw EngineError.closed }
            return context
        } catch {
            opening = nil
            throw chromiumEngineError(error)
        }
    }
}

func chromiumEngineError(_ error: Error) -> EngineError {
    if let error = error as? EngineError { return error }
    if let error = error as? ChromiumError {
        switch error {
        case .notReady: return .notReady(error.localizedDescription)
        case .closed: return .closed
        case .unavailable, .operationFailed: return .notReady(error.localizedDescription)
        }
    }
    return .notReady(error.localizedDescription)
}

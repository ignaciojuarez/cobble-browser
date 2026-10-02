import AppKit
import LocalAuthentication
import Security
import WebKit

@MainActor
final class WebKitPage: NSObject, WKNavigationDelegate, WKUIDelegate, BrowserPage {
    let tabID: UUID
    let state = PageState()
    let events = PageEvents()
    let contextID: BrowsingContextID
    let context: WebKitContext?
    var capabilities: EngineCapabilities { WebKitEngine.supported }
    var nativeView: NSView { closed ? NSView() : webView }
    private lazy var prompts = PagePresenter(window: { [weak self] in self?.storedWebView?.window },
                                             pendingChanged: { [weak self] in self?.state.hasPendingPrompt = $0 })
    private var storedWebView: WKWebView?
    private var observations: [NSKeyValueObservation] = []
    private var activeNavigation: WKNavigation?
    private var committedNavigation: WKNavigation?
    private var committedSafeToReload = false
    private var downloadHandoffNavigation: WKNavigation?
    private var visitedNavigation: WKNavigation?
    private var pendingRequest: URLRequest?
    private var failedProvisionally = false
    private var faviconGeneration = UUID()
    private var supersededNavigations: [WKNavigation] = []
    private var lastAutomaticRecovery: Date?
    private var hasCommittedPage = false
    private var safeToReload = false
    private var pendingSafeToReload = false
    private var closed = false
    private var lastPublishedURL: String?
    private var lastPublishedTitle: String?
    private var mediaProbe: Task<Void, Never>?
    // Any future display-capture grant must also set this before granting;
    // native current-state getters cannot reveal latent flags after capture ends.
    private var hasCaptureHistory = false
    private var findRequestID = UUID()
    private var pageIdentity = UUID()
    private var windowID: UUID
    private var pendingClientCertificate: PageClientCertificateRequest?
    private var pendingClientCertificateNavigation: WKNavigation?
    private(set) var scopedLocalFileURL: URL?
    private struct PendingLocalFile {
        let navigation: WKNavigation
        let url: URL
        let scoped: Bool
        let previousNavigation: WKNavigation?
        let previousHasCommittedPage: Bool
        let previousSafeToReload: Bool
        let previousPendingSafeToReload: Bool
        let previousFailedProvisionally: Bool
        let previousRequest: URLRequest?
        let continuation: CheckedContinuation<Void, Error>
    }
    private var pendingLocalFile: PendingLocalFile?
    private var inspectable = false
    private let configuration: WKWebViewConfiguration
    private let siteSettings: SiteSettingsStore?
    private let profileID: UUID
    private let isPrivate: Bool
    private let clientCertificateSearchList: [SecKeychain]?

    init(tabID: UUID, dataStore: WKWebsiteDataStore,
         configuration: WKWebViewConfiguration? = nil,
         siteSettings: SiteSettingsStore? = nil, profileID: UUID = Profile.defaultID, isPrivate: Bool = false, context: WebKitContext? = nil, contextID: BrowsingContextID? = nil,
         windowID: UUID = UUID(), clientCertificateSearchList: [SecKeychain]? = nil,
         onChange: @escaping (UUID, String, String) -> Void) {
        self.tabID = tabID
        let resolvedConfiguration = configuration ?? WKWebViewConfiguration()
        if configuration == nil {
            if let session = context?.extensionSession as? WebKitExtensionSession {
                session.configure(resolvedConfiguration)
            }
            else {
                resolvedConfiguration.websiteDataStore = dataStore
                resolvedConfiguration.preferences.javaScriptCanOpenWindowsAutomatically = false
            }
        }
        Self.applySafariCompatibleUserAgent(to: resolvedConfiguration)
        self.configuration = resolvedConfiguration
        self.context = context
        self.contextID = context?.id ?? contextID ?? BrowsingContextID(engineID: .webKit, profileID: profileID, privateWindowID: isPrivate ? UUID() : nil)
        events.onChange = onChange
        state.lifecycle = context?.blocker.isReady == false ? .preparing : .ready
        self.siteSettings = siteSettings
        self.profileID = profileID
        self.isPrivate = isPrivate
        self.windowID = windowID
        self.clientCertificateSearchList = clientCertificateSearchList
        super.init()
    }

    var webView: WKWebView {
        if let storedWebView { return storedWebView }
        let view = WKWebView(frame: .zero, configuration: configuration)
        guard !closed else { return view }
        storedWebView = view
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = inspectable
        observations = [
            view.observe(\.url, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.publishPage() }
            },
            view.observe(\.title, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.publishPage() }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
            view.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
            view.observe(\.cameraCaptureState, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            },
            view.observe(\.microphoneCaptureState, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refreshState() }
            }
        ]
        if let session = context?.extensionSession as? WebKitExtensionSession {
            session.didOpen(self)
        }
        startMediaProbe()
        return view
    }

    func applyContentRules(_ rule: WKContentRuleList?) {
        guard !closed else { return }
        let controller = (storedWebView?.configuration ?? configuration).userContentController
        controller.removeAllContentRuleLists()
        if let rule { controller.add(rule) }
    }

    func navigate(to url: URL?) {
        guard !closed else { return }
        beginNavigation(to: url)
        if let url {
            if url.isFileURL {
                trackNavigation(webView.loadFileURL(url, allowingReadAccessTo: url))
            } else {
                trackNavigation(webView.load(URLRequest(url: url)))
            }
        } else {
            trackNavigation(webView.loadHTMLString("", baseURL: nil))
        }
    }

    func openLocalFile(_ url: URL) async throws {
        guard !closed else { throw EngineError.closed }
        guard url.isFileURL else { throw EngineError.notReady(String(localized: "Choose a local file.")) }
        cancelPendingLocalFile(EngineError.notReady("The local-file load was replaced by another navigation."),
                               restoringDocument: true)
        let scoped = url.startAccessingSecurityScopedResource()
        let previousNavigation = activeNavigation
        let previousHasCommittedPage = hasCommittedPage
        let previousSafeToReload = safeToReload
        let previousPendingSafeToReload = pendingSafeToReload
        let previousFailedProvisionally = failedProvisionally
        let previousRequest = pendingRequest
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            beginNavigation(to: url)
            guard let navigation = webView.loadFileURL(url, allowingReadAccessTo: url) else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                activeNavigation = previousNavigation
                hasCommittedPage = previousHasCommittedPage
                safeToReload = previousSafeToReload
                pendingSafeToReload = previousPendingSafeToReload
                failedProvisionally = previousFailedProvisionally
                pendingRequest = previousRequest
                refreshState()
                continuation.resume(throwing: EngineError.notReady("The local file could not start loading."))
                return
            }
            trackNavigation(navigation)
            pendingLocalFile = PendingLocalFile(
                navigation: navigation, url: url, scoped: scoped,
                previousNavigation: previousNavigation,
                previousHasCommittedPage: previousHasCommittedPage,
                previousSafeToReload: previousSafeToReload,
                previousPendingSafeToReload: previousPendingSafeToReload,
                previousFailedProvisionally: previousFailedProvisionally,
                previousRequest: previousRequest, continuation: continuation)
        }
    }

    private func beginNavigation(to url: URL?) {
        cancelClientCertificateRequest()
        invalidateConnectionDetails()
        downloadHandoffNavigation = nil
        pageIdentity = UUID()
        resetFind()
        clearFavicon()
        state.errorMessage = nil
        state.isCrashed = false
        state.hoveredLink = nil
        state.blockedPopup = false
        applyPopupPreference(for: url)
        applyBrowserIdentity(for: url)
        hasCommittedPage = false
        safeToReload = false
        pendingSafeToReload = true
        failedProvisionally = false
        pendingRequest = URLRequest(url: url ?? URL(string: "about:blank")!)
    }

    private func releaseLocalFileAccess() {
        scopedLocalFileURL?.stopAccessingSecurityScopedResource()
        scopedLocalFileURL = nil
    }

    func goBack() {
        guard !closed, let view = storedWebView, view.canGoBack else { return }
        invalidateConnectionDetails()
        trackNavigation(view.goBack())
    }

    func goForward() {
        guard !closed, let view = storedWebView, view.canGoForward else { return }
        invalidateConnectionDetails()
        trackNavigation(view.goForward())
    }

    func reload() { reload(revalidating: false) }

    func reloadFromOrigin() { reload(revalidating: true) }

    private func reload(revalidating: Bool) {
        guard !closed, let view = storedWebView else { return }
        if failedProvisionally, var request = pendingRequest {
            guard ["GET", "HEAD"].contains(request.httpMethod?.uppercased() ?? "GET") else {
                state.errorMessage = String(localized: "Return to the previous page and submit the form again to retry this request.")
                return
            }
            state.errorMessage = nil
            state.isCrashed = false
            hasCommittedPage = false
            failedProvisionally = false
            invalidateConnectionDetails()
            if let url = request.url, url.isFileURL {
                trackNavigation(view.loadFileURL(url, allowingReadAccessTo: url))
            } else {
                if revalidating { request.cachePolicy = .reloadRevalidatingCacheData }
                trackNavigation(view.load(request))
            }
            return
        }
        if !safeToReload {
            let alert = PagePresenter.alert(title: String(localized: "Reload this page?"), message: String(localized: "Reloading may submit form data again."), buttons: [String(localized: "Reload"), String(localized: "Cancel")])
            present(alert) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self, !self.closed else { return }
                self.state.errorMessage = nil
                self.state.isCrashed = false
                self.invalidateConnectionDetails()
                self.trackNavigation(revalidating ? view.reloadFromOrigin() : view.reload())
            }
        } else {
            state.errorMessage = nil
            state.isCrashed = false
            invalidateConnectionDetails()
            trackNavigation(revalidating ? view.reloadFromOrigin() : view.reload())
        }
    }

    func stop() { storedWebView?.stopLoading() }

    func find(_ text: String, backwards: Bool = false) {
        guard !closed else { return }
        resetFind()
        state.findQuery = text
        guard let view = storedWebView else { return }
        let request = findRequestID
        let options = WKFindConfiguration()
        options.backwards = backwards
        options.caseSensitive = false
        options.wraps = true
        if text.isEmpty {
            view.find("", configuration: options) { _ in }
            return
        }
        view.find(text, configuration: options) { [weak self] result in
            guard let self, !self.closed, self.findRequestID == request else { return }
            self.state.findMatchFound = result.matchFound
        }
    }

    private func resetFind() {
        findRequestID = UUID()
        state.findQuery = ""
        state.findMatchFound = nil
    }

    func zoom(by factor: Double) {
        guard !closed, let view = storedWebView, factor.isFinite, factor > 0 else { return }
        view.pageZoom = min(3, max(0.5, view.pageZoom * factor))
        rememberZoom()
    }

    func resetZoom() {
        guard !closed else { return }
        storedWebView?.pageZoom = 1
        rememberZoom()
    }

    private func rememberZoom() {
        guard !isPrivate, hasCommittedPage, let view = storedWebView, let url = view.url,
              AddressResolver.canonicalOrigin(url) != nil else { return }
        siteSettings?.setZoom(view.pageZoom, origin: url, profileID: profileID, engineID: contextID.engineID)
    }

    private func applyRememberedZoom() {
        guard !isPrivate, hasCommittedPage, let view = storedWebView else { return }
        view.pageZoom = view.url.flatMap { url in
            siteSettings?.setting(origin: url, profileID: profileID, engineID: contextID.engineID).zoom
        } ?? 1
    }

    func snapshot() async throws -> NSImage {
        guard !closed else { throw EngineError.closed }
        guard let view = storedWebView, state.lifecycle == .ready,
              view.bounds.width > 0, view.bounds.height > 0 else {
            throw EngineError.notReady(String(localized: "The page has no visible area to capture."))
        }
        let navigation = activeNavigation
        let url = state.urlString
        let image = try await view.takeSnapshot(configuration: nil)
        guard !closed else { throw EngineError.closed }
        guard activeNavigation === navigation, state.urlString == url else {
            throw EngineError.notReady(String(localized: "The page navigated while taking the screenshot. Try again."))
        }
        return image
    }

    func pageArchive() async throws -> Data {
        guard !closed, let view = storedWebView, state.lifecycle == .ready else { throw EngineError.closed }
        let identity = pageIdentity
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            view.createWebArchiveData { result in
                switch result {
                case .success(let data): continuation.resume(returning: data)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        guard !closed, identity == pageIdentity else {
            throw EngineError.notReady(String(localized: "The page changed while Cobble was creating the archive. Try again."))
        }
        return data
    }

    func currentDOM() async throws -> String {
        guard !closed, let view = storedWebView, state.lifecycle == .ready else { throw EngineError.closed }
        let identity = pageIdentity
        let result = try await view.evaluateJavaScript("document.documentElement ? document.documentElement.outerHTML : ''")
        guard !closed, identity == pageIdentity else {
            throw EngineError.notReady(String(localized: "The page changed while Cobble was reading the current DOM. Try again."))
        }
        guard let html = result as? String else { throw EngineError.notReady(String(localized: "WebKit did not return the current page DOM.")) }
        return html
    }

    func connectionDetails() async throws -> PageConnectionDetails? {
        guard !closed, let view = storedWebView, let url = view.url else { return nil }
        let connection = PageConnection.classify(urlString: url.absoluteString,
            hasOnlySecureContent: view.hasOnlySecureContent)
        let certificates = (view.serverTrust.flatMap { SecTrustCopyCertificateChain($0) } as? [SecCertificate]) ?? []
        let certificateChain = certificates.prefix(16).map(Self.certificateDetails)
        return PageConnectionDetails(url: url, connection: connection,
            certificate: certificateChain.first, certificateChain: certificateChain,
            certificateChainTruncated: certificates.count > certificateChain.count, certificateErrors: [],
            // WebKit exposes a mixed-content signal, not the displayed/ran split.
            mixedContent: PageMixedContentDetails(displayed: false, ran: false,
                containedForm: false,
                displayedWithCertificateErrors: false, ranWithCertificateErrors: false))
    }

    private static func certificateDetails(_ certificate: SecCertificate) -> PageCertificateDetails {
        let subject = certificateText(SecCertificateCopySubjectSummary(certificate) as String?)
            ?? String(localized: "Unknown")
        let issuer = certificateString(property: kSecOIDX509V1IssuerName, certificate: certificate)
            ?? String(localized: "Unknown")
        return PageCertificateDetails(subject: subject, issuer: issuer,
            validFrom: certificateDate(property: kSecOIDX509V1ValidityNotBefore, certificate: certificate),
            validUntil: certificateDate(property: kSecOIDX509V1ValidityNotAfter, certificate: certificate))
    }

    private static func certificateProperty(_ oid: CFString, certificate: SecCertificate) -> Any? {
        guard let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil),
              let property = (values as NSDictionary).object(forKey: oid) as? NSDictionary else { return nil }
        return property.object(forKey: kSecPropertyKeyValue)
    }

    private static func certificateDate(property oid: CFString, certificate: SecCertificate) -> Date? {
        certificateProperty(oid, certificate: certificate) as? Date
    }

    private static func certificateString(property oid: CFString, certificate: SecCertificate) -> String? {
        let value = certificateProperty(oid, certificate: certificate)
        if let entries = value as? [NSDictionary],
           let commonName = entries.first(where: {
               ($0.object(forKey: kSecPropertyKeyLabel) as? String)?.localizedCaseInsensitiveContains("common name") == true
           }), let name = commonName.object(forKey: kSecPropertyKeyValue) as? String {
            return certificateText(name)
        }
        return certificateText(value as? String)
    }

    private static func certificateText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func setInspectable(_ enabled: Bool) {
        inspectable = enabled
        storedWebView?.isInspectable = enabled
    }

    func printPage() {
        guard !closed, let view = storedWebView else { return }
        view.printOperation(with: .shared).run()
    }

    func setCapture(_ kind: PermissionKind, _ capture: PageCapture) {
        guard !closed, let view = storedWebView else { return }
        hasCaptureHistory = true
        state.audioMuteBlocked = true
        let state: WKMediaCaptureState = switch capture {
        case .none: .none
        case .active: .active
        case .muted: .muted
        }
        switch kind {
        case .camera: view.setCameraCaptureState(state, completionHandler: nil)
        case .microphone: view.setMicrophoneCaptureState(state, completionHandler: nil)
        }
    }

    func setAudioMuted(_ muted: Bool) throws {
        guard !closed else { throw EngineError.closed }
        try WebKitAudioMute.set(muted, on: webView, hasCaptureHistory: hasCaptureHistory)
        refreshAudioState()
    }

    func moveToWindow(_ windowID: UUID) throws {
        guard !closed else { throw EngineError.closed }
        self.windowID = windowID
        (context?.extensionSession as? WebKitExtensionSession)?.willMove(self)
    }

    func close() {
        guard !closed else { return }
        closed = true
        cancelPendingLocalFile(EngineError.closed)
        cancelClientCertificateRequest()
        pageIdentity = UUID()
        releaseLocalFileAccess()
        resetFind()
        mediaProbe?.cancel()
        mediaProbe = nil
        state.lifecycle = .closing
        clearFavicon()
        prompts.cancelAll()
        observations.removeAll()
        state.hoveredLink = nil
        state.blockedPopup = false
        state.connection = .empty
        state.camera = .none
        state.microphone = .none
        state.grantedMediaKinds.removeAll()
        state.mediaPlayback = .none
        state.isAudioMuted = false
        state.isPlayingAudio = false
        state.isDisplayCapturing = false
        state.audioMuteBlocked = false
        state.connectionDetailsReady = false
        if storedWebView != nil,
           let session = context?.extensionSession as? WebKitExtensionSession {
            session.didClose(self)
        }
        storedWebView?.navigationDelegate = nil
        storedWebView?.uiDelegate = nil
        storedWebView?.stopLoading()
        storedWebView?.removeFromSuperview()
        storedWebView = nil
        activeNavigation = nil
        committedNavigation = nil
        downloadHandoffNavigation = nil
        supersededNavigations.removeAll()
        pendingRequest = nil
        visitedNavigation = nil
        events.clear()
        state.lifecycle = .closed
    }

    private func refreshState() {
        guard !closed, let view = storedWebView else { return }
        let wasLoading = state.isLoading
        state.isLoading = view.isLoading
        state.estimatedProgress = view.estimatedProgress
        state.canGoBack = view.canGoBack
        state.canGoForward = view.canGoForward
        state.connection = .classify(urlString: view.url?.absoluteString ?? "",
            hasOnlySecureContent: view.hasOnlySecureContent)
        let detailsBecameReady = !state.isLoading && view.url != nil && !state.connectionDetailsReady
        state.connectionDetailsReady = !state.isLoading && view.url != nil
        if (wasLoading && !state.isLoading) || detailsBecameReady { state.connectionDetailsRevision = UUID() }
        state.camera = Self.capture(view.cameraCaptureState)
        state.microphone = Self.capture(view.microphoneCaptureState)
        if state.camera != .none { state.grantedMediaKinds.remove(.camera) }
        if state.microphone != .none { state.grantedMediaKinds.remove(.microphone) }
        if state.camera != .none || state.microphone != .none || WebKitAudioMute.isDisplayCapturing(view) {
            hasCaptureHistory = true
        }
        refreshAudioState()
        if wasLoading != state.isLoading,
           let session = context?.extensionSession as? WebKitExtensionSession {
            session.didChange(self, properties: [.loading])
        }
    }

    private func invalidateConnectionDetails() {
        state.connectionDetailsReady = false
        state.connectionDetailsRevision = UUID()
    }

    private static func capture(_ state: WKMediaCaptureState) -> PageCapture {
        switch state {
        case .none: .none
        case .active: .active
        case .muted: .muted
        @unknown default: .none
        }
    }

    // ponytail: poll native playback/audio state; remove when a supported observation API exists.
    private func startMediaProbe() {
        mediaProbe?.cancel()
        mediaProbe = Task { [weak self] in
            while let self, !self.closed, !Task.isCancelled {
                self.refreshMediaPlayback()
                let interval: Duration = (self.state.mediaPlayback == .playing || self.state.isAudioMuted)
                    ? .seconds(1) : .seconds(4)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func refreshMediaPlayback() {
        guard !closed, let view = storedWebView else { return }
        refreshAudioState()
        view.requestMediaPlaybackState { [weak self] playback in
            guard let self, !self.closed else { return }
            let next: PageMediaPlayback = switch playback {
            case .playing: .playing
            case .paused: .paused
            case .suspended: .suspended
            default: .none
            }
            self.state.mediaPlayback = next
        }
    }

    private func refreshAudioState() {
        guard !closed, let view = storedWebView else { return }
        let muted = WebKitAudioMute.isMuted(view)
        let audible = WebKitAudioMute.isPlayingAudio(view)
        let display = WebKitAudioMute.isDisplayCapturing(view)
        if display { hasCaptureHistory = true }
        state.isDisplayCapturing = display
        state.audioMuteBlocked = hasCaptureHistory
        let session = context?.extensionSession as? WebKitExtensionSession
        if state.isAudioMuted != muted {
            state.isAudioMuted = muted
            session?.didChange(self, properties: [.muted])
        }
        if state.isPlayingAudio != audible {
            state.isPlayingAudio = audible
            session?.didChange(self, properties: [.playingAudio])
        }
    }

    private func publishPage() {
        guard !closed, hasCommittedPage, let view = storedWebView else { return }
        let rawURL = view.url?.absoluteString ?? ""
        let url = rawURL == "about:blank" ? "" : rawURL
        let title = url.isEmpty ? "New Tab" : (view.title.flatMap { $0.isEmpty ? nil : $0 } ?? view.url?.host ?? url)
        guard url != lastPublishedURL || title != lastPublishedTitle else { return }
        let sameDocumentURLChange = url != lastPublishedURL && visitedNavigation != nil
            && visitedNavigation === activeNavigation
        lastPublishedURL = url
        lastPublishedTitle = title
        state.urlString = url
        state.title = title
        applyPopupPreference()
        events.onChange?(tabID, url, title)
        if sameDocumentURLChange, let address = URL(string: url),
           ["http", "https"].contains(address.scheme?.lowercased() ?? "") {
            events.onVisit?(tabID, url, title)
        }
        if let session = context?.extensionSession as? WebKitExtensionSession {
            session.didChange(self, properties: [.URL, .title])
        }
    }

    private func trackNavigation(_ navigation: WKNavigation?) {
        if let previous = activeNavigation, previous !== navigation {
            if pendingClientCertificateNavigation === previous { cancelClientCertificateRequest() }
            if pendingLocalFile?.navigation === previous {
                cancelPendingLocalFile(EngineError.notReady("The local-file load was replaced by another navigation."))
            }
            supersededNavigations.append(previous)
            // Retain a bounded set so delayed callbacks cannot revive a superseded load.
            if supersededNavigations.count > 32 { supersededNavigations.removeFirst() }
        }
        activeNavigation = navigation
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !closed, !supersededNavigations.contains(where: { $0 === navigation }) else { return }
        downloadHandoffNavigation = nil
        if pendingClientCertificate != nil,
           pendingClientCertificateNavigation !== navigation { cancelClientCertificateRequest() }
        prompts.cancelAll()
        invalidateConnectionDetails()
        pageIdentity = UUID()
        trackNavigation(navigation)
        resetFind()
        clearFavicon()
        hasCommittedPage = false
        failedProvisionally = false
        state.errorMessage = nil
        refreshState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !closed, navigation === activeNavigation else { return }
        state.grantedMediaKinds.removeAll()
        committedNavigation = navigation
        hasCommittedPage = true
        pageIdentity = UUID()
        releaseLocalFileAccess(unlessCurrentURL: webView.url)
        finishPendingLocalFile(navigation, result: .success(()))
        applyRememberedZoom()
        safeToReload = pendingSafeToReload
        committedSafeToReload = safeToReload
        state.isCrashed = false
        publishPage()
        refreshState()
        if navigation !== visitedNavigation, let url = webView.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            visitedNavigation = navigation
            events.onVisit?(tabID, url.absoluteString, state.title)
        }
    }

    private func releaseLocalFileAccess(unlessCurrentURL url: URL?) {
        guard let scoped = scopedLocalFileURL,
              url?.isFileURL == true, url?.standardizedFileURL.path == scoped.standardizedFileURL.path else {
            releaseLocalFileAccess()
            return
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed, hasCommittedPage, navigation === activeNavigation else { return }
        publishPage()
        refreshState()
        if let url = webView.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            loadFavicon(for: url)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishPendingLocalFile(navigation, result: .failure(error))
        navigationFailed(navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !closed, navigation === activeNavigation else { return }
        let restoredLocalFile = restorePendingLocalFileDocument(navigation, error: error)
        if restoredLocalFile {
            refreshState()
            if !Self.isCancelledNavigation(error) { state.errorMessage = error.localizedDescription }
            return
        }
        if !(downloadHandoffNavigation.map { navigation === $0 } ?? false),
           !Self.isCancelledNavigation(error) { failedProvisionally = true }
        navigationFailed(navigation, error: error)
    }

    private func clearFavicon() {
        faviconGeneration = UUID()
        state.favicon = nil
        state.faviconOrigin = nil
    }

    private func finishPendingLocalFile(_ navigation: WKNavigation, result: Result<Void, Error>) {
        guard let pending = pendingLocalFile, pending.navigation === navigation else { return }
        pendingLocalFile = nil
        switch result {
        case .success:
            releaseLocalFileAccess()
            if pending.scoped { scopedLocalFileURL = pending.url }
            pending.continuation.resume()
        case .failure(let error):
            if pending.scoped { pending.url.stopAccessingSecurityScopedResource() }
            pending.continuation.resume(throwing: error)
        }
    }

    private func cancelPendingLocalFile(_ error: Error, restoringDocument: Bool = false) {
        guard let pending = pendingLocalFile else { return }
        pendingLocalFile = nil
        if pending.scoped { pending.url.stopAccessingSecurityScopedResource() }
        if restoringDocument {
            activeNavigation = pending.previousNavigation
            hasCommittedPage = pending.previousHasCommittedPage
            safeToReload = pending.previousSafeToReload
            pendingSafeToReload = pending.previousPendingSafeToReload
            failedProvisionally = pending.previousFailedProvisionally
            pendingRequest = pending.previousRequest
        }
        pending.continuation.resume(throwing: error)
    }

    private func restorePendingLocalFileDocument(_ navigation: WKNavigation, error: Error) -> Bool {
        guard let pending = pendingLocalFile, pending.navigation === navigation else { return false }
        pendingLocalFile = nil
        if pending.scoped { pending.url.stopAccessingSecurityScopedResource() }
        activeNavigation = pending.previousNavigation
        hasCommittedPage = pending.previousHasCommittedPage
        safeToReload = pending.previousSafeToReload
        pendingSafeToReload = pending.previousPendingSafeToReload
        failedProvisionally = pending.previousFailedProvisionally
        pendingRequest = pending.previousRequest
        pending.continuation.resume(throwing: error)
        return true
    }

    private func loadFavicon(for url: URL) {
        guard !closed, let view = storedWebView else { return }
        let generation = faviconGeneration
        // Fetch inside the page's WebKit store, isolated from page-script overrides.
        let script = """
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 4000);
        try {
            const urls = [], seen = new Set();
            const push = href => {
                try {
                    const candidate = new URL(href, document.baseURI);
                    if (candidate.protocol !== 'http:' && candidate.protocol !== 'https:') return;
                    if (seen.has(candidate.href)) return;
                    seen.add(candidate.href);
                    urls.push(candidate);
                } catch (_) {}
            };
            for (const wantSame of [true, false]) {
                for (const link of document.querySelectorAll('link[rel~="icon"]')) {
                    try {
                        const candidate = new URL(link.getAttribute('href'), document.baseURI);
                        if ((candidate.origin === location.origin) === wantSame) push(candidate.href);
                    } catch (_) {}
                }
            }
            push('/favicon.ico');
            for (const icon of urls) {
                try {
                    const cross = icon.origin !== location.origin;
                    const response = await fetch(icon.href, {
                        credentials: cross ? 'omit' : 'same-origin', mode: 'cors', redirect: 'follow', signal: controller.signal
                    });
                    if (!response.ok || Number(response.headers.get('content-length')) > 65536 || !response.body) continue;
                    const reader = response.body.getReader();
                    const chunks = [];
                    let size = 0, overflow = false;
                    while (true) {
                        const { value, done } = await reader.read();
                        if (done) break;
                        size += value.byteLength;
                        if (size > 65536) { await reader.cancel(); overflow = true; break; }
                        chunks.push(value);
                    }
                    if (overflow) continue;
                    const blob = new Blob(chunks, { type: response.headers.get('content-type') || 'application/octet-stream' });
                    const encoded = await new Promise(resolve => {
                        const file = new FileReader();
                        file.onload = () => resolve(file.result);
                        file.onerror = () => resolve(null);
                        file.readAsDataURL(blob);
                    });
                    if (typeof encoded === 'string') return [encoded, ...urls.map(icon => icon.href)];
                } catch (_) {}
            }
            return urls.map(icon => icon.href);
        } catch (_) { return null; }
        finally { controller.abort(); clearTimeout(timer); }
        """
        view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            guard let self, case .success(let value) = result,
                  let candidates = value as? [String] else { return }
            if let encoded = candidates.first, encoded.hasPrefix("data:"), encoded.utf8.count < 100_000,
               let comma = encoded.firstIndex(of: ","),
               let data = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])),
               self.acceptFavicon(data, for: url, generation: generation) { return }
            Task { [weak self] in
                for candidate in candidates.prefix(12) {
                    guard let self, self.faviconGeneration == generation else { return }
                    guard let iconURL = URL(string: candidate), ["http", "https"].contains(iconURL.scheme?.lowercased() ?? "") else { continue }
                    var request = URLRequest(url: iconURL)
                    request.httpShouldHandleCookies = false
                    request.timeoutInterval = 4
                    request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          let response = response as? HTTPURLResponse,
                          (200...206).contains(response.statusCode), data.count <= 65_536 else { continue }
                    if self.acceptFavicon(data, for: url, generation: generation) { return }
                }
            }
        }
    }

    @discardableResult private func acceptFavicon(_ data: Data, for url: URL, generation: UUID) -> Bool {
        guard !closed, hasCommittedPage, faviconGeneration == generation,
              let current = storedWebView?.url,
              AddressResolver.canonicalOrigin(current) == AddressResolver.canonicalOrigin(url),
              data.count <= 65_536,
              let png = CachedFavicon.normalizedPNG(from: data) else { return false }
        state.favicon = NSImage(data: png)
        state.faviconOrigin = AddressResolver.canonicalOrigin(current)
        events.onFavicon?(tabID, current, png)
        return true
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        guard !closed, navigation === activeNavigation else { return }
        let isDownloadHandoff = downloadHandoffNavigation.map { navigation === $0 } ?? false
        if isDownloadHandoff || Self.isCancelledNavigation(error) {
            if isDownloadHandoff { downloadHandoffNavigation = nil }
            failedProvisionally = false
            hasCommittedPage = committedNavigation != nil
            safeToReload = committedSafeToReload
            if let committedNavigation { activeNavigation = committedNavigation }
            refreshState()
            if hasCommittedPage { events.onChange?(tabID, state.urlString, state.title) }
            return
        }
        refreshState()
        state.errorMessage = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !closed else { return }
        cancelClientCertificateRequest()
        cancelPendingLocalFile(EngineError.notReady("The local-file load stopped because the page process closed."))
        invalidateConnectionDetails()
        state.isCrashed = true
        state.isLoading = false
        let now = Date()
        guard hasCommittedPage, safeToReload,
              lastAutomaticRecovery.map({ now.timeIntervalSince($0) >= 60 }) ?? true else {
            state.errorMessage = String(localized: "This page stopped responding. Reload to try again.")
            return
        }
        lastAutomaticRecovery = now
        hasCommittedPage = false
        trackNavigation(webView.reload())
        if activeNavigation == nil { state.errorMessage = String(localized: "This page stopped responding. Reload to try again.") }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard !closed else { decisionHandler(.cancel); return }
        if let url = Self.externalApplicationURL(from: action.request, webView: webView) {
            decisionHandler(.cancel)
            if Self.shouldOfferExternalApplication(for: action) { offerExternalApplication(url) }
            return
        }
        if action.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if action.navigationType == .linkActivated,
           action.targetFrame != nil,
           action.modifierFlags.contains(.command) || action.buttonNumber == 2,
           events.onCreatePage != nil {
            _ = createChild(configuration: webView.configuration, request: action.request,
                            activate: Self.activatesNewTab(modifiers: action.modifierFlags, buttonNumber: action.buttonNumber))
            decisionHandler(.cancel)
            return
        }
        if action.targetFrame?.isMainFrame == true {
            pendingRequest = action.request
            applyBrowserIdentity(for: action.request.url)
            applyPopupPreference(for: action.request.url)
            pendingSafeToReload = ["GET", "HEAD"].contains(action.request.httpMethod?.uppercased() ?? "GET")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard !closed else { decisionHandler(.cancel); return }
        let isAttachment = (response.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("attachment") == true
        let shouldDownload = isAttachment || !response.canShowMIMEType
        if response.isForMainFrame {
            applyPopupPreference(for: response.response.url)
            if shouldDownload { downloadHandoffNavigation = activeNavigation }
        }
        decisionHandler(shouldDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        receive(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        receive(download)
    }

    private func receive(_ download: WKDownload) {
        if !closed, let receive = events.onDownload {
            receive(WebKitDownload(download, webView: webView, clientCertificateSearchList: clientCertificateSearchList))
        }
        else { download.cancel { _ in } }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !closed else { return nil }
        if let url = Self.externalApplicationURL(from: navigationAction.request, webView: webView) {
            if Self.shouldOfferExternalApplication(for: navigationAction) { offerExternalApplication(url) }
            return nil
        }
        let sourceURL = securityOriginURL(navigationAction.sourceFrame.securityOrigin)
        let sourceSetting = popupSetting(for: sourceURL)
        // WKPreferences applies to the whole page. An Allow grant for its top
        // frame must not authorize scripts in a different embedded origin.
        let embeddedWithoutGrant = sourceURL.flatMap(AddressResolver.canonicalOrigin) != webView.url.flatMap(AddressResolver.canonicalOrigin)
            && sourceSetting != .allow && navigationAction.navigationType != .linkActivated
        guard !embeddedWithoutGrant,
              Self.allowsPopup(navigationType: navigationAction.navigationType, popups: sourceSetting,
                               isPrivate: isPrivate,
                               automaticWindowsAllowed: webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically) else {
            state.blockedPopup = true
            return nil
        }
        // WebKit loads popup requests itself; nil distinguishes this from Cmd-click.
        return createChild(configuration: configuration, request: nil,
                           activate: Self.activatesNewTab(modifiers: navigationAction.modifierFlags,
                                                         buttonNumber: navigationAction.buttonNumber))
    }

    func webViewDidClose(_ webView: WKWebView) { if !closed { events.onClose?() } }

    func webView(_ webView: WKWebView, mouseDidMoveOverElement elementInformation: [String: Any],
                 with modifierFlags: NSEvent.ModifierFlags) {
        guard !closed else { return }
        state.hoveredLink = Self.hoveredLink(from: elementInformation)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        present(PagePresenter.alert(title: originName(frame.securityOrigin), message: message, buttons: [String(localized: "OK")])) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        present(PagePresenter.alert(title: originName(frame.securityOrigin), message: message, buttons: [String(localized: "OK"), String(localized: "Cancel")])) {
            completionHandler($0 == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let alert = PagePresenter.alert(title: originName(frame.securityOrigin), message: prompt, buttons: [String(localized: "OK"), String(localized: "Cancel")])
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        guard !closed else { completionHandler(nil); return }
        prompts.chooseFiles(multiple: parameters.allowsMultipleSelection, directories: parameters.allowsDirectories,
                            completion: completionHandler)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        guard !closed else { decisionHandler(.deny); return }
        let kinds: Set<PermissionKind>
        switch type {
        case .camera: kinds = [.camera]
        case .microphone: kinds = [.microphone]
        case .cameraAndMicrophone: kinds = [.camera, .microphone]
        @unknown default: decisionHandler(.deny); return
        }
        let originURL = securityOriginURL(origin)
        let requestOrigin = originURL.flatMap(AddressResolver.canonicalOrigin)
        let topLevelOrigin = webView.url.flatMap(AddressResolver.canonicalOrigin)
        let sameOrigin = frame.isMainFrame || (requestOrigin != nil && requestOrigin == topLevelOrigin)
        let navigation = activeNavigation
        prompts.requestMedia(kinds: kinds, origin: originURL, topLevelOrigin: topLevelOrigin, sameOrigin: sameOrigin,
            tabID: tabID, contextID: contextID, store: siteSettings, isCurrent: { [weak self] in
                guard let self else { return false }
                return !self.closed && self.activeNavigation === navigation
            }) { [weak self] decision in
                if decision == .allow {
                    self?.hasCaptureHistory = true
                    self?.state.audioMuteBlocked = true
                    self?.state.grantedMediaKinds.formUnion(kinds)
                }
                decisionHandler(decision == .allow ? .grant : (decision == .deny ? .deny : .prompt))
            }
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !closed else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        #if DEBUG && COBBLE_AUTH_FIXTURE
        if let credential = LoginSharingFixture.credential(for: challenge) {
            completionHandler(.useCredential, credential)
            return
        }
        #endif
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodClientCertificate {
            publishClientCertificateChallenge(challenge, completionHandler: completionHandler)
            return
        }
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest].contains(method) else {
            // Default handling retains system certificate validation; never accept arbitrary server trust.
            completionHandler(.performDefaultHandling, nil)
            return
        }
        Self.presentHTTPAuthentication(challenge, using: prompts,
            isCurrent: { [weak self] in self?.closed == false }, completionHandler: completionHandler)
    }

    static func presentHTTPAuthentication(_ challenge: URLAuthenticationChallenge,
        using presenter: PagePresenter, id: UUID = UUID(), isCurrent: @escaping @MainActor () -> Bool,
        completionHandler: @escaping @MainActor @Sendable
            (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.previousFailureCount < 3 else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let alert = PagePresenter.alert(title: String(format: String(localized: "Sign in to %@"), challenge.protectionSpace.host),
                              message: challenge.previousFailureCount == 0 ? String(localized: "This website requires a username and password.") : String(localized: "Sign-in failed. Check your username and password."),
                              buttons: [String(localized: "Sign In"), String(localized: "Cancel")])
        let username = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
        username.placeholderString = String(localized: "Username")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        password.placeholderString = String(localized: "Password")
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
        fields.addSubview(username)
        fields.addSubview(password)
        alert.accessoryView = fields
        presenter.present(alert, id: id) { response in
            if isCurrent(), response == .alertFirstButtonReturn {
                completionHandler(.useCredential, URLCredential(user: username.stringValue, password: password.stringValue, persistence: .none))
            } else { completionHandler(.cancelAuthenticationChallenge, nil) }
        }
    }

    private func publishClientCertificateChallenge(_ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable
            (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        cancelClientCertificateRequest()
        guard !closed, let publish = events.onClientCertificateRequest,
              let requestingOrigin = Self.origin(for: challenge.protectionSpace),
              !requestingOrigin.absoluteString.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let available = Self.clientCertificateIdentities(
            acceptedIssuers: challenge.protectionSpace.distinguishedNames,
            searchList: clientCertificateSearchList)
        guard !available.identities.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let choices = available.identities.map(\.choice)
        let credentials = Dictionary(uniqueKeysWithValues: available.identities.map { ($0.choice.id, $0) })
        let visibleURL = storedWebView?.url
        let topLevelOrigin = visibleURL.flatMap(AddressResolver.canonicalOrigin)
            .flatMap(URL.init(string:))
        var identity = PagePromptIdentity(tabID: tabID, contextID: contextID,
            windowID: windowID, documentID: "", frameID: "", requestingOrigin: requestingOrigin,
            topLevelOrigin: topLevelOrigin)
        identity.visiblePageOrigin = visibleURL
        let requestID = UUID()
        let navigation = activeNavigation
        let request = PageClientCertificateRequest(id: requestID, identity: identity,
            prompt: PageClientCertificatePrompt(choices: choices,
                                                choicesTruncated: available.truncated,
                                                context: .page(pageID: pageIdentity.uuidString))) {
                [weak self] choiceID in
                guard let self else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                guard !self.closed, self.pendingClientCertificate?.id == requestID,
                      self.activeNavigation === navigation else {
                    if self.pendingClientCertificate?.id == requestID {
                        self.pendingClientCertificate = nil
                        self.pendingClientCertificateNavigation = nil
                    }
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                self.pendingClientCertificate = nil
                self.pendingClientCertificateNavigation = nil
                guard let choiceID, let selected = credentials[choiceID] else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                completionHandler(.useCredential, URLCredential(identity: selected.identity,
                    certificates: selected.certificates, persistence: .none))
            }
        pendingClientCertificate = request
        pendingClientCertificateNavigation = activeNavigation
        publish(request)
    }

    private func cancelClientCertificateRequest() {
        guard let request = pendingClientCertificate else { return }
        pendingClientCertificate = nil
        pendingClientCertificateNavigation = nil
        events.onPromptCancelled?(request.id)
        request.resolve(nil)
    }

    static func origin(for space: URLProtectionSpace) -> URL? {
        var parts = URLComponents()
        parts.scheme = space.protocol
        parts.host = space.host
        if space.port > 0 { parts.port = space.port }
        return parts.url
    }

    struct ClientCertificateIdentity {
        let identity: SecIdentity
        let certificates: [SecCertificate]
        let choice: PageClientCertificateChoice
    }

    static func clientCertificateIdentities(acceptedIssuers: [Data]?,
                                            searchList: [SecKeychain]?)
        -> (identities: [ClientCertificateIdentity],
            truncated: Bool) {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecUseAuthenticationContext: authentication
        ]
        var scopedQuery = query
        if let searchList { scopedQuery[kSecMatchSearchList] = searchList }
        var result: CFTypeRef?
        guard SecItemCopyMatching(scopedQuery as CFDictionary, &result) == errSecSuccess,
              let result else { return ([], false) }
        let values: [SecIdentity]
        if let list = result as? [SecIdentity] { values = list }
        else if CFGetTypeID(result) == SecIdentityGetTypeID() { values = [result as! SecIdentity] }
        else { return ([], false) }
        let accepted = Set(acceptedIssuers ?? [])
        let supportingCertificates = clientCertificates(
            searchList: searchList, authentication: authentication)
        var identities: [ClientCertificateIdentity] = []
        var byteCount = 0
        var truncated = false
        for identity in values {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate else { continue }
            var trust: SecTrust?
            let candidates = [certificate] + supportingCertificates.filter { !CFEqual($0, certificate) }
            let selfSigned = candidates.filter {
                (SecCertificateCopyNormalizedSubjectSequence($0) as Data?) ==
                    (SecCertificateCopyNormalizedIssuerSequence($0) as Data?)
            }
            guard SecTrustCreateWithCertificates(candidates as CFArray,
                    SecPolicyCreateSSL(false, nil), &trust) == errSecSuccess, let trust else { continue }
            if !selfSigned.isEmpty {
                guard SecTrustSetAnchorCertificates(trust, selfSigned as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else { continue }
            }
            SecTrustSetNetworkFetchAllowed(trust, false)
            _ = SecTrustEvaluateWithError(trust, nil)
            let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? [certificate]
            guard let terminal = chain.last else { continue }
            var eligibility: SecTrust?
            guard SecTrustCreateWithCertificates(chain as CFArray,
                    SecPolicyCreateSSL(false, nil), &eligibility) == errSecSuccess,
                  let eligibility,
                  SecTrustSetAnchorCertificates(eligibility, [terminal] as CFArray) == errSecSuccess,
                  SecTrustSetAnchorCertificatesOnly(eligibility, true) == errSecSuccess else { continue }
            SecTrustSetNetworkFetchAllowed(eligibility, false)
            guard SecTrustEvaluateWithError(eligibility, nil) else { continue }
            guard accepted.isEmpty || chain.contains(where: {
                guard let subject = SecCertificateCopyNormalizedSubjectSequence($0) as Data? else {
                    return false
                }
                return accepted.contains(subject)
            }) else { continue }
            let raw = certificateDetails(certificate)
            let details = PageCertificateDetails(
                subject: boundedUTF8(raw.subject, maxBytes: 1024),
                issuer: boundedUTF8(raw.issuer, maxBytes: 1024),
                validFrom: raw.validFrom, validUntil: raw.validUntil)
            var serialError: Unmanaged<CFError>?
            let serialData = SecCertificateCopySerialNumberData(certificate, &serialError) as Data?
            let serial = serialData.flatMap { data -> String? in
                guard !data.isEmpty else { return nil }
                let significant = data.drop(while: { $0 == 0 })
                let bytes = (significant.isEmpty ? data.suffix(1) : significant).prefix(64)
                return bytes.map { String(format: "%02X", $0) }.joined()
            }
            let itemBytes = details.subject.utf8.count + details.issuer.utf8.count + (serial?.utf8.count ?? 0)
            guard identities.count < 64, byteCount + itemBytes <= 64 * 1024 else {
                truncated = true
                continue
            }
            byteCount += itemBytes
            identities.append(ClientCertificateIdentity(identity: identity,
                certificates: chain, choice: PageClientCertificateChoice(id: UUID(),
                    certificate: details, serialNumber: serial)))
        }
        return (identities, truncated)
    }

    private static func clientCertificates(searchList: [SecKeychain]?,
                                           authentication: LAContext) -> [SecCertificate] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecUseAuthenticationContext: authentication
        ]
        if let searchList { query[kSecMatchSearchList] = searchList }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let result else { return [] }
        if let certificates = result as? [SecCertificate] { return certificates }
        if CFGetTypeID(result) == SecCertificateGetTypeID() {
            return [result as! SecCertificate]
        }
        return []
    }

    private static func boundedUTF8(_ value: String, maxBytes: Int) -> String {
        var result = ""
        var count = 0
        for scalar in value.unicodeScalars {
            let bytes = scalar.utf8.count
            guard count + bytes <= maxBytes else { break }
            result.unicodeScalars.append(scalar)
            count += bytes
        }
        return result
    }

    private func securityOriginURL(_ origin: WKSecurityOrigin) -> URL? {
        guard !origin.host.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = origin.protocol
        parts.host = origin.host.contains(":") && !origin.host.hasPrefix("[") ? "[\(origin.host)]" : origin.host
        if origin.port > 0 { parts.port = origin.port }
        return parts.url
    }

    private func originName(_ origin: WKSecurityOrigin) -> String {
        securityOriginURL(origin)?.absoluteString ?? "This page"
    }



    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !closed else { completion(.cancel); return }
        prompts.present(alert, completion: completion)
    }

    // Cancelling an unhandled scheme reports WebKitErrorDomain 102, not NSURLErrorCancelled.
    private static func isCancelledNavigation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.code == NSURLErrorCancelled
            || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
    }

    private static let forbiddenExternalSchemes: Set<String> = [
        "http", "https", "file", "filesystem", "about", "data", "javascript", "blob"
    ]

    private static func externalApplicationURL(from request: URLRequest, webView: WKWebView) -> URL? {
        guard let url = request.url, let scheme = url.scheme, !scheme.isEmpty,
              !forbiddenExternalSchemes.contains(scheme.lowercased()),
              !WKWebView.handlesURLScheme(scheme),
              webView.configuration.urlSchemeHandler(forURLScheme: scheme) == nil,
              url.absoluteString.utf8.count <= 8192 else { return nil }
        return url
    }

    // Login redirects and JS location changes use .other, not .linkActivated.
    private static func shouldOfferExternalApplication(for action: WKNavigationAction) -> Bool {
        guard action.targetFrame?.isMainFrame != false else { return false }
        switch action.navigationType {
        case .backForward, .reload: return false
        default: return true
        }
    }

    private func offerExternalApplication(_ url: URL) {
        let alert = PagePresenter.alert(title: String(localized: "Open another application?"),
            message: url.absoluteString, buttons: [String(localized: "Open"), String(localized: "Cancel")])
        present(alert) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.events.onExternalURL?(url) }
        }
    }

    func prepare() async throws {
        guard !closed else { throw EngineError.closed }
        ApplePasskeys.prepareIfNeeded()
        if let context {
            if let session = context.extensionSession as? WebKitExtensionSession {
                try await session.prepare()
            }
            await context.blocker.waitUntilReady()
            if !isPrivate { await context.blocker.ensureBundledRules(profileID: profileID) }
            guard !closed else { throw EngineError.closed }
            guard context.blocker.canLoad(profileID: profileID) else {
                throw EngineError.notReady(String(localized: "Content rules could not load. Disable or replace them in Settings before opening this page."))
            }
        }
        applyContentRules()
        state.lifecycle = .ready
    }
    func applyContentRules() { applyContentRules(context?.blocker.rules(for: profileID)) }
    func applySiteSettings() {
        applyPopupPreference()
        applyRememberedZoom()
    }

    private func applyBrowserIdentity(for url: URL?) {
        let identity = url.flatMap { siteSettings?.browserIdentity(for: $0, profileID: profileID) } ?? .standard
        webView.customUserAgent = identity.userAgent
    }

    static func allowsPopup(navigationType: WKNavigationType, popups: SitePermission, isPrivate: Bool,
                            automaticWindowsAllowed: Bool) -> Bool {
        // With automatic windows disabled, WebKit only sends script popups here after a user gesture.
        SiteSettingsStore.allowsPopup(setting: popups, isPrivate: isPrivate,
            userGesture: navigationType == .linkActivated || !automaticWindowsAllowed)
    }

    // Sites allowlist Safari by Version/ + Safari/ tokens. Default WKWebView omits both.
    static func applySafariCompatibleUserAgent(to configuration: WKWebViewConfiguration) {
        let current = configuration.applicationNameForUserAgent ?? ""
        guard !current.contains("Safari/") else { return }
        configuration.applicationNameForUserAgent = safariApplicationName
    }

    private static let safariApplicationName: String = {
        let plist = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")?
            .appending(path: "Contents/Info.plist")
        let version = plist.flatMap { NSDictionary(contentsOf: $0)?["CFBundleShortVersionString"] as? String }
            ?? "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0"
        return "Version/\(version) Safari/605.1.15"
    }()

    private func popupSetting(for url: URL?) -> SitePermission {
        guard !isPrivate, let url,
              AddressResolver.canonicalOrigin(url) != nil else { return .ask }
        return siteSettings?.setting(origin: url, profileID: profileID, engineID: contextID.engineID).popups ?? .ask
    }

    private func applyPopupPreference() {
        applyPopupPreference(for: storedWebView?.url ?? URL(string: state.urlString))
    }

    private func applyPopupPreference(for url: URL?) {
        let allow = !isPrivate && popupSetting(for: url) == .allow
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = allow
        storedWebView?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = allow
    }
    func setActive(_ active: Bool) {
        if !active { prompts.cancelAll(); cancelClientCertificateRequest() }
        if let session = context?.extensionSession as? WebKitExtensionSession {
            session.setActive(self, active: active)
        }
    }
    func waitUntilClosed() async {}

    static func activatesNewTab(modifiers: NSEvent.ModifierFlags, buttonNumber: Int) -> Bool {
        if modifiers.contains(.command) || buttonNumber == 2 { return modifiers.contains(.shift) }
        return true
    }

    private func createChild(configuration: WKWebViewConfiguration, request: URLRequest?, activate: Bool) -> WKWebView? {
        guard !closed, let create = events.onCreatePage else { return nil }
        let child = WebKitPage(tabID: UUID(), dataStore: configuration.websiteDataStore,
            configuration: configuration, siteSettings: siteSettings, profileID: profileID,
            isPrivate: isPrivate, context: context, contextID: contextID,
            windowID: windowID, clientCertificateSearchList: clientCertificateSearchList) { _, _, _ in }
        child.applyContentRules()
        guard create(child, activate) else { child.close(); return nil }
        if let request { child.trackNavigation(child.webView.load(request)) }
        return child.webView
    }

    var storedWebViewForExtensions: WKWebView? { storedWebView }

    func createExtensionChild(url: URL?, configuration: WKWebViewConfiguration) -> WebKitPage? {
        guard !closed, let create = events.onCreatePage else { return nil }
        let child = WebKitPage(tabID: UUID(), dataStore: configuration.websiteDataStore,
            configuration: configuration, siteSettings: siteSettings, profileID: profileID,
            isPrivate: isPrivate, context: context, contextID: contextID,
            windowID: windowID, clientCertificateSearchList: clientCertificateSearchList) { _, _, _ in }
        child.applyContentRules()
        guard create(child, true) else { child.close(); return nil }
        if let url { child.trackNavigation(child.webView.load(URLRequest(url: url))) }
        return child
    }
}

extension WebKitPage: WKWebExtensionTab {
    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard !closed, let storedWebView,
              (self.context?.extensionSession as? WebKitExtensionSession)?.owns(context) == true else { return nil }
        return storedWebView
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let session = self.context?.extensionSession as? WebKitExtensionSession, session.owns(context) else { return nil }
        return session.window(for: self)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { false }
    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool { false }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard (self.context?.extensionSession as? WebKitExtensionSession)?.owns(context) == true,
              storedWebView != nil else { completionHandler(EngineError.closed); return }
        guard let activate = events.onActivate else {
            completionHandler(EngineError.unsupported(String(localized: "activating a retained extension tab"))); return
        }
        activate()
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard (self.context?.extensionSession as? WebKitExtensionSession)?.owns(context) == true else {
            completionHandler(EngineError.closed); return
        }
        if let onClose = events.onClose { onClose() } else { close() }
        completionHandler(nil)
    }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        (self.context?.extensionSession as? WebKitExtensionSession)?.owns(context) == true && state.isPlayingAudio
    }
    func isMuted(for context: WKWebExtensionContext) -> Bool {
        (self.context?.extensionSession as? WebKitExtensionSession)?.owns(context) == true && state.isAudioMuted
    }
    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard (self.context?.extensionSession as? WebKitExtensionSession)?.owns(context) == true else {
            completionHandler(EngineError.closed); return
        }
        guard !state.audioMuteBlocked else {
            completionHandler(EngineError.notReady(String(localized: "Tab audio mute is unavailable while this page has captured media."))); return
        }
        do {
            try setAudioMuted(muted)
            guard state.isAudioMuted == muted else {
                completionHandler(EngineError.notReady(String(localized: "Tab audio mute is unavailable while this page has captured media.")))
                return
            }
            completionHandler(nil)
        }
        catch { completionHandler(error) }
    }
}

#if DEBUG
extension WebKitPage: PageResourceDiagnosing {
    var resourceProcesses: ProcessDiscovery {
        guard let view = storedWebView, !closed else { return ProcessDiscovery() }
        var result = ProcessDiscovery()
        let getters: [(NSObject, String, String)] = [
            (view, "_webProcessIdentifier", "Content"),
            (view, "_provisionalWebProcessIdentifier", "Provisional content"),
            (view.configuration.websiteDataStore, "_networkProcessIdentifier", "Networking"),
            (view, "_gpuProcessIdentifier", "GPU"),
            (view, "_modelProcessIdentifier", "Model")
        ]
        for (object, name, role) in getters {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector),
                  let method = class_getInstanceMethod(type(of: object), selector),
                  method_getNumberOfArguments(method) == 2 else {
                result.limitations.append("WebKit \(role) PID getter unavailable."); continue
            }
            func encoding(_ index: UInt32?) -> String {
                let pointer = index.map { method_copyArgumentType(method, $0) } ?? method_copyReturnType(method)
                guard let pointer else { return "" }
                defer { free(pointer) }
                return String(cString: pointer)
            }
            guard encoding(nil) == "i", encoding(0) == "@", encoding(1) == ":" else {
                result.limitations.append("WebKit \(role) PID getter has an unsupported signature."); continue
            }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Int32
            let pid = unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, selector)
            if pid > 0 { result.processes.append(.init(pid: pid, group: "WebKit processes", role: role)) }
        }
        result.limitations.append("WebKit discovery covers referenced and previously identified processes; other services may be absent.")
        return result
    }
}
#endif

extension WebKitPage {
    static func hoveredLink(from element: [AnyHashable: Any]) -> String? {
        let value = element["WebKitLinkURL"] ?? element["LinkURL"]
        let url = value as? URL ?? (value as? String).flatMap(URL.init(string:))
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()) else { return nil }
        return url.absoluteString
    }
}

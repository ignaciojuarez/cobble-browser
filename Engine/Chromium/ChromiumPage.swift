import AppKit
import CobbleChromium

@MainActor final class ChromiumPage: BrowserPage {
    let tabID: UUID
    let contextID: BrowsingContextID
    let state = PageState()
    let events = PageEvents()
    let capabilities = EngineCapabilities(pageOperations: chromiumPageOperations, requiresCloseConfirmation: true,
                                          permissions: chromiumPermissions, captureControls: chromiumCaptureControls,
                                          supportsPopupPolicy: chromiumSupportsPopupPolicy)
    let nativeView = NSView(frame: .zero)
    #if COBBLE_CHROMIUM_ABI4
    let archiveFormat: PageArchiveFormat = .mhtml
    #else
    let archiveFormat: PageArchiveFormat = .webArchive
    #endif

    let context: ChromiumContext
    private(set) var windowID: UUID
    private(set) var source: CobbleChromium.ChromiumPage?
    private unowned let engine: ChromiumEngine
    private var prepareTask: Task<Void, Error>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    var closing = false
    private var closeForced = false
    private var isActive = false
    private var isVisible = false
    private var inspectable = false
    private var appPromptPending = false
    private lazy var externalApplications = PagePresenter(window: { [weak self] in self?.nativeView.window },
        pendingChanged: { [weak self] in self?.setAppPromptPending($0) })
    private var appleSignIn: AppleSignInSession?
    private var appleSignInURL: String?
    private var publishedURL = ""
    private var publishedTitle = ""
    #if COBBLE_CHROMIUM_ABI18
    private var publishedNavigationFailure: ChromiumNavigationFailure?
    #endif
    private var publishedFaviconPNG: Data?
    private var publishedFaviconOrigin: String?
    private var securityErrorPage = false
    private var securityCertificateError = false
    private var securityDisplayedMixedContent = false
    private var securityRanMixedContent = false
    private var committedURL: URL?
    private var zoomOrigin: String?
    private var pendingZoom: (origin: String, factor: Double)?
    #if COBBLE_CHROMIUM_ABI4
    private var findRequestID: Int32?
    private weak var devToolsSession: ChromiumPageDevToolsSession?
    #endif
    #if COBBLE_CHROMIUM_ABI10
    private var scopedLocalFileURL: URL?
    private var authorizedLocalFileURL: URL?
    #endif

    init(tabID: UUID, context: ChromiumContext, windowID: UUID, engine: ChromiumEngine,
         source: CobbleChromium.ChromiumPage? = nil) {
        self.tabID = tabID
        self.context = context
        self.contextID = context.id
        self.windowID = windowID
        self.engine = engine
        self.source = source
        if let source { attach(source) }
    }

    func prepare() async throws {
        guard !closing else { throw EngineError.closed }
        ApplePasskeys.prepareIfNeeded()
        if source != nil { return }
        if let prepareTask { return try await prepareTask.value }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw EngineError.closed }
            #if COBBLE_CHROMIUM_ABI4
            if !self.contextID.isPrivate {
                try await self.engine.chromiumContentBlocker.prepare(profileID: self.contextID.profileID)
            }
            #endif
            let source = try await self.context.makeNativePage(hostWindowID: self.windowID)
            guard !self.closing else {
                // The tab was retired while Chromium was opening its page.
                // There is no visible host to restore, so bypass before-unload.
                source.forceClose()
                _ = await source.waitUntilClosed()
                throw EngineError.closed
            }
            self.attach(source)
        }
        prepareTask = task
        do {
            try await task.value
            prepareTask = nil
        } catch {
            prepareTask = nil
            throw chromiumEngineError(error)
        }
    }

    func navigate(to url: URL?) {
        guard !closing, let source else { return }
        cancelAppleSignIn()
        resetFind()
        invalidateConnectionDetails()
        do { try source.load(url ?? URL(string: "about:blank")!) }
        catch { state.errorMessage = error.localizedDescription; refresh(source) }
    }

    func goBack() { guard !closing, state.canGoBack else { return }; cancelAppleSignIn(); resetFind(); invalidateConnectionDetails(); source?.goBack() }
    func goForward() { guard !closing, state.canGoForward else { return }; cancelAppleSignIn(); resetFind(); invalidateConnectionDetails(); source?.goForward() }
    func reload() {
        guard !closing, let source else { return }
        cancelAppleSignIn()
        resetFind()
        #if COBBLE_CHROMIUM_ABI4
        invalidateConnectionDetails()
        #if COBBLE_CHROMIUM_ABI10
        if reloadLocalFile(source) { return }
        #endif
        if !source.reload() {
            state.errorMessage = String(localized: "This page cannot be reloaded right now.")
            refresh(source)
        }
        #else
        source.reload()
        #endif
    }
    func stop() { guard !closing else { return }; source?.stop() }
    func focus() { guard !closing else { return }; source?.focus() }
    func setActive(_ active: Bool) {
        if !active { externalApplications.cancelAll() }
        isActive = active
        if active { focus() }
    }
    func setAppPromptPending(_ pending: Bool) {
        appPromptPending = pending
        #if COBBLE_CHROMIUM_ABI4
        state.hasPendingPrompt = pending || source?.hasPendingPrompt == true
        #else
        state.hasPendingPrompt = pending
        #endif
    }
    func setVisible(_ visible: Bool) {
        isVisible = visible
        #if COBBLE_CHROMIUM_ABI4
        source?.setVisible(visible)
        #endif
    }

    func setInspectable(_ enabled: Bool) {
        inspectable = enabled
        #if COBBLE_CHROMIUM_ABI4
        if !enabled { _ = devToolsSession?.close() }
        #endif
    }

    #if COBBLE_CHROMIUM_ABI4
    private func closeDevTools() {
        _ = devToolsSession?.close()
        devToolsSession = nil
    }
    #endif

    func moveToWindow(_ windowID: UUID) throws {
        #if COBBLE_CHROMIUM_ABI4
        guard !closing, state.lifecycle == .ready, !state.isLoading,
              !state.hasPendingPrompt, let source else {
            throw EngineError.notReady("Finish the current page action before moving this Chromium tab.")
        }
        do {
            try source.move(toHostWindowID: windowID)
            self.windowID = windowID
        } catch { throw chromiumEngineError(error) }
        #else
        throw EngineError.unsupported(String(localized: "moving live tabs between windows"))
        #endif
    }

    func find(_ text: String, backwards: Bool) {
        guard !closing, let source else { return }
        state.findQuery = text
        state.findMatchFound = nil
        do {
            #if COBBLE_CHROMIUM_ABI4
            findRequestID = nil
            findRequestID = try source.find(text, backwards: backwards)
            if let result = source.findResult { receiveFindResult(result) }
            #else
            try source.find(text, backwards: backwards)
            #endif
        }
        catch { state.errorMessage = error.localizedDescription }
    }

    func zoom(by factor: Double) {
        guard !closing, let source, factor.isFinite, factor > 0 else { return }
        guard let current = source.zoomFactor else {
            state.errorMessage = "Zoom is unavailable for this Chromium page."
            return
        }
        do {
            try source.setZoomFactor(min(3, max(0.5, current * factor)))
            rememberZoom(source)
        }
        catch { state.errorMessage = error.localizedDescription }
    }

    func resetZoom() {
        guard !closing, let source else { return }
        do {
            try source.setZoomFactor(1)
            rememberZoom(source)
        }
        catch { state.errorMessage = error.localizedDescription }
    }

    func applySiteSettings() {
        zoomOrigin = nil
        applyRememberedZoom()
    }

    func reloadFromOrigin() {
        #if COBBLE_CHROMIUM_ABI4
        guard !closing, let source else { return }
        cancelAppleSignIn()
        resetFind()
        invalidateConnectionDetails()
        #if COBBLE_CHROMIUM_ABI10
        if reloadLocalFile(source) { return }
        #endif
        do { try source.reloadFromOrigin() }
        catch { state.errorMessage = chromiumEngineError(error).localizedDescription; refresh(source) }
        #else
        state.errorMessage = EngineError.unsupported(String(localized: "Reload from Origin")).localizedDescription
        #endif
    }

    #if COBBLE_CHROMIUM_ABI10
    static func isAuthorizedLocalFile(_ currentURL: URL?, authorizedURL: URL?) -> Bool {
        guard let currentURL, currentURL.isFileURL, let authorizedURL else { return false }
        return currentURL.standardizedFileURL == authorizedURL.standardizedFileURL
    }

    private func reloadLocalFile(_ source: CobbleChromium.ChromiumPage) -> Bool {
        guard let url = URL(string: source.urlString), url.isFileURL else { return false }
        guard Self.isAuthorizedLocalFile(url, authorizedURL: authorizedLocalFileURL) else {
            state.errorMessage = String(localized: "Cobble no longer has permission to reload this local file. Choose it again with File > Open File…")
            return true
        }
        Task { @MainActor [weak self, weak source] in
            guard let self, let source, !self.closing, self.source === source,
                  Self.isAuthorizedLocalFile(URL(string: source.urlString), authorizedURL: self.authorizedLocalFileURL),
                  URL(string: source.urlString)?.standardizedFileURL == url.standardizedFileURL else { return }
            do {
                try await source.openLocalFile(url)
                guard !self.closing, self.source === source,
                      URL(string: source.urlString)?.standardizedFileURL == url.standardizedFileURL else { return }
                self.refresh(source)
            } catch {
                guard !self.closing, self.source === source,
                      URL(string: source.urlString)?.standardizedFileURL == url.standardizedFileURL else { return }
                self.state.errorMessage = chromiumEngineError(error).localizedDescription
                self.refresh(source)
            }
        }
        return true
    }

    func openLocalFile(_ url: URL) async throws {
        guard !closing, state.lifecycle == .ready, let source else { throw EngineError.closed }
        guard url.isFileURL else { throw EngineError.notReady(String(localized: "Choose a local file.")) }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            try await source.openLocalFile(url)
            guard !closing, self.source === source,
                  URL(string: source.urlString)?.standardizedFileURL == url.standardizedFileURL else {
                throw EngineError.closed
            }
            releaseLocalFileAccess()
            authorizedLocalFileURL = url
            if scoped { scopedLocalFileURL = url }
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw chromiumEngineError(error)
        }
    }

    private func releaseLocalFileAccess(unlessCurrentURL url: URL? = nil) {
        if let url, url.isFileURL,
           url.standardizedFileURL == authorizedLocalFileURL?.standardizedFileURL { return }
        scopedLocalFileURL?.stopAccessingSecurityScopedResource()
        scopedLocalFileURL = nil
        authorizedLocalFileURL = nil
    }
    #endif

    func pageArchive() async throws -> Data {
        #if COBBLE_CHROMIUM_ABI4
        guard !closing, state.lifecycle == .ready, let source else { throw EngineError.closed }
        do {
            let data = try await source.webArchive()
            guard !closing, self.source === source else { throw EngineError.closed }
            return data
        }
        catch { throw chromiumEngineError(error) }
        #else
        throw EngineError.unsupported(String(localized: "saving pages"))
        #endif
    }

    func currentDOM() async throws -> String {
        #if COBBLE_CHROMIUM_ABI4
        guard !closing, state.lifecycle == .ready, let source else { throw EngineError.closed }
        do {
            let dom = try await source.currentDOM()
            guard !closing, self.source === source else { throw EngineError.closed }
            return dom
        }
        catch { throw chromiumEngineError(error) }
        #else
        throw EngineError.unsupported(String(localized: "viewing the current page DOM"))
        #endif
    }

    func connectionDetails() async throws -> PageConnectionDetails? {
        #if COBBLE_CHROMIUM_ABI4
        guard !closing, state.lifecycle == .ready, let source else { throw EngineError.closed }
        let revision = state.connectionDetailsRevision
        do {
            guard let details = try await source.connectionDetails() else { return nil }
            guard !closing, self.source === source, state.connectionDetailsRevision == revision,
                  details.url.absoluteString == source.urlString else {
                throw EngineError.notReady("The page changed while Cobble was reading connection details. Try again.")
            }
            let connection: PageConnection = switch details.connection {
            case .unknown: .unknown
            case .empty: .empty
            case .secure: .secure
            case .mixed: .mixed
            case .insecure: .insecure
            }
            let certificate = details.certificate.map {
                PageCertificateDetails(subject: Self.securityText($0.subject),
                    issuer: Self.securityText($0.issuer),
                    validFrom: $0.validFrom, validUntil: $0.validUntil)
            }
            let nativeChain = details.certificateChain
            let certificateChain = nativeChain.prefix(16).map {
                PageCertificateDetails(subject: Self.securityText($0.subject),
                    issuer: Self.securityText($0.issuer),
                    validFrom: $0.validFrom, validUntil: $0.validUntil)
            }
            let mixed = details.mixedContent
            return PageConnectionDetails(url: details.url, connection: connection, certificate: certificate,
                certificateChain: certificateChain,
                certificateChainTruncated: details.certificateChainTruncated || nativeChain.count > certificateChain.count,
                certificateErrors: details.certificateErrorCodes.prefix(32).map(Self.certificateErrorDescription),
                mixedContent: PageMixedContentDetails(displayed: mixed.displayed, ran: mixed.ran,
                    containedForm: mixed.containedForm,
                    displayedWithCertificateErrors: mixed.displayedWithCertificateErrors,
                    ranWithCertificateErrors: mixed.ranWithCertificateErrors))
        } catch let error as EngineError { throw error }
        catch { throw chromiumEngineError(error) }
        #else
        return nil
        #endif
    }

    func openDevTools(hostWindowID: UUID) throws -> any PageDevToolsSession {
        #if COBBLE_CHROMIUM_ABI4
        guard !closing, state.lifecycle == .ready, !hasPendingPrompt, let source else {
            throw EngineError.notReady("The Chromium page is not ready for Developer Tools.")
        }
        guard inspectable else { throw EngineError.unsupported(String(localized: "Developer Tools")) }
        guard devToolsSession?.isClosed != false else {
            throw EngineError.notReady("Developer Tools are already open for this page.")
        }
        do {
            let session = ChromiumPageDevToolsSession(source: try source.openDevTools(hostWindowID: hostWindowID))
            devToolsSession = session
            return session
        } catch { throw chromiumEngineError(error) }
        #else
        throw EngineError.unsupported(String(localized: "Developer Tools"))
        #endif
    }

    #if COBBLE_CHROMIUM_ABI4
    private static func securityText(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? String(localized: "Unknown") : text
    }

    private static func certificateErrorDescription(_ code: String) -> String {
        switch code {
        case "commonNameInvalid": String(localized: "The certificate does not match this website")
        case "dateInvalid": String(localized: "The certificate is expired or not yet valid")
        case "authorityInvalid": String(localized: "The certificate authority is not trusted")
        case "noRevocationMechanism": String(localized: "The certificate cannot be checked for revocation")
        case "unableToCheckRevocation": String(localized: "Certificate revocation could not be checked")
        case "revoked": String(localized: "The certificate was revoked")
        case "invalid": String(localized: "The certificate is invalid")
        case "weakSignature": String(localized: "The certificate uses a weak signature")
        case "nonUniqueName": String(localized: "The certificate name is not unique")
        case "weakKey": String(localized: "The certificate uses a weak key")
        case "pinnedKeyMissing": String(localized: "The certificate does not use the required key")
        case "nameConstraintViolation": String(localized: "The certificate violates its name constraints")
        case "validityTooLong": String(localized: "The certificate validity period is too long")
        case "certificateTransparencyRequired": String(localized: "Certificate transparency information is missing")
        case "knownInterceptionBlocked": String(localized: "A known interception certificate was blocked")
        case "selfSignedLocalNetwork": String(localized: "The local-network certificate is self-signed")
        default: String(format: String(localized: "Certificate error: %@"), String(code.prefix(128)))
        }
    }
    #endif

    func printPage() {
        #if COBBLE_CHROMIUM_ABI4
        guard !closing, let source else { return }
        do { try source.printPage() }
        catch { state.errorMessage = error.localizedDescription }
        #else
        state.errorMessage = "Printing is not available in Chromium yet."
        #endif
    }

    #if COBBLE_CHROMIUM_ABI4
    @discardableResult func stopMediaCapture() -> Bool {
        guard !closing, let source else { return false }
        guard source.stopMediaCapture() else {
            state.errorMessage = "Chromium could not stop camera and microphone capture."
            return false
        }
        return true
    }

    func setAudioMuted(_ muted: Bool) throws {
        guard !closing else { throw EngineError.closed }
        guard let source else { throw EngineError.notReady("The Chromium page is not ready.") }
        do { try source.setAudioMuted(muted) }
        catch {
            let failure = chromiumEngineError(error)
            state.errorMessage = failure.localizedDescription
            throw failure
        }
    }

    func snapshot() async throws -> NSImage {
        guard !closing, state.lifecycle == .ready, let source else { throw EngineError.closed }
        let data: Data
        do { data = try await source.snapshotPNG() }
        catch { throw chromiumEngineError(error) }
        guard !closing, self.source === source, state.lifecycle == .ready else { throw EngineError.closed }
        guard let image = NSImage(data: data) else {
            throw EngineError.notReady("Chromium returned an invalid page screenshot.")
        }
        return image
    }
    #endif

    func applyContentRules() {}

    func requestClose() async -> Bool {
        externalApplications.cancelAll()
        guard state.lifecycle != .closed else { return true }
        guard !closing else {
            if closeForced {
                await waitUntilClosed()
                return state.lifecycle == .closed
            }
            guard let source else {
                await waitUntilClosed()
                return state.lifecycle == .closed
            }
            let closed = await source.waitUntilClosed()
            if closed || closeForced {
                await waitUntilClosed()
                return state.lifecycle == .closed
            }
            return state.lifecycle == .closed
        }
        guard let source else {
            // A close can arrive while asynchronous page creation is still in
            // flight. Do not report closed until that native page is retired.
            closing = true
            state.lifecycle = .closing
            if let prepareTask { _ = await prepareTask.result }
            finishClose()
            return true
        }
        closing = true
        state.lifecycle = .closing
        source.onChange = nil
        source.onClose = { [weak self] in self?.finishClose() }
        source.onCloseCancelled = { [weak self] in self?.closeCancelled() }
        source.onNavigationCommitted = nil
        #if COBBLE_CHROMIUM_ABI4
        source.onFindResult = nil
        source.onPrimaryMainFrameCommitted = nil
        #endif
        source.onActivate = nil
        source.close()
        let closed = await source.waitUntilClosed()
        if closed { return true }
        if closeForced {
            await waitUntilClosed()
            return state.lifecycle == .closed
        }
        closeCancelled()
        return false
    }

    /// EngineRegistry uses this for discard, engine switching, and shutdown.
    /// It bypasses before-unload cancellation after Cobble has removed the tab.
    func close() {
        externalApplications.cancelAll()
        guard state.lifecycle != .closed else { return }
        #if COBBLE_CHROMIUM_ABI4
        closeDevTools()
        #endif
        if closing {
            source?.onCloseCancelled = nil
            closeForced = true
            source?.forceClose()
            return
        }
        closing = true
        closeForced = true
        state.lifecycle = .closing
        events.clear()
        guard let source else {
            if let prepareTask {
                Task { [weak self] in
                    _ = await prepareTask.result
                    self?.finishClose()
                }
            } else {
                finishClose()
            }
            return
        }
        source.onChange = nil
        source.onClose = { [weak self] in self?.finishClose() }
        source.onCloseCancelled = nil
        source.onNavigationCommitted = nil
        #if COBBLE_CHROMIUM_ABI4
        source.onFindResult = nil
        source.onPrimaryMainFrameCommitted = nil
        #endif
        source.onActivate = nil
        source.forceClose()
    }

    func waitUntilClosed() async {
        while state.lifecycle != .closed {
            await withCheckedContinuation { continuation in
                guard state.lifecycle != .closed else {
                    continuation.resume()
                    return
                }
                closeWaiters.append(continuation)
            }
        }
    }

    func attach(_ source: CobbleChromium.ChromiumPage) {
        guard !closing else { return }
        self.source = source
        engine.remember(self, source: source)
        source.onChange = { [weak self, weak source] in
            guard let self, let source else { return }
            self.refresh(source)
        }
        source.onClose = { [weak self] in self?.nativeDidClose() }
        source.onCloseCancelled = { [weak self] in self?.closeCancelled() }
        source.onNavigationCommitted = { [weak self, weak source] url, title in
            guard let self, let source, self.source === source else { return }
            self.navigationCommitted(url, title: title)
        }
        #if COBBLE_CHROMIUM_ABI4
        observePageDetails(source)
        #endif
        source.onActivate = { [weak self, weak source] in
            guard let self, let source, self.source === source, !self.closing else { return }
            self.events.onActivate?()
        }
        let pageView = source.nativeView
        pageView.removeFromSuperview()
        pageView.frame = nativeView.bounds
        pageView.autoresizingMask = [.width, .height]
        nativeView.addSubview(pageView)
        if isActive { source.focus() }
        #if COBBLE_CHROMIUM_ABI4
        source.setVisible(isVisible)
        #endif
        state.lifecycle = .ready
        refresh(source)
    }

    private func refresh(_ source: CobbleChromium.ChromiumPage) {
        guard !closing, self.source === source else { return }
        let previousConnection = state.connection
        let wasLoading = state.isLoading
        if state.urlString != source.urlString || (!state.isLoading && source.isLoading) { resetFind() }
        state.urlString = source.urlString
        state.title = source.title
        state.isLoading = source.isLoading
        #if COBBLE_CHROMIUM_ABI18
        state.estimatedProgress = source.estimatedProgress
        state.isUnresponsive = source.isUnresponsive
        if publishedNavigationFailure != source.navigationFailure {
            publishedNavigationFailure = source.navigationFailure
            state.errorMessage = source.navigationFailure?.localizedDescription
        }
        #endif
        state.canGoBack = source.canGoBack
        state.canGoForward = source.canGoForward
        state.isCrashed = source.isCrashed
        #if COBBLE_CHROMIUM_ABI4
        if source.isCrashed {
            #if COBBLE_CHROMIUM_ABI10
            releaseLocalFileAccess()
            #endif
            if state.connectionDetailsReady || previousConnection != .unknown {
                state.connectionDetailsRevision = UUID()
            }
            state.isPlayingAudio = false
            state.isAudioMuted = false
            state.camera = .none
            state.microphone = .none
            state.grantedMediaKinds.removeAll()
            state.isDisplayCapturing = false
            state.hoveredLink = nil
            state.hasPendingPrompt = false
            state.favicon = nil
            state.faviconOrigin = nil
            state.connection = .unknown
            state.connectionDetailsReady = false
            securityErrorPage = false
            securityCertificateError = false
            securityDisplayedMixedContent = false
            securityRanMixedContent = false
            publishedFaviconPNG = nil
            publishedFaviconOrigin = nil
        } else {
            #if COBBLE_CHROMIUM_ABI10
            if source.securityErrorPage { releaseLocalFileAccess() }
            #endif
            state.isPlayingAudio = source.isAudible
            state.isAudioMuted = source.isAudioMuted
            state.camera = source.isCapturingCamera ? .active : .none
            state.microphone = source.isCapturingMicrophone ? .active : .none
            if state.camera != .none { state.grantedMediaKinds.remove(.camera) }
            if state.microphone != .none { state.grantedMediaKinds.remove(.microphone) }
            state.hoveredLink = source.hoveredLink.flatMap { value in
                guard value.utf8.count <= 8_192, let url = URL(string: value),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                return url.absoluteString
            }
            state.hasPendingPrompt = appPromptPending || source.hasPendingPrompt
            publishFavicon(source)
            switch source.connection {
            case .unknown: state.connection = .unknown
            case .empty: state.connection = .empty
            case .secure: state.connection = .secure
            case .mixed: state.connection = .mixed
            case .insecure: state.connection = .insecure
            }
            let securityChanged = previousConnection != state.connection
                || securityErrorPage != source.securityErrorPage
                || securityCertificateError != source.securityCertificateError
                || securityDisplayedMixedContent != source.securityDisplayedMixedContent
                || securityRanMixedContent != source.securityRanMixedContent
            securityErrorPage = source.securityErrorPage
            securityCertificateError = source.securityCertificateError
            securityDisplayedMixedContent = source.securityDisplayedMixedContent
            securityRanMixedContent = source.securityRanMixedContent
            let detailsBecameReady = !source.isLoading && !state.connectionDetailsReady
            state.connectionDetailsReady = !source.isLoading
            if securityChanged || (wasLoading && !source.isLoading) || detailsBecameReady {
                state.connectionDetailsRevision = UUID()
            }
        }
        #endif
        if let pendingZoom,
           URL(string: source.urlString).flatMap(AddressResolver.canonicalOrigin) != pendingZoom.origin {
            self.pendingZoom = nil
        }
        applyRememberedZoom()
        startAppleSignInIfNeeded(source.urlString)
        guard source.urlString != publishedURL || source.title != publishedTitle else { return }
        if source.urlString != publishedURL { state.blockedPopup = false }
        publishedURL = source.urlString
        publishedTitle = source.title
        events.onChange?(tabID, source.urlString, source.title)
    }

    #if COBBLE_CHROMIUM_ABI4
    private func publishFavicon(_ source: CobbleChromium.ChromiumPage) {
        let faviconOrigin = URL(string: source.urlString).flatMap(AddressResolver.canonicalOrigin)
        guard publishedFaviconPNG != source.faviconPNG || publishedFaviconOrigin != faviconOrigin else { return }
        publishedFaviconPNG = source.faviconPNG
        publishedFaviconOrigin = faviconOrigin
        let png = source.faviconPNG.flatMap(CachedFavicon.normalizedPNG(from:))
        let url = URL(string: source.urlString)
        state.favicon = png.flatMap(NSImage.init(data:))
        state.faviconOrigin = state.favicon == nil ? nil : faviconOrigin
        if let url, let png, state.favicon != nil { events.onFavicon?(tabID, url, png) }
    }
    #endif

    private func resetFind() {
        state.findQuery = ""
        state.findMatchFound = nil
        #if COBBLE_CHROMIUM_ABI4
        findRequestID = nil
        #endif
    }

    private func invalidateConnectionDetails() {
        state.connectionDetailsReady = false
        state.connectionDetailsRevision = UUID()
    }

    #if COBBLE_CHROMIUM_ABI4
    private func observePageDetails(_ source: CobbleChromium.ChromiumPage) {
        source.onPrimaryMainFrameCommitted = { [weak self, weak source] url in
            guard let self, let source, self.source === source, !self.closing else { return }
            self.externalApplications.cancelAll()
            // ponytail: ABI lacks document identity; retaining same-origin grants can unload an idle
            // replacement on Deny. Clear on full commits once the SDK exposes same-document status.
            if self.committedURL.flatMap(AddressResolver.canonicalOrigin)
                != AddressResolver.canonicalOrigin(url) {
                self.state.grantedMediaKinds.removeAll()
            }
            self.committedURL = url
            #if COBBLE_CHROMIUM_ABI10
            self.releaseLocalFileAccess(unlessCurrentURL: url)
            #endif
            self.state.connectionDetailsRevision = UUID()
            self.zoomOrigin = nil
            self.resetFind()
            self.applyRememberedZoom()
        }
        source.onFindResult = { [weak self, weak source] result in
            guard let self, let source, self.source === source, !self.closing else { return }
            self.receiveFindResult(result)
        }
    }

    private func receiveFindResult(_ result: CobbleChromium.ChromiumPage.FindResult) {
        guard findRequestID == result.requestID, result.isFinal, !state.findQuery.isEmpty else { return }
        state.findMatchFound = result.matchCount > 0
    }
    #endif

    private var canUseCommittedZoom: Bool {
        guard committedURL != nil else { return false }
        #if COBBLE_CHROMIUM_ABI4
        return true
        #else
        return source?.isLoading == false
        #endif
    }

    private func rememberZoom(_ source: CobbleChromium.ChromiumPage) {
        guard !contextID.isPrivate, let zoom = source.zoomFactor,
              let visibleURL = URL(string: source.urlString),
              let visibleOrigin = AddressResolver.canonicalOrigin(visibleURL) else { return }
        guard canUseCommittedZoom, let url = committedURL,
              AddressResolver.canonicalOrigin(url) == visibleOrigin else {
            pendingZoom = (visibleOrigin, zoom)
            return
        }
        pendingZoom = nil
        context.siteSettings?.setZoom(zoom, origin: url, profileID: contextID.profileID,
                                      engineID: contextID.engineID)
    }

    private func applyRememberedZoom() {
        guard !closing, !contextID.isPrivate, let source, canUseCommittedZoom,
              let url = committedURL, let origin = AddressResolver.canonicalOrigin(url),
              let visibleURL = URL(string: source.urlString),
              AddressResolver.canonicalOrigin(visibleURL) == origin,
              origin != zoomOrigin else { return }
        let pending = pendingZoom.flatMap { $0.origin == origin ? $0.factor : nil }
        let zoom = pending ?? context.siteSettings?.setting(origin: url, profileID: contextID.profileID,
                                                            engineID: contextID.engineID).zoom ?? 1
        zoomOrigin = origin
        do {
            try source.setZoomFactor(zoom)
            if pending != nil { rememberZoom(source) }
        } catch {
            zoomOrigin = nil
            state.errorMessage = error.localizedDescription
        }
    }

    private func navigationCommitted(_ url: URL, title: String) {
        state.errorMessage = nil
        #if !COBBLE_CHROMIUM_ABI4
        committedURL = url
        zoomOrigin = nil
        applyRememberedZoom()
        #endif
        guard !context.isPrivate,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        events.onVisit?(tabID, url.absoluteString, title)
    }

    #if COBBLE_CHROMIUM_ABI4
    var committedOrigin: String? { committedURL.flatMap(AddressResolver.canonicalOrigin) }
    #endif

    func offerExternalApplication(_ url: URL) {
        guard !closing, isActive, state.lifecycle == .ready, !hasPendingPrompt,
              nativeView.window?.attachedSheet == nil, events.onExternalURL != nil else { return }
        let pageURL = state.urlString
        let alert = PagePresenter.alert(title: String(localized: "Open another application?"),
            message: url.absoluteString, buttons: [String(localized: "Open"), String(localized: "Cancel")])
        externalApplications.present(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, !self.closing,
                  self.isActive, self.state.lifecycle == .ready, self.state.urlString == pageURL else { return }
            self.events.onExternalURL?(url)
        }
    }

    private func cancelAppleSignIn() {
        appleSignInURL = nil
        appleSignIn?.cancel()
        appleSignIn = nil
    }

    private func startAppleSignInIfNeeded(_ urlString: String) {
        guard appleSignIn == nil else { return }
        if appleSignInURL != urlString { appleSignInURL = nil }
        guard appleSignInURL == nil, let url = URL(string: urlString),
              let request = AppleSignIn.request(from: url) else { return }
        appleSignInURL = urlString
        var stoppedURL = urlString
        appleSignIn = AppleSignInSession.start(request: request, window: nativeView.window, prepare: { [weak self] in
            guard let self else { return false }
            guard !self.closing, let source = self.source,
                  source.urlString == urlString else {
                self.appleSignInURL = nil
                return false
            }
            source.stop()
            stoppedURL = source.urlString
            return !self.closing
        }) { [weak self] callback in
            guard let self, !self.closing, self.state.lifecycle != .closed else { return }
            self.appleSignIn = nil
            guard self.appleSignInURL == urlString, self.source?.urlString == stoppedURL else { return }
            if let callback {
                self.navigate(to: callback)
            } else if self.state.canGoBack {
                self.goBack()
            }
        }
    }

    private func nativeDidClose() {
        guard state.lifecycle != .closed else { return }
        let callback = closing ? nil : events.onClose
        finishClose()
        callback?()
    }

    private func closeCancelled() {
        guard closing, !closeForced, state.lifecycle != .closed else { return }
        closing = false
        state.lifecycle = .ready
        state.errorMessage = "Chromium cancelled the close request; this page is still open."
        guard let source else { return }
        source.onChange = { [weak self, weak source] in
            guard let self, let source else { return }
            self.refresh(source)
        }
        source.onClose = { [weak self] in self?.nativeDidClose() }
        source.onCloseCancelled = { [weak self] in self?.closeCancelled() }
        source.onNavigationCommitted = { [weak self, weak source] url, title in
            guard let self, let source, self.source === source else { return }
            self.navigationCommitted(url, title: title)
        }
        #if COBBLE_CHROMIUM_ABI4
        observePageDetails(source)
        #endif
        source.onActivate = { [weak self, weak source] in
            guard let self, let source, self.source === source, !self.closing else { return }
            self.events.onActivate?()
        }
    }

    private func finishClose() {
        guard state.lifecycle != .closed else { return }
        #if COBBLE_CHROMIUM_ABI4
        closeDevTools()
        #endif
        #if COBBLE_CHROMIUM_ABI10
        releaseLocalFileAccess()
        #endif
        appleSignIn?.cancel()
        appleSignIn = nil
        resetFind()
        committedURL = nil
        zoomOrigin = nil
        pendingZoom = nil
        if let source {
            source.onChange = nil
            source.onClose = nil
            source.onCloseCancelled = nil
            source.onNavigationCommitted = nil
            #if COBBLE_CHROMIUM_ABI4
            source.onFindResult = nil
            source.onPrimaryMainFrameCommitted = nil
            #endif
            source.onActivate = nil
            source.nativeView.removeFromSuperview()
            engine.forget(source)
        }
        source = nil
        prepareTask = nil
        closing = true
        state.isLoading = false
        state.camera = .none
        state.microphone = .none
        state.grantedMediaKinds.removeAll()
        state.isDisplayCapturing = false
        state.isPlayingAudio = false
        state.isAudioMuted = false
        state.hasPendingPrompt = false
        state.connectionDetailsReady = false
        appPromptPending = false
        publishedFaviconPNG = nil
        publishedFaviconOrigin = nil
        state.blockedPopup = false
        state.lifecycle = .closed
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
        events.clear()
    }
}

#if COBBLE_CHROMIUM_ABI4
@MainActor private final class ChromiumPageDevToolsSession: PageDevToolsSession {
    private let source: ChromiumDevToolsSession

    init(source: ChromiumDevToolsSession) {
        self.source = source
        source.onClose = { [weak self] in self?.onClose?() }
    }

    var nativeView: NSView { source.nativeView }
    var isClosed: Bool { source.isClosed }
    var onClose: (() -> Void)?
    func focus() { source.focus() }
    func setVisible(_ visible: Bool) { source.setVisible(visible) }
    @discardableResult func close() -> Bool { source.close() }
}
#endif

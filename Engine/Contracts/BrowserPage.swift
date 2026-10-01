import AppKit
import Observation

enum PageOperation: Hashable, Sendable { case find, zoom, printPage, muteAudio, reloadFromOrigin, snapshot, localFile, savePage, pageDOM, inspect, openDevTools, detach }
enum PermissionKind: Hashable, Sendable { case camera, microphone }
enum PageMediaPlayback: Hashable, Sendable { case none, playing, paused, suspended }
enum PageConnection: Hashable, Sendable {
    case unknown, empty, secure, mixed, insecure
    static func classify(urlString: String, hasOnlySecureContent: Bool? = nil) -> PageConnection {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else { return .empty }
        if scheme == "https" { return hasOnlySecureContent.map { $0 ? .secure : .mixed } ?? .unknown }
        if scheme == "http" { return .insecure }
        return .empty
    }
}
struct PageCertificateDetails: Equatable, Sendable {
    let subject: String
    let issuer: String
    let validFrom: Date?
    let validUntil: Date?
}
struct PageMixedContentDetails: Equatable, Sendable {
    let displayed: Bool
    let ran: Bool
    let containedForm: Bool
    let displayedWithCertificateErrors: Bool
    let ranWithCertificateErrors: Bool
    var hasIssues: Bool {
        displayed || ran || containedForm || displayedWithCertificateErrors || ranWithCertificateErrors
    }
}
struct PageConnectionDetails: Equatable, Sendable {
    let url: URL
    let connection: PageConnection
    let certificate: PageCertificateDetails?
    let certificateChain: [PageCertificateDetails]
    let certificateChainTruncated: Bool
    let certificateErrors: [String]
    let mixedContent: PageMixedContentDetails

    init(url: URL, connection: PageConnection, certificate: PageCertificateDetails?,
         certificateChain: [PageCertificateDetails] = [], certificateChainTruncated: Bool = false,
         certificateErrors: [String], mixedContent: PageMixedContentDetails) {
        self.url = url
        self.connection = connection
        self.certificate = certificate
        self.certificateChain = certificateChain
        self.certificateChainTruncated = certificateChainTruncated
        self.certificateErrors = certificateErrors
        self.mixedContent = mixedContent
    }
}
enum PageCapture: Hashable, Sendable { case none, active, muted }
enum PageCaptureControl: Hashable, Sendable {
    case mute(PermissionKind), stop(PermissionKind), stopAllUserMedia
}
enum PageArchiveFormat: Sendable {
    case webArchive, mhtml
    var filenameExtension: String { self == .webArchive ? "webarchive" : "mhtml" }
}
@MainActor @Observable final class PageState {
    enum Lifecycle { case preparing, ready, closing, closed }
    var lifecycle: Lifecycle = .preparing
    var urlString = ""
    var title = ""
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var errorMessage: String?
    var isCrashed = false
    var favicon: NSImage?
    var faviconOrigin: String?
    var connection: PageConnection = .unknown
    var connectionDetailsRevision = UUID()
    var connectionDetailsReady = false
    var camera: PageCapture = .none
    var microphone: PageCapture = .none
    /// Native permission granted before capture-state notifications arrive.
    var grantedMediaKinds: Set<PermissionKind> = []
    var hoveredLink: String?
    var blockedPopup = false
    var mediaPlayback: PageMediaPlayback = .none
    var isPlayingAudio = false
    var isAudioMuted = false
    var isDisplayCapturing = false
    var audioMuteBlocked = false
    /// Native dialogs and permission popovers that would be cancelled by retirement.
    var hasPendingPrompt = false
    var findQuery = ""
    /// Nil means no completed result is available from this engine.
    var findMatchFound: Bool?
}

/// The owner installs callbacks before loading or accepting an engine-created popup.
@MainActor final class PageEvents {
    var onChange: ((UUID, String, String) -> Void)?
    var onVisit: ((UUID, String, String) -> Void)?
    var onFavicon: ((UUID, URL, Data) -> Void)?
    var onCreatePage: ((any BrowserPage, _ activate: Bool) -> Bool)?
    var onDownload: ((any EngineDownload) -> Void)?
    var onClose: (() -> Void)?
    var onActivate: (() -> Void)?
    var onExternalURL: ((URL) -> Void)?
    var onKeyEvent: ((NSEvent) -> Bool)?
    var onMediaPermissionRequest: ((PageMediaPermissionRequest) -> Void)?
    var onJavaScriptDialog: ((PageJavaScriptDialogRequest) -> Void)?
    var onHTTPAuthRequest: ((PageHTTPAuthRequest) -> Void)?
    var onFileChooserRequest: ((PageFileChooserRequest) -> Void)?
    var onExternalProtocolRequest: ((PageExternalProtocolRequest) -> Void)?
    var onClientCertificateRequest: ((PageClientCertificateRequest) -> Void)?
    var onPromptCancelled: ((UUID) -> Void)?
    func clear() {
        onChange = nil; onVisit = nil; onFavicon = nil; onCreatePage = nil
        onDownload = nil; onClose = nil; onActivate = nil; onExternalURL = nil; onKeyEvent = nil
        onMediaPermissionRequest = nil; onJavaScriptDialog = nil; onHTTPAuthRequest = nil
        onFileChooserRequest = nil; onExternalProtocolRequest = nil; onClientCertificateRequest = nil
        onPromptCancelled = nil
    }
}

@MainActor protocol BrowserPage: AnyObject {
    var tabID: UUID { get }
    var contextID: BrowsingContextID { get }
    var nativeView: NSView { get }
    var state: PageState { get }
    var capabilities: EngineCapabilities { get }
    var events: PageEvents { get }
    var archiveFormat: PageArchiveFormat { get }
    /// Idempotent: concurrent callers await the same initialization and required rules.
    func prepare() async throws
    func navigate(to url: URL?)
    func goBack()
    func goForward()
    func reload()
    /// Revalidate the current page with its origin; this does not clear website data.
    func reloadFromOrigin()
    func stop()
    func find(_ text: String, backwards: Bool)
    func zoom(by factor: Double)
    func resetZoom()
    func printPage()
    /// Capture only the visible page viewport, without browser chrome or durable side effects.
    func snapshot() async throws -> NSImage
    /// Opens one file explicitly authorized by the user. Implementations grant no sibling or parent-directory access.
    func openLocalFile(_ url: URL) async throws
    /// Saves the browser's current live contents as an engine-specific archive.
    func pageArchive() async throws -> Data
    /// Returns the current, script-mutated DOM. It is not the original response body.
    func currentDOM() async throws -> String
    /// Returns an on-demand security snapshot bound to its exact page URL.
    func connectionDetails() async throws -> PageConnectionDetails?
    func setInspectable(_ enabled: Bool)
    /// Opens developer tools in a host window that the app registered before this call.
    func openDevTools(hostWindowID: UUID) throws -> any PageDevToolsSession
    func setCapture(_ kind: PermissionKind, _ capture: PageCapture)
    @discardableResult func stopMediaCapture() -> Bool
    func setAudioMuted(_ muted: Bool) throws
    func focus()
    /// Reports the tab selected by the browser so engine integrations can publish native lifecycle events.
    func setActive(_ active: Bool)
    /// Combines app-owned presentation with any prompt state owned by the engine.
    func setAppPromptPending(_ pending: Bool)
    /// Visibility is independent of selection: a selected tab can be in a hidden window.
    func setVisible(_ visible: Bool)
    func applyContentRules()
    func applySiteSettings()
    /// Requests a user-visible close. Engines that can refuse the request
    /// return false and retain the page. Internal retirement uses `close()`.
    func requestClose() async -> Bool
    /// Moves this live page to another native window without navigating or recreating it.
    func moveToWindow(_ windowID: UUID) throws
    /// Immediately invalidate callbacks; native teardown may complete later.
    func close()
    func waitUntilClosed() async
}

extension BrowserPage {
    var archiveFormat: PageArchiveFormat { .webArchive }
    var isLoading: Bool { state.isLoading }
    var canGoBack: Bool { state.canGoBack }
    var canGoForward: Bool { state.canGoForward }
    var errorMessage: String? { state.errorMessage }
    var hasPendingPrompt: Bool { state.hasPendingPrompt }
    var isCrashed: Bool { state.isCrashed }
    var favicon: NSImage? { state.favicon }
    func focus() { nativeView.window?.makeFirstResponder(nativeView) }
    func setActive(_ active: Bool) {}
    func setAppPromptPending(_ pending: Bool) { state.hasPendingPrompt = pending }
    func setVisible(_ visible: Bool) {}
    func snapshot() async throws -> NSImage { throw EngineError.unsupported(String(localized: "Page screenshots")) }
    func openLocalFile(_ url: URL) async throws { throw EngineError.unsupported(String(localized: "opening local files")) }
    func pageArchive() async throws -> Data { throw EngineError.unsupported(String(localized: "saving pages")) }
    func currentDOM() async throws -> String { throw EngineError.unsupported(String(localized: "viewing the current page DOM")) }
    func connectionDetails() async throws -> PageConnectionDetails? { nil }
    func setInspectable(_ enabled: Bool) {}
    func openDevTools(hostWindowID: UUID) throws -> any PageDevToolsSession {
        throw EngineError.unsupported(String(localized: "Developer Tools"))
    }
    func reloadFromOrigin() { state.errorMessage = EngineError.unsupported(String(localized: "Reload from Origin")).localizedDescription }
    func find(_ text: String) { find(text, backwards: false) }
    func requestClose() async -> Bool { true }
    func moveToWindow(_: UUID) throws { throw EngineError.unsupported(String(localized: "moving live tabs between windows")) }
    func setCapture(_ kind: PermissionKind, _ capture: PageCapture) {}
    @discardableResult func stopMediaCapture() -> Bool { false }
    func setAudioMuted(_ muted: Bool) throws { throw EngineError.unsupported(String(localized: "tab audio muting")) }
    func applySiteSettings() {}
}

/// One engine-owned developer-tools frontend hosted in an app-owned window.
@MainActor protocol PageDevToolsSession: AnyObject {
    var nativeView: NSView { get }
    var isClosed: Bool { get }
    var onClose: (() -> Void)? { get set }
    func focus()
    func setVisible(_ visible: Bool)
    @discardableResult func close() -> Bool
}

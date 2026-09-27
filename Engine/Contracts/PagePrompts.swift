import Foundation

/// Engine-neutral ownership for a native media decision. The adapter validates
/// its live native document before publishing; the browser revalidates its tab,
/// context, window and top-level origin before presentation.
@MainActor final class PageMediaPermissionRequest {
    let id: UUID
    let tabID: UUID
    let contextID: BrowsingContextID
    let windowID: UUID
    let documentID: String
    let frameID: String
    let kinds: Set<PermissionKind>
    let requestingOrigin: URL
    let embeddingOrigin: URL
    private var completion: ((SitePermission) -> Void)?

    init(id: UUID = UUID(), tabID: UUID, contextID: BrowsingContextID, windowID: UUID,
         documentID: String, frameID: String, kinds: Set<PermissionKind>,
         requestingOrigin: URL, embeddingOrigin: URL,
         completion: @escaping (SitePermission) -> Void) {
        self.id = id
        self.tabID = tabID
        self.contextID = contextID
        self.windowID = windowID
        self.documentID = documentID
        self.frameID = frameID
        self.kinds = kinds
        self.requestingOrigin = requestingOrigin
        self.embeddingOrigin = embeddingOrigin
        self.completion = completion
    }

    var isPending: Bool { completion != nil }
    func resolve(_ decision: SitePermission) {
        guard let completion else { return }
        self.completion = nil
        completion(decision)
    }
}

struct PagePromptIdentity {
    let tabID: UUID
    let contextID: BrowsingContextID
    let windowID: UUID
    /// Exact document/frame identity for document-owned prompts. Both are empty
    /// only when the prompt payload carries an explicit navigation/page context.
    let documentID: String
    let frameID: String
    let requestingOrigin: URL
    let topLevelOrigin: URL?
    /// The URL shown by the page while this document-owned prompt is active.
    /// This differs from `topLevelOrigin` during a pending cross-origin navigation.
    var visiblePageOrigin: URL? = nil
}
enum PageJavaScriptDialogKind: Equatable { case alert, confirm, prompt, beforeUnload, formRepost }
struct PageJavaScriptDialog {
    let kind: PageJavaScriptDialogKind
    let message: String
    let defaultText: String?
    let isReload: Bool
}
enum PageJavaScriptDialogResult { case accept(String?), cancel }
struct PageHTTPAuthChallenge {
    let requestURL: URL
    let scheme: String
    let realm: String?
    let isProxy: Bool
    let firstAttempt: Bool
    let primaryNavigation: Bool
}
struct PageHTTPAuthCredential { let username: String; let password: String }
enum PageFileChooserMode { case open, openMultiple, uploadFolder, openDirectory, save }
struct PageFileChooser {
    let mode: PageFileChooserMode
    let title: String?
    let defaultFilename: String?
    let acceptedTypes: [String]
}
struct PageExternalProtocolPrompt {
    let targetURL: URL
    let userGesture: Bool
    let primaryMainFrame: Bool
    let fencedFrame: Bool
}
struct PageClientCertificateChoice: Identifiable, Equatable, Sendable {
    let id: UUID
    let certificate: PageCertificateDetails
    let serialNumber: String?
}
enum PageClientCertificateContext: Equatable, Sendable {
    case document(documentID: String, frameID: String)
    case navigation(navigationID: String, primaryMainFrame: Bool)
    /// WebKit exposes only a page-level authentication challenge.
    case page(pageID: String)
}
struct PageClientCertificatePrompt: Equatable, Sendable {
    let choices: [PageClientCertificateChoice]
    let choicesTruncated: Bool
    let context: PageClientCertificateContext
}

@MainActor final class PagePromptRequest<Prompt, Result> {
    let id: UUID
    let identity: PagePromptIdentity
    let prompt: Prompt
    private var completion: ((Result) -> Void)?

    init(id: UUID = UUID(), identity: PagePromptIdentity, prompt: Prompt,
         completion: @escaping (Result) -> Void) {
        self.id = id; self.identity = identity; self.prompt = prompt; self.completion = completion
    }

    var isPending: Bool { completion != nil }
    func resolve(_ result: Result) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
    }
}

typealias PageJavaScriptDialogRequest = PagePromptRequest<PageJavaScriptDialog, PageJavaScriptDialogResult>
typealias PageHTTPAuthRequest = PagePromptRequest<PageHTTPAuthChallenge, PageHTTPAuthCredential?>
typealias PageFileChooserRequest = PagePromptRequest<PageFileChooser, [URL]?>
typealias PageExternalProtocolRequest = PagePromptRequest<PageExternalProtocolPrompt, Bool>
typealias PageClientCertificateRequest = PagePromptRequest<PageClientCertificatePrompt, UUID?>

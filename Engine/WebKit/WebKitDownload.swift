import Security
import WebKit

@MainActor final class WebKitDownload: NSObject, EngineDownload, WKDownloadDelegate {
    let id = UUID()
    private var download: WKDownload?
    private let webView: WKWebView
    private weak var presentingWindow: NSWindow?
    private let clientCertificateSearchList: [SecKeychain]?
    private lazy var prompts = PagePresenter(window: { [weak self] in self?.presentingWindow })
    private var windowCloseObserver: NSObjectProtocol?
    private var pendingChallengeID: UUID?
    private var authenticationClosed = false
    private let originalRequest: URLRequest?
    private var observation: NSKeyValueObservation?
    private var retired = false
    private enum State { case downloading, pausing, paused(Data), resuming, cancelled }
    private var state = State.downloading
    private var pauseCompletion: ((Result<Void, Error>) -> Void)?
    private var cancelCompletions: [() -> Void] = []
    private var responseCanResume = false
    private var observedProgress = 0.0
    private var delegateResumeData: Data?
    private var resumeWasUsed = false
    var suggestedFilename: String { download?.originalRequest?.url?.lastPathComponent ?? originalRequest?.url?.lastPathComponent ?? "Download" }
    var window: NSWindow? { presentingWindow }
    var onProgress: ((Double?) -> Void)?
    var onDestination: ((String, @escaping (URL?) -> Void) -> Void)?
    var onFinish: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    init(_ download: WKDownload, webView: WKWebView,
         clientCertificateSearchList: [SecKeychain]? = nil, presentingWindow: NSWindow? = nil) {
        self.download = download
        self.webView = webView
        self.clientCertificateSearchList = clientCertificateSearchList
        self.presentingWindow = presentingWindow ?? webView.window
        originalRequest = download.originalRequest
        super.init()
        if let window = self.presentingWindow {
            windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.presentingWindow = nil
                    self?.cancelAuthenticationPrompt()
                }
            }
        }
    }
    func start() {
        if let download { observe(download) }
    }
    private func observe(_ download: WKDownload) {
        observation = nil
        download.delegate = self
        observation = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                guard download === self.download else { return }
                let fraction = download.progress.totalUnitCount > 0 ? download.progress.fractionCompleted : nil
                self.observedProgress = fraction ?? 0
                self.onProgress?(fraction)
            }
        }
    }
    func cancel(completion: @escaping () -> Void) {
        retired = true
        cancelAuthenticationPrompt()
        switch state {
        case .paused:
            state = .cancelled
            completion()
        case .pausing, .resuming:
            cancelCompletions.append(completion)
        case .downloading:
            state = .cancelled
            guard let download else { completion(); return }
            download.cancel { _ in completion() }
        case .cancelled:
            completion()
        }
    }
    private var isSafeHTTPGet: Bool {
        guard !retired, let request = originalRequest, let url = request.url,
              ["http", "https"].contains(url.scheme?.lowercased()), (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil, request.httpBodyStream == nil else { return false }
        return true
    }
    var canRetry: Bool { isSafeHTTPGet }
    var canPause: Bool {
        guard isSafeHTTPGet, !resumeWasUsed, responseCanResume, observedProgress > 0, observedProgress < 1,
              case .downloading = state else { return false }
        return true
    }
    var canResume: Bool {
        if case .paused = state { return !retired }
        return false
    }
    func pause(completion: @escaping (Result<Void, Error>) -> Void) {
        guard canPause, let download else { completion(.failure(EngineDownloadPauseError.unsupported)); return }
        state = .pausing
        delegateResumeData = nil
        pauseCompletion = completion
        download.cancel { [weak self] data in self?.finishPause(data) }
    }
    func resume(completion: @escaping (Result<Void, Error>) -> Void) {
        guard case .paused(let data) = state, !retired else {
            completion(.failure(EngineDownloadPauseError.unsupported)); return
        }
        state = .resuming
        webView.resumeDownload(fromResumeData: data) { [weak self] replacement in
            guard let self else { replacement.cancel { _ in }; return }
            guard !self.retired else {
                replacement.cancel { _ in self.finishCancellation() }
                completion(.failure(EngineDownloadPauseError.unsupported))
                return
            }
            self.download = replacement
            self.responseCanResume = false
            self.observedProgress = 0
            self.resumeWasUsed = true
            self.state = .downloading
            self.authenticationClosed = false
            self.observe(replacement)
            completion(.success(()))
        }
    }
    func retry(completion: @escaping ((any EngineDownload)?) -> Void) {
        guard canRetry, let request = originalRequest else { completion(nil); return }
        webView.startDownload(using: request) { [weak self] replacement in
            guard let self, !self.retired else {
                replacement.cancel { _ in completion(nil) }
                return
            }
            completion(WebKitDownload(replacement, webView: self.webView,
                clientCertificateSearchList: self.clientCertificateSearchList,
                presentingWindow: self.presentingWindow))
        }
    }
    func detach() {
        retired = true
        cancelAuthenticationPrompt()
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        windowCloseObserver = nil
        observation = nil; download?.delegate = nil
        onProgress = nil; onDestination = nil; onFinish = nil; onFailure = nil
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard download === self.download, let onDestination else { completionHandler(nil); return }
        responseCanResume = Self.canResume(response)
        onDestination(suggestedFilename, completionHandler)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard download === self.download, !retired else { return }
        authenticationClosed = true
        cancelAuthenticationPrompt()
        resumeWasUsed = false
        onFinish?()
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard download === self.download else { return }
        authenticationClosed = true
        cancelAuthenticationPrompt()
        switch state {
        case .pausing:
            delegateResumeData = resumeData
        case .downloading where download === self.download && !retired:
            if resumeWasUsed, let resumeData, !resumeData.isEmpty {
                state = .paused(resumeData)
                observation = nil
                self.download?.delegate = nil
                self.download = nil
            }
            onFailure?(error)
        default: break
        }
    }
    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard download === self.download, !retired, !authenticationClosed else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let challengeID = UUID()
        let previousID = pendingChallengeID
        pendingChallengeID = challengeID
        if let previousID { prompts.cancel(previousID) }
        guard download === self.download, !retired, !authenticationClosed,
              pendingChallengeID == challengeID else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let complete: @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = {
            [weak self] disposition, credential in
            if self?.pendingChallengeID == challengeID { self?.pendingChallengeID = nil }
            completionHandler(disposition, credential)
        }
        #if DEBUG && COBBLE_AUTH_FIXTURE
        if let credential = LoginSharingFixture.credential(for: challenge) {
            complete(.useCredential, credential)
            return
        }
        #endif
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            guard presentingWindow?.isVisible == true else {
                complete(.cancelAuthenticationChallenge, nil)
                return
            }
            WebKitPage.presentHTTPAuthentication(challenge, using: prompts, id: challengeID,
                isCurrent: { [weak self, weak download] in
                    guard let self, let download else { return false }
                    return !self.retired && !self.authenticationClosed && self.download === download
                        && self.pendingChallengeID == challengeID
                }, completionHandler: complete)
        case NSURLAuthenticationMethodClientCertificate:
            let available = WebKitPage.clientCertificateIdentities(
                acceptedIssuers: challenge.protectionSpace.distinguishedNames,
                searchList: clientCertificateSearchList)
            guard presentingWindow?.isVisible == true, !available.identities.isEmpty,
                  let origin = WebKitPage.origin(for: challenge.protectionSpace) else {
                complete(.cancelAuthenticationChallenge, nil)
                return
            }
            let credentials = Dictionary(uniqueKeysWithValues: available.identities.map { ($0.choice.id, $0) })
            prompts.chooseClientCertificate(id: challengeID, origin: origin.absoluteString,
                choices: available.identities.map(\.choice), truncated: available.truncated) { [weak self, weak download] choiceID in
                guard let self, let download, !self.retired, !self.authenticationClosed,
                      self.download === download,
                      self.pendingChallengeID == challengeID,
                      let choiceID, let selected = credentials[choiceID] else {
                    complete(.cancelAuthenticationChallenge, nil)
                    return
                }
                complete(.useCredential, URLCredential(identity: selected.identity,
                    certificates: selected.certificates, persistence: .none))
            }
        default:
            complete(.performDefaultHandling, nil)
        }
    }

    private func cancelAuthenticationPrompt() {
        pendingChallengeID = nil
        prompts.cancelAll()
    }

    private func finishPause(_ data: Data?) {
        guard case .pausing = state else { return }
        let completion = pauseCompletion
        pauseCompletion = nil
        guard let data = data ?? delegateResumeData, !data.isEmpty, !retired else {
            state = .cancelled
            completion?(.failure(EngineDownloadPauseError.unsupported))
            finishCancellation()
            return
        }
        state = .paused(data)
        observation = nil
        download?.delegate = nil
        download = nil
        completion?(.success(()))
    }

    private func finishCancellation() {
        let completions = cancelCompletions
        cancelCompletions.removeAll()
        completions.forEach { $0() }
    }

    static func canResume(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else { return false }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key).lowercased()] = String(describing: pair.value)
        }
        guard headers["accept-ranges"]?.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("bytes") == .orderedSame }) == true,
              Self.hasValidator(headers) else { return false }
        return response.statusCode == 200 || Self.hasContentRange(headers["content-range"])
    }

    private static func hasValidator(_ headers: [String: String]) -> Bool {
        if let etag = headers["etag"]?.trimmingCharacters(in: .whitespaces),
           etag.count > 2, !etag.lowercased().hasPrefix("w/"), etag.first == "\"", etag.last == "\"" {
            let opaque = etag.dropFirst().dropLast().unicodeScalars
            if !opaque.isEmpty && opaque.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E && $0.value != 0x22 }) { return true }
        }
        guard let value = headers["last-modified"]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
    }

    private static func hasContentRange(_ value: String?) -> Bool {
        guard let value else { return false }
        let parts = value.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "bytes" else { return false }
        let rangeAndTotal = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2 else { return false }
        let range = rangeAndTotal[0].split(separator: "-", omittingEmptySubsequences: false)
        guard range.count == 2, let start = UInt64(range[0]), let end = UInt64(range[1]), let total = UInt64(rangeAndTotal[1]) else { return false }
        return start <= end && end < total
    }
}

import AppKit

@MainActor protocol EngineDownload: AnyObject {
    var id: UUID { get }
    var suggestedFilename: String { get }
    var window: NSWindow? { get }
    /// Nil means the engine cannot determine the total byte count yet.
    var onProgress: ((Double?) -> Void)? { get set }
    var onDestination: ((String, @escaping (URL?) -> Void) -> Void)? { get set }
    var onFinish: (() -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func start()
    func cancel(completion: @escaping () -> Void)
    func detach()
    var canPause: Bool { get }
    var canResume: Bool { get }
    func pause(completion: @escaping (Result<Void, Error>) -> Void)
    func resume(completion: @escaping (Result<Void, Error>) -> Void)
    var canRetry: Bool { get }
    func retry(completion: @escaping ((any EngineDownload)?) -> Void)
}

extension EngineDownload {
    var canPause: Bool { false }
    var canResume: Bool { false }
    func pause(completion: @escaping (Result<Void, Error>) -> Void) { completion(.failure(EngineDownloadPauseError.unsupported)) }
    func resume(completion: @escaping (Result<Void, Error>) -> Void) { completion(.failure(EngineDownloadPauseError.unsupported)) }
    var canRetry: Bool { false }
    func retry(completion: @escaping ((any EngineDownload)?) -> Void) { completion(nil) }
}

enum EngineDownloadPauseError: LocalizedError {
    case unsupported
    var errorDescription: String? { String(localized: "This download cannot be paused or resumed.") }
}

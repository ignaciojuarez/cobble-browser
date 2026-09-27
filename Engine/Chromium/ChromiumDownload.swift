import AppKit
import CobbleChromium

@MainActor final class ChromiumEngineDownload: EngineDownload {
    let id = UUID()
    let suggestedFilename: String
    private let source: ChromiumDownload
    private weak var presentingWindow: NSWindow?
    private var started = false
    private var terminal = false
    var window: NSWindow? { presentingWindow }
    var onProgress: ((Double?) -> Void)?
    var onDestination: ((String, @escaping (URL?) -> Void) -> Void)?
    var onFinish: (() -> Void)?
    var onFailure: ((Error) -> Void)?

    init(_ source: ChromiumDownload, window: NSWindow?) {
        self.source = source
        suggestedFilename = source.suggestedFilename
        presentingWindow = window
    }

    func start() {
        guard !started else { return }
        started = true
        source.onProgress = { [weak self] received, total in
            guard let self, !self.terminal else { return }
            self.onProgress?(total > 0 ? Double(received) / Double(total) : nil)
        }
        source.onFinish = { [weak self] in
            guard let self, !self.terminal else { return }
            self.terminal = true
            self.onFinish?()
        }
        source.onFailure = { [weak self] error in
            guard let self, !self.terminal else { return }
            #if COBBLE_CHROMIUM_ABI4
            self.terminal = !self.source.canResume
            #else
            self.terminal = true
            #endif
            self.onFailure?(error)
        }
        guard let onDestination else {
            source.setDestination(nil)
            return
        }
        onDestination(suggestedFilename) { [weak source] url in
            source?.setDestination(url)
        }
    }

    func cancel(completion: @escaping () -> Void) {
        source.cancel { [source] in
            completion()
            source.release()
        }
    }

    #if COBBLE_CHROMIUM_ABI4
    var canPause: Bool { !terminal && source.canPause }
    var canResume: Bool { !terminal && source.canResume }
    func pause(completion: @escaping (Result<Void, Error>) -> Void) {
        do { try source.pause(); completion(.success(())) }
        catch { completion(.failure(chromiumEngineError(error))) }
    }
    func resume(completion: @escaping (Result<Void, Error>) -> Void) {
        do { try source.resume(); completion(.success(())) }
        catch { completion(.failure(chromiumEngineError(error))) }
    }
    #endif

    func detach() {
        terminal = true
        source.onProgress = nil
        source.onFinish = nil
        source.onFailure = nil
        source.release()
        onProgress = nil
        onDestination = nil
        onFinish = nil
        onFailure = nil
    }
}

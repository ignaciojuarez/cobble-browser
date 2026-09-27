import AppKit
import Observation

enum DownloadStatus: String {
    case choosingDestination = "Choose Destination"
    case downloading = "Downloading"
    case paused = "Paused"
    case finished = "Finished"
    case cancelled = "Cancelled"
    case failed = "Failed"

    var label: String {
        switch self {
        case .choosingDestination: String(localized: "Choose Destination")
        case .downloading: String(localized: "Downloading")
        case .paused: String(localized: "Paused")
        case .finished: String(localized: "Finished")
        case .cancelled: String(localized: "Cancelled")
        case .failed: String(localized: "Failed")
        }
    }

    var isActive: Bool { self == .choosingDestination || self == .downloading || self == .paused }
    var needsAttention: Bool { isActive }
}

@MainActor
@Observable
final class DownloadItem: Identifiable {
    let id = UUID()
    var name: String
    var status: DownloadStatus = .choosingDestination
    var progress: Double?
    var destinationURL: URL?
    var errorMessage: String?
    var isRetrying = false
    var isPausing = false
    var isResuming = false
    var retainsPauseState = false
    let isPrivate: Bool

    init(name: String, isPrivate: Bool) {
        self.name = name
        self.isPrivate = isPrivate
    }
}

@MainActor
@Observable
final class DownloadStore {
    private let preferences: BrowserPreferences
    private(set) var entries: [DownloadItem] = []
    @ObservationIgnored private var downloads: [UUID: any EngineDownload] = [:]
    @ObservationIgnored private var cancelPanels: [UUID: () -> Void] = [:]
    @ObservationIgnored private var temporaryURLs: [UUID: URL] = [:]
    @ObservationIgnored private var scopedURLs: [UUID: URL] = [:]
    @ObservationIgnored private var replacementApproved: Set<UUID> = []
    @ObservationIgnored private var panelFolders: [UUID: URL] = [:]
    private var operationTokens: [UUID: UUID] = [:]
    private var cancellingIDs: Set<UUID> = []
    @ObservationIgnored private var cancellationSteps: [UUID: Int] = [:]
    @ObservationIgnored private var cancellationWaiters: [UUID: [() -> Void]] = [:]

    init(preferences: BrowserPreferences) { self.preferences = preferences }

    func accept(_ download: any EngineDownload, isPrivate: Bool) {
        guard !downloads.values.contains(where: { $0.id == download.id }) else { return }
        let item = DownloadItem(name: Self.safeFilename(download.suggestedFilename), isPrivate: isPrivate)
        entries.insert(item, at: 0)
        downloads[item.id] = download
        download.onProgress = { [weak item] progress in
            guard let item, item.status.isActive else { return }
            item.progress = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        }
        download.onDestination = { [weak self] name, completion in
            guard let self else { completion(nil); return }
            self.chooseDestination(id: item.id, suggestedFilename: name, completionHandler: completion)
        }
        download.onFinish = { [weak self] in self?.finish(id: item.id) }
        download.onFailure = { [weak self] error in self?.fail(id: item.id, error: error) }
        download.start()
    }

    func cancel(id: UUID) {
        guard let item = entries.first(where: { $0.id == id }),
              item.status.needsAttention || operationTokens[id] != nil,
              let download = downloads[id], cancellingIDs.insert(id).inserted else { return }
        cancellationSteps[id] = operationTokens.removeValue(forKey: id) == nil ? 1 : 2
        item.isRetrying = false
        item.status = .cancelled
        cancelPanels.removeValue(forKey: id)?()
        download.cancel { [weak self] in self?.finishCancellationStep(id: id) }
    }

    func retry(id: UUID) {
        guard let item = entries.first(where: { $0.id == id }), item.status == .failed,
              operationTokens[id] == nil, let download = downloads[id], download.canRetry else { return }
        let token = beginOperation(id)
        item.isRetrying = true
        download.retry { [weak self] replacement in
            guard let self else {
                replacement?.cancel { replacement?.detach() }
                return
            }
            if self.cancellingIDs.contains(id) {
                self.finishPendingRetryCancellation(id: id, replacement: replacement)
                return
            }
            guard self.finishOperation(id, token) else {
                replacement?.cancel { replacement?.detach() }
                return
            }
            guard let item = self.entries.first(where: { $0.id == id }), item.status == .failed else {
                replacement?.cancel { replacement?.detach() }
                return
            }
            guard let replacement else {
                item.isRetrying = false
                return
            }
            item.isRetrying = false
            self.entries.removeAll { $0.id == id }
            self.release(id: id)
            self.accept(replacement, isPrivate: item.isPrivate)
        }
    }

    func pause(id: UUID) {
        guard let item = entries.first(where: { $0.id == id }), item.status == .downloading,
              let download = downloads[id], download.canPause, operationTokens[id] == nil else { return }
        let token = beginOperation(id)
        item.isPausing = true
        download.pause { [weak self] result in
            guard let self else { return }
            item.isPausing = false
            if self.cancellingIDs.contains(id) {
                self.finishCancellationStep(id: id)
                return
            }
            guard self.finishOperation(id, token) else { return }
            switch result {
            case .success:
                item.status = .paused
                item.retainsPauseState = true
                item.errorMessage = nil
            case .failure(let error):
                item.status = .failed
                item.errorMessage = String(format: String(localized: "Could not pause the download: %@"), error.localizedDescription)
                // No native resume data means the partial transfer is terminal. Its
                // private staging directory and scoped authorization must not outlive it.
                self.release(id: id)
            }
        }
    }

    func resume(id: UUID) {
        guard let item = entries.first(where: { $0.id == id }), item.status == .paused,
              let download = downloads[id], download.canResume, operationTokens[id] == nil else { return }
        let token = beginOperation(id)
        item.isResuming = true
        item.retainsPauseState = true
        item.errorMessage = nil
        download.resume { [weak self] result in
            guard let self else { return }
            item.isResuming = false
            if self.cancellingIDs.contains(id) {
                self.finishCancellationStep(id: id)
                return
            }
            guard self.finishOperation(id, token) else { return }
            switch result {
            case .success: item.status = .downloading
            case .failure(let error): item.errorMessage = String(format: String(localized: "Could not resume the download: %@"), error.localizedDescription)
            }
        }
    }

    func open(id: UUID) {
        guard let item = entries.first(where: { $0.id == id }), item.status == .finished,
              let url = item.destinationURL else { return }
        if !NSWorkspace.shared.open(url) { item.errorMessage = String(localized: "The downloaded file could not be opened.") }
    }

    func reveal(id: UUID) {
        guard let item = entries.first(where: { $0.id == id }), item.status == .finished,
              let url = item.destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func removeCompleted() {
        let ids = entries.filter { ($0.status == .finished || $0.status == .cancelled) &&
            operationTokens[$0.id] == nil && !cancellingIDs.contains($0.id) }.map(\.id)
        entries.removeAll { ($0.status == .finished || $0.status == .cancelled) &&
            operationTokens[$0.id] == nil && !cancellingIDs.contains($0.id) }
        ids.forEach { release(id: $0) }
    }

    var activeCount: Int { entries.filter { $0.status.needsAttention || operationTokens[$0.id] != nil || cancellingIDs.contains($0.id) }.count }
    func canRetry(id: UUID) -> Bool { operationTokens[id] == nil && downloads[id]?.canRetry == true }
    func canPause(id: UUID) -> Bool { operationTokens[id] == nil && downloads[id]?.canPause == true }
    func canResume(id: UUID) -> Bool { operationTokens[id] == nil && downloads[id]?.canResume == true }

    static func quitWarning(activeCount: Int) -> (title: String, message: String)? {
        switch activeCount {
        case 0: nil
        case 1: (String(localized: "A download is in progress"), String(localized: "Quitting cancels it and waits for it to stop. Finished files stay on disk."))
        default: (String(format: String(localized: "%@ downloads are in progress"), "\(activeCount)"), String(localized: "Quitting cancels unfinished downloads and waits for them to stop. Finished files stay on disk."))
        }
    }

    private func chooseDestination(id: UUID, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let item = entries.first(where: { $0.id == id }), item.status.isActive,
              let download = downloads[id] else { completionHandler(nil); return }
        if let temporary = temporaryURLs[id], item.destinationURL != nil {
            completionHandler(temporary)
            return
        }
        item.name = Self.safeFilename(suggestedFilename)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        if let folder = preferences.beginDownloadFolder() {
            panel.directoryURL = folder
            panelFolders[id] = folder
        } else {
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            if preferences.downloadFolderName != nil { item.errorMessage = preferences.errorMessage }
        }
        panel.canCreateDirectories = true
        panel.title = String(localized: "Save Download")
        cancelPanels[id] = {
            panel.cancel(nil)
            completionHandler(nil)
        }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] result in
            guard let self else { return }
            let folder = self.panelFolders.removeValue(forKey: id)
            defer { if let folder { self.preferences.endDownloadFolder(folder) } }
            guard self.cancelPanels.removeValue(forKey: id) != nil else { return }
            guard result == .OK, let destination = panel.url, destination.isFileURL, item.status.isActive else {
                item.status = .cancelled
                completionHandler(nil)
                self.release(id: id)
                return
            }
            item.destinationURL = destination
            item.name = destination.lastPathComponent
            if destination.startAccessingSecurityScopedResource() { self.scopedURLs[id] = destination }
            if FileManager.default.fileExists(atPath: destination.path) { self.replacementApproved.insert(id) }
            do {
                // Keep the approved filename for the engine's file-type checks, but
                // stage bytes separately so a failed transfer preserves an existing file.
                self.temporaryURLs[id] = try Self.makeStagingURL(for: destination)
                item.status = .downloading
                item.errorMessage = nil
                completionHandler(self.temporaryURLs[id])
            } catch {
                item.status = .failed
                item.errorMessage = String(format: String(localized: "Could not prepare the download: %@"), error.localizedDescription)
                completionHandler(nil)
                self.release(id: id)
            }
        }
        if let window = download.window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    private func finish(id: UUID) {
        guard !cancellingIDs.contains(id) else { return }
        guard let item = entries.first(where: { $0.id == id }), item.status == .downloading,
              let temporary = temporaryURLs[item.id], let destination = item.destinationURL else { return }
        do {
            try Self.finalizeDownload(from: temporary, to: destination, replacementApproved: replacementApproved.contains(item.id))
            item.status = .finished
            item.retainsPauseState = false
            item.progress = 1
        } catch {
            item.status = .failed
            item.errorMessage = String(format: String(localized: "Could not save the download: %@"), error.localizedDescription)
        }
        release(id: item.id)
    }

    static func makeStagingURL(for destination: URL) throws -> URL {
        let manager = FileManager.default
        let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: destination.deletingLastPathComponent(), create: true)
        return directory.appendingPathComponent(destination.lastPathComponent)
    }

    static func finalizeDownload(from temporary: URL, to destination: URL, replacementApproved: Bool) throws {
        if replacementApproved, FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            // A newly created collision fails instead of replacing an unapproved file.
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private func fail(id: UUID, error: Error) {
        guard let item = entries.first(where: { $0.id == id }) else { return }
        guard !cancellingIDs.contains(id), item.status != .cancelled else { return }
        if item.isRetrying { return }
        if operationTokens.removeValue(forKey: id) != nil {
            item.isPausing = false
            item.isResuming = false
        }
        if downloads[id]?.canResume == true {
            item.status = .paused
            item.isResuming = false
            item.errorMessage = item.retainsPauseState
                ? String(format: String(localized: "Could not resume the download: %@"), error.localizedDescription)
                : error.localizedDescription
            item.retainsPauseState = true
        } else if item.status != .cancelled {
            item.status = .failed
            item.errorMessage = error.localizedDescription
            release(id: id, retainingDownload: downloads[id]?.canRetry == true)
        }
    }

    func cancelAll() async {
        for id in entries.map(\.id) where entries.contains(where: { $0.id == id && ($0.status.needsAttention || operationTokens[id] != nil || cancellingIDs.contains(id)) }) {
            if !cancellingIDs.contains(id) { cancel(id: id) }
            await waitForCancellation(id: id)
        }
    }

    private func release(id: UUID, retainingDownload: Bool = false) {
        operationTokens.removeValue(forKey: id)
        cancelPanels.removeValue(forKey: id)?()
        if !retainingDownload { downloads.removeValue(forKey: id)?.detach() }
        // Each staging URL owns a unique private directory. Engines report completion
        // or cancellation only after their file work has stopped.
        if let temporary = temporaryURLs.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
        }
        scopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        replacementApproved.remove(id)
    }

    private func beginOperation(_ id: UUID) -> UUID {
        let token = UUID()
        operationTokens[id] = token
        return token
    }

    private func finishOperation(_ id: UUID, _ token: UUID) -> Bool {
        guard operationTokens[id] == token else { return false }
        operationTokens.removeValue(forKey: id)
        return true
    }

    private func waitForCancellation(id: UUID) async {
        guard cancellingIDs.contains(id) else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters[id, default: []].append { continuation.resume() }
        }
    }

    private func finishPendingRetryCancellation(id: UUID, replacement: (any EngineDownload)?) {
        guard let replacement else { finishCancellationStep(id: id); return }
        replacement.cancel { [weak self, replacement] in
            replacement.detach()
            self?.finishCancellationStep(id: id)
        }
    }

    private func finishCancellationStep(id: UUID) {
        guard let steps = cancellationSteps[id] else { return }
        guard steps > 1 else {
            cancellationSteps.removeValue(forKey: id)
            cancellingIDs.remove(id)
            release(id: id)
            let waiters = cancellationWaiters.removeValue(forKey: id) ?? []
            waiters.forEach { $0() }
            return
        }
        cancellationSteps[id] = steps - 1
    }

    static func safeFilename(_ suggested: String) -> String {
        let component = suggested.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let name = component.components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != ".." else { return "Download" }
        var bytes = 0
        let prefix = name.prefix { character in
            bytes += String(character).utf8.count
            return bytes <= 200
        }
        return prefix.isEmpty ? "Download" : String(prefix)
    }
}

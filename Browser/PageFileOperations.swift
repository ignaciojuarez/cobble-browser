import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class PageFileOperations {
    @ObservationIgnored weak var owner: BrowserWindowModel?
    private(set) var isReadingDOM = false
    private(set) var isSavingScreenshot = false
    private(set) var isSavingPage = false
    private(set) var isOpeningLocalFile = false
    @ObservationIgnored private var screenshotTask: Task<Void, Never>?
    @ObservationIgnored private var savePageTask: Task<Void, Never>?
    @ObservationIgnored private var domTask: Task<Void, Never>?
    @ObservationIgnored private var localFileTask: Task<Void, Never>?
    @ObservationIgnored private var screenshotPanel: NSSavePanel?
    @ObservationIgnored private var savePagePanel: NSSavePanel?
    @ObservationIgnored private var localFilePanel: NSOpenPanel?

    init(owner: BrowserWindowModel) { self.owner = owner }

    var hasPendingOperations: Bool {
        isSavingScreenshot || isSavingPage || isOpeningLocalFile || isReadingDOM
    }

    func saveScreenshot() {
        guard let owner else { return }
        guard !isSavingScreenshot else { return }
        guard owner.canPerform(.screenshot), let page = owner.selectedPage,
              let window = page.nativeView.window, window.attachedSheet == nil else {
            owner.addressError = String(localized: "Open a visible page before saving a screenshot.")
            return
        }
        owner.addressError = nil
        isSavingScreenshot = true
        screenshotTask = Task { [weak self, page, window] in
            guard let self else { return }
            defer { self.isSavingScreenshot = false; self.screenshotPanel = nil; self.screenshotTask = nil }
            do {
                let image = try await page.snapshot()
                guard !owner.isClosed, owner.selectedPage === page,
                      page.nativeView.window === window, window.isVisible else { return }
                guard window.attachedSheet == nil else {
                    owner.addressError = String(localized: "Finish the open dialog before saving a screenshot.")
                    return
                }
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    owner.addressError = String(localized: "Could not encode the page screenshot as PNG.")
                    return
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = String(localized: "Cobble Screenshot.png")
                panel.message = String(localized: "Save the visible page area. Content outside the viewport is not included.")
                screenshotPanel = panel
                guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url, !owner.isClosed else { return }
                do { try png.write(to: url, options: .atomic) }
                catch { owner.addressError = String(format: String(localized: "Could not save the screenshot: %@"), error.localizedDescription) }
            } catch {
                guard !owner.isClosed, owner.selectedPage === page else { return }
                owner.addressError = String(format: String(localized: "Could not save the screenshot: %@"), error.localizedDescription)
            }
        }
    }

    func openLocalFile() {
        guard let owner else { return }
        guard !owner.app.isDeletingProfile(owner.record.profileID) else { return }
        guard !isOpeningLocalFile, let window = owner.nativeWindow,
              window.isVisible, window.attachedSheet == nil else {
            owner.addressError = String(localized: "Open a visible window before choosing a local file.")
            return
        }
        let tabID = owner.selectedTab?.id
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Cobble can read only the file you choose. Linked local assets are not granted.")
        panel.prompt = String(localized: "Open")
        localFilePanel = panel
        isOpeningLocalFile = true
        owner.addressError = nil
        panel.beginSheetModal(for: window) { [weak self, weak owner] response in
            guard let self, let owner else { return }
            self.localFilePanel = nil
            guard response == .OK, let url = panel.url, !owner.isClosed,
                  !owner.app.isDeletingProfile(owner.record.profileID), owner.record.selectedTabID == tabID,
                  owner.nativeWindow === window else { self.isOpeningLocalFile = false; return }
            self.localFileTask = Task { [weak self] in
                guard let self else { return }
                defer { self.isOpeningLocalFile = false; self.localFileTask = nil }
                do { try await owner.acceptLocalFile(url, replacing: tabID) }
                catch where !owner.isClosed {
                    owner.addressError = String(format: String(localized: "Could not open the local file: %@"), error.localizedDescription)
                }
                catch {}
            }
        }
    }

    func savePage() {
        guard let owner else { return }
        guard !owner.app.isDeletingProfile(owner.record.profileID) else { return }
        guard !isSavingPage, let page = owner.selectedPage, let tabID = owner.selectedTab?.id,
              let window = page.nativeView.window, window.attachedSheet == nil else {
            owner.addressError = String(localized: "Open a visible page before saving it.")
            return
        }
        owner.addressError = nil
        isSavingPage = true
        savePageTask = Task { [weak self, page, window] in
            guard let self else { return }
            defer { self.isSavingPage = false; self.savePagePanel = nil; self.savePageTask = nil }
            do {
                let archive = try await page.pageArchive()
                guard !owner.isClosed, !owner.app.isDeletingProfile(owner.record.profileID), owner.record.selectedTabID == tabID,
                      owner.selectedPage === page, page.nativeView.window === window, window.isVisible else { return }
                guard window.attachedSheet == nil else {
                    owner.addressError = String(localized: "Finish the open dialog before saving the page.")
                    return
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType(filenameExtension: page.archiveFormat.filenameExtension) ?? .data]
                panel.nameFieldStringValue = "Cobble Page.\(page.archiveFormat.filenameExtension)"
                panel.message = String(localized: "Save an archive of the current live page. This is not the original response source.")
                savePagePanel = panel
                guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url, !owner.isClosed,
                      !owner.app.isDeletingProfile(owner.record.profileID), owner.record.selectedTabID == tabID,
                      owner.selectedPage === page else { return }
                do { try archive.write(to: url, options: .atomic) }
                catch { owner.addressError = String(format: String(localized: "Could not save the page archive: %@"), error.localizedDescription) }
            } catch {
                guard !owner.isClosed, !owner.app.isDeletingProfile(owner.record.profileID),
                      owner.record.selectedTabID == tabID, owner.selectedPage === page else { return }
                owner.addressError = String(format: String(localized: "Could not save the page archive: %@"), error.localizedDescription)
            }
        }
    }

    func viewCurrentDOM() {
        guard let owner else { return }
        guard !owner.isClosed, !isReadingDOM, !owner.app.isDeletingProfile(owner.record.profileID) else { return }
        guard let page = owner.selectedPage, let tabID = owner.selectedTab?.id, let window = page.nativeView.window else {
            owner.addressError = String(localized: "Open a visible page before viewing its current DOM.")
            return
        }
        owner.addressError = nil
        isReadingDOM = true
        domTask = Task { [weak self, page, window] in
            guard let self else { return }
            defer { self.isReadingDOM = false; self.domTask = nil }
            do {
                let dom = try await page.currentDOM()
                guard !owner.isClosed, !owner.app.isDeletingProfile(owner.record.profileID), owner.record.selectedTabID == tabID,
                      owner.selectedPage === page, page.nativeView.window === window, window.isVisible else { return }
                PagePresenter.showReadOnlyText(title: String(localized: "Current Page DOM"), text: dom)
            } catch {
                guard !owner.isClosed, !owner.app.isDeletingProfile(owner.record.profileID),
                      owner.record.selectedTabID == tabID, owner.selectedPage === page else { return }
                owner.addressError = String(format: String(localized: "Could not read the current page DOM: %@"), error.localizedDescription)
            }
        }
    }

    func cancelAll() {
        screenshotTask?.cancel()
        savePageTask?.cancel()
        domTask?.cancel()
        localFileTask?.cancel()
        screenshotTask = nil
        savePageTask = nil
        domTask = nil
        localFileTask = nil
        screenshotPanel?.cancel(nil)
        savePagePanel?.cancel(nil)
        localFilePanel?.cancel(nil)
        screenshotPanel = nil
        savePagePanel = nil
        localFilePanel = nil
        isSavingScreenshot = false
        isSavingPage = false
        isOpeningLocalFile = false
        isReadingDOM = false
    }
}

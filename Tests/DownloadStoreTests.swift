import XCTest
import Observation
import WebKit
import Darwin
@testable import Cobble

@MainActor
final class DownloadStoreTests: XCTestCase {
    private func withFiles(body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleDownloadTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("transfer"), directory.appendingPathComponent("destination"))
    }

    func testFinalizationMovesBytesToNewDestination() throws {
        try withFiles { temporary, destination in
            let bytes = Data("download".utf8)
            try bytes.write(to: temporary)
            try DownloadStore.finalizeDownload(from: temporary, to: destination, replacementApproved: false)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        }
    }

    func testStagingPreservesFilenameWithoutCreatingOrSharingTheTarget() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Invoice 2026.tar.gz")
        let first = try DownloadStore.makeStagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        let second = try DownloadStore.makeStagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }

        XCTAssertEqual(first.lastPathComponent, destination.lastPathComponent)
        XCTAssertEqual(second.lastPathComponent, destination.lastPathComponent)
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(
            try first.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject,
            try destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        )
        let permissions = try FileManager.default.attributesOfItem(atPath: first.deletingLastPathComponent().path)
        XCTAssertEqual((permissions[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
    }

    func testResumeMetadataRequiresByteTokenStrongValidatorAnd206ContentRange() {
        func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://cobble.test/file")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        XCTAssertTrue(WebKitDownload.canResume(response(200, ["Accept-Ranges": "bytes", "ETag": "\"v1\""])))
        XCTAssertFalse(WebKitDownload.canResume(response(200, ["Accept-Ranges": "xbytes", "ETag": "\"v1\""])))
        XCTAssertFalse(WebKitDownload.canResume(response(200, ["Accept-Ranges": "bytes", "ETag": "W/\"v1\""])))
        XCTAssertFalse(WebKitDownload.canResume(response(200, ["Accept-Ranges": "bytes", "ETag": "\"v1\",\"v2\""])))
        XCTAssertFalse(WebKitDownload.canResume(response(200, ["Accept-Ranges": "bytes", "Last-Modified": "not-a-date"])))
        XCTAssertFalse(WebKitDownload.canResume(response(200, ["Accept-Ranges": "bytes", "Last-Modified": "Wed, 21 Oct 2015 07:28:00 PST"])))
        XCTAssertFalse(WebKitDownload.canResume(response(206, ["Accept-Ranges": "bytes", "ETag": "\"v1\""])))
        XCTAssertFalse(WebKitDownload.canResume(response(206, ["Accept-Ranges": "bytes", "ETag": "\"v1\"", "Content-Range": "bytes 99-10/5"])))
        XCTAssertTrue(WebKitDownload.canResume(response(206, ["Accept-Ranges": "bytes", "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT", "Content-Range": "bytes 10-99/100"])))
    }

    func testWebKitBlobDownloadSurvivesPageClosureAndFinishesStagedBytes() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Cobble Fixture.txt")
        let staging = try DownloadStore.makeStagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        try await page.prepare()
        let finished = expectation(description: "WebKit transfer finishes after its page closes")
        var transfer: (any EngineDownload)?
        var destinationCount = 0
        var transferError: Error?
        page.events.onDownload = { download in
            XCTAssertNil(transfer)
            transfer = download
            download.onDestination = { name, completion in
                destinationCount += 1
                XCTAssertEqual(name, destination.lastPathComponent)
                completion(staging)
                page.close()
            }
            download.onFinish = { finished.fulfill() }
            download.onFailure = { error in
                transferError = error
                finished.fulfill()
            }
            download.start()
        }
        page.webView.loadHTMLString("""
            <!doctype html><meta charset="utf-8"><title>Download fixture</title>
            <script>
            window.onload = () => {
              const anchor = document.createElement('a');
              anchor.href = URL.createObjectURL(new Blob(['Cobble fixture bytes'], {type: 'text/plain'}));
              anchor.download = 'Cobble Fixture.txt';
              document.body.append(anchor);
              anchor.click();
            };
            </script><body>Isolated download fixture</body>
            """, baseURL: nil)
        await fulfillment(of: [finished], timeout: 15)
        if let transfer { await withCheckedContinuation { continuation in transfer.cancel { continuation.resume() } } }
        transfer?.detach()
        XCTAssertNil(transferError)
        XCTAssertEqual(destinationCount, 1)
        XCTAssertEqual(page.state.lifecycle, .closed)
        XCTAssertEqual(try Data(contentsOf: staging), Data("Cobble fixture bytes".utf8))
    }


    func testWebKitHTTPRetryCreatesANewDownloadFromSafeGET() async throws {
        let server = try LocalHTTPFixture { _ in
            .init(headers: ["Content-Type": "application/x-cobble-fixture"], body: "retried bytes")
        }
        try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleRetryDownload-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("retry.cobble")
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        try await page.prepare()
        let started = expectation(description: "download started")
        let failed = expectation(description: "first download failed")
        let finished = expectation(description: "retry finished")
        var retry: (any EngineDownload)?
        page.webView.startDownload(using: URLRequest(url: server.url("/retry.cobble"))) { nativeDownload in
            let transfer = WebKitDownload(nativeDownload, webView: page.webView)
            transfer.onDestination = { _, completion in completion(nil) }
            transfer.onFailure = { _ in
                XCTAssertTrue(transfer.canRetry)
                transfer.retry { replacement in
                    retry = replacement
                    guard let replacement else { return XCTFail("Expected retry download") }
                    replacement.onDestination = { _, completion in completion(destination) }
                    replacement.onFinish = { finished.fulfill() }
                    replacement.onFailure = { error in XCTFail("Unexpected retry failure: \(error)"); finished.fulfill() }
                    replacement.start()
                }
                failed.fulfill()
            }
            transfer.start()
            started.fulfill()
        }
        await fulfillment(of: [started, failed, finished], timeout: 15)
        retry?.detach()
        XCTAssertEqual(try Data(contentsOf: destination), Data("retried bytes".utf8))
        XCTAssertEqual(server.requests.count, 2)
    }

    func testWebKitPauseResumesLargeValidatedHTTPDownloadInItsOriginalStagingFile() async throws {
        let server = try ResumableHTTPFixture()
        try await server.start()
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleResumeDownload-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent("resume.bin")
        let page = WebKitPage(tabID: UUID(), dataStore: .nonPersistent()) { _, _, _ in }
        defer { page.close() }
        try await page.prepare()
        let paused = expectation(description: "download pauses with native resume data")
        let finished = expectation(description: "resumed download finishes")
        var transfer: WebKitDownload?
        var destinations: [URL] = []
        page.webView.startDownload(using: URLRequest(url: server.url())) { native in
            let candidate = WebKitDownload(native, webView: page.webView)
            transfer = candidate
            candidate.onDestination = { _, completion in destinations.append(staging); completion(staging) }
            candidate.onFinish = { finished.fulfill() }
            candidate.onFailure = { error in XCTFail("Unexpected resume failure: \(error)"); finished.fulfill() }
            candidate.start()
        }
        for _ in 0..<400 {
            if ((try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) >= 1_048_576 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(staging.resourceValues(forKeys: [.fileSizeKey]).fileSize), 1_048_576)
        XCTAssertTrue(try XCTUnwrap(transfer).canPause, "Pause needs validated byte-range metadata and partial progress")
        try XCTUnwrap(transfer).pause { result in
            if case .failure(let error) = result { XCTFail("Pause failed: \(error)") }
            paused.fulfill()
        }
        await fulfillment(of: [paused], timeout: 15)
        XCTAssertTrue(try XCTUnwrap(transfer).canResume)
        try XCTUnwrap(transfer).resume { result in
            if case .failure(let error) = result { XCTFail("Resume failed: \(error)") }
        }
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertEqual(try Data(contentsOf: staging), server.bytes)
        XCTAssertGreaterThanOrEqual(server.rangeOffsets.max() ?? 0, 1_048_576)
        XCTAssertGreaterThanOrEqual(server.requestCount, 2)
        XCTAssertEqual(destinations, [staging], "This SDK resumes into the retained file without another destination callback")
    }

    func testApprovedReplacementInstallsDownloadedBytes() throws {
        try withFiles { temporary, destination in
            try Data("old".utf8).write(to: destination)
            let bytes = Data("new".utf8)
            try bytes.write(to: temporary)
            try DownloadStore.finalizeDownload(from: temporary, to: destination, replacementApproved: true)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        }
    }

    func testFinalizationPreservesIncomingQuarantineMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleQuarantine-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("download.app")
        let key = "com.apple.quarantine"
        let incoming = Data("0081;00000000;CobbleFixture;incoming".utf8)
        func tag(_ url: URL, _ value: Data) {
            let result = value.withUnsafeBytes { setxattr(url.path, key, $0.baseAddress, value.count, 0, 0) }
            XCTAssertEqual(result, 0)
        }
        func tagValue(_ url: URL) -> Data? {
            let length = getxattr(url.path, key, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var result = Data(count: length)
            let read = result.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, length, 0, 0) }
            return read == length ? result : nil
        }

        let first = try DownloadStore.makeStagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: first.deletingLastPathComponent()) }
        try Data("first".utf8).write(to: first)
        tag(first, incoming)
        try DownloadStore.finalizeDownload(from: first, to: destination, replacementApproved: false)
        XCTAssertEqual(tagValue(destination), incoming)

        let second = try DownloadStore.makeStagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: second.deletingLastPathComponent()) }
        try Data("second".utf8).write(to: second)
        tag(destination, Data("0081;00000000;CobbleFixture;old".utf8))
        tag(second, incoming)
        try DownloadStore.finalizeDownload(from: second, to: destination, replacementApproved: true)
        XCTAssertEqual(tagValue(destination), incoming)
    }

    func testUnapprovedCollisionPreservesBothFiles() throws {
        try withFiles { temporary, destination in
            let original = Data("original".utf8), downloaded = Data("downloaded".utf8)
            try original.write(to: destination)
            try downloaded.write(to: temporary)
            XCTAssertThrowsError(try DownloadStore.finalizeDownload(from: temporary, to: destination, replacementApproved: false))
            XCTAssertEqual(try Data(contentsOf: destination), original)
            XCTAssertEqual(try Data(contentsOf: temporary), downloaded)
        }
    }

    func testFailedReplacementPreservesExistingDestination() throws {
        try withFiles { missingTransfer, destination in
            let original = Data("original".utf8)
            try original.write(to: destination)
            XCTAssertThrowsError(try DownloadStore.finalizeDownload(from: missingTransfer, to: destination, replacementApproved: true))
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }

    func testApprovedDestinationRemovedDuringTransferCanBeCreated() throws {
        try withFiles { temporary, destination in
            let bytes = Data("downloaded".utf8)
            try bytes.write(to: temporary)
            try DownloadStore.finalizeDownload(from: temporary, to: destination, replacementApproved: true)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
        }
    }

    func testQuitWarningNamesActiveTransfers() {
        XCTAssertNil(DownloadStore.quitWarning(activeCount: 0))
        XCTAssertEqual(DownloadStore.quitWarning(activeCount: 1)?.title, String(localized: "A download is in progress"))
        XCTAssertEqual(DownloadStore.quitWarning(activeCount: 1)?.message, String(localized: "Quitting cancels it and waits for it to stop. Finished files stay on disk."))
        XCTAssertEqual(
            DownloadStore.quitWarning(activeCount: 3)?.title,
            String(format: String(localized: "%@ downloads are in progress"), String(3))
        )
    }

    func testClearingFinishedAndCancelledDownloadsKeepsRetryableFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleClearDownloads-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let failed = PendingDownload(canRetry: true)
        store.accept(failed, isPrivate: false)
        failed.onFailure?(CocoaError(.fileWriteUnknown))
        let cancelled = PendingDownload()
        store.accept(cancelled, isPrivate: false)
        store.cancel(id: try XCTUnwrap(store.entries.first?.id))

        store.removeCompleted()

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.status, .failed)
    }

    func testCancellationInvalidatesPendingRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleDownloadRaces-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))

        let retrying = PendingDownload(canRetry: true)
        store.accept(retrying, isPrivate: false)
        retrying.onFailure?(CocoaError(.fileWriteUnknown))
        let retryID = store.entries[0].id
        store.retry(id: retryID)
        XCTAssertTrue(store.entries[0].isRetrying)
        XCTAssertEqual(store.activeCount, 1)
        store.cancel(id: retryID)
        XCTAssertFalse(store.entries[0].isRetrying)
        let lateReplacement = PendingDownload()
        retrying.finishRetry(lateReplacement)
        XCTAssertTrue(lateReplacement.cancelled)
        XCTAssertEqual(store.entries.first(where: { $0.id == retryID })?.status, .cancelled)
        XCTAssertEqual(store.activeCount, 0)
    }

    func testActiveCountObservationTracksRetryAndCancellationCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleDownloadObservation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let download = PendingDownload(canRetry: true, delaysCancellation: true)
        store.accept(download, isPrivate: false)
        download.onFailure?(CocoaError(.fileWriteUnknown))
        let id = try XCTUnwrap(store.entries.first?.id)
        let started = expectation(description: "Retry invalidates active count")
        withObservationTracking { _ = store.activeCount } onChange: { started.fulfill() }
        store.retry(id: id)
        await fulfillment(of: [started], timeout: 1)
        store.cancel(id: id)
        download.finishRetry(nil)
        let stopped = expectation(description: "Native cancellation invalidates active count")
        withObservationTracking { _ = store.activeCount } onChange: { stopped.fulfill() }
        download.finishCancellation()
        await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(store.activeCount, 0)
    }

    func testPendingCancellationKeepsTransferActiveUntilNativeTeardown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePendingCancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let download = PendingDownload(delaysCancellation: true)
        store.accept(download, isPrivate: false)
        let id = try XCTUnwrap(store.entries.first?.id)

        store.cancel(id: id)
        XCTAssertEqual(store.entries.first?.status, .cancelled)
        XCTAssertEqual(store.activeCount, 1)
        store.removeCompleted()
        XCTAssertEqual(store.entries.count, 1)

        var didFinish = false
        let cancellation = Task { @MainActor in
            await store.cancelAll()
            didFinish = true
        }
        await Task.yield()
        XCTAssertFalse(didFinish)
        XCTAssertEqual(download.cancelCount, 1)
        download.finishCancellation()
        await cancellation.value

        XCTAssertEqual(store.activeCount, 0)
        store.removeCompleted()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testCancellationWaitsForLateRetryReplacementTeardown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleRetryCancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let original = PendingDownload(canRetry: true)
        store.accept(original, isPrivate: false)
        original.onFailure?(CocoaError(.fileWriteUnknown))
        let id = try XCTUnwrap(store.entries.first?.id)
        store.retry(id: id)
        store.cancel(id: id)

        var didFinish = false
        let cancellation = Task { @MainActor in
            await store.cancelAll()
            didFinish = true
        }
        await Task.yield()
        XCTAssertFalse(didFinish)

        let replacement = PendingDownload(delaysCancellation: true)
        original.finishRetry(replacement)
        await Task.yield()
        XCTAssertTrue(replacement.cancelled)
        XCTAssertFalse(didFinish)
        replacement.finishCancellation()
        await cancellation.value
        XCTAssertTrue(didFinish)
        XCTAssertEqual(store.activeCount, 0)
    }

    func testPausedDownloadRemainsActiveAndResumesWithoutReplacingItsRow() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePauseDownload-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let download = PendingDownload(canPause: true)
        store.accept(download, isPrivate: true)
        let id = try XCTUnwrap(store.entries.first?.id)
        store.entries[0].status = .downloading

        store.pause(id: id)
        XCTAssertEqual(store.entries[0].status, .paused)
        XCTAssertEqual(store.activeCount, 1)
        XCTAssertTrue(store.canResume(id: id))
        store.resume(id: id)

        XCTAssertEqual(store.entries[0].id, id)
        XCTAssertEqual(store.entries[0].status, .downloading)
        XCTAssertEqual(store.activeCount, 1)
    }

    func testNaturalResumableInterruptionKeepsSameTransferDestinationAndQuitFence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleInterruptedDownload-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let download = PendingDownload(canPause: true)
        store.accept(download, isPrivate: true)
        let item = try XCTUnwrap(store.entries.first)
        let id = item.id
        let destination = directory.appendingPathComponent("fixture.txt")
        item.status = .downloading
        item.destinationURL = destination
        let interruption = CocoaError(.fileReadUnknown)

        download.onFailure?(interruption)

        XCTAssertEqual(item.id, id)
        XCTAssertEqual(item.status, .paused)
        XCTAssertEqual(item.destinationURL, destination)
        XCTAssertTrue(item.isPrivate)
        XCTAssertEqual(item.errorMessage, interruption.localizedDescription)
        XCTAssertEqual(store.activeCount, 1)
        XCTAssertNotNil(DownloadStore.quitWarning(activeCount: store.activeCount))
        XCTAssertTrue(store.canResume(id: id))

        store.resume(id: id)

        XCTAssertEqual(download.resumeCount, 1)
        XCTAssertEqual(store.entries.first?.id, id)
        XCTAssertEqual(store.entries.first?.destinationURL, destination)
        XCTAssertEqual(store.entries.first?.status, .downloading)
    }

    func testNaturalResumableInterruptionCanCancelSameTransfer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleInterruptedCancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let download = PendingDownload(canPause: true)
        store.accept(download, isPrivate: false)
        let id = try XCTUnwrap(store.entries.first?.id)
        store.entries[0].status = .downloading
        download.onFailure?(CocoaError(.fileReadUnknown))

        store.cancel(id: id)

        XCTAssertEqual(store.entries.first?.id, id)
        XCTAssertEqual(store.entries.first?.status, .cancelled)
        XCTAssertTrue(download.cancelled)
        XCTAssertEqual(store.activeCount, 0)
    }

    func testNaturalNonresumableInterruptionRemainsTerminal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleTerminalInterruption-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let download = PendingDownload()
        store.accept(download, isPrivate: false)
        store.entries[0].status = .downloading
        let interruption = CocoaError(.fileReadUnknown)

        download.onFailure?(interruption)

        XCTAssertEqual(store.entries.first?.status, .failed)
        XCTAssertEqual(store.entries.first?.errorMessage, interruption.localizedDescription)
        XCTAssertEqual(store.activeCount, 0)
        XCTAssertFalse(store.canResume(id: try XCTUnwrap(store.entries.first?.id)))
    }

    func testPauseWithoutNativeResumeDataFailsHonestly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePauseFailure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let download = PendingDownload(canPause: true, pauseSucceeds: false)
        store.accept(download, isPrivate: false)
        let id = try XCTUnwrap(store.entries.first?.id)
        store.entries[0].status = .downloading

        store.pause(id: id)

        XCTAssertEqual(store.entries[0].status, .failed)
        XCTAssertEqual(
            store.entries[0].errorMessage,
            String(format: String(localized: "Could not pause the download: %@"), String(localized: "This download cannot be paused or resumed."))
        )
        XCTAssertEqual(store.activeCount, 0)
    }

    func testPauseCancellationKeepsActiveCountUntilNativePauseAndCancellationFinish() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobblePauseCancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let download = PendingDownload(canPause: true, delaysPause: true, delaysCancellation: true)
        store.accept(download, isPrivate: false)
        let id = try XCTUnwrap(store.entries.first?.id)
        store.entries[0].status = .downloading

        store.pause(id: id)
        store.cancel(id: id)
        XCTAssertEqual(store.activeCount, 1)
        download.finishPause()
        XCTAssertEqual(store.activeCount, 1)
        download.finishCancellation()
        XCTAssertEqual(store.activeCount, 0)
    }

    func testResumedFailureWithNativeResumeDataReturnsToPausedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleResumeFailure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let download = PendingDownload(canPause: true)
        store.accept(download, isPrivate: false)
        let id = try XCTUnwrap(store.entries.first?.id)
        store.entries[0].status = .downloading
        store.pause(id: id)
        store.resume(id: id)
        download.onFailure?(CocoaError(.fileReadUnknown))

        XCTAssertEqual(store.entries[0].status, .paused)
        XCTAssertEqual(store.activeCount, 1)
        XCTAssertTrue(store.canResume(id: id))
    }

    func testFailureDuringDelayedResumeCannotBeRevivedByStaleCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleDelayedResumeFailure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let download = PendingDownload(canPause: true, delaysResume: true)
        store.accept(download, isPrivate: false)
        let id = try XCTUnwrap(store.entries.first?.id)
        store.entries[0].status = .downloading
        store.pause(id: id)
        store.resume(id: id)

        download.onFailure?(CocoaError(.fileReadUnknown))
        XCTAssertEqual(store.entries[0].status, .paused)
        XCTAssertFalse(store.entries[0].isResuming)
        XCTAssertTrue(store.entries[0].errorMessage?.contains("Could not resume") == true)

        download.finishResume()
        XCTAssertEqual(store.entries[0].status, .paused)
    }

    func testTerminalFailureDuringDelayedPauseCannotBeRevivedByStaleCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleDelayedPauseFailure-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let download = PendingDownload(canPause: true, delaysPause: true)
        store.accept(download, isPrivate: false)
        let id = try XCTUnwrap(store.entries.first?.id)
        store.entries[0].status = .downloading
        store.pause(id: id)
        download.resumeAvailable = false

        download.onFailure?(CocoaError(.fileReadUnknown))
        XCTAssertEqual(store.entries[0].status, .failed)
        XCTAssertFalse(store.entries[0].isPausing)
        XCTAssertEqual(store.activeCount, 0)

        download.finishPause()
        XCTAssertEqual(store.entries[0].status, .failed)
    }

    func testQuitWaitsForDelayedResumeReplacementCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleResumeCancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DownloadStore(preferences: BrowserPreferences(directory: directory))
        let download = PendingDownload(canPause: true, delaysResume: true, delaysCancellation: true)
        store.accept(download, isPrivate: false)
        let id = try XCTUnwrap(store.entries.first?.id)
        store.entries[0].status = .downloading
        store.pause(id: id)
        store.resume(id: id)

        var didFinish = false
        let quit = Task { @MainActor in await store.cancelAll(); didFinish = true }
        await Task.yield()
        XCTAssertEqual(store.activeCount, 1)
        XCTAssertFalse(didFinish)
        download.finishResume()
        XCTAssertEqual(store.activeCount, 1)
        XCTAssertFalse(didFinish)
        download.finishCancellation()
        await quit.value
        XCTAssertTrue(didFinish)
        XCTAssertEqual(store.activeCount, 0)
    }

    func testDownloadFilenamesCannotSupplyPaths() {
        XCTAssertEqual(DownloadStore.safeFilename("../../invoice.pdf"), "invoice.pdf")
        XCTAssertEqual(DownloadStore.safeFilename("C:\\folder\\invoice.pdf"), "invoice.pdf")
        XCTAssertEqual(DownloadStore.safeFilename(".."), "Download")
        XCTAssertEqual(DownloadStore.safeFilename("\n\u{0}"), "Download")
        XCTAssertEqual(DownloadStore.safeFilename("report:2026.pdf"), "report-2026.pdf")
        XCTAssertLessThanOrEqual(DownloadStore.safeFilename(String(repeating: "😀", count: 200)).utf8.count, 200)
        XCTAssertEqual(DownloadStore.safeFilename(String(repeating: "\u{301}", count: 300)), "Download")
    }

}

@MainActor private final class PendingDownload: EngineDownload {
    let id = UUID()
    let suggestedFilename = "fixture.txt"
    var window: NSWindow? { nil }
    var onProgress: ((Double?) -> Void)?
    var onDestination: ((String, @escaping (URL?) -> Void) -> Void)?
    var onFinish: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var cancelled = false
    private(set) var cancelCount = 0
    private let supportsRetry: Bool
    private let supportsPause: Bool
    private let pauseSucceeds: Bool
    private let delaysPause: Bool
    private let delaysResume: Bool
    private let delaysCancellation: Bool
    private var retryCompletion: (((any EngineDownload)?) -> Void)?
    private var cancellationCompletion: (() -> Void)?
    private var pauseCompletion: ((Result<Void, Error>) -> Void)?
    private var resumeCompletion: ((Result<Void, Error>) -> Void)?
    private(set) var resumeCount = 0
    var resumeAvailable = true

    init(canRetry: Bool = false, canPause: Bool = false, pauseSucceeds: Bool = true,
         delaysPause: Bool = false, delaysResume: Bool = false, delaysCancellation: Bool = false) {
        supportsRetry = canRetry
        supportsPause = canPause
        self.pauseSucceeds = pauseSucceeds
        self.delaysPause = delaysPause
        self.delaysResume = delaysResume
        self.delaysCancellation = delaysCancellation
    }
    func start() {}
    func cancel(completion: @escaping () -> Void) {
        cancelled = true; cancelCount += 1
        if delaysCancellation { cancellationCompletion = completion }
        else { completion() }
    }
    func finishCancellation() { cancellationCompletion?(); cancellationCompletion = nil }
    func detach() { onProgress = nil; onDestination = nil; onFinish = nil; onFailure = nil }
    var canRetry: Bool { supportsRetry }
    var canPause: Bool { supportsPause && !cancelled }
    var canResume: Bool { supportsPause && !cancelled && pauseSucceeds && resumeAvailable }
    func pause(completion: @escaping (Result<Void, Error>) -> Void) {
        if delaysPause { pauseCompletion = completion }
        else { completion(pauseSucceeds ? .success(()) : .failure(EngineDownloadPauseError.unsupported)) }
    }
    func finishPause() { pauseCompletion?(pauseSucceeds ? .success(()) : .failure(EngineDownloadPauseError.unsupported)); pauseCompletion = nil }
    func resume(completion: @escaping (Result<Void, Error>) -> Void) {
        resumeCount += 1
        if delaysResume { resumeCompletion = completion } else { completion(.success(())) }
    }
    func finishResume() { resumeCompletion?(.success(())); resumeCompletion = nil }
    func retry(completion: @escaping ((any EngineDownload)?) -> Void) { retryCompletion = completion }
    func finishRetry(_ result: (any EngineDownload)?) { retryCompletion?(result); retryCompletion = nil }
}

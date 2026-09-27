#if DEBUG
import XCTest
@testable import Cobble

final class ResourceMonitorTests: XCTestCase {
    private let process = DiagnosticProcess(pid: 123, group: "WebKit processes", role: "Content")
    private func counters(start: UInt64 = 1, time: Double = 1, cpu: UInt64 = 0) -> ResourceCounters {
        .init(identity: .init(pid: 123, start: start), time: time, memory: 100,
              cpu: cpu, read: cpu, written: cpu, wakeups: cpu)
    }
    func testDeltasDeduplicationAndPIDReplacement() {
        var sampler = ResourceSampler()
        let discovery = ProcessDiscovery(processes: [process, process])
        let first = sampler.sample(discovery, read: { _ in .success(self.counters()) })
        XCTAssertEqual(first.readings.count, 1)
        XCTAssertNil(first.cpu)
        let second = sampler.sample(discovery, read: { _ in .success(self.counters(time: 3, cpu: 1_000_000_000)) })
        XCTAssertEqual(second.cpu, 50)
        XCTAssertEqual(second.memory, 100)
        let replacement = sampler.sample(discovery, read: { _ in .success(self.counters(start: 2, time: 4)) })
        XCTAssertNil(replacement.cpu)
        XCTAssertNil(ResourceSampler.rate(0, 1, elapsed: 1))
        XCTAssertNil(ResourceSampler.rate(1, 0, elapsed: 0))
    }
    func testTrackingExitDeniedAccessAndReuseWithoutRediscovery() {
        var sampler = ResourceSampler()
        _ = sampler.sample(.init(processes: [process]), read: { _ in .success(self.counters()) })
        let retained = sampler.sample(.init(), read: { _ in .success(self.counters(time: 2)) })
        XCTAssertEqual(retained.readings.count, 1)
        let denied = sampler.sample(.init(), read: { _ in .failure(POSIXError(.EPERM)) })
        XCTAssertNil(denied.memory)
        XCTAssertTrue(denied.partial)
        XCTAssertNotNil(denied.readings.first?.error)
        let replacement = sampler.sample(.init(), read: { _ in .success(self.counters(start: 2)) })
        XCTAssertTrue(replacement.readings.isEmpty)
        _ = sampler.sample(.init(processes: [process]), read: { _ in .success(self.counters()) })
        let exited = sampler.sample(.init(), read: { _ in .failure(POSIXError(.ESRCH)) })
        XCTAssertTrue(exited.readings.isEmpty)
        let gone = sampler.sample(.init(), read: { _ in XCTFail("Exited process retained"); return .failure(POSIXError(.ESRCH)) })
        XCTAssertNil(gone.memory)
    }
    func testPartialTotalsAndBoundedHistory() {
        var sampler = ResourceSampler()
        let missing = DiagnosticProcess(pid: 456, group: "Chromium processes", role: "GPU")
        for tick in 0..<100 {
            let result = sampler.sample(.init(processes: [process, missing]), read: {
                $0 == 123 ? .success(self.counters()) : .failure(POSIXError(.EACCES))
            }, now: Double(tick))
            XCTAssertEqual(result.memory, 100)
            XCTAssertTrue(result.partial)
        }
        XCTAssertEqual(sampler.history.count, 60)
        _ = sampler.sample(.init(), read: { _ in .failure(POSIXError(.ESRCH)) }, now: 200)
        XCTAssertEqual(sampler.history.count, 1)
    }
    func testNativeHostCounters() throws {
        let value = try ResourceCounters.read(getpid()).get()
        XCTAssertEqual(value.identity.pid, getpid())
        XCTAssertGreaterThan(value.memory, 0)
        XCTAssertGreaterThan(value.identity.start, 0)
    }

    @MainActor func testBadgeSamplingIsSharedAndStopsAfterLastConsumer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([TestEngine(.webKit)]))
        defer { app.library.close(); try? FileManager.default.removeItem(at: directory) }
        let monitor = app.resources
        XCTAssertTrue(monitor === app.resources)
        let first = UUID(), second = UUID()
        monitor.setBadgeVisible(true, windowID: first)
        monitor.setBadgeVisible(true, windowID: second)
        XCTAssertNotNil(monitor.task)
        for _ in 0..<100 where monitor.history.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(monitor.history.isEmpty)
        XCTAssertNotEqual(monitor.memoryText, "Unavailable")
        monitor.setBadgeVisible(false, windowID: first)
        XCTAssertNotNil(monitor.task)
        monitor.show()
        monitor.panel?.close()
        XCTAssertNotNil(monitor.task, "Visible sidebar still needs readings")
        monitor.setBadgeVisible(false, windowID: second)
        XCTAssertNil(monitor.task)
        let stoppedCount = monitor.history.count
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(monitor.history.count, stoppedCount)
        await app.engines.shutdown()
    }

    @MainActor func testPanelReuseCloseAndPrivateWindowPageCounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = TestEngine(.webKit)
        let chromium = TestEngine(.init(rawValue: "chromium"))
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([engine, chromium]))
        defer { app.library.close(); try? FileManager.default.removeItem(at: directory) }
        let first = app.newWindow(url: URL(string: "http://127.0.0.1/fixture"))
        first.activateSelected()
        let panelCounts = ResourcePanelController(app: app)
        _ = panelCounts.collect()
        XCTAssertEqual(panelCounts.pageCounts["webkit"], 1)
        XCTAssertNil(panelCounts.pageCounts["chromium"])
        XCTAssertTrue(app.preferences.setDefaultEngine(chromium.id))
        let second = app.newWindow(isPrivate: true, url: URL(string: "http://127.0.0.1/private"))
        second.activateSelected()
        _ = panelCounts.collect()
        XCTAssertEqual(panelCounts.pageCounts["webkit"], 1)
        XCTAssertEqual(panelCounts.pageCounts["chromium"], 1)
        second.closePages()
        _ = panelCounts.collect()
        XCTAssertNil(panelCounts.pageCounts["chromium"])
        XCTAssertEqual(panelCounts.pageCounts["webkit"], 1)
        first.closePages()
        let panel = ResourcePanelController(app: app)
        panel.show()
        let original = panel.panel
        panel.show()
        XCTAssertTrue(panel.panel === original)
        XCTAssertNotNil(panel.task)
        panel.panel?.close()
        XCTAssertNil(panel.task)
        panel.show()
        XCTAssertTrue(panel.panel === original)
        panel.panel?.close()
        app.windows.forEach { $0.closePages() }
        await app.engines.shutdown()
    }
}
#endif

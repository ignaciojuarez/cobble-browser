#if DEBUG
import AppKit
import SwiftUI
import Observation

@MainActor @Observable final class ResourcePanelController: NSObject, NSWindowDelegate {
    private weak var app: AppModel?
    private(set) var panel: NSPanel?
    private(set) var task: Task<Void, Never>?
    var history: [ResourceSample] = []
    var pageCounts: [String: Int] = [:]
    var thermal = "Unknown"
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var badgeWindows: Set<UUID> = []
    private var needsSampling: Bool { panel?.isVisible == true || !badgeWindows.isEmpty }
    var memoryText: String { Self.memory(history.last?.memory) }

    static func memory(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        return value >= 1_073_741_824 ? String(format: "%.2f GiB", value / 1_073_741_824) : String(format: "%.0f MiB", value / 1_048_576)
    }

    func setBadgeVisible(_ visible: Bool, windowID: UUID) {
        if visible { badgeWindows.insert(windowID) } else { badgeWindows.remove(windowID) }
        if needsSampling { start() } else { stop() }
    }

    init(app: AppModel) {
        self.app = app
        super.init()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let sleep = note.name == NSWorkspace.willSleepNotification
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.sleeping = sleep
                    self.stop()
                    if !sleep, self.needsSampling { self.start() }
                }
            })
        }
    }

    func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 375),
                                styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "Resources"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: ResourcePanelView(model: self))
            panel.center()
            self.panel = panel
        }
        let reopening = panel?.isVisible != true
        panel?.makeKeyAndOrderFront(nil)
        if reopening { stop() }
        start()
    }

    func windowWillClose(_ notification: Notification) {
        if badgeWindows.isEmpty { stop() }
    }
    func stop() { task?.cancel(); task = nil }
    private func start() {
        guard task == nil, !sleeping else { return }
        history = []
        task = Task { [weak self] in
            var sampler = ResourceSampler()
            while !Task.isCancelled {
                guard let self, let app = self.app, self.needsSampling else { return }
                let input = self.collect()
                let providers = app.engines.engines.compactMap { ($0 as? any EngineResourceDiagnosing)?.resourceDiscovery }
                let current = sampler
                let updated = await Task.detached(priority: .utility) {
                    var discovery = input
                    for provider in providers {
                        let result = provider()
                        discovery.processes += result.processes
                        discovery.limitations += result.limitations
                    }
                    discovery.limitations = Array(Set(discovery.limitations)).sorted()
                    var next = current
                    _ = next.sample(discovery)
                    return next
                }.value
                guard !Task.isCancelled else { return }
                sampler = updated
                self.history = sampler.history
                switch ProcessInfo.processInfo.thermalState {
                case .nominal: self.thermal = "Nominal"
                case .fair: self.thermal = "Fair"
                case .serious: self.thermal = "Serious"
                case .critical: self.thermal = "Critical"
                @unknown default: self.thermal = "Unknown"
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func collect() -> ProcessDiscovery {
        var result = ProcessDiscovery(processes: [.init(pid: getpid(), group: "Shared host", role: "Cobble")],
                                      limitations: ["Measured footprint is summed across processes, not unique physical RAM."])
        guard let app else { return result }
        var counts: [String: Int] = [:]
        var seen = Set<ObjectIdentifier>()
        for page in app.windows.flatMap(\.resourcePages) where seen.insert(ObjectIdentifier(page)).inserted {
            counts[page.contextID.engineID.rawValue, default: 0] += 1
            if let diagnostic = page as? any PageResourceDiagnosing {
                let discovery = diagnostic.resourceProcesses
                result.processes += discovery.processes
                result.limitations += discovery.limitations
            }
        }
        pageCounts = counts
        return result
    }
}

struct ResourceMemoryBadge: View {
    let model: ResourcePanelController
    let windowID: UUID

    var body: some View {
        Button { model.show() } label: {
            Label(model.memoryText, systemImage: "memorychip")
                .font(.system(size: 12, weight: .medium)).monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("Measured app RAM. Click for Resources and coverage details.")
        .accessibilityLabel("Measured app RAM: \(model.memoryText). Open Resources")
        .onAppear { model.setBadgeVisible(true, windowID: windowID) }
        .onDisappear { model.setBadgeVisible(false, windowID: windowID) }
    }
}

private struct ResourcePanelView: View {
    let model: ResourcePanelController
    @State private var details = false
    private var sample: ResourceSample? { model.history.last }
    private func memory(_ value: Double?) -> String { ResourcePanelController.memory(value) }
    private func activityRate(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        if value < 1024 { return String(format: "%.0f B/s", value) }
        if value < 1_048_576 { return String(format: "%.1f KiB/s", value / 1024) }
        return String(format: "%.1f MiB/s", value / 1_048_576)
    }
    private func cpu(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "Unavailable" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                metric("Measured RAM", symbol: "memorychip", value: model.memoryText,
                       values: model.history.map(\.memory), color: .orange)
                metric("Measured CPU", symbol: "cpu", value: cpu(sample?.cpu),
                       values: model.history.map(\.cpu), color: .blue)
            }
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text("RAM").frame(width: 88, alignment: .trailing)
                    Text("CPU").frame(width: 80, alignment: .trailing)
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                engineRow("Shared", group: "Shared host", symbol: "square.stack.3d.up", color: .secondary)
                Divider()
                engineRow("WebKit", group: "WebKit processes", symbol: "safari", color: .blue,
                          tabs: model.pageCounts["webkit", default: 0])
                Divider()
                engineRow("Chrome", group: "Chromium processes", symbol: "globe", color: .orange,
                          tabs: model.pageCounts["chromium", default: 0])
            }
            .padding(14)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)))

            DisclosureGroup("Details", isExpanded: $details) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Coverage: \(sample?.memory == nil ? "unavailable" : "partial")")
                        Text("Shared is Cobble's main process. In Full builds, some Chromium code runs there too. Chrome measures its separate helper processes.")
                        Text("CPU 100% = one core. Missing counters are unavailable; measured totals may omit processes.")
                        Text("Thermal state: \(model.thermal)")
                        ForEach(sample?.limitations ?? [], id: \.self) { Text($0) }
                        ForEach(sample?.readings ?? [], id: \.process.pid) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(row.process.role) · PID \(row.process.pid)").fontWeight(.medium)
                                if let error = row.error { Text(error) }
                                Text("Read \(activityRate(row.read)) · Write \(activityRate(row.written))")
                                Text("Wakeups \(row.wakeups.map { String(format: "%.1f/s", $0) } ?? "Unavailable")")
                                if row.cpu == nil { Text("CPU rate unavailable until two readable samples.") }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 190).font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(.top, 10)
            }.font(.system(size: 13)).padding(.horizontal, 4)
        }.padding(16).frame(width: 420)
            .onChange(of: details) { _, expanded in
                model.panel?.setContentSize(NSSize(width: 420, height: expanded ? 585 : 375))
            }
    }

    private func engineRow(_ name: String, group: String, symbol: String, color: Color, tabs: Int? = nil) -> some View {
        let rows = sample?.readings.filter { $0.process.group == group } ?? []
        let subtotal = ResourceSample(time: 0, readings: rows, limitations: [])
        return HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(color).frame(width: 24)
            Text(name).fontWeight(.medium)
            if let tabs {
                Text("\(tabs)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(color.opacity(0.12), in: Capsule())
                    .foregroundStyle(color)
                    .help("\(tabs) instantiated \(name) tabs across all windows, including private tabs")
                    .accessibilityLabel("\(tabs) live tabs")
            }
            Spacer(minLength: 0)
            Text(memory(subtotal.memory)).frame(width: 88, alignment: .trailing)
            Text(cpu(subtotal.cpu)).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
        }.font(.system(size: 13)).monospacedDigit().padding(.vertical, 12)
    }

    private func metric(_ name: String, symbol: String, value: String, values: [Double?], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(name, systemImage: symbol)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(color)
            Text(value).font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Canvas { context, size in
                // Two samples per bar keep the full history legible in a small card.
                let bars: [Double?] = stride(from: 0, to: values.count, by: 2).map { index in
                    let pair = values[index..<min(index + 2, values.count)].compactMap { $0 }
                    return pair.isEmpty ? nil : pair.reduce(0, +) / Double(pair.count)
                }
                let maximum = max(bars.compactMap { $0 }.max() ?? 1, 1)
                let step = size.width / 30
                for (index, value) in bars.enumerated() {
                    guard let value else { continue }
                    let height = max(2, size.height * value / maximum)
                    let rectangle = CGRect(x: Double(index) * step, y: size.height - height,
                                           width: max(1, step - 1.5), height: height)
                    context.fill(Path(roundedRect: rectangle, cornerRadius: 1.5), with: .color(color.opacity(0.85)))
                }
            }.frame(height: 32).accessibilityLabel("\(name) measured history over the last 60 seconds")
            Text("Last 60 seconds").font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.16)))
    }
}
#endif

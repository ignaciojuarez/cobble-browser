#if DEBUG
import Foundation
import Darwin

struct ResourceIdentity: Hashable, Sendable {
    let pid: Int32
    let start: UInt64
}

struct ResourceCounters: Sendable {
    let identity: ResourceIdentity
    let time: Double
    let memory: UInt64
    let cpu: UInt64
    let read: UInt64
    let written: UInt64
    let wakeups: UInt64

    static func read(_ pid: Int32) -> Result<Self, POSIXError> {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        return .success(Self(identity: .init(pid: pid, start: usage.ri_proc_start_abstime),
                             time: ProcessInfo.processInfo.systemUptime, memory: usage.ri_phys_footprint,
                             cpu: usage.ri_user_time + usage.ri_system_time,
                             read: usage.ri_diskio_bytesread, written: usage.ri_diskio_byteswritten,
                             wakeups: usage.ri_interrupt_wkups))
    }
}

struct ResourceReading: Sendable {
    let process: DiagnosticProcess
    var counters: ResourceCounters?
    var cpu: Double?
    var read: Double?
    var written: Double?
    var wakeups: Double?
    var error: String?
}

struct ResourceSample: Sendable {
    let time: Double
    var readings: [ResourceReading]
    var limitations: [String]
    func total(_ value: (ResourceReading) -> Double?) -> Double? {
        let values = readings.compactMap(value)
        return values.isEmpty ? nil : values.reduce(0, +)
    }
    var memory: Double? { total { $0.counters.map { Double($0.memory) } } }
    var cpu: Double? { total { $0.cpu } }
    var partial: Bool { !limitations.isEmpty || readings.contains { $0.counters == nil || $0.cpu == nil } }
}

struct ResourceSampler: Sendable {
    private var tracked: [ResourceIdentity: DiagnosticProcess] = [:]
    private var previous: [ResourceIdentity: ResourceCounters] = [:]
    private(set) var history: [ResourceSample] = []

    static func rate(_ current: UInt64, _ previous: UInt64, elapsed: Double) -> Double? {
        guard elapsed > 0, current >= previous else { return nil }
        return Double(current - previous) / elapsed
    }

    mutating func sample(_ discovery: ProcessDiscovery,
                         read: (Int32) -> Result<ResourceCounters, POSIXError> = ResourceCounters.read,
                         now: Double = ProcessInfo.processInfo.systemUptime) -> ResourceSample {
        var candidates = Dictionary(grouping: discovery.processes, by: \.pid).mapValues { $0[0] }
        for process in tracked.values where candidates[process.pid] == nil { candidates[process.pid] = process }
        let discovered = Set(discovery.processes.map(\.pid))
        var readings: [ResourceReading] = []
        var next: [ResourceIdentity: ResourceCounters] = [:]
        var live: [ResourceIdentity: DiagnosticProcess] = [:]
        for process in candidates.values.sorted(by: { $0.pid < $1.pid }) {
            switch read(process.pid) {
            case .failure(let error):
                if error.code == .ESRCH { continue }
                // A denied read is still unknown; retain its known identity until exit is confirmed.
                for (id, old) in tracked where id.pid == process.pid { live[id] = old }
                readings.append(ResourceReading(process: process, error: "PID \(process.pid): \(error.localizedDescription)"))
            case .success(let counters):
                guard discovered.contains(process.pid) || tracked[counters.identity] != nil else { continue }
                live[counters.identity] = process
                var reading = ResourceReading(process: process, counters: counters)
                if let old = previous[counters.identity] {
                    let elapsed = counters.time - old.time
                    reading.cpu = Self.rate(counters.cpu, old.cpu, elapsed: elapsed).map { $0 / 1_000_000_000 * 100 }
                    reading.read = Self.rate(counters.read, old.read, elapsed: elapsed)
                    reading.written = Self.rate(counters.written, old.written, elapsed: elapsed)
                    reading.wakeups = Self.rate(counters.wakeups, old.wakeups, elapsed: elapsed)
                }
                next[counters.identity] = counters
                readings.append(reading)
            }
        }
        tracked = live; previous = next
        let result = ResourceSample(time: now, readings: readings, limitations: discovery.limitations)
        history.removeAll { now - $0.time >= 60 }
        history.append(result)
        if history.count > 60 { history.removeFirst(history.count - 60) }
        return result
    }
}
#endif

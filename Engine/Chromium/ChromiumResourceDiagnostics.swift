#if DEBUG
import Foundation
import Darwin

extension ChromiumEngine: EngineResourceDiagnosing {
    var resourceDiscovery: @Sendable () -> ProcessDiscovery {
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath()
        return { Self.discoverResources(bundle: bundle) }
    }

    nonisolated static func discoverResources(bundle: URL) -> ProcessDiscovery {
        var result = ProcessDiscovery(limitations: [
            "Chromium browser work shares Cobble's host process. Detached or broker services cannot be fully attributed."
        ])
        let required = proc_listallpids(nil, 0)
        guard required > 0 else {
            result.limitations.append("Chromium process enumeration unavailable."); return result
        }
        var pids = [Int32](repeating: 0, count: Int(required) + 128)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0, count < pids.count else {
            result.limitations.append("Chromium process enumeration incomplete."); return result
        }
        var info: [Int32: proc_bsdinfo] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var value = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout.size(ofValue: value))) == MemoryLayout.size(ofValue: value) {
                info[pid] = value
            }
        }
        let host = getpid()
        guard let hostInfo = info[host] else {
            result.limitations.append("Chromium host identity unavailable."); return result
        }
        func start(_ value: proc_bsdinfo) -> UInt64 { value.pbi_start_tvsec * 1_000_000 + value.pbi_start_tvusec }
        let root = bundle.appendingPathComponent("Contents/Frameworks").path + "/"
        for (pid, value) in info where pid != host && start(value) >= start(hostInfo) {
            var parent = Int32(value.pbi_ppid)
            var visited: Set<Int32> = [pid]
            while parent != host, let ancestor = info[parent], visited.insert(parent).inserted {
                parent = Int32(ancestor.pbi_ppid)
            }
            guard parent == host else { continue }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else {
                result.limitations.append("Descendant PID \(pid) executable path unavailable."); continue
            }
            let bytes = path.prefix(Int(length)).prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
            let executable = String(decoding: bytes, as: UTF8.self)
            guard !executable.isEmpty else {
                result.limitations.append("Descendant PID \(pid) executable path unavailable."); continue
            }
            let url = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
            guard url.path.hasPrefix(root), url.path.contains(" Helper"),
                  url.deletingLastPathComponent().lastPathComponent == "MacOS",
                  url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents",
                  let helper = Bundle(url: url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()),
                  helper.executableURL?.resolvingSymlinksInPath() == url else { continue }
            result.processes.append(.init(pid: pid, group: "Chromium processes", role: url.lastPathComponent))
        }
        return result
    }
}
#endif

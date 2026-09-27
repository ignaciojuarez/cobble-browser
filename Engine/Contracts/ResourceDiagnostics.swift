#if DEBUG
import Foundation

struct DiagnosticProcess: Sendable, Hashable {
    let pid: Int32
    let group: String
    let role: String
}

struct ProcessDiscovery: Sendable {
    var processes: [DiagnosticProcess] = []
    var limitations: [String] = []
}

@MainActor protocol PageResourceDiagnosing {
    var resourceProcesses: ProcessDiscovery { get }
}

@MainActor protocol EngineResourceDiagnosing {
    // Capture adapter configuration on the main actor; discovery runs off-thread.
    var resourceDiscovery: @Sendable () -> ProcessDiscovery { get }
}
#endif

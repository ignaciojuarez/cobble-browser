#if DEBUG && RESOURCE_DISCOVERY_FIXTURE
// Standalone native fixture, no SDK or Chromium runtime required:
// swiftc -D DEBUG -D RESOURCE_DISCOVERY_FIXTURE Engine/Contracts/ResourceDiagnostics.swift \
//   Engine/Chromium/ChromiumResourceDiagnostics.swift Tests/ChromiumResourceFixture.swift -o /tmp/cobble-resource-fixture
import Foundation

@MainActor final class ChromiumEngine {}

@main struct ChromiumResourceFixture {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("Contents/Frameworks/Chromium Helper.app")
        let executable = helper.appendingPathComponent("Contents/MacOS/Chromium Helper")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleExecutable": "Chromium Helper", "CFBundleIdentifier": "test.cobble.resource-helper",
            "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try plist.write(to: helper.appendingPathComponent("Contents/Info.plist"))
        let child = Process()
        child.executableURL = executable; child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["30"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        // No page or engine instance exists. The zero-tab helper still counts.
        let found = ChromiumEngine.discoverResources(bundle: root)
        precondition(found.processes.map(\.pid) == [child.processIdentifier])
        precondition(!found.limitations.isEmpty)
        child.terminate(); child.waitUntilExit()
        precondition(ChromiumEngine.discoverResources(bundle: root).processes.isEmpty)
        print("Chromium resource fixture passed: zero pages, bundled helper, unrelated child, exit")
    }
}
#endif

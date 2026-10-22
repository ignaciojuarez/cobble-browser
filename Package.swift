// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Pin the SDK matched to the packaged ABI 18 runtime with H.264/AAC support.
// An explicit local checkout remains available for SDK development and legacy checks.
let localSDKPath = ProcessInfo.processInfo.environment["COBBLE_CHROMIUM_SDK_PATH"]
    .flatMap { $0.isEmpty ? nil : $0 }
precondition(localSDKPath == nil || localSDKPath!.hasPrefix("/"),
             "COBBLE_CHROMIUM_SDK_PATH must be an absolute path to the development SDK")
let localSDKABI: Int = localSDKPath.map { path in
    let header = path + "/chromium/overlay/chrome/browser/ui/cobble/cobble_chromium.h"
    guard let source = try? String(contentsOfFile: header, encoding: .utf8),
          let line = source.split(separator: "\n").first(where: { $0.hasPrefix("#define CCS_ABI_VERSION ") }),
          let token = line.split(separator: " ").last,
          token.hasSuffix("u"),
          let value = Int(token.dropLast()), value > 0 else {
        preconditionFailure("Development SDK has no valid CCS_ABI_VERSION header")
    }
    return value
} ?? 18
precondition(localSDKABI == 18,
             "Unsupported development Chromium SDK ABI \(localSDKABI); this client supports ABI 18")
let chromiumSDK: Package.Dependency = localSDKPath.map {
    .package(name: "chrome-sdk", path: $0)
} ?? .package(url: "https://github.com/ignaciojuarez/chrome-sdk.git",
              revision: "dec9f5313e654b1d8bac53855ce37bde10cc4d6b")
let clientSettings: [SwiftSetting] = [.define("COBBLE_CHROMIUM_CLIENT")]
    + (ProcessInfo.processInfo.environment["COBBLE_AUTH_FIXTURE"] == "1" ? [.define("COBBLE_AUTH_FIXTURE", .when(configuration: .debug))] : [])

// The regular Xcode app remains the system-WebKit executable. This product
// builds Cobble's same native UI as the owned Chromium launcher's client.
let package = Package(
    name: "CobbleNativeClient",
    platforms: [.macOS("26.0")],
    products: [.library(name: "CobbleNativeClient", type: .dynamic, targets: ["CobbleNativeClient"])],
    dependencies: [chromiumSDK, .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0")],
    targets: [
        .target(name: "CobbleNativeClient",
                dependencies: [.product(name: "CobbleChromium", package: "chrome-sdk"),
                               .product(name: "Sparkle", package: "Sparkle")],
                path: ".",
                exclude: ["App/Info.plist", "App/Localizable.xcstrings", "App/Cobble.sdef", "App/es.lproj", "Tests", "Assets.xcassets", "Cobble.xcodeproj",
                          "AGENTS.md", "ARCHITECTURE.md", "DECISIONS.md", "FEATURES.md",
                          "ROADMAP.md", "CHANGELOG.md", "RESEARCH.md", "CHROMIUM.md", "Cobble.entitlements", "Scripts", "docs", "updates",
                          "AppIcon.icon", "t3.json", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md"],
                sources: ["App", "Browser", "Domain", "Engine", "Persistence", "UI"],
                resources: [.copy("Themes")],
                swiftSettings: clientSettings),
        .testTarget(name: "ChromiumAdapterTests",
                    dependencies: ["CobbleNativeClient"],
                    path: "Tests/Chromium",
                    swiftSettings: clientSettings),
    ]
)

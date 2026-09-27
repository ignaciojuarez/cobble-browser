import Foundation

protocol BrowserThemeProviding {
    var configuration: BrowserThemeConfiguration { get }
}

enum ThemeControlRole: String, Codable, CaseIterable, Sendable { case toolbar, navigation, space, inline }
enum SpacePreviewMode: String, Codable, CaseIterable, Sendable { case dots, selectedIconAndDots, icons }

enum BrowserWindowStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case flat, rounded, veryRounded
    var id: Self { self }
    var contentInset: Double { self == .flat ? 0 : 8 }
    var cornerRadius: Double {
        switch self {
        case .flat: 0
        case .rounded: 8
        case .veryRounded: 16
        }
    }
    var title: String {
        switch self {
        case .flat: String(localized: "Flat")
        case .rounded: String(localized: "Rounded")
        case .veryRounded: String(localized: "Very Rounded")
        }
    }
}

struct ThemeSurfaceConfiguration: Codable, Equatable, Sendable {
    enum Material: String, Codable, Sendable { case none, flat, glass }
    enum Shape: String, Codable, Sendable { case circle, capsule, roundedRectangle }
    var material: Material
    var shape: Shape
    var radius: Double
    var interactive: Bool
    var keepActive: Bool
    var fillOpacity: Double
    var strokeOpacity: Double
    var fillHex, strokeHex: String?
}

struct ThemeControlConfiguration: Codable, Equatable, Sendable {
    enum Weight: String, Codable, Sendable { case regular, medium, semibold, bold }
    var surface: ThemeSurfaceConfiguration
    var side: Double
    var iconSize: Double
    var font: BrowserChromeFont
    var weight: Weight
    var hideWhenDisabled: Bool
    var hoverOpacity: Double
    var hoverHex: String?
}

struct BrowserThemeConfiguration: Codable, Equatable, Sendable, BrowserThemeProviding {
    var configuration: Self { self }
    struct Colors: Codable, Equatable, Sendable {
        var selectedTab, hover, pin, selectedPin, selectedPinStroke: Double
    }
    struct Controls: Codable, Equatable, Sendable {
        var toolbar, navigation, space, inline: ThemeControlConfiguration
        subscript(role: ThemeControlRole) -> ThemeControlConfiguration {
            switch role {
            case .toolbar: toolbar
            case .navigation: navigation
            case .space: space
            case .inline: inline
            }
        }
    }
    struct Groups: Codable, Equatable, Sendable {
        var navigation, spaces: ThemeSurfaceConfiguration
    }
    struct SpacePreview: Codable, Equatable, Sendable {
        var mode: SpacePreviewMode
        var dotSize, inactiveOpacity: Double
        func showsIcon(selected: Bool) -> Bool { mode == .icons || (mode == .selectedIconAndDots && selected) }
    }
    var version: Int
    var accentHex: String?
    var font: BrowserChromeFont
    var loadingIndicator: TabLoadingIndicatorStyle
    var defaultWindowStyle: BrowserWindowStyle?
    var controlCornerRadius: Double
    var darkSidebar, primaryUsesAccent: Bool
    var folderIconSize: Double
    var primaryHex, chromeHex: String?
    var folderColorHex: String
    var sidebarHex: String?
    var colors: Colors
    var controls: Controls
    var groups: Groups
    var selectedTabSurface, hoveredTabSurface: ThemeSurfaceConfiguration
    var spacePreview: SpacePreview
    var symbols: [String: String]

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        func opacity(_ n: Double) -> Bool { n.isFinite && (0...1).contains(n) }
        func dimension(_ n: Double) -> Bool { n.isFinite && (0...100).contains(n) }
        func hex(_ s: String) -> Bool { s.utf8.count == 6 && s.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) } }
        let controls = ThemeControlRole.allCases.map { value.controls[$0] }
        let surfaces = controls.map(\.surface) + [value.groups.navigation, value.groups.spaces, value.selectedTabSurface, value.hoveredTabSurface]
        guard value.version == 1, value.accentHex.map(hex) ?? true, hex(value.folderColorHex), value.sidebarHex.map(hex) ?? true, value.primaryHex.map(hex) ?? true, value.chromeHex.map(hex) ?? true,
              [value.folderIconSize, value.controlCornerRadius, value.spacePreview.dotSize].allSatisfy(dimension),
              [value.colors.selectedTab, value.colors.hover, value.colors.pin, value.colors.selectedPin,
               value.colors.selectedPinStroke, value.spacePreview.inactiveOpacity].allSatisfy(opacity),
              controls.allSatisfy({ (16...64).contains($0.side) && (1...32).contains($0.iconSize) && opacity($0.hoverOpacity) && ($0.hoverHex.map(hex) ?? true) }),
              surfaces.allSatisfy({ dimension($0.radius) && opacity($0.fillOpacity) && opacity($0.strokeOpacity) && ($0.fillHex.map(hex) ?? true) && ($0.strokeHex.map(hex) ?? true) }),
              ["sidebar", "back", "forward", "reload", "stop", "add", "downloads", "folder"].allSatisfy({ value.symbols[$0]?.isEmpty == false }),
              value.controls.space.surface.material == .none else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}

extension BrowserThemePreset: BrowserThemeProviding {
    var configuration: BrowserThemeConfiguration { Self.configurations[self == .custom ? .legacy : self]! }

    private static let configurations: [Self: BrowserThemeConfiguration] = {
        Dictionary(uniqueKeysWithValues: [Self.native, .legacy, .retro].map { preset in
            let name = "CobbleTheme-\(preset.rawValue)"
            #if SWIFT_PACKAGE
            let url = Bundle.main.url(forResource: name, withExtension: "json")
                ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Themes")
            #else
            let url = Bundle.main.url(forResource: name, withExtension: "json")
            #endif
            do {
                guard let url else { throw CocoaError(.fileNoSuchFile) }
                return (preset, try BrowserThemeConfiguration.decode(Data(contentsOf: url)))
            } catch {
                preconditionFailure("Invalid bundled theme \(name): \(error)")
            }
        })
    }()
}

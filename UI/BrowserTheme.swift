import SwiftUI

enum ThemeMetrics { static let spacing: CGFloat = 8 }

enum ThemeIcon: String, Hashable {
    case sidebar, back, forward, reload, stop, add, downloads, folder
}

struct BrowserThemeStyle: Equatable {
    let configuration: BrowserThemeConfiguration
    let accent: Color

    init(provider: some BrowserThemeProviding, accent: Color) {
        configuration = provider.configuration
        self.accent = accent
    }

    var controlCornerRadius: CGFloat { configuration.controlCornerRadius }
    func innerCornerRadius(inset: CGFloat) -> CGFloat { max(0, controlCornerRadius - inset) }

    var selectedTab: Color { accent.opacity(configuration.colors.selectedTab) }
    var hover: Color { accent.opacity(configuration.colors.hover) }
    var pin: Color { accent.opacity(configuration.colors.pin) }
    var selectedPin: Color { accent.opacity(configuration.colors.selectedPin) }
    var selectedPinStroke: Color { accent.opacity(configuration.colors.selectedPinStroke) }
    @MainActor var folderColor: Color { Color(nsColor: BrowserPreferences.color(hex: configuration.folderColorHex)) }
    @MainActor var primary: Color {
        configuration.primaryHex.map { Color(nsColor: BrowserPreferences.color(hex: $0)) }
            ?? (configuration.primaryUsesAccent ? accent : .primary)
    }
    @MainActor var chromeBackground: Color {
        configuration.chromeHex.map { Color(nsColor: BrowserPreferences.color(hex: $0)) } ?? .clear
    }
    var controlWeight: Font.Weight { configuration.controls.toolbar.weight.swiftUI }
    @MainActor var sidebarBackground: Color {
        configuration.sidebarHex.map { Color(nsColor: BrowserPreferences.color(hex: $0)) } ?? .clear
    }
    func symbol(_ icon: ThemeIcon) -> String { configuration.symbols[icon.rawValue]! }
}

extension ThemeControlConfiguration.Weight {
    var swiftUI: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

extension BrowserChromeFont {
    var design: Font.Design {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

/// The same surface renders individual controls, selected rows, and control groups.
struct ThemeSurface: ViewModifier {
    let configuration: ThemeSurfaceConfiguration
    var tint: Color = .white
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fill: Color { configuration.fillHex.map { Color(nsColor: BrowserPreferences.color(hex: $0)) } ?? tint }
    private var stroke: Color { configuration.strokeHex.map { Color(nsColor: BrowserPreferences.color(hex: $0)) } ?? .white }

    var shape: AnyShape {
        switch configuration.shape {
        case .circle: AnyShape(Circle())
        case .capsule: AnyShape(Capsule())
        case .roundedRectangle: AnyShape(RoundedRectangle(cornerRadius: configuration.radius))
        }
    }

    func body(content: Content) -> some View {
        Group {
            switch configuration.material {
            case .none: content
            case .flat:
                content.background(fill.opacity(configuration.fillOpacity), in: shape)
                    .overlay(shape.stroke(stroke.opacity(configuration.strokeOpacity)).allowsHitTesting(false))
            case .glass:
                content.glassEffect(.clear.interactive(configuration.interactive && !reduceMotion), in: shape)
            }
        }
        .transformEnvironment(\.appearsActive) { if configuration.keepActive { $0 = true } }
    }
}

struct ThemeControlGroup<Content: View>: View {
    let configuration: ThemeSurfaceConfiguration
    @ViewBuilder var content: Content

    var body: some View {
        content.modifier(ThemeSurface(configuration: configuration))
    }
}

private struct BrowserThemeKey: EnvironmentKey {
    static let defaultValue = BrowserThemeStyle(provider: BrowserThemePreset.legacy, accent: .white)
}

extension EnvironmentValues {
    var browserTheme: BrowserThemeStyle {
        get { self[BrowserThemeKey.self] }
        set { self[BrowserThemeKey.self] = newValue }
    }
}

extension BrowserThemePreset {
    var title: String {
        switch self {
        case .native: String(localized: "Native")
        case .legacy: String(localized: "Legacy")
        case .retro: String(localized: "Retro")
        case .custom: String(localized: "Custom")
        }
    }
}

struct TabLoadingIndicator: View {
    let style: TabLoadingIndicatorStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch style {
            case .system:
                ProgressView().controlSize(.small)
            case .terminalSquares:
                if reduceMotion {
                    squares(active: nil)
                } else {
                    TimelineView(.animation(minimumInterval: 0.16)) { context in
                        squares(active: Int(context.date.timeIntervalSinceReferenceDate / 0.16) % 9)
                    }
                }
            }
        }
        .frame(width: 16, height: 16)
    }

    private func squares(active: Int?) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(3), spacing: 2), count: 3), spacing: 2) {
            ForEach(0..<9, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.secondary)
                    .frame(width: 3, height: 3)
                    .opacity(opacity(for: index, active: active))
            }
        }
        .frame(width: 13, height: 13)
    }

    private func opacity(for index: Int, active: Int?) -> Double {
        guard let active else { return 0.7 }
        return switch (active - index + 9) % 9 {
        case 0: 1
        case 1: 0.72
        case 2: 0.45
        default: 0.18
        }
    }
}

extension TabLoadingIndicatorStyle {
    var title: String {
        switch self {
        case .system: String(localized: "Default")
        case .terminalSquares: String(localized: "Terminal Squares")
        }
    }
    var accessibilityTitle: String {
        String(format: String(localized: "%@ progress indicator"), title)
    }
}

extension BrowserChromeFont {
    var title: String {
        switch self {
        case .system: String(localized: "System Default")
        case .rounded: String(localized: "Rounded")
        case .serif: String(localized: "Serif")
        case .monospaced: String(localized: "Monospaced")
        }
    }
    var swiftUIFont: Font? {
        switch self {
        case .system: nil
        case .rounded: .system(.body, design: .rounded)
        case .serif: .system(.body, design: .serif)
        case .monospaced: .system(.body, design: .monospaced)
        }
    }
    func font(for style: Font.TextStyle) -> Font {
        switch self {
        case .system: .system(style)
        case .rounded: .system(style, design: .rounded)
        case .serif: .system(style, design: .serif)
        case .monospaced: .system(style, design: .monospaced)
        }
    }
    var previewFont: Font { swiftUIFont ?? .body }
}

/// All sidebar controls use the same typography, geometry, hover, and glass rendering.
struct SidebarItemControl: ViewModifier {
    var tint: Color = .secondary
    var pointSize: CGFloat = 11
    var weight: Font.Weight = .semibold
    var side: CGFloat = 22
    var disabled = false
    var role: ThemeControlRole = .inline
    var highlighted = false
    @Environment(\.browserTheme) private var theme
    @State private var hovered = false

    func body(content: Content) -> some View {
        let configuration = theme.configuration.controls[role]
        let shape = ThemeSurface(configuration: configuration.surface).shape
        let hoverColor = configuration.hoverHex.map { Color(nsColor: BrowserPreferences.color(hex: $0)) } ?? theme.accent
        content.buttonStyle(.plain)
            .font(.system(size: role == .inline ? pointSize : configuration.iconSize,
                          weight: role == .inline ? weight : configuration.weight.swiftUI,
                          design: configuration.font.design))
            .foregroundStyle(tint)
            .frame(width: role == .inline ? side : configuration.side,
                   height: role == .inline ? side : configuration.side)
            .modifier(ThemeSurface(configuration: configuration.surface,
                                   tint: configuration.surface.material == .glass ? .white : .black))
            .contentShape(shape)
            .overlay {
                shape.fill(hoverColor.opacity(!disabled && (hovered || highlighted) ? configuration.hoverOpacity : 0))
                    .allowsHitTesting(false)
            }
            .opacity(disabled ? 0.45 : 1)
            .onHover { hovered = $0 }
            .transformEnvironment(\.appearsActive) { if configuration.surface.keepActive { $0 = true } }
    }
}

extension View {
    func sidebarItemControl(tint: Color = .secondary, pointSize: CGFloat = 11, weight: Font.Weight = .semibold,
                            side: CGFloat = 22, disabled: Bool = false, role: ThemeControlRole = .inline,
                            highlighted: Bool = false) -> some View {
        modifier(SidebarItemControl(tint: tint, pointSize: pointSize, weight: weight, side: side,
                                    disabled: disabled, role: role, highlighted: highlighted))
    }
}

struct SidebarItemButton: View {
    var systemImage: String
    var help: String
    var disabled = false
    var tint: Color = .secondary
    var pointSize: CGFloat = 11
    var weight: Font.Weight = .semibold
    var side: CGFloat = 22
    var role: ThemeControlRole = .inline
    var action: () -> Void
    @Environment(\.browserTheme) private var theme

    var body: some View {
        if !disabled || !theme.configuration.controls[role].hideWhenDisabled {
            let configuration = theme.configuration.controls[role]
            let buttonSide = role == .inline ? side : configuration.side
            Button(action: action) {
                Image(systemName: systemImage)
                    .frame(width: buttonSide, height: buttonSide)
                    .contentShape(ThemeSurface(configuration: configuration.surface).shape)
            }
            .disabled(disabled)
            .help(help)
            .accessibilityLabel(help)
            .sidebarItemControl(tint: tint, pointSize: pointSize, weight: weight, side: side, disabled: disabled, role: role)
        }
    }
}

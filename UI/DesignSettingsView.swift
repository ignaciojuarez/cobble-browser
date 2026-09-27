import SwiftUI

struct DesignSettingsView: View {
    @Bindable var preferences: BrowserPreferences

    var body: some View {
        SettingsPage {
            SettingsGroup("Theme") {
                HStack(spacing: 12) {
                    ForEach([BrowserThemePreset.native, .legacy, .retro]) { theme in
                        themeChoice(theme)
                    }
                }
                if preferences.theme == .custom {
                    Text("Custom, based on \(preferences.themeTemplate.title)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            SettingsGroup("Window style") {
                Text("Controls the page corners and the space around the page.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(BrowserWindowStyle.allCases) { style in
                        windowStyleChoice(style)
                    }
                }
            }
            SettingsGroup("Customize") {
                SettingsRow("Browser interface", detail: "Changes Cobble’s browser chrome, not the content of webpages.") {
                    Picker("Browser interface font", selection: Binding(
                        get: { preferences.browserChromeFont },
                        set: { preferences.setBrowserChromeFont($0) }
                    )) {
                        ForEach(BrowserChromeFont.allCases) { font in
                            Text(font.title).tag(font)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                Divider()
                SettingsRow("Accent color", detail: "Tabs, pins, previews, and hover states derive from this color.") {
                    ColorPicker("Accent color", selection: Binding(
                        get: { Color(nsColor: preferences.themeAccentColor) },
                        set: { preferences.setThemeAccentColor(NSColor($0)) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(preferences.browserChromeFont.previewFont)
                    .foregroundStyle(.secondary)
            }
            if let error = preferences.errorMessage {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private func themeChoice(_ preset: BrowserThemePreset) -> some View {
        let selected = preferences.themeTemplate == preset
        let style = BrowserThemeStyle(provider: preset, accent: Color(nsColor: BrowserPreferences.color(hex: preset.defaultAccentHex)))
        var controlSurface = style.configuration.controls.toolbar.surface
        var selectedSurface = style.configuration.selectedTabSurface
        controlSurface.interactive = false
        return Button {
            preferences.setTheme(preset)
        } label: {
            VStack(spacing: 8) {
                VStack(spacing: 5) {
                    HStack(spacing: 5) {
                        ForEach([ThemeIcon.sidebar, .back, .reload], id: \.self) { icon in
                            Image(systemName: style.symbol(icon))
                                .font(.system(size: 10, weight: style.controlWeight))
                                .frame(width: 22, height: 20)
                                .modifier(ThemeSurface(configuration: controlSurface))
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: style.symbol(.folder)).foregroundStyle(style.folderColor)
                        Color.clear.frame(height: 15)
                            .modifier(ThemeSurface(configuration: selectedSurface, tint: style.accent))
                    }
                }
                .foregroundStyle(style.primary)
                .transformEnvironment(\.colorScheme) { if style.configuration.darkSidebar { $0 = .dark } }
                .padding(8)
                .frame(width: 106, height: 68)
                .background(style.configuration.darkSidebar ? style.sidebarBackground : Color.primary.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: style.controlCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: style.controlCornerRadius)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint).padding(5)
                    }
                }
                Text(preset.title).font(.callout.weight(.medium))
            }
            .frame(width: 120)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(preset.title))
        .accessibilityValue(selected ? Text("Selected") : Text("Not selected"))
    }

    private func windowStyleChoice(_ style: BrowserWindowStyle) -> some View {
        let selected = preferences.windowStyle == style
        return Button {
            preferences.setWindowStyle(style)
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Circle().fill(.white.opacity(0.8)).frame(width: 5, height: 5)
                        Capsule().fill(.white.opacity(0.45)).frame(width: 13, height: 3)
                        Capsule().fill(.white.opacity(0.45)).frame(width: 13, height: 3)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 7).padding(.top, 9)
                    .frame(width: 28)
                    RoundedRectangle(cornerRadius: style.cornerRadius / 2)
                        .fill(.white.opacity(0.35))
                        .overlay(alignment: .topLeading) {
                            Capsule().fill(.white.opacity(0.5))
                                .frame(width: 34, height: 4)
                                .padding(9)
                        }
                        .padding(.vertical, style.contentInset / 2)
                        .padding(.trailing, style.contentInset / 2)
                }
                .frame(width: 106, height: 68)
                .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint).padding(5)
                    }
                }
                Text(style.title).font(.callout.weight(.medium))
            }
            .frame(width: 120)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(style.title))
        .accessibilityValue(selected ? Text("Selected") : Text("Not selected"))
    }
}

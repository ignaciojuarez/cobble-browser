import XCTest
import SwiftUI
@testable import Cobble

final class BrowserThemeTests: XCTestCase {
    @MainActor func testNativeGlassButtonsUseConfiguredSize() {
        let theme = BrowserThemeStyle(provider: BrowserThemePreset.native, accent: .white)
        let button = NSHostingView(rootView: SidebarItemButton(systemImage: "plus", help: "Add", role: .toolbar) {}
            .environment(\.browserTheme, theme))
        XCTAssertEqual(button.fittingSize.width, theme.configuration.controls.toolbar.side, accuracy: 0.5)
        XCTAssertEqual(button.fittingSize.height, theme.configuration.controls.toolbar.side, accuracy: 0.5)
    }

    func testBundledThemesRoundTripAndDefineEveryControl() throws {
        for preset in [BrowserThemePreset.native, .legacy, .retro] {
            let theme = preset.configuration
            XCTAssertEqual(try BrowserThemeConfiguration.decode(JSONEncoder().encode(theme)), theme)
            for role in ThemeControlRole.allCases {
                XCTAssertGreaterThan(theme.controls[role].side, 0)
            }
            XCTAssertEqual(theme.controls.space.surface.material, .none)
        }
        let native = BrowserThemePreset.native.configuration
        XCTAssertEqual(native.accentHex, BrowserThemePreset.legacy.configuration.accentHex)
        XCTAssertEqual(native.controls.toolbar.surface.shape, .circle)
        XCTAssertTrue(native.controls.toolbar.surface.interactive)
        XCTAssertTrue(native.controls.toolbar.surface.keepActive)
        XCTAssertTrue(native.controls.navigation.hideWhenDisabled)
        XCTAssertEqual(native.controls.navigation.surface.material, .none)
        XCTAssertEqual(native.groups.navigation.material, .glass)
        XCTAssertEqual(native.groups.spaces.shape, .capsule)
        XCTAssertEqual(native.selectedTabSurface.material, .glass)
        XCTAssertEqual(native.defaultWindowStyle, .veryRounded)
        XCTAssertEqual(BrowserThemePreset.legacy.configuration.defaultWindowStyle, .rounded)
        XCTAssertEqual(BrowserThemePreset.retro.configuration.defaultWindowStyle, .flat)
    }

    func testTerminalUsesKiwiPaletteAndThemeFolderDefault() {
        let terminal = BrowserThemePreset.retro.configuration
        XCTAssertEqual(terminal.accentHex, "FFFFFF")
        XCTAssertEqual(terminal.chromeHex, "070908")
        XCTAssertEqual(terminal.sidebarHex, "090C0A")
        XCTAssertEqual(terminal.primaryHex, "F2F3EF")
        XCTAssertEqual(terminal.folderColorHex, "929991")
        XCTAssertEqual(terminal.symbols["folder"], "diamond")
        XCTAssertNil(terminal.selectedTabSurface.fillHex)
        XCTAssertEqual(terminal.hoveredTabSurface.strokeHex, "252925")
        XCTAssertEqual(Folder().color, .theme)
        XCTAssertEqual(Folder(color: .blue).color, .blue)
    }

    func testOptionalAccentDefaultAndOverride() throws {
        for preset in [BrowserThemePreset.native, .legacy, .retro] {
            XCTAssertEqual(preset.defaultAccentHex, "FFFFFF")
        }
        var theme = BrowserThemePreset.retro.configuration
        theme.accentHex = nil
        XCTAssertNil(try BrowserThemeConfiguration.decode(JSONEncoder().encode(theme)).accentHex)
        theme.accentHex = "A8DC52"
        XCTAssertEqual(try BrowserThemeConfiguration.decode(JSONEncoder().encode(theme)).accentHex, "A8DC52")
        theme.accentHex = "invalid"
        XCTAssertThrowsError(try BrowserThemeConfiguration.decode(JSONEncoder().encode(theme)))
    }

    func testWindowStyleGeometryAndOptionalThemeDefault() throws {
        XCTAssertEqual(BrowserWindowStyle.flat.contentInset, 0)
        XCTAssertEqual(BrowserWindowStyle.flat.cornerRadius, 0)
        XCTAssertEqual(BrowserWindowStyle.rounded.contentInset, 8)
        XCTAssertEqual(BrowserWindowStyle.rounded.cornerRadius, 8)
        XCTAssertEqual(BrowserWindowStyle.veryRounded.contentInset, 8)
        XCTAssertEqual(BrowserWindowStyle.veryRounded.cornerRadius, 16)
        var theme = BrowserThemePreset.native.configuration
        theme.defaultWindowStyle = nil
        XCTAssertNil(try BrowserThemeConfiguration.decode(JSONEncoder().encode(theme)).defaultWindowStyle)
    }

    func testSpacePreviewModesAndInvalidConfiguration() throws {
        var theme = BrowserThemePreset.native.configuration
        for mode in SpacePreviewMode.allCases {
            theme.spacePreview.mode = mode
            XCTAssertEqual(theme.spacePreview.showsIcon(selected: false), mode == .icons)
            XCTAssertEqual(theme.spacePreview.showsIcon(selected: true), mode != .dots)
        }
        theme.version = 2
        XCTAssertThrowsError(try BrowserThemeConfiguration.decode(JSONEncoder().encode(theme)))
        theme.version = 1
        theme.controls.toolbar.side = -1
        XCTAssertThrowsError(try BrowserThemeConfiguration.decode(JSONEncoder().encode(theme)))
        theme = BrowserThemePreset.native.configuration
        theme.controls.space.surface.material = .flat
        XCTAssertThrowsError(try BrowserThemeConfiguration.decode(JSONEncoder().encode(theme)))
        theme = BrowserThemePreset.native.configuration
        theme.symbols.removeValue(forKey: "back")
        XCTAssertThrowsError(try BrowserThemeConfiguration.decode(JSONEncoder().encode(theme)))
    }
}

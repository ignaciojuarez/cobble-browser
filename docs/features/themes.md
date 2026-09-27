# Browser themes

Native, Legacy, and Retro are bundled as versioned JSON in `Themes/`. `BrowserThemeProviding` supplies validated `BrowserThemeConfiguration` values to shared SwiftUI controls; both Xcode and Swift Package builds package the same resources.

| Area | Current behavior |
| --- | --- |
| Presets | Native is the new-install default with glass controls and selected rows. Legacy keeps rounded translucent chrome. Retro uses a dark [Kiwi OS palette](https://github.com/ignaciojuarez/kiwios/blob/b99aac7/KiwiOS/Web/app.css). |
| Customization | Accent, font, loading indicator, control surfaces, sidebar colors, symbols, space preview, and folder defaults come from JSON. Explicit user colors override preset defaults. |
| Window style | Flat, Rounded, and Very Rounded are user-selectable. A preset can supply a default style; one without a default leaves the current style. |
| Persistence | Version 7 preferences migrate earlier font/loading choices and preserve customization. Corrupt or unsupported theme data is rejected. |
| Accessibility | Interactive surfaces respect Reduce Motion. Drag previews inherit the source view's appearance and accessibility environment. |

The decoder validates versions, colors, required symbols, dimensions, and the no-idle-background rule for space items. `UI/BrowserTheme.swift` owns shared rendering; glass controls use fixed geometry and maintain contrast on dark sidebars.

Focused theme, drop, and preference checks passed **53** tests. Hosted render checks cover all three presets in light and dark appearance at 800 × 500; persistence checks cover defaults, migration, customization, corrupt records, and unsupported versions. A synthetic sidebar-click fixture remains unreliable, and live Downloads visual review was interrupted. Manual VoiceOver, high-contrast, and signed Fast/Full visual qualification remain open.

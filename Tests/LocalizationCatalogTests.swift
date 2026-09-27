import AppKit
import SwiftUI
import XCTest
@testable import Cobble

final class LocalizationCatalogTests: XCTestCase {
    func testSpanishCatalogCoversEveryTranslatableEntry() throws {
        let catalog = try catalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            XCTAssertNotNil(value(key, in: catalog), "Missing Spanish translation: \(key)")
        }
    }

    func testSpanishCatalogHasNativeSettingsAndMenuTranslations() throws {
        let catalog = try catalog()
        XCTAssertEqual(value("Browsing", in: catalog), "Navegación")
        XCTAssertEqual(value("Design", in: catalog), "Diseño")
        XCTAssertEqual(value("Default search engine", in: catalog), "Motor de búsqueda predeterminado")
        XCTAssertEqual(value("Settings…", in: catalog), "Ajustes…")
        XCTAssertEqual(value("New Private Window", in: catalog), "Nueva ventana privada")
        XCTAssertEqual(value("About Cobble", in: catalog), "Acerca de Cobble")
        XCTAssertEqual(value("Space %@", in: catalog), "Espacio %@")
        XCTAssertEqual(value("Open an external application?", in: catalog), "¿Abrir una aplicación externa?")
        XCTAssertEqual(value("Open Developer Tools", in: catalog), "Abrir herramientas para desarrolladores")
        XCTAssertEqual(value("Enable Developer Tools", in: catalog), "Activar herramientas para desarrolladores")
        XCTAssertEqual(value("Clear Data…", in: catalog), "Borrar datos…")
        XCTAssertEqual(value("Cached Resources from the Last 24 Hours…", in: catalog),
                       "Recursos almacenados en caché de las últimas 24 horas…")
        XCTAssertNotNil(value("Website records are grouped by site. A registrable domain includes its subdomains; an IP address or internal hostname matches only itself. Remove clears cookies and site storage for that site, plus cached resources associated with it. Engines may also clear shared transient caches; some process-wide cached resources require all-sites clearing. Clear Data can remove profile data by category and time range. History visits are deleted in History settings. Cobble unloads affected pages first.", in: catalog))
    }

    func testSpanishCatalogPreservesLiteralProtocolTerms() throws {
        let catalog = try catalog()
        XCTAssertEqual(value("Save Download", in: catalog), "Guardar descarga")
        XCTAssertEqual(value("https://example.com/search?q={searchTerms}", in: catalog),
                       "https://example.com/search?q={searchTerms}")
    }

    @MainActor func testDefaultBrowserActionCoversRegisteredWebSchemes() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let declared = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(Set(SettingsView.defaultBrowserSchemes), Set(["http", "https"]))
        XCTAssertEqual(Set(SettingsView.defaultBrowserSchemes), Set(declared))
    }

    func testSpanishCatalogHasIncomingBlockerAndTabLabels() throws {
        let catalog = try catalog()
        XCTAssertEqual(value("Move Tab to New Window", in: catalog), "Mover pestaña a una ventana nueva")
        XCTAssertEqual(value("Choose an HTTPS update source first.", in: catalog),
                       "Elige primero una fuente de actualización HTTPS.")
        XCTAssertEqual(
            value("Apple Passwords AutoFill for arbitrary sites needs Apple’s web-browser entitlement on a signed Cobble after Account Holder approval. This build does not include it. Cobble does not store passwords.", in: catalog),
            "El Autocompletar de Contraseñas de Apple para sitios arbitrarios necesita el permiso de navegador web de Apple en un Cobble firmado tras la aprobación del Account Holder. Esta compilación no lo incluye. Cobble no guarda contraseñas."
        )
        XCTAssertEqual(
            value("Chromium Sign in with Apple uses the system WebKit sheet. Chromium password AutoFill still needs an SDK path. Cobble does not store passwords.", in: catalog),
            "Iniciar sesión con Apple en Chromium usa la hoja WebKit del sistema. El Autocompletar de Contraseñas de Apple en Chromium sigue necesitando una ruta del SDK. Cobble no guarda contraseñas."
        )
        XCTAssertEqual(value("Sign in with Apple", in: catalog), "Iniciar sesión con Apple")
    }

    func testHostedSpanishBundleFormatsNativeMenuKeys() throws {
        let main = Bundle.main
        let mainTitle = main.localizedString(forKey: "Select Tab %@", value: nil, table: nil)
        let mainTab1 = String(format: mainTitle, "1")
        let mainTab9 = String(format: mainTitle, "9")
        if Locale.current.identifier.hasPrefix("es") {
            XCTAssertEqual(mainTab1, "Seleccionar pestaña 1")
            XCTAssertEqual(mainTab9, "Seleccionar pestaña 9")
        } else {
            XCTAssertEqual(mainTab1, "Select Tab 1")
            XCTAssertEqual(mainTab9, "Select Tab 9")
        }
        let bundle = try spanishBundle()
        XCTAssertEqual(bundle.localizedString(forKey: "File", value: nil, table: nil), "Archivo")
        XCTAssertEqual(bundle.localizedString(forKey: "Select Tab %@", value: nil, table: nil), "Seleccionar pestaña %@")
        XCTAssertEqual(String(format: bundle.localizedString(forKey: "Select Tab %@", value: nil, table: nil), "1"), "Seleccionar pestaña 1")
        XCTAssertEqual(String(format: bundle.localizedString(forKey: "Select Tab %@", value: nil, table: nil), "9"), "Seleccionar pestaña 9")
        XCTAssertEqual(String(format: bundle.localizedString(forKey: "Rename %@", value: nil, table: nil), "Favorito"), "Cambiar nombre de Favorito")
        XCTAssertEqual(bundle.localizedString(forKey: "Finish the current page action before changing tabs.", value: nil, table: nil),
                       "Termina la acción actual de la página antes de cambiar de pestaña.")
        XCTAssertEqual(bundle.localizedString(forKey: "Pause", value: nil, table: nil), "Pausar")
        XCTAssertEqual(bundle.localizedString(forKey: "Resume", value: nil, table: nil), "Reanudar")
        XCTAssertEqual(String(format: bundle.localizedString(forKey: "Could not resume the download: %@", value: nil, table: nil), "error"),
                       "No se pudo reanudar la descarga: error")
        XCTAssertEqual(String(format: bundle.localizedString(forKey: "%@, level %@, %@ folder", value: nil, table: nil), "Proyectos", "2", "expandida"),
                       "Proyectos, nivel 2, carpeta expandida")
    }

    @MainActor func testSettingsViewLaysOutAtMinimumWidth() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CobbleSpanishSettingsTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = AppModel(store: SessionStore(directory: directory), engines: EngineRegistry([]))
        defer { app.library.close(); try? FileManager.default.removeItem(at: directory) }
        let view = NSHostingView(rootView: SettingsView(app: app))
        view.frame = NSRect(x: 0, y: 0, width: 760, height: 540)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(view.fittingSize.width, 760)
        try writeRender(view)
    }

    private func catalog() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("App/Localizable.xcstrings"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func spanishBundle() throws -> Bundle {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "es", withExtension: "lproj"))
        return try XCTUnwrap(Bundle(url: url))
    }

    @MainActor private func writeRender(_ view: NSView) throws {
        guard let path = ProcessInfo.processInfo.environment["COBBLE_LOCALIZATION_RENDER_PATH"] else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Could not create the Settings render bitmap")
            return
        }
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }

    private func value(_ key: String, in catalog: [String: Any]) -> String? {
        guard let strings = catalog["strings"] as? [String: Any],
              let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let spanish = localizations["es"] as? [String: Any],
              let unit = spanish["stringUnit"] as? [String: Any] else { return nil }
        return unit["value"] as? String
    }
}

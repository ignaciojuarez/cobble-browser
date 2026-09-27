import AppKit

extension CachedFavicon {
    /// Rasterizes engine-provided icon bytes into the persisted 32×32 PNG bound.
    static func normalizedPNG(from data: Data) -> Data? {
        guard !data.isEmpty, data.count <= 1_048_576, let source = NSImage(data: data),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= 16_384 else { return nil }
        return png
    }
}

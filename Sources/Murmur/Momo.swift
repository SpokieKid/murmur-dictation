// Artwork is loaded once. The optical-size glyph has open counters for the
// system menu-bar tint and the dark recording capsule.
import AppKit

enum Momo {
    static let glyph: NSImage = {
        let image = loadImage("MomoGlyph", extension: "svg")
        image.size = NSSize(width: 20, height: 17)
        image.isTemplate = true
        return image
    }()

    static let portrait = loadImage("MomoPortrait", extension: "png")

    private static func loadImage(_ name: String, extension ext: String) -> NSImage {
        if let url = Bundle.murmurResources.url(forResource: name, withExtension: ext),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "mic", accessibilityDescription: nil) ?? NSImage()
    }
}

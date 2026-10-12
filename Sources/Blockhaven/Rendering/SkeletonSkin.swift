#if canImport(AppKit)
import AppKit

/// The skeleton's textures, drawn procedurally like every other texture in
/// the project — nothing here is a bundled image asset.
///
/// Bone-pale rather than mottled green, so the silhouette reads as a
/// different threat at a glance, before a player is even close enough to
/// tell it isn't closing the distance the way a fizzler does.
enum SkeletonSkin {
    private static let pixels = 16

    static let body: NSImage = render { drawBone($0) }

    static let face: NSImage = render {
        drawBone($0)
        drawFace($0)
    }

    /// A cold blue-white wash for the hurt flash, on the same texture
    /// `FizzlerSkin.flash` washes toward — the pattern that makes a red
    /// tint over it land on red rather than mud.
    static let flash: NSImage = render {
        drawBone($0)
        $0.setBlendMode(.sourceAtop)
        $0.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.72).cgColor)
        $0.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    }

    /// The Moon's maintenance sentry: the same frame cast in dark metal,
    /// with one red scanning eye where a skull would have two sockets.
    static let sentryBody: NSImage = render { drawMetal($0) }

    static let sentryFace: NSImage = render {
        drawMetal($0)
        $0.setFillColor(rgb(0.08, 0.08, 0.10).cgColor)
        $0.fill(CGRect(x: 2, y: 8, width: 12, height: 4))
        $0.setFillColor(rgb(1.0, 0.18, 0.12).cgColor)
        $0.fill(CGRect(x: 6, y: 9, width: 4, height: 2))
        $0.setFillColor(rgb(1.0, 0.72, 0.60).cgColor)
        $0.fill(CGRect(x: 7, y: 10, width: 2, height: 1))
    }

    private static func drawMetal(_ context: CGContext) {
        let shades = [rgb(0.30, 0.32, 0.36), rgb(0.38, 0.40, 0.44), rgb(0.24, 0.25, 0.28), rgb(0.46, 0.48, 0.52)]
        for y in 0..<pixels {
            for x in 0..<pixels {
                let n = latticeHash(x / 4, y / 4, seed: 0x5E47)
                let jitter = latticeHash(x, y, seed: 0x5E48)
                let index = Int((n * 0.7 + jitter * 0.3) * Double(shades.count))
                pixel(context, x, y, shades[min(shades.count - 1, index)])
            }
        }
        for x in 0..<pixels { pixel(context, x, 5, rgb(0.86, 0.66, 0.18)) }
    }

    private static func render(_ body: (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        if let context = NSGraphicsContext.current?.cgContext { body(context) }
        image.unlockFocus()
        return image
    }

    /// Bone-pale with grey-blue shadow patches, picked per pixel from the
    /// shared lattice hash so it's identical every run — same construction
    /// as `FizzlerSkin.drawMottle`, different palette.
    private static func drawBone(_ context: CGContext) {
        let shades = [
            rgb(0.82, 0.79, 0.72),
            rgb(0.72, 0.70, 0.64),
            rgb(0.88, 0.85, 0.78),
            rgb(0.62, 0.61, 0.58),
        ]
        for y in 0..<pixels {
            for x in 0..<pixels {
                let n = latticeHash(x / 2, y / 2, seed: 0x50E1E70)
                let jitter = latticeHash(x, y, seed: 0xB04E)
                let index = Int((n * 0.75 + jitter * 0.25) * Double(shades.count))
                pixel(context, x, y, shades[min(shades.count - 1, index)])
            }
        }
    }

    /// Hollow dark eye sockets and a lipless grin — no fangs, unlike the
    /// fizzler's mouth, so the two faces don't read as the same joke twice.
    private static func drawFace(_ context: CGContext) {
        let dark = rgb(0.06, 0.05, 0.05)
        context.setFillColor(dark.cgColor)

        context.fill(CGRect(x: 3, y: 9, width: 3, height: 3))
        context.fill(CGRect(x: 10, y: 9, width: 3, height: 3))

        // A flat row of teeth rather than a fizzler's soft frown.
        context.fill(CGRect(x: 4, y: 4, width: 8, height: 2))
        for x in stride(from: 4, to: 12, by: 2) {
            context.fill(CGRect(x: x, y: 3, width: 1, height: 1))
        }
    }

    private static func pixel(_ context: CGContext, _ x: Int, _ y: Int, _ color: NSColor) {
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: x, y: y, width: 1, height: 1))
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}
#endif

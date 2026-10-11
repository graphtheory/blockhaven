#if canImport(AppKit)
import AppKit

/// The fizzler's textures, drawn procedurally like every other texture in
/// the project — nothing here is a bundled image asset.
///
/// Three 16×16 tiles: mossy stone with a few dim ember cracks for the
/// body, the same stone carrying the face, and the burning version for the
/// pre-detonation blink — the cracks blazing rather than the whole thing
/// whitening.
enum FizzlerSkin {
    private static let pixels = 16

    static let body: NSImage = render {
        drawStone($0)
        drawCracks($0, burning: false)
    }

    static let face: NSImage = render {
        drawStone($0)
        drawFace($0)
    }

    static let flash: NSImage = render {
        drawStone($0)
        // Darken the stone so the blazing cracks stand out of it.
        $0.setFillColor(NSColor(calibratedWhite: 0, alpha: 0.35).cgColor)
        $0.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        drawCracks($0, burning: true)
    }

    private static func render(_ body: (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        if let context = NSGraphicsContext.current?.cgContext { body(context) }
        image.unlockFocus()
        return image
    }

    /// Grey cobbled stone with moss creeping down from the top, picked per
    /// pixel from the shared lattice hash so it is identical every run.
    private static func drawStone(_ context: CGContext) {
        let stone = [rgb(0.47, 0.47, 0.44), rgb(0.40, 0.40, 0.38), rgb(0.54, 0.53, 0.50), rgb(0.34, 0.34, 0.33)]
        let moss = [rgb(0.31, 0.45, 0.20), rgb(0.37, 0.53, 0.24), rgb(0.26, 0.38, 0.17)]
        for y in 0..<pixels {
            for x in 0..<pixels {
                // Cobbles: a coarse cell picks the shade, a fine hash grains it.
                let cell = latticeHash(x / 3, (y + x / 3) / 3, seed: 0xF1A2)
                let grain = latticeHash(x, y, seed: 0x5EED)
                // Bottom-left origin, so high `y` is the top of the tile.
                let mossChance = Double(y) / Double(pixels) * 0.85 - 0.2
                if latticeHash(x / 2, y / 2, seed: 0x0B05) < mossChance {
                    pixel(context, x, y, moss[min(moss.count - 1, Int(grain * Double(moss.count)))])
                } else {
                    let index = Int((cell * 0.7 + grain * 0.3) * Double(stone.count))
                    pixel(context, x, y, stone[min(stone.count - 1, index)])
                }
            }
        }
    }

    /// A jagged crack network. Dark with a dim ember in it at rest; blazing
    /// yellow-white with an orange halo while the fuse burns.
    private static func drawCracks(_ context: CGContext, burning: Bool) {
        let path: [(Int, Int)] = [
            (2, 13), (3, 12), (4, 12), (5, 11), (6, 10), (6, 9), (7, 8), (8, 8), (9, 7), (10, 6), (10, 5), (11, 4), (12, 3),
            (7, 8), (6, 7), (5, 6), (5, 5), (4, 4),
            (9, 7), (10, 8), (11, 9), (12, 10), (13, 10),
        ]
        let core = burning ? rgb(1.0, 0.93, 0.55) : rgb(0.16, 0.10, 0.07)
        let glow = burning ? rgb(1.0, 0.55, 0.12) : rgb(0.62, 0.27, 0.08)
        for (index, (x, y)) in path.enumerated() {
            if burning {
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    pixel(context, x + dx, y + dy, glow)
                }
            }
            // At rest only every third crack pixel shows its ember.
            pixel(context, x, y, !burning && index % 3 == 0 ? glow : core)
        }
        if burning {
            for (index, (x, y)) in path.enumerated() where index % 2 == 0 { pixel(context, x, y, core) }
        }
    }

    /// The face: two ember slits for eyes under a heavy stone brow, and a
    /// glowing crack where a mouth would be. Bottom-left origin.
    private static func drawFace(_ context: CGContext) {
        let brow = rgb(0.25, 0.25, 0.24)
        let ember = rgb(1.0, 0.56, 0.14)
        let hot = rgb(1.0, 0.86, 0.42)
        context.setFillColor(brow.cgColor)
        context.fill(CGRect(x: 2, y: 11, width: 12, height: 1))
        for x in [3, 10] {
            context.setFillColor(ember.cgColor)
            context.fill(CGRect(x: x, y: 9, width: 3, height: 1))
            pixel(context, x + 1, 9, hot)
        }
        // The mouth: a crooked glowing seam, not an open mouth.
        for (x, y) in [(5, 5), (6, 4), (7, 5), (8, 4), (9, 5), (10, 4)] {
            pixel(context, x, y, ember)
        }
        pixel(context, 7, 5, hot)
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

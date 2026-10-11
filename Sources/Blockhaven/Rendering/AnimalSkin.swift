#if canImport(AppKit)
import AppKit

/// The animals' textures, drawn procedurally like every other texture in
/// the project — nothing here is a bundled image asset.
///
/// Three 16×16 tiles per kind: the body, the head carrying the face, and a
/// whitened copy the hurt flash tints red.
enum AnimalSkin {
    private static let pixels = 16

    /// `morph` picks the colour an animal came out; only the axolotl and
    /// the cod have a second one, so every other kind ignores it.
    static func body(for kind: AnimalKind, morph: AnimalMorph = .common) -> NSImage {
        switch kind {
        case .pig: return pigBody
        case .cow: return cowBody
        case .sheep: return sheepBody
        case .chicken: return chickenBody
        case .axolotl: return morph == .rare ? cyanBody : axolotlBody
        case .cod: return morph == .rare ? tropicalBody : codBody
        case .squid: return squidBody
        case .wolf: return wolfBody
        }
    }

    static func head(for kind: AnimalKind, morph: AnimalMorph = .common) -> NSImage {
        switch kind {
        case .pig: return pigHead
        case .cow: return cowHead
        case .sheep: return sheepHead
        case .chicken: return chickenHead
        case .axolotl: return morph == .rare ? cyanHead : axolotlHead
        case .cod: return morph == .rare ? tropicalBody : codBody
        case .squid: return squidBody
        case .wolf: return wolfHead
        }
    }

    static func flash(for kind: AnimalKind, morph: AnimalMorph = .common) -> NSImage {
        switch kind {
        case .pig: return pigFlash
        case .cow: return cowFlash
        case .sheep: return sheepFlash
        case .chicken: return chickenFlash
        case .axolotl: return morph == .rare ? cyanFlash : axolotlFlash
        case .cod: return morph == .rare ? tropicalFlash : codFlash
        case .squid: return squidFlash
        case .wolf: return wolfFlash
        }
    }

    /// The frilly bits that are a different shade from the hide: the
    /// axolotl's gill fronds, a cod's fins, a squid's arms.
    ///
    /// Keyed on the kind as well as the morph, unlike the version this
    /// replaces. That one took only a morph, from when the axolotl was the
    /// only animal that had a frill at all — which meant every later
    /// swimmer would have worn axolotl-pink fronds over its own hide, with
    /// nothing but a render to say so.
    static func frill(for kind: AnimalKind, morph: AnimalMorph = .common) -> NSImage {
        switch kind {
        case .axolotl: return morph == .rare ? cyanGills : pinkGills
        case .cod: return morph == .rare ? tropicalFins : codFins
        case .squid: return squidArms
        default: return body(for: kind, morph: morph)
        }
    }

    /// The pale underside, which is what stops a belly reading as more of
    /// the same slab of colour.
    static func belly(for kind: AnimalKind, morph: AnimalMorph = .common) -> NSImage {
        switch kind {
        case .axolotl: return morph == .rare ? cyanBelly : pinkBelly
        case .cod: return morph == .rare ? tropicalBelly : codBelly
        case .wolf: return wolfBelly
        default: return body(for: kind, morph: morph)
        }
    }

    /// The chicken's beak and feet, and its comb and wattle. Nothing else
    /// has either, so unlike the two above these take no kind.
    static let beak: NSImage = render {
        mottle($0, seed: 0xBEA4, cell: 5, shades: [
            rgb(0.95, 0.66, 0.18),
            rgb(0.92, 0.60, 0.14),
            rgb(0.98, 0.73, 0.27),
            rgb(0.89, 0.55, 0.11),
        ])
    }

    static let comb: NSImage = render {
        mottle($0, seed: 0xC0AB, cell: 4, shades: [
            rgb(0.84, 0.18, 0.16),
            rgb(0.77, 0.13, 0.12),
            rgb(0.91, 0.26, 0.23),
            rgb(0.71, 0.10, 0.11),
        ])
    }

    /// The one dark bead every eye box wears. A fish's and a squid's eyes
    /// sit on the sides of the head, where the split-face front texture the
    /// land animals use cannot reach them, so they are their own little
    /// boxes and this is what they are painted with.
    static let eye: NSImage = render {
        // Mostly pupil. The pale rim is two pixels, not three: on a box
        // five centimetres across it is the rim that is seen at any
        // distance, and a wider one turns an eye into a white sticker.
        fill($0, 0, 0, pixels, pixels, rgb(0.93, 0.92, 0.89))
        fill($0, 2, 2, 12, 12, rgb(0.09, 0.08, 0.11))
        // A speck of light off-centre, which is the whole difference
        // between an eye and a hole.
        fill($0, 9, 9, 2, 2, rgb(0.80, 0.83, 0.88))
    }

    // MARK: - Pig

    private static let pigBody: NSImage = render { drawPigHide($0) }

    private static let pigHead: NSImage = render {
        drawPigHide($0)
        // A broad snout across the middle with two nostrils, which is the
        // whole of a pig's face once the eyes are on.
        fill($0, 4, 4, 8, 6, rgb(0.83, 0.44, 0.50))
        fill($0, 6, 6, 2, 2, rgb(0.55, 0.26, 0.32))
        fill($0, 9, 6, 2, 2, rgb(0.55, 0.26, 0.32))
        drawEyes($0, y: 11, dark: rgb(0.12, 0.07, 0.09))
    }

    private static let pigFlash: NSImage = whitened { drawPigHide($0) }

    /// Mostly clean pink with sparse darker patches, not a solid fill —
    /// three light variants against one darker one, so the odd patch reads
    /// as a blotch on otherwise plain hide rather than an even mottle.
    private static func drawPigHide(_ context: CGContext) {
        mottle(context, seed: 0x91C0FF, cell: 5, shades: [
            rgb(0.95, 0.62, 0.65),
            rgb(0.95, 0.62, 0.65),
            rgb(0.97, 0.69, 0.71),
            rgb(0.85, 0.48, 0.54),
        ])
    }

    // MARK: - Cow

    private static let cowBody: NSImage = render { drawCowHide($0) }

    private static let cowHead: NSImage = render {
        drawCowHide($0)
        // A pale muzzle low on the face, the way a cow's is.
        fill($0, 4, 3, 8, 5, rgb(0.82, 0.74, 0.68))
        fill($0, 6, 5, 2, 1, rgb(0.48, 0.40, 0.36))
        fill($0, 9, 5, 2, 1, rgb(0.48, 0.40, 0.36))
        drawEyes($0, y: 10, dark: rgb(0.10, 0.08, 0.07))
    }

    private static let cowFlash: NSImage = whitened { drawCowHide($0) }

    /// Brown and white in large flat patches — one colour per coarse cell,
    /// no per-pixel variation within it, so the two colours stay separate
    /// the way a cow's hide is instead of speckling at the boundary.
    private static func drawCowHide(_ context: CGContext) {
        let brown = rgb(0.33, 0.22, 0.15)
        let white = rgb(0.90, 0.88, 0.84)
        for y in 0..<pixels {
            for x in 0..<pixels {
                let patch = latticeHash(x / 5, y / 5, seed: 0xC0BEEF)
                pixel(context, x, y, patch > 0.5 ? brown : white)
            }
        }
    }

    // MARK: - Sheep

    private static let sheepBody: NSImage = render { drawFleece($0) }

    private static let sheepHead: NSImage = render {
        // The face is bare skin, not fleece — flat tan with a fringe of
        // wool along the top so the head still reads as a sheep's.
        fill($0, 0, 0, pixels, pixels, rgb(0.84, 0.78, 0.70))
        fill($0, 0, 12, pixels, 4, rgb(0.93, 0.92, 0.88))
        fill($0, 5, 2, 6, 4, rgb(0.72, 0.65, 0.58))
        drawEyes($0, y: 8, dark: rgb(0.13, 0.11, 0.10))
    }

    private static let sheepFlash: NSImage = whitened { drawFleece($0) }

    /// Off-white wool in soft clumps: one shade per coarse cell rather than
    /// per pixel, so it reads as curled fleece rather than static.
    private static func drawFleece(_ context: CGContext) {
        let shades = [
            rgb(0.94, 0.93, 0.90),
            rgb(0.87, 0.86, 0.82),
            rgb(0.98, 0.97, 0.95),
            rgb(0.90, 0.89, 0.85),
        ]
        mottle(context, seed: 0x5EEEB, cell: 4, shades: shades)
    }

    // MARK: - Chicken

    private static let chickenBody: NSImage = render { drawFeathers($0) }

    private static let chickenHead: NSImage = render {
        drawFeathers($0)
        // No muzzle, no snout: a chicken's face is eyes and nothing else,
        // because the beak and the wattle are their own boxes out in front
        // of it rather than markings painted on the head.
        drawEyes($0, y: 7, dark: rgb(0.11, 0.09, 0.08))
    }

    private static let chickenFlash: NSImage = whitened { drawFeathers($0) }

    /// White plumage, barely mottled. A chicken is nearly a flat colour and
    /// wants to stay one: mottle it as hard as the pig's hide is and it
    /// reads as a dirty sheep.
    private static func drawFeathers(_ context: CGContext) {
        mottle(context, seed: 0xC4EEE, cell: 5, shades: [
            rgb(0.96, 0.95, 0.92),
            rgb(0.96, 0.95, 0.92),
            rgb(0.99, 0.98, 0.96),
            rgb(0.89, 0.87, 0.83),
        ])
    }

    // MARK: - Cod

    /// Sandy olive over a pale belly — the colour of a fish seen from
    /// above, which is how a fish in a lake is nearly always seen.
    private static let codPalette = Palette(
        hide: [
            rgb(0.58, 0.53, 0.38),
            rgb(0.54, 0.49, 0.35),
            rgb(0.65, 0.60, 0.44),
            rgb(0.47, 0.42, 0.30),
        ],
        fronds: [
            rgb(0.45, 0.40, 0.28),
            rgb(0.41, 0.36, 0.25),
            rgb(0.51, 0.46, 0.33),
            rgb(0.37, 0.32, 0.22),
        ],
        belly: [
            rgb(0.87, 0.84, 0.75),
            rgb(0.83, 0.80, 0.71),
            rgb(0.90, 0.88, 0.80),
            rgb(0.79, 0.76, 0.67),
        ],
        mouth: rgb(0.40, 0.35, 0.25)
    )

    private static let codBody: NSImage = render { hide(codPalette, into: $0) }
    private static let codFlash: NSImage = whitened { hide(codPalette, into: $0) }
    private static let codFins: NSImage = render { fronds(codPalette, into: $0) }
    private static let codBelly: NSImage = render { belly(codPalette, into: $0) }

    /// The rare cod, one in eight: a tropical fish in orange and white
    /// bands. Bands rather than a mottle on purpose — every other animal in
    /// the game is mottled, and the whole job of a rare morph is to be
    /// visibly not the common one at twenty blocks, which a fourth shade of
    /// speckle would not manage.
    private static let tropicalBody: NSImage = render { drawBands($0) }
    private static let tropicalFlash: NSImage = whitened { drawBands($0) }
    private static let tropicalFins: NSImage = render {
        mottle($0, seed: 0x7401, cell: 5, shades: [
            rgb(0.99, 0.85, 0.30),
            rgb(0.97, 0.79, 0.22),
            rgb(1.00, 0.90, 0.42),
            rgb(0.94, 0.72, 0.16),
        ])
    }
    private static let tropicalBelly: NSImage = render {
        mottle($0, seed: 0x7402, cell: 5, shades: [
            rgb(0.99, 0.96, 0.93),
            rgb(0.97, 0.93, 0.89),
            rgb(1.00, 0.98, 0.96),
            rgb(0.94, 0.89, 0.84),
        ])
    }

    /// Four bands across the tile, edged in a darker line so they stay
    /// separate at the size a fish is actually seen at.
    private static func drawBands(_ context: CGContext) {
        let orange = rgb(0.95, 0.48, 0.13)
        let cream = rgb(0.99, 0.95, 0.90)
        let edge = rgb(0.68, 0.28, 0.06)
        fill(context, 0, 0, pixels, pixels, cream)
        for start in [1, 7, 13] {
            fill(context, 0, start, pixels, 4, orange)
            fill(context, 0, start, pixels, 1, edge)
        }
    }

    // MARK: - Squid

    /// Deep indigo, close to flat. A squid hanging in dim water is a
    /// silhouette before it is a texture, so what matters here is that it
    /// is darker than anything else that swims.
    private static let squidPalette = Palette(
        hide: [
            rgb(0.30, 0.27, 0.50),
            rgb(0.27, 0.24, 0.46),
            rgb(0.35, 0.32, 0.56),
            rgb(0.23, 0.20, 0.40),
        ],
        fronds: [
            rgb(0.25, 0.21, 0.42),
            rgb(0.22, 0.18, 0.38),
            rgb(0.30, 0.26, 0.48),
            rgb(0.19, 0.16, 0.33),
        ],
        belly: [
            rgb(0.30, 0.27, 0.50),
            rgb(0.27, 0.24, 0.46),
            rgb(0.35, 0.32, 0.56),
            rgb(0.23, 0.20, 0.40),
        ],
        mouth: rgb(0.18, 0.15, 0.32)
    )

    private static let squidBody: NSImage = render { hide(squidPalette, into: $0) }
    private static let squidFlash: NSImage = whitened { hide(squidPalette, into: $0) }
    private static let squidArms: NSImage = render { fronds(squidPalette, into: $0) }

    // MARK: - Wolf

    /// Grey with a warm cast rather than a flat neutral, so it reads as
    /// an animal in daylight instead of as a shadow, and pale enough that
    /// the hurt flash has somewhere to go.
    private static let wolfPalette = Palette(
        hide: [
            rgb(0.66, 0.64, 0.62),
            rgb(0.60, 0.58, 0.56),
            rgb(0.72, 0.70, 0.68),
            rgb(0.54, 0.52, 0.50),
        ],
        fronds: [
            rgb(0.58, 0.56, 0.54),
            rgb(0.53, 0.51, 0.49),
            rgb(0.64, 0.62, 0.60),
            rgb(0.48, 0.46, 0.44),
        ],
        belly: [
            rgb(0.90, 0.89, 0.86),
            rgb(0.85, 0.84, 0.81),
            rgb(0.94, 0.93, 0.91),
            rgb(0.80, 0.79, 0.76),
        ],
        mouth: rgb(0.24, 0.22, 0.21)
    )

    private static let wolfBody: NSImage = render { hide(wolfPalette, into: $0) }
    private static let wolfHead: NSImage = render { face(wolfPalette, into: $0) }
    private static let wolfFlash: NSImage = whitened { hide(wolfPalette, into: $0) }
    private static let wolfBelly: NSImage = render { belly(wolfPalette, into: $0) }

    // MARK: - Axolotl

    /// The leucistic one: clean bubblegum pink with barely any variation —
    /// a leucistic axolotl is almost a flat colour, so this mottles far
    /// more gently than the pig's hide does, or it reads as a pig.
    private static let pink = Palette(
        hide: [
            rgb(0.98, 0.74, 0.79),
            rgb(0.98, 0.74, 0.79),
            rgb(0.99, 0.79, 0.83),
            rgb(0.96, 0.68, 0.75),
        ],
        // The fronds: the same pink pushed toward the red that the feathery
        // bits of a real axolotl are.
        fronds: [
            rgb(0.93, 0.47, 0.58),
            rgb(0.90, 0.40, 0.52),
            rgb(0.95, 0.55, 0.64),
            rgb(0.88, 0.36, 0.49),
        ],
        belly: [
            rgb(0.99, 0.90, 0.91),
            rgb(0.99, 0.86, 0.88),
            rgb(0.99, 0.92, 0.93),
            rgb(0.97, 0.83, 0.86),
        ],
        mouth: rgb(0.80, 0.46, 0.54)
    )

    /// The rare one, one spawn in ten. Same drawing, four different
    /// colours — which is the whole reason the palette is a value and not
    /// four more copies of the same three functions.
    private static let cyan = Palette(
        hide: [
            rgb(0.44, 0.83, 0.86),
            rgb(0.44, 0.83, 0.86),
            rgb(0.52, 0.88, 0.90),
            rgb(0.36, 0.75, 0.80),
        ],
        fronds: [
            rgb(0.62, 0.52, 0.86),
            rgb(0.56, 0.45, 0.82),
            rgb(0.69, 0.60, 0.90),
            rgb(0.51, 0.40, 0.78),
        ],
        belly: [
            rgb(0.86, 0.96, 0.97),
            rgb(0.81, 0.94, 0.95),
            rgb(0.90, 0.97, 0.98),
            rgb(0.77, 0.91, 0.94),
        ],
        mouth: rgb(0.28, 0.60, 0.66)
    )

    /// The four colours an axolotl morph is: its hide, its fronds, its
    /// belly and the line of its mouth.
    private struct Palette {
        let hide: [NSColor]
        let fronds: [NSColor]
        let belly: [NSColor]
        let mouth: NSColor
    }

    private static let axolotlBody: NSImage = render { hide(pink, into: $0) }
    private static let axolotlHead: NSImage = render { face(pink, into: $0) }
    private static let axolotlFlash: NSImage = whitened { hide(pink, into: $0) }
    private static let pinkGills: NSImage = render { fronds(pink, into: $0) }
    private static let pinkBelly: NSImage = render { belly(pink, into: $0) }

    private static let cyanBody: NSImage = render { hide(cyan, into: $0) }
    private static let cyanHead: NSImage = render { face(cyan, into: $0) }
    private static let cyanFlash: NSImage = whitened { hide(cyan, into: $0) }
    private static let cyanGills: NSImage = render { fronds(cyan, into: $0) }
    private static let cyanBelly: NSImage = render { belly(cyan, into: $0) }

    private static func hide(_ palette: Palette, into context: CGContext) {
        mottle(context, seed: 0xA0A07, cell: 5, shades: palette.hide)
    }

    private static func fronds(_ palette: Palette, into context: CGContext) {
        mottle(context, seed: 0x6111, cell: 4, shades: palette.fronds)
    }

    private static func belly(_ palette: Palette, into context: CGContext) {
        mottle(context, seed: 0xBE111, cell: 5, shades: palette.belly)
    }

    private static func face(_ palette: Palette, into context: CGContext) {
        hide(palette, into: context)
        // An axolotl's face is two black beads and a wide flat mouth. No
        // pale eye surround, unlike the three above: the beads read against
        // the hide on their own, and a white ring around them turns a smile
        // into a stare.
        let dark = rgb(0.14, 0.09, 0.12)
        fill(context, 3, 10, 2, 2, dark)
        fill(context, 11, 10, 2, 2, dark)
        // The mouth runs nearly the width of the face and turns up at both
        // ends — the whole reason an axolotl looks pleased with itself.
        fill(context, 4, 5, 8, 1, palette.mouth)
        fill(context, 3, 6, 1, 1, palette.mouth)
        fill(context, 12, 6, 1, 1, palette.mouth)
    }

    // MARK: - Shared drawing

    private static func render(_ body: (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        if let context = NSGraphicsContext.current?.cgContext { body(context) }
        image.unlockFocus()
        return image
    }

    /// The same hide washed toward white. `sourceAtop` whitens what was
    /// drawn rather than painting a flat square, and an unlit tint can only
    /// darken — so the red hurt flash needs a pale texture underneath it.
    private static func whitened(_ body: (CGContext) -> Void) -> NSImage {
        render {
            body($0)
            $0.setBlendMode(.sourceAtop)
            $0.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.72).cgColor)
            $0.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
    }

    /// One shade per `cell`×`cell` block of pixels, picked from the shared
    /// lattice hash with nothing sampled at the raw pixel rate — that's what
    /// keeps this reading as blotches of hide rather than single-pixel
    /// speckle. `cell` wants to be large relative to the 16×16 tile (3-5) or
    /// the "patches" are barely bigger than the noise they replaced.
    /// Identical every run.
    private static func mottle(_ context: CGContext, seed: UInt64, cell: Int, shades: [NSColor]) {
        for y in 0..<pixels {
            for x in 0..<pixels {
                let n = latticeHash(x / cell, y / cell, seed: seed)
                let index = Int(n * Double(shades.count))
                pixel(context, x, y, shades[min(shades.count - 1, index)])
            }
        }
    }

    /// Two eyes, the same on all three faces. The pale surround is what
    /// keeps them readable over the cow's dark patches; without it an eye
    /// landing on brown vanishes. Coordinates are bottom-left origin,
    /// matching the drawing context.
    private static func drawEyes(_ context: CGContext, y: Int, dark: NSColor) {
        fill(context, 3, y, 3, 3, rgb(0.97, 0.97, 0.96))
        fill(context, 10, y, 3, 3, rgb(0.97, 0.97, 0.96))
        // Pupils turned toward the middle, which is what stops a face
        // reading as two blank squares.
        fill(context, 5, y + 1, 1, 2, dark)
        fill(context, 10, y + 1, 1, 2, dark)
    }

    private static func fill(
        _ context: CGContext,
        _ x: Int, _ y: Int, _ width: Int, _ height: Int,
        _ color: NSColor
    ) {
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: x, y: y, width: width, height: height))
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

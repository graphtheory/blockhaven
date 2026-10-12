#if canImport(AppKit)
import AppKit
import CoreGraphics

/// The sheet itself, painted with CoreGraphics. The layout it is painted
/// into — which tile lives in which slot — is `AtlasLayout.swift`.
extension TextureAtlas {
    static let image: NSImage = buildSheet()

    /// A single face texture at full brightness, for inventory icons.
    static func tileImage(_ tile: AtlasTile) -> NSImage {
        if let cached = tileCache[tile] { return cached }
        let image = NSImage(size: NSSize(width: tilePixels, height: tilePixels))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        if let context = NSGraphicsContext.current?.cgContext {
            draw(tile: tile, in: context)
        }
        image.unlockFocus()
        tileCache[tile] = image
        return image
    }

    private static var tileCache: [AtlasTile: NSImage] = [:]

    private static func buildSheet() -> NSImage {
        let image = NSImage(size: NSSize(width: sheetWidth, height: sheetHeight))
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        if let context = NSGraphicsContext.current?.cgContext {
            for tile in shadedTiles {
                for shade in 0..<shadeLevels {
                    drawSlot(slot(for: tile, shadeIndex: shade), in: context) { ctx in
                        draw(tile: tile, in: ctx)
                        // Darken only the pixels that were actually drawn,
                        // so a transparent texture (glass) keeps its holes.
                        let dim = 1 - brightness(forIndex: shade)
                        if dim > 0.001 {
                            ctx.saveGState()
                            ctx.setBlendMode(.sourceAtop)
                            ctx.setFillColor(NSColor(calibratedWhite: 0, alpha: dim).cgColor)
                            ctx.fill(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
                            ctx.restoreGState()
                        }
                    }
                }
            }
            for stage in 0..<10 {
                drawSlot(crackSlot(stage: stage), in: context) { ctx in
                    drawCracks(ctx, stage: stage)
                }
            }
            for tile in flatTiles {
                drawSlot(flatSlot(for: tile), in: context) { ctx in
                    draw(tile: tile, in: ctx)
                }
            }
        }
        image.unlockFocus()
        return image
    }

    /// Positions the context over one slot and runs `body` in slot-local
    /// coordinates. AppKit's origin is bottom-left, so slot row 0 (the
    /// atlas's top row) draws at the top of the canvas.
    private static func drawSlot(_ slot: Int, in context: CGContext, _ body: (CGContext) -> Void) {
        let column = slot % columns
        let row = slot / columns
        context.saveGState()
        context.translateBy(
            x: CGFloat(column * tilePixels),
            y: CGFloat((rows - 1 - row) * tilePixels)
        )
        context.clip(to: CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
        body(context)
        context.restoreGState()
    }

    // MARK: - Tile painting

    /// Deterministic per-pixel value in 0..<1, so every regeneration of the
    /// sheet is byte-identical.
    private static func noise(_ x: Int, _ y: Int, _ salt: Int) -> Double {
        latticeHash(x &* 31 &+ salt, y &* 17 &+ salt, seed: UInt64(truncatingIfNeeded: 0x5EED &+ salt))
    }

    private static func fill(_ context: CGContext, _ color: NSColor) {
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
    }

    private static func pixel(_ context: CGContext, _ x: Int, _ y: Int, _ color: NSColor) {
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: x, y: y, width: 1, height: 1))
    }

    /// Speckles the tile with `shades`, chosen per pixel from the noise
    /// field — the base texture look for dirt, stone, sand and friends.
    private static func speckle(_ context: CGContext, base: NSColor, shades: [NSColor], density: Double, salt: Int) {
        fill(context, base)
        for y in 0..<tilePixels {
            for x in 0..<tilePixels {
                let n = noise(x, y, salt)
                guard n < density else { continue }
                let index = Int(noise(x, y, salt &+ 7) * Double(shades.count)) % max(1, shades.count)
                pixel(context, x, y, shades[index])
            }
        }
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
    }

    /// Concentric growth rings around the tile centre — what the cut end of
    /// any trunk looks like. The oak's own top predates this and draws its
    /// rings inline; the two later species share it.
    private static func ringGrain(_ context: CGContext, outer: NSColor, inner: NSColor) {
        let centre = Double(tilePixels) / 2
        for y in 0..<tilePixels {
            for x in 0..<tilePixels {
                let dx = Double(x) + 0.5 - centre, dy = Double(y) + 0.5 - centre
                let radius = (dx * dx + dy * dy).squareRoot()
                if radius > 6.5 {
                    pixel(context, x, y, outer)
                } else if Int(radius) % 2 == 0 {
                    pixel(context, x, y, inner)
                }
            }
        }
    }

    /// One flower on a stem, on a transparent field: a couple of leaves low
    /// down, then a four-petal head with a centre. Every flower in the game
    /// is this drawing in three colours, which is what keeps them a family.
    private static func drawFlower(
        _ context: CGContext,
        petal: NSColor, petalShade: NSColor, centre: NSColor, stemHeight: Int
    ) {
        context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
        let stem = rgb(0.24, 0.46, 0.19)
        let leaf = rgb(0.31, 0.55, 0.23)
        for y in 0..<stemHeight { pixel(context, 7, y, stem) }
        pixel(context, 6, 2, leaf)
        pixel(context, 5, 3, leaf)
        pixel(context, 8, 4, leaf)
        pixel(context, 9, 5, leaf)

        // A four-petal head, drawn as a plus with the corners knocked in so
        // it is round rather than square at this size.
        let head = stemHeight + 1
        for (dx, dy) in [(0, 0), (0, 1), (0, 2), (-1, 1), (1, 1),
                         (-1, 0), (1, 0), (-1, 2), (1, 2), (0, 3), (-2, 1), (2, 1)] {
            pixel(context, 7 + dx, head + dy, petal)
        }
        for (dx, dy) in [(-2, 0), (2, 0), (-2, 2), (2, 2), (-1, 3), (1, 3)] {
            pixel(context, 7 + dx, head + dy, petalShade)
        }
        pixel(context, 7, head + 1, centre)
        pixel(context, 6, head + 1, centre)
    }

    /// A radiant lamp's face: the glass tile's trick in a hue. The body is
    /// painted below the opaque material's 0.5 alpha threshold, so it cuts
    /// out and you see through the block; the frame, an inner glow ring and
    /// a scatter of sparkle streaks sit above it, so what remains reads as
    /// a pane of coloured light. The colour never reaches the flood — the
    /// engine's light has no hue — but a lamp's own face renders at full
    /// brightness, which is where all of this shows.
    private static func radiantGlass(_ context: CGContext, hue: (Double, Double, Double)) {
        let bright = rgb(
            hue.0 + (1 - hue.0) * 0.6, hue.1 + (1 - hue.1) * 0.6, hue.2 + (1 - hue.2) * 0.6,
            0.85
        )
        context.setFillColor(rgb(hue.0, hue.1, hue.2, 0.42).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
        context.setStrokeColor(rgb(hue.0, hue.1, hue.2, 0.95).cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(tilePixels) - 1, height: CGFloat(tilePixels) - 1))
        context.setStrokeColor(bright.cgColor)
        context.stroke(CGRect(x: 1.5, y: 1.5, width: CGFloat(tilePixels) - 3, height: CGFloat(tilePixels) - 3))
        // The shine: a bright X corner to corner, so the pane reads as a
        // jewel facet rather than an empty frame — the middles of the four
        // triangles it cuts stay see-through — plus loose glints, because
        // these are lamps, and lamps show off.
        for i in 2..<(tilePixels - 2) {
            pixel(context, i, i, bright)
            pixel(context, i, tilePixels - 1 - i, bright)
        }
        for i in 0..<4 {
            pixel(context, 4 + i, 11 - i, rgb(1, 1, 1, 0.8))
        }
        for (x, y) in [(11, 12), (5, 5), (12, 4), (3, 10)] {
            pixel(context, x, y, rgb(1, 1, 1, 0.7))
        }
    }

    private static func draw(tile: AtlasTile, in context: CGContext) {
        switch tile {
        case .grassTop:
            speckle(context, base: rgb(0.36, 0.62, 0.24),
                    shades: [rgb(0.31, 0.55, 0.20), rgb(0.42, 0.69, 0.29), rgb(0.34, 0.58, 0.22)],
                    density: 0.55, salt: 11)

        case .grassSide:
            // Dirt body with a ragged grass fringe over the top few rows.
            speckle(context, base: rgb(0.44, 0.31, 0.19),
                    shades: [rgb(0.38, 0.26, 0.15), rgb(0.50, 0.36, 0.23)],
                    density: 0.5, salt: 12)
            for x in 0..<tilePixels {
                let depth = 3 + Int(noise(x, 0, 13) * 2.99)
                for y in (tilePixels - depth)..<tilePixels {
                    let shade = noise(x, y, 14)
                    pixel(context, x, y, shade < 0.4 ? rgb(0.31, 0.55, 0.20) : rgb(0.36, 0.62, 0.24))
                }
            }

        case .dirt:
            speckle(context, base: rgb(0.44, 0.31, 0.19),
                    shades: [rgb(0.38, 0.26, 0.15), rgb(0.50, 0.36, 0.23), rgb(0.41, 0.29, 0.17)],
                    density: 0.55, salt: 12)

        case .farmlandTop:
            // Dirt, darker for having been turned over, and furrowed —
            // three grooved rows rather than a flat speckle, so a tilled
            // field reads as worked ground the moment you look down at it.
            speckle(context, base: rgb(0.36, 0.25, 0.14),
                    shades: [rgb(0.31, 0.21, 0.11), rgb(0.42, 0.30, 0.17)],
                    density: 0.55, salt: 33)
            let furrow = rgb(0.24, 0.16, 0.08)
            for row in [3, 8, 13] {
                for x in 0..<tilePixels {
                    pixel(context, x, row, furrow)
                }
            }

        case .stone:
            speckle(context, base: rgb(0.50, 0.50, 0.50),
                    shades: [rgb(0.44, 0.44, 0.44), rgb(0.57, 0.57, 0.57), rgb(0.47, 0.47, 0.47)],
                    density: 0.5, salt: 21)

        case .cobblestone:
            // Irregular stones separated by dark mortar.
            fill(context, rgb(0.33, 0.33, 0.33))
            for by in 0..<4 {
                for bx in 0..<4 {
                    let jitter = noise(bx, by, 31)
                    let shade = 0.45 + jitter * 0.22
                    context.setFillColor(rgb(shade, shade, shade).cgColor)
                    let inset = jitter < 0.5 ? 1 : 0
                    context.fill(CGRect(x: bx * 4 + inset, y: by * 4, width: 3 - inset, height: 3))
                }
            }

        case .sand:
            speckle(context, base: rgb(0.87, 0.82, 0.60),
                    shades: [rgb(0.81, 0.76, 0.54), rgb(0.92, 0.88, 0.68)],
                    density: 0.45, salt: 41)

        case .sandstoneTop:
            speckle(context, base: rgb(0.85, 0.80, 0.58),
                    shades: [rgb(0.80, 0.75, 0.53)], density: 0.35, salt: 42)

        case .sandstoneSide:
            speckle(context, base: rgb(0.85, 0.80, 0.58),
                    shades: [rgb(0.80, 0.75, 0.53)], density: 0.3, salt: 43)
            for y in [3, 4, 10, 11] {
                for x in 0..<tilePixels {
                    pixel(context, x, y, rgb(0.73, 0.68, 0.47))
                }
            }

        case .gravel:
            speckle(context, base: rgb(0.52, 0.50, 0.49),
                    shades: [rgb(0.38, 0.36, 0.35), rgb(0.64, 0.62, 0.61), rgb(0.45, 0.43, 0.42)],
                    density: 0.7, salt: 51)

        case .logSide:
            // Vertical bark grooves over a warm brown, with per-pixel
            // jitter so a trunk doesn't read as a smeared column.
            fill(context, rgb(0.45, 0.33, 0.19))
            for x in 0..<tilePixels {
                let groove = noise(x, 0, 61)
                let base = groove < 0.22 ? 0.34 : 0.52 + groove * 0.14
                for y in 0..<tilePixels {
                    let jitter = (noise(x, y, 62) - 0.5) * 0.10
                    let shade = base + jitter
                    pixel(context, x, y, rgb(shade, shade * 0.72, shade * 0.42))
                }
            }

        case .logTop:
            // Concentric growth rings around the tile centre.
            fill(context, rgb(0.55, 0.42, 0.24))
            let centre = Double(tilePixels) / 2
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let dx = Double(x) + 0.5 - centre, dy = Double(y) + 0.5 - centre
                    let radius = (dx * dx + dy * dy).squareRoot()
                    if radius > 6.5 {
                        pixel(context, x, y, rgb(0.36, 0.25, 0.13))
                    } else if Int(radius) % 2 == 0 {
                        pixel(context, x, y, rgb(0.49, 0.36, 0.20))
                    }
                }
            }

        case .planks:
            // Four horizontal boards with dark seams and grain flecks.
            fill(context, rgb(0.68, 0.53, 0.32))
            for y in 0..<tilePixels {
                if y % 4 == 3 {
                    for x in 0..<tilePixels { pixel(context, x, y, rgb(0.48, 0.36, 0.20)) }
                } else {
                    for x in 0..<tilePixels where noise(x, y, 71) < 0.25 {
                        pixel(context, x, y, rgb(0.61, 0.47, 0.28))
                    }
                }
            }

        case .leaves:
            speckle(context, base: rgb(0.27, 0.52, 0.18),
                    shades: [rgb(0.19, 0.39, 0.12), rgb(0.36, 0.64, 0.25),
                             rgb(0.10, 0.22, 0.07), rgb(0.31, 0.57, 0.21)],
                    density: 0.85, salt: 81)

        case .birchLogSide:
            // Pale bark with short dark lenticels across it. Birch is
            // nearly white, and it is the *flecks* that stop it reading as
            // a column of snow.
            fill(context, rgb(0.88, 0.86, 0.80))
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let n = noise(x, y, 141)
                    if n < 0.06 {
                        pixel(context, x, y, rgb(0.24, 0.22, 0.20))
                    } else if n < 0.10 {
                        pixel(context, x, y, rgb(0.42, 0.39, 0.35))
                    } else if n < 0.30 {
                        pixel(context, x, y, rgb(0.81, 0.79, 0.73))
                    }
                }
            }
            // Two longer scars, which is what birch bark actually does.
            for y in [3, 11] {
                for x in 2..<7 { pixel(context, x, y, rgb(0.30, 0.28, 0.25)) }
            }

        case .birchLogTop:
            fill(context, rgb(0.83, 0.76, 0.60))
            ringGrain(context, outer: rgb(0.88, 0.86, 0.80), inner: rgb(0.74, 0.66, 0.50))

        case .birchLeaves:
            speckle(context, base: rgb(0.44, 0.63, 0.25),
                    shades: [rgb(0.33, 0.51, 0.18), rgb(0.56, 0.74, 0.33),
                             rgb(0.24, 0.38, 0.13), rgb(0.49, 0.68, 0.29)],
                    density: 0.85, salt: 143)

        case .spruceLogSide:
            // Darker and redder than oak, with deeper grooves.
            fill(context, rgb(0.30, 0.21, 0.13))
            for x in 0..<tilePixels {
                let groove = noise(x, 0, 151)
                let base = groove < 0.28 ? 0.22 : 0.34 + groove * 0.12
                for y in 0..<tilePixels {
                    let jitter = (noise(x, y, 152) - 0.5) * 0.09
                    let shade = base + jitter
                    pixel(context, x, y, rgb(shade, shade * 0.68, shade * 0.46))
                }
            }

        case .spruceLogTop:
            fill(context, rgb(0.42, 0.30, 0.18))
            ringGrain(context, outer: rgb(0.28, 0.19, 0.11), inner: rgb(0.37, 0.26, 0.15))

        case .spruceLeaves:
            // Blue-green and much darker than oak, which is most of what
            // makes a conifer read as a different tree at a distance.
            speckle(context, base: rgb(0.16, 0.33, 0.21),
                    shades: [rgb(0.10, 0.23, 0.15), rgb(0.22, 0.42, 0.27),
                             rgb(0.06, 0.15, 0.10), rgb(0.19, 0.37, 0.24)],
                    density: 0.88, salt: 153)

        case .cactusSide:
            fill(context, rgb(0.18, 0.44, 0.19))
            // Vertical ribs with a paler crest, and spines along them.
            for x in 0..<tilePixels {
                let rib = abs((x % 5) - 2)
                let shade = 0.14 + Double(rib) * 0.035
                for y in 0..<tilePixels {
                    let jitter = (noise(x, y, 161) - 0.5) * 0.05
                    pixel(context, x, y, rgb(shade + jitter, (shade + jitter) * 2.5, (shade + jitter) * 1.1))
                }
            }
            for y in stride(from: 1, to: tilePixels, by: 4) {
                for x in stride(from: 2, to: tilePixels, by: 5) {
                    pixel(context, x, y, rgb(0.85, 0.86, 0.72))
                }
            }

        case .cactusTop:
            fill(context, rgb(0.22, 0.50, 0.22))
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let dx = Double(x) - 7.5, dy = Double(y) - 7.5
                    let radius = (dx * dx + dy * dy).squareRoot()
                    if radius > 6.6 {
                        pixel(context, x, y, rgb(0.14, 0.36, 0.15))
                    } else if radius < 2.4 {
                        pixel(context, x, y, rgb(0.28, 0.58, 0.27))
                    }
                }
            }

        case .tallGrass:
            // Blades rising from the bottom edge, thinning as they go, on
            // a transparent field. Nothing is drawn above the tips, which
            // is what makes the slab read as grass rather than as a wall.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            // Short and crowded rather than tall and separate: blades that
            // reach the top of the tile read as reeds, and the tuft has to
            // sit close enough to the ground colour that a meadow looks
            // like grass rather than like something growing out of it.
            let blades = [
                (x: 1, height: 6, tint: -0.04), (x: 3, height: 9, tint: 0.06),
                (x: 4, height: 5, tint: -0.07), (x: 6, height: 10, tint: 0.09),
                (x: 7, height: 7, tint: 0.0), (x: 9, height: 11, tint: 0.11),
                (x: 10, height: 6, tint: -0.05), (x: 12, height: 9, tint: 0.04),
                (x: 14, height: 6, tint: -0.02),
            ]
            for blade in blades {
                for y in 0..<blade.height {
                    let taper = Double(y) / Double(blade.height)
                    let green = 0.60 + blade.tint - taper * 0.09
                    pixel(context, blade.x, y, rgb(green * 0.56, green, green * 0.36))
                    // A second column low down, so the base is thicker than
                    // the tip and the tuft has a shape.
                    if taper < 0.5 {
                        pixel(context, blade.x + 1, y, rgb(green * 0.48, green * 0.88, green * 0.31))
                    }
                }
            }

        case .poppy:
            drawFlower(context,
                       petal: rgb(0.80, 0.16, 0.15), petalShade: rgb(0.62, 0.09, 0.10),
                       centre: rgb(0.16, 0.13, 0.10), stemHeight: 8)

        case .dandelion:
            drawFlower(context,
                       petal: rgb(0.96, 0.83, 0.20), petalShade: rgb(0.84, 0.66, 0.10),
                       centre: rgb(0.99, 0.94, 0.55), stemHeight: 7)

        case .cornflower:
            drawFlower(context,
                       petal: rgb(0.29, 0.38, 0.85), petalShade: rgb(0.19, 0.26, 0.68),
                       centre: rgb(0.13, 0.17, 0.42), stemHeight: 9)

        case .tntSide:
            // A wooden powder crate: dark vertical boards, an iron hoop near
            // each end, and a yellow-and-black hazard band round the middle
            // so it reads as dangerous from across a field.
            speckle(context, base: rgb(0.45, 0.31, 0.18),
                    shades: [rgb(0.38, 0.26, 0.15), rgb(0.52, 0.37, 0.22)],
                    density: 0.45, salt: 141)
            context.setFillColor(rgb(0.30, 0.20, 0.11).cgColor)
            for x in stride(from: 3, to: tilePixels, by: 4) {
                context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: CGFloat(tilePixels)))
            }
            for y in [1, 13] {
                context.setFillColor(rgb(0.30, 0.31, 0.33).cgColor)
                context.fill(CGRect(x: 0, y: CGFloat(y), width: CGFloat(tilePixels), height: 2))
                context.setFillColor(rgb(0.46, 0.47, 0.49).cgColor)
                context.fill(CGRect(x: 0, y: CGFloat(y + 1), width: CGFloat(tilePixels), height: 1))
            }
            // Hazard band: diagonal stripes, four rows tall.
            for y in 6...9 {
                for x in 0..<tilePixels {
                    let stripe = ((x + y) / 2) % 2 == 0
                    pixel(context, x, y, stripe ? rgb(0.93, 0.76, 0.12) : rgb(0.10, 0.09, 0.08))
                }
            }

        case .tntTop:
            // The lid: boards, a hoop round the rim, and the fuse coiled out
            // of a bung hole in the middle.
            speckle(context, base: rgb(0.48, 0.33, 0.19),
                    shades: [rgb(0.40, 0.28, 0.16), rgb(0.55, 0.39, 0.23)],
                    density: 0.45, salt: 142)
            context.setFillColor(rgb(0.32, 0.22, 0.12).cgColor)
            for y in stride(from: 3, to: tilePixels, by: 4) {
                context.fill(CGRect(x: 0, y: CGFloat(y), width: CGFloat(tilePixels), height: 1))
            }
            context.setStrokeColor(rgb(0.36, 0.37, 0.39).cgColor)
            context.setLineWidth(1)
            context.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(tilePixels) - 1, height: CGFloat(tilePixels) - 1))
            context.setFillColor(rgb(0.12, 0.09, 0.07).cgColor)
            context.fill(CGRect(x: 6, y: 6, width: 4, height: 4))
            let fuse = rgb(0.78, 0.70, 0.52)
            for (x, y) in [(7, 7), (8, 8), (9, 9), (10, 9), (11, 10), (11, 11)] { pixel(context, x, y, fuse) }
            pixel(context, 12, 12, rgb(0.95, 0.55, 0.15))

        case .torch:
            // A stick with something burning on the end of it. Drawn on a
            // cleared field so the crossed slabs cut away to nothing around
            // the post, the same way the plants do.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let stick = rgb(0.45, 0.32, 0.18)
            let stickLit = rgb(0.58, 0.43, 0.25)
            for y in 0..<9 {
                pixel(context, 7, y, stick)
                pixel(context, 8, y, y > 5 ? stickLit : stick)
            }
            // The head: a hot core, a flame around it, and one bright pixel
            // at the very top so the thing has a highlight to catch the eye
            // in a dark corridor.
            for (x, y, colour) in [
                (7, 9, rgb(0.99, 0.62, 0.16)), (8, 9, rgb(0.99, 0.70, 0.22)),
                (7, 10, rgb(1.00, 0.84, 0.34)), (8, 10, rgb(1.00, 0.78, 0.28)),
                (6, 10, rgb(0.92, 0.46, 0.10)), (9, 10, rgb(0.92, 0.46, 0.10)),
                (7, 11, rgb(1.00, 0.95, 0.62)), (8, 11, rgb(1.00, 0.90, 0.48)),
                (7, 12, rgb(1.00, 0.99, 0.86)),
            ] { pixel(context, x, y, colour) }

        case .railStraight, .railBooster, .railDetector:
            // Runs north–south in the tile; the mesher turns the plate for
            // the east–west case rather than the sheet carrying both.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let sleeper = rgb(0.42, 0.31, 0.19)
            let sleeperDark = rgb(0.34, 0.25, 0.15)
            for y in stride(from: 1, to: tilePixels, by: 4) {
                for x in 2..<14 {
                    pixel(context, x, y, x % 3 == 0 ? sleeperDark : sleeper)
                }
            }
            // A powered rail's runners are gold, a detector's copper —
            // which is the only thing that tells either apart from a plain
            // rail at a moving cart's speed.
            let metal = tile == .railBooster ? rgb(0.85, 0.72, 0.28)
                : tile == .railDetector ? rgb(0.82, 0.47, 0.24) : rgb(0.71, 0.72, 0.75)
            let metalDark = tile == .railBooster ? rgb(0.66, 0.54, 0.18)
                : tile == .railDetector ? rgb(0.62, 0.33, 0.15) : rgb(0.53, 0.54, 0.57)
            for y in 0..<tilePixels {
                for x in [4, 11] {
                    pixel(context, x, y, y % 5 == 0 ? metalDark : metal)
                }
            }

        case .railCurve:
            // A quarter turn: north to east in the tile, rotated by the
            // mesher for the other three corners.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let sleeper = rgb(0.42, 0.31, 0.19)
            let metal = rgb(0.71, 0.72, 0.75)
            let metalDark = rgb(0.53, 0.54, 0.57)
            // Sleepers fanned round the corner, then the two runners as
            // quarter arcs at two radii.
            for step in 0...12 {
                let angle = Double(step) / 12 * Double.pi / 2
                for radius in stride(from: 3.0, through: 12.0, by: 1.0) {
                    let x = Int(radius * cos(angle)), y = Int(radius * sin(angle))
                    guard x >= 0, x < tilePixels, y >= 0, y < tilePixels else { continue }
                    if step % 3 == 0 { pixel(context, x, y, sleeper) }
                }
            }
            for step in 0...20 {
                let angle = Double(step) / 20 * Double.pi / 2
                for (radius, shade) in [(4.5, metal), (11.0, metal)] {
                    let x = Int(radius * cos(angle)), y = Int(radius * sin(angle))
                    guard x >= 0, x < tilePixels, y >= 0, y < tilePixels else { continue }
                    pixel(context, x, y, step % 5 == 0 ? metalDark : shade)
                }
            }

        case .leverOff, .leverOn:
            // A stub of metal on a stone base. The base never changes; the
            // stub does, dull iron thrown one way and hot copper thrown the
            // other, which is the only difference a player standing over it
            // needs to read at a glance.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let base = rgb(0.45, 0.45, 0.47)
            context.setFillColor(base.cgColor)
            context.fill(CGRect(x: 3, y: 1, width: 10, height: 3))
            context.setFillColor(rgb(0.34, 0.34, 0.36).cgColor)
            context.fill(CGRect(x: 3, y: 1, width: 10, height: 1))
            let on = tile == .leverOn
            let stub = on ? rgb(0.92, 0.55, 0.22) : rgb(0.60, 0.60, 0.63)
            let stubDark = on ? rgb(0.72, 0.38, 0.10) : rgb(0.42, 0.42, 0.45)
            for y in 4..<13 {
                pixel(context, 7, y, stub)
                pixel(context, 8, y, stubDark)
            }
            if on {
                pixel(context, 7, 12, rgb(1.0, 0.85, 0.5))
                pixel(context, 8, 12, rgb(1.0, 0.78, 0.4))
            }

        case .wireOff, .wireOn:
            // A trace across the floor, dull copper cold and glowing hot
            // once a lever somewhere is feeding it — the shape the mesher
            // draws is the same flat plate a rail uses; only the colour of
            // the trace says whether current is in it.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let on = tile == .wireOn
            let core = on ? rgb(0.98, 0.48, 0.12) : rgb(0.42, 0.26, 0.14)
            let glow = on ? rgb(1.0, 0.78, 0.35) : rgb(0.30, 0.18, 0.10)
            for x in 2..<14 {
                pixel(context, x, 7, core)
                pixel(context, x, 8, glow)
            }
            for y in 2..<14 {
                pixel(context, 7, y, core)
                pixel(context, 8, y, glow)
            }

        case .signalTorchOff, .signalTorchOn:
            // The same stick `torch` draws, so it reads as a torch first —
            // but the head is copper, matching the wire and the lever's own
            // stub, so the family reads as one thing at a glance: dull and
            // cold means no power is moving, hot orange means it is. A
            // plain torch's flame never goes out; this one visibly can,
            // which is the whole difference a player is meant to read off
            // it without opening a menu.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let on = tile == .signalTorchOn
            let stick = rgb(0.45, 0.32, 0.18)
            let stickLit = rgb(0.58, 0.43, 0.25)
            for y in 0..<9 {
                pixel(context, 7, y, stick)
                pixel(context, 8, y, y > 5 ? stickLit : stick)
            }
            let core = on ? rgb(0.99, 0.62, 0.16) : rgb(0.40, 0.40, 0.43)
            let mid = on ? rgb(1.00, 0.78, 0.28) : rgb(0.52, 0.52, 0.55)
            let rim = on ? rgb(0.92, 0.46, 0.10) : rgb(0.30, 0.30, 0.33)
            let bright = on ? rgb(1.00, 0.95, 0.62) : rgb(0.66, 0.66, 0.69)
            for (x, y, colour) in [
                (7, 9, core), (8, 9, mid),
                (7, 10, mid), (8, 10, core),
                (6, 10, rim), (9, 10, rim),
                (7, 11, bright), (8, 11, mid),
                (7, 12, bright),
            ] { pixel(context, x, y, colour) }

        case .signalRelayOff, .signalRelayOn:
            // The same copper cross `wire` draws underneath a small stone
            // block sitting on top of it — the block is what tells the two
            // flat things apart at a glance: a plain trace only ever
            // carries what reaches it, this one resets it.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let on = tile == .signalRelayOn
            let core = on ? rgb(0.98, 0.48, 0.12) : rgb(0.42, 0.26, 0.14)
            let glow = on ? rgb(1.0, 0.78, 0.35) : rgb(0.30, 0.18, 0.10)
            for x in 2..<14 {
                pixel(context, x, 7, core)
                pixel(context, x, 8, glow)
            }
            for y in 2..<14 {
                pixel(context, 7, y, core)
                pixel(context, 8, y, glow)
            }
            let stone = rgb(0.55, 0.55, 0.58)
            let stoneLit = on ? rgb(0.72, 0.58, 0.32) : rgb(0.45, 0.45, 0.48)
            for y in 5..<11 {
                for x in 5..<11 {
                    pixel(context, x, y, stoneLit)
                }
            }
            for x in 5..<11 {
                pixel(context, x, 5, stone)
                pixel(context, x, 10, stone)
            }
            for y in 5..<11 {
                pixel(context, 5, y, stone)
                pixel(context, 10, y, stone)
            }

        case .pressurePlateOff, .pressurePlateOn:
            // A slab of stone with a groove round its edge — the groove is
            // what reads as "this is a separate piece sitting in a
            // recess", the same visual promise wire's inset geometry makes
            // good on. Colour, not shape, says whether it is currently
            // pressed: the plate darkens the same way a lever's stub lights
            // up, a single language for "this is carrying signal" no
            // matter which primitive is doing the carrying.
            let on = tile == .pressurePlateOn
            let face = on ? rgb(0.42, 0.42, 0.44) : rgb(0.58, 0.58, 0.61)
            let groove = rgb(0.30, 0.30, 0.32)
            context.setFillColor(face.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            context.setStrokeColor(groove.cgColor)
            context.setLineWidth(1)
            context.stroke(CGRect(x: 1, y: 1, width: tilePixels - 2, height: tilePixels - 2))

        case .deadBush:
            // Bare crooked twigs and nothing else — no leaves at all, which
            // is the whole reason it reads as dead rather than as brown grass.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let twig = rgb(0.44, 0.33, 0.17)
            let paleTwig = rgb(0.56, 0.44, 0.25)
            for y in 0..<9 { pixel(context, 7, y, twig) }
            for (x, y) in [(6, 4), (5, 5), (4, 6), (3, 6), (8, 3), (9, 4), (10, 5), (11, 5),
                           (6, 8), (5, 9), (8, 9), (9, 10), (7, 10), (7, 11)] {
                pixel(context, x, y, y % 2 == 0 ? twig : paleTwig)
            }

        case .sapling, .birchSapling, .spruceSapling:
            // A short twig with a single tuft of its own species' leaf
            // colour on top — the same three greens `leaves`, `birchLeaves`
            // and `spruceLeaves` sample, so a sapling reads as the seedling
            // of the tree it is going to become rather than as a generic
            // plant.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let trunk = tile == .spruceSapling ? rgb(0.30, 0.21, 0.13)
                : tile == .birchSapling ? rgb(0.72, 0.68, 0.60) : rgb(0.45, 0.33, 0.19)
            let leaf = tile == .spruceSapling ? rgb(0.16, 0.33, 0.21)
                : tile == .birchSapling ? rgb(0.44, 0.63, 0.25) : rgb(0.27, 0.52, 0.18)
            let leafBright = tile == .spruceSapling ? rgb(0.22, 0.42, 0.27)
                : tile == .birchSapling ? rgb(0.56, 0.74, 0.33) : rgb(0.36, 0.64, 0.25)
            for y in 0..<5 {
                pixel(context, 7, y, trunk)
                pixel(context, 8, y, trunk)
            }
            for (dx, dy, bright) in [
                (-2, 4, false), (-1, 5, true), (0, 6, false), (1, 6, true), (2, 5, false),
                (-1, 3, true), (1, 3, false), (0, 4, true), (-2, 6, false), (2, 6, true),
            ] {
                pixel(context, 7 + dx, dy, bright ? leafBright : leaf)
            }

        case .wheatStage0, .wheatStage1, .wheatStage2, .wheatStage3:
            // The same sparse blades `tallGrass` draws, but progressively
            // taller and denser, and the colour drifts from sprout green to
            // harvest gold — the whole growth is legible from across a
            // field without a single frame of animation.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let stage = tile.rawValue - AtlasTile.wheatStage0.rawValue
            let blades = [1, 3, 4, 6, 7, 9, 10, 12, 14]
            let maxHeight = 4 + stage * 3
            let green = rgb(0.55, 0.68, 0.16)
            let gold = rgb(0.82, 0.68, 0.16)
            for (i, x) in blades.enumerated() {
                let bladeHeight = max(1, maxHeight - (i % 3))
                for y in 0..<bladeHeight {
                    let ripe = Double(stage) / 3.0
                    let taper = Double(y) / Double(bladeHeight)
                    let colour = ripe > 0.5
                        ? rgb(0.55 + 0.27 * ripe - taper * 0.1, 0.68 - 0.20 * ripe, 0.16)
                        : green
                    pixel(context, x, y, colour)
                }
            }
            // The ripe stage alone droops a head of grain at the tip of
            // every third blade — the one visual tell that this planting
            // is ready rather than merely tall.
            if stage == 3 {
                for x in stride(from: 1, to: tilePixels, by: 3) {
                    pixel(context, x, maxHeight, gold)
                }
            }

        case .glass:
            // Mostly transparent with a light frame and a corner glint.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            context.setFillColor(rgb(0.82, 0.91, 0.95, 0.18).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            context.setStrokeColor(rgb(0.86, 0.94, 0.98, 0.75).cgColor)
            context.setLineWidth(1)
            context.stroke(CGRect(x: 0.5, y: 0.5, width: CGFloat(tilePixels) - 1, height: CGFloat(tilePixels) - 1))
            for i in 0..<4 {
                pixel(context, 3 + i, 12 - i, rgb(1, 1, 1, 0.55))
            }

        case .bedrock:
            speckle(context, base: rgb(0.29, 0.29, 0.31),
                    shades: [rgb(0.14, 0.14, 0.15), rgb(0.44, 0.44, 0.46), rgb(0.22, 0.22, 0.24)],
                    density: 0.8, salt: 91)

        case .coalOre:
            drawOre(context, blobs: [rgb(0.10, 0.10, 0.10), rgb(0.18, 0.18, 0.18)], salt: 101)
        case .ironOre:
            drawOre(context, blobs: [rgb(0.78, 0.63, 0.51), rgb(0.65, 0.49, 0.38)], salt: 102)
        // The treasure ores glow — brighter veins, darker stone, and a
        // halo round each blob. The blocks really emit (see
        // `lightEmission`); the tile's job is to look like the source.
        case .goldOre:
            drawOre(context, blobs: [rgb(1.0, 0.86, 0.38), rgb(0.88, 0.70, 0.22)], salt: 103,
                    glow: rgb(0.58, 0.49, 0.24))
        case .diamondOre:
            drawOre(context, blobs: [rgb(0.55, 0.98, 0.95), rgb(0.36, 0.84, 0.84)], salt: 104,
                    glow: rgb(0.27, 0.48, 0.49))

        case .snow:
            speckle(context, base: rgb(0.95, 0.96, 0.98),
                    shades: [rgb(0.88, 0.91, 0.95)], density: 0.25, salt: 111)

        case .water:
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let n = noise(x, y, 121)
                    let shade = 0.30 + n * 0.10
                    pixel(context, x, y, rgb(shade * 0.35, shade * 0.85, shade * 1.6, 0.72))
                }
            }

        case .lava:
            // Molten rather than merely warm — this reads at a glance even
            // lit at its own full brightness, which a mostly-dark cooling
            // crust did not: the melt is most of the tile, cracked crust is
            // the minority, not the other way round. Opaque, unlike
            // water's translucent tint, so a pool reads as solid danger
            // rather than something to see through and swim in.
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let n = noise(x, y, 122)
                    let crust = noise(x * 2, y * 2, 123)
                    if crust > 0.45 {
                        let dark = 0.30 + n * 0.10
                        pixel(context, x, y, rgb(dark * 1.7, dark * 0.55, dark * 0.10))
                    } else {
                        let hot = 0.80 + n * 0.20
                        pixel(context, x, y, rgb(hot, hot * 0.62 + n * 0.15, hot * 0.10))
                    }
                }
            }

        case .craftingTableTop:
            fill(context, rgb(0.62, 0.47, 0.28))
            context.setStrokeColor(rgb(0.40, 0.29, 0.16).cgColor)
            context.setLineWidth(1)
            for i in 1..<3 {
                context.move(to: CGPoint(x: CGFloat(i) * 16.0 / 3, y: 0))
                context.addLine(to: CGPoint(x: CGFloat(i) * 16.0 / 3, y: 16))
                context.move(to: CGPoint(x: 0, y: CGFloat(i) * 16.0 / 3))
                context.addLine(to: CGPoint(x: 16, y: CGFloat(i) * 16.0 / 3))
            }
            context.strokePath()
            context.stroke(CGRect(x: 0.5, y: 0.5, width: 15, height: 15))

        case .craftingTableSide:
            fill(context, rgb(0.60, 0.45, 0.27))
            for y in 0..<tilePixels where y % 5 == 4 {
                for x in 0..<tilePixels { pixel(context, x, y, rgb(0.42, 0.31, 0.17)) }
            }
            context.setFillColor(rgb(0.35, 0.25, 0.13).cgColor)
            context.fill(CGRect(x: 3, y: 6, width: 2, height: 6))
            context.fill(CGRect(x: 2, y: 11, width: 4, height: 2))
            context.fill(CGRect(x: 11, y: 6, width: 2, height: 6))
            context.fill(CGRect(x: 10, y: 11, width: 4, height: 2))

        case .chestFront:
            drawChestBoards(context, salt: 401)
            // The lid line: the seam a chest opens along, two pixels down
            // from the top, with the band of iron that crosses it.
            for x in 0..<tilePixels {
                pixel(context, x, tilePixels - 5, rgb(0.26, 0.16, 0.08))
                pixel(context, x, tilePixels - 6, rgb(0.42, 0.29, 0.15))
            }
            context.setFillColor(rgb(0.30, 0.30, 0.33).cgColor)
            context.fill(CGRect(x: 6, y: 3, width: 4, height: 9))
            // The latch itself, pale enough to find at a glance across a
            // room — it is the one detail that says "this opens".
            context.setFillColor(rgb(0.74, 0.74, 0.78).cgColor)
            context.fill(CGRect(x: 7, y: 8, width: 2, height: 3))
            context.setFillColor(rgb(0.16, 0.16, 0.18).cgColor)
            context.fill(CGRect(x: 7, y: 5, width: 2, height: 2))

        case .chestTop:
            drawChestBoards(context, salt: 402)
            // Iron straps across the lid, matching where the front's band
            // runs up and over.
            context.setFillColor(rgb(0.30, 0.30, 0.33).cgColor)
            context.fill(CGRect(x: 6, y: 0, width: 4, height: 16))
            context.setFillColor(rgb(0.42, 0.42, 0.46).cgColor)
            context.fill(CGRect(x: 6, y: 0, width: 1, height: 16))

        case .furnaceFront, .furnaceFrontLit:
            let lit = tile == .furnaceFrontLit
            speckle(context, base: rgb(0.42, 0.42, 0.44),
                    shades: [rgb(0.36, 0.36, 0.38), rgb(0.50, 0.50, 0.52), rgb(0.30, 0.30, 0.32)],
                    density: 0.6, salt: 191)
            // The mouth: a dark opening cold, embers and a lick of flame
            // once something is burning behind it — the one signal the
            // whole feature leans on, since nothing here draws a UI.
            context.setFillColor((lit ? rgb(0.95, 0.42, 0.08) : rgb(0.08, 0.08, 0.09)).cgColor)
            context.fill(CGRect(x: 4, y: 3, width: 8, height: 6))
            if lit {
                context.setFillColor(rgb(1.0, 0.82, 0.35).cgColor)
                context.fill(CGRect(x: 6, y: 4, width: 4, height: 3))
                context.setFillColor(rgb(1.0, 0.95, 0.72).cgColor)
                context.fill(CGRect(x: 7, y: 5, width: 2, height: 1))
            } else {
                context.setFillColor(rgb(0.22, 0.20, 0.19).cgColor)
                context.fill(CGRect(x: 5, y: 4, width: 2, height: 4))
            }
            // A lintel of darker stone above the mouth, cold or lit alike.
            context.setFillColor(rgb(0.28, 0.28, 0.30).cgColor)
            context.fill(CGRect(x: 3, y: 2, width: 10, height: 1))

        case .hopperSide:
            speckle(context, base: rgb(0.46, 0.47, 0.50),
                    shades: [rgb(0.38, 0.39, 0.42), rgb(0.55, 0.56, 0.60)],
                    density: 0.5, salt: 233)
            // A seam where the funnel's wall meets the block below it.
            context.setFillColor(rgb(0.30, 0.31, 0.34).cgColor)
            context.fill(CGRect(x: 0, y: 11, width: tilePixels, height: 1))

        case .hopperTop:
            // The funnel mouth: a dark square hole cut into the sheet
            // metal, exactly what falls through it and nothing more.
            speckle(context, base: rgb(0.46, 0.47, 0.50),
                    shades: [rgb(0.38, 0.39, 0.42), rgb(0.55, 0.56, 0.60)],
                    density: 0.5, salt: 234)
            context.setFillColor(rgb(0.10, 0.10, 0.11).cgColor)
            context.fill(CGRect(x: 4, y: 4, width: 8, height: 8))
            context.setStrokeColor(rgb(0.20, 0.20, 0.22).cgColor)
            context.setLineWidth(1)
            context.stroke(CGRect(x: 4.5, y: 4.5, width: 7, height: 7))

        case .brick:
            fill(context, rgb(0.72, 0.72, 0.70)) // mortar
            for row in 0..<4 {
                let offset = row % 2 == 0 ? 0 : 4
                for col in -1..<3 {
                    let x = col * 8 + offset
                    let n = noise(col, row, 131)
                    context.setFillColor(rgb(0.62 + n * 0.08, 0.30 + n * 0.05, 0.24 + n * 0.04).cgColor)
                    context.fill(CGRect(x: x, y: row * 4, width: 7, height: 3))
                }
            }

        case .obsidian:
            speckle(context, base: rgb(0.09, 0.07, 0.14),
                    shades: [rgb(0.05, 0.04, 0.09), rgb(0.20, 0.16, 0.31), rgb(0.13, 0.10, 0.20)],
                    density: 0.6, salt: 141)

        case .goldBlock:
            // Cast metal rather than yellow wool, and the whole of the
            // trick is the rim: lit along the top and left, in shadow along
            // the bottom and right, the way every bevel ever drawn works.
            speckle(context, base: rgb(0.93, 0.76, 0.22),
                    shades: [rgb(0.98, 0.84, 0.34), rgb(0.87, 0.69, 0.16)],
                    density: 0.35, salt: 171)
            for i in 0..<tilePixels {
                pixel(context, i, tilePixels - 1, rgb(1.0, 0.93, 0.55))
                pixel(context, 0, i, rgb(1.0, 0.93, 0.55))
                pixel(context, i, 0, rgb(0.62, 0.46, 0.10))
                pixel(context, tilePixels - 1, i, rgb(0.62, 0.46, 0.10))
            }
            // A sparkle off the upper-left, because gold that does not
            // glint is mustard.
            for (x, y) in [(4, 11), (5, 11), (4, 10), (11, 5)] {
                pixel(context, x, y, rgb(1.0, 0.97, 0.75))
            }

        case .sandstoneCarved:
            // Sandstone with a wall's worth of glyphs cut into it: an ankh,
            // an eye and a run of water, recessed a shade darker the way a
            // relief reads at sixteen pixels. Drawn in rows-from-the-top
            // and flipped at the pixel, because the glyphs are the one
            // texture in the sheet that is a picture of something.
            speckle(context, base: rgb(0.85, 0.80, 0.58),
                    shades: [rgb(0.80, 0.75, 0.53)], density: 0.3, salt: 172)
            for x in 0..<tilePixels {
                pixel(context, x, 0, rgb(0.73, 0.68, 0.47))
                pixel(context, x, tilePixels - 1, rgb(0.73, 0.68, 0.47))
            }
            let cut = rgb(0.58, 0.52, 0.33)
            let ankh = [(4, 2), (3, 3), (5, 3), (3, 4), (5, 4), (4, 5),
                        (2, 6), (3, 6), (4, 6), (5, 6), (6, 6),
                        (4, 7), (4, 8), (4, 9), (4, 10), (4, 11), (4, 12)]
            let eye = [(8, 3), (9, 3), (10, 3), (11, 3), (12, 3), (13, 3),
                       (9, 4), (10, 4), (11, 4), (8, 5), (10, 5), (12, 5),
                       (9, 6), (10, 6), (11, 6), (12, 6), (13, 7),
                       (10, 7), (10, 8)]
            let water = [(8, 12), (9, 11), (10, 12), (11, 11), (12, 12), (13, 11), (14, 12)]
            for (x, row) in ankh + eye + water {
                pixel(context, x, tilePixels - 1 - row, cut)
            }

        case .seaStone:
            // Sea-stone: a teal body flecked light and dark, with wandering
            // dark seams so a wall of it reads as fitted masonry rather
            // than as painted stone. The seams follow the noise field, not
            // a grid — seaStone's whole look is that the lines are alive.
            speckle(context, base: rgb(0.36, 0.60, 0.56),
                    shades: [rgb(0.30, 0.53, 0.49), rgb(0.44, 0.68, 0.62), rgb(0.33, 0.57, 0.52)],
                    density: 0.55, salt: 181)
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let n = noise(x / 3, y / 3, 182)
                    let m = noise(x / 3 + 1, y / 3, 182)
                    guard abs(n - m) > 0.55 else { continue }
                    pixel(context, x, y, rgb(0.22, 0.42, 0.40))
                }
            }

        case .glowCrystal:
            // Dark umber rock crazed with veins of light: the seams are the
            // seaStone trick run bright side out, and the hottest pixels
            // sit where two veins cross.
            speckle(context, base: rgb(0.38, 0.25, 0.12),
                    shades: [rgb(0.32, 0.20, 0.09), rgb(0.44, 0.30, 0.15)],
                    density: 0.5, salt: 211)
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let n = noise(x / 3, y / 3, 212)
                    let m = noise(x / 3 + 1, y / 3, 212)
                    if abs(n - m) > 0.5 {
                        pixel(context, x, y, rgb(0.99, 0.80, 0.35))
                    } else if noise(x, y, 213) < 0.07 {
                        pixel(context, x, y, rgb(1.0, 0.93, 0.60))
                    }
                }
            }

        case .pearlLight:
            // All glow, no stone: a white-hot heart falling off to a
            // magenta rim, with a scatter of specular glints. The
            // gradient does the work — a face this bright reads as a
            // light source only if its edges are visibly cooler than
            // its middle.
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let half = Double(tilePixels - 1) / 2
                    let dx = (Double(x) - half) / half
                    let dy = (Double(y) - half) / half
                    let r = min(1.0, (dx * dx + dy * dy).squareRoot() / 1.15)
                    let t = r * r
                    var red = 1.0 - 0.04 * t
                    var green = 0.88 - 0.62 * t
                    var blue = 1.0 - 0.03 * t
                    if x == 0 || y == 0 || x == tilePixels - 1 || y == tilePixels - 1 {
                        red -= 0.08; green -= 0.10; blue -= 0.05
                    }
                    if noise(x, y, 221) > 0.94 { red = 1.0; green = 0.97; blue = 1.0 }
                    pixel(context, x, y, rgb(red, green, blue))
                }
            }

        case .sandstonePillar:
            // A fluted column shaft: vertical grooves cut into cream
            // sandstone, one groove and one lit ridge per four pixels.
            // The verticals are the whole texture — stacked, they are
            // what makes a run of cubes read as one column.
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let jitter = (noise(x, y, 231) - 0.5) * 0.05
                    var red = 0.87, green = 0.82, blue = 0.61
                    if x % 4 == 0 { red = 0.72; green = 0.66; blue = 0.47 }
                    if x % 4 == 2 { red = 0.94; green = 0.89; blue = 0.70 }
                    pixel(context, x, y, rgb(red + jitter, green + jitter, blue + jitter))
                }
            }

        case .pillarCapital:
            // The painted capital, drawn as the temple painters laid it
            // out: a plain abacus on top, a flare of green lotus leaves
            // widening upward, and gold-red-gold-blue-gold bands where
            // the capital meets its shaft. The leaves are a five-pixel
            // repeat so the pattern ties across neighbouring faces.
            let cream = rgb(0.90, 0.84, 0.64)
            fill(context, cream)
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    switch y {
                    case 0...1:
                        // Meets the fluted shaft below.
                        if x % 4 == 0 { pixel(context, x, y, rgb(0.74, 0.68, 0.48)) }
                    case 2, 4, 6: pixel(context, x, y, rgb(0.87, 0.69, 0.22))
                    case 3: pixel(context, x, y, rgb(0.24, 0.38, 0.68))
                    case 5: pixel(context, x, y, rgb(0.78, 0.24, 0.17))
                    case 7...13:
                        let hw = (y - 7) / 3
                        let dc = abs((x % 5) - 2)
                        if dc <= hw {
                            pixel(context, x, y, dc < hw || hw == 0
                                ? rgb(0.24, 0.60, 0.28) : rgb(0.15, 0.44, 0.20))
                        }
                    default:
                        // The abacus: a shaded top edge, so the block ends
                        // in a slab rather than in leaves against sky.
                        pixel(context, x, y, y == 15
                            ? rgb(0.82, 0.76, 0.55) : rgb(0.93, 0.88, 0.70))
                    }
                }
            }

        case .plaster:
            // Lime plaster: warm off-white with a faint trowel mottle. The
            // quiet field the timber frame's beams read against, and quiet
            // is the whole job — any more texture and a wall of it shimmers.
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let mottle = (noise(x, y, 411) - 0.5) * 0.04
                    let seam = noise(x / 3, y / 3, 413) < 0.12 ? -0.03 : 0.0
                    pixel(context, x, y, rgb(
                        0.91 + mottle + seam, 0.88 + mottle + seam, 0.79 + mottle + seam
                    ))
                }
            }

        case .timberFrame:
            // Half-timbering: the plaster field crossed by dark oak — a
            // sill, a lintel, two posts and one diagonal brace. One brace
            // rather than an X because at sixteen pixels an X reads as a
            // shutter; the diagonal ties across a wall of these anyway.
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let mottle = (noise(x, y, 421) - 0.5) * 0.04
                    let beam = y <= 1 || y >= 14 || x <= 1 || x >= 14
                        || abs(x - y) <= 1
                    if beam {
                        let grain = (noise(x, y, 423) - 0.5) * 0.06
                        pixel(context, x, y, rgb(0.33 + grain, 0.23 + grain, 0.13 + grain))
                    } else {
                        pixel(context, x, y, rgb(0.91 + mottle, 0.88 + mottle, 0.79 + mottle))
                    }
                }
            }

        case .cloud:
            // A cloud you can stand on: white going faintly blue-grey
            // toward the bottom of the face, with drifts of brighter white
            // — soft, but unmistakably a block, because the game's whole
            // charm is that even the sky comes in cubes.
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let settle = Double(tilePixels - 1 - y) / 15.0 * 0.10
                    let drift = noise(x / 2, y / 2, 431) < 0.30 ? 0.03 : 0.0
                    pixel(context, x, y, rgb(
                        0.97 - settle + drift, 0.97 - settle * 0.8 + drift, 0.99 + drift
                    ))
                }
            }

        case .balloonCanvas:
            // Airship canvas: cream and terracotta gores with a stitched
            // seam between panels, the way the balloon in the reference
            // painting is striped.
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let weave = (noise(x, y, 441) - 0.5) * 0.05
                    let stripe = (x / 4) % 2 == 0
                    var color = stripe
                        ? (0.93 + weave, 0.87 + weave, 0.72 + weave)
                        : (0.79 + weave, 0.36 + weave, 0.21 + weave)
                    // The seam rows where panels are sewn, slightly darker.
                    if y == 7 || x % 4 == 3 {
                        color = (color.0 - 0.08, color.1 - 0.08, color.2 - 0.08)
                    }
                    pixel(context, x, y, rgb(color.0, color.1, color.2))
                }
            }

        case .radiantRed:
            radiantGlass(context, hue: (1.0, 0.30, 0.25))
        case .radiantYellow:
            radiantGlass(context, hue: (1.0, 0.85, 0.20))
        case .radiantGreen:
            radiantGlass(context, hue: (0.35, 0.95, 0.35))
        case .radiantCyan:
            radiantGlass(context, hue: (0.30, 0.95, 0.95))

        case .diamondBlock:
            // The gold block's drawing in diamond's colours: pale ice-cyan
            // with the same lit-and-shadowed bevel, and more sparkle,
            // because diamond that does not sparkle is just teal.
            speckle(context, base: rgb(0.55, 0.87, 0.85),
                    shades: [rgb(0.64, 0.93, 0.91), rgb(0.47, 0.80, 0.79)],
                    density: 0.35, salt: 201)
            for i in 0..<tilePixels {
                pixel(context, i, tilePixels - 1, rgb(0.80, 0.99, 0.97))
                pixel(context, 0, i, rgb(0.80, 0.99, 0.97))
                pixel(context, i, 0, rgb(0.30, 0.58, 0.58))
                pixel(context, tilePixels - 1, i, rgb(0.30, 0.58, 0.58))
            }
            for (x, y) in [(4, 11), (5, 11), (4, 10), (11, 5), (10, 4), (12, 10), (6, 4)] {
                pixel(context, x, y, rgb(0.97, 1.0, 1.0))
            }

        case .seaLantern:
            // A glowing core behind a pale frame. The brightness is real —
            // the block floods light like a torch — so the tile's job is
            // only to look like the thing doing it: hot white-cyan in the
            // middle, cooling toward a grey-teal border.
            fill(context, rgb(0.76, 0.83, 0.81))
            let centre = Double(tilePixels - 1) / 2
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let d = max(abs(Double(x) - centre), abs(Double(y) - centre))
                    let jitter = (noise(x, y, 191) - 0.5) * 0.06
                    if d < 5 {
                        let t = d / 5
                        pixel(context, x, y, rgb(
                            0.93 - t * 0.12 + jitter,
                            0.99 - t * 0.10 + jitter,
                            0.96 - t * 0.08 + jitter
                        ))
                    } else if d < 6.5 {
                        pixel(context, x, y, rgb(0.62 + jitter, 0.76 + jitter, 0.74 + jitter))
                    }
                }
            }

        case .doorBottom:
            // The solid half: vertical boards with a recessed panel routed
            // into them. Nothing transparent — a door you can see through
            // at knee height reads as a hole.
            drawDoorBoards(context, salt: 151)
            context.setStrokeColor(rgb(0.38, 0.27, 0.14).cgColor)
            context.setLineWidth(1)
            context.stroke(CGRect(x: 3.5, y: 2.5, width: 9, height: 11))
            context.setStrokeColor(rgb(0.74, 0.59, 0.38).cgColor)
            context.stroke(CGRect(x: 4.5, y: 3.5, width: 7, height: 9))

        case .doorTop:
            // The half with the window in it. The panes are painted rather
            // than cut out: the door is an opaque-pass block, so an actual
            // hole would show whatever the depth buffer happened to hold.
            drawDoorBoards(context, salt: 152)
            context.setFillColor(rgb(0.38, 0.27, 0.14).cgColor)
            context.fill(CGRect(x: 2, y: 5, width: 12, height: 10))
            context.setFillColor(rgb(0.62, 0.78, 0.86).cgColor)
            context.fill(CGRect(x: 3, y: 6, width: 10, height: 8))
            // Muntin bars, splitting the opening into four panes.
            context.setFillColor(rgb(0.42, 0.31, 0.17).cgColor)
            context.fill(CGRect(x: 7, y: 6, width: 2, height: 8))
            context.fill(CGRect(x: 3, y: 9, width: 10, height: 2))
            // A glint in the upper-left pane, so the glass reads as glass.
            for i in 0..<3 { pixel(context, 4 + i, 13 - i, rgb(0.88, 0.95, 1.0)) }
            // Brass handle, low on this half — where a hand reaches.
            context.setFillColor(rgb(0.78, 0.68, 0.28).cgColor)
            context.fill(CGRect(x: 12, y: 2, width: 2, height: 2))

        case .bedBlanket:
            drawBedCloth(context, salt: 161)

        case .bedPillow:
            drawBedCloth(context, salt: 162)
            // A pillow sitting in the middle of the head cell. Centred on
            // purpose: the top face's UVs turn with the bed's facing, and a
            // pillow shoved against one end would end up against the wrong
            // one for two of the four directions.
            context.setFillColor(rgb(0.93, 0.93, 0.90).cgColor)
            context.fill(CGRect(x: 2, y: 4, width: 12, height: 8))
            context.setFillColor(rgb(0.82, 0.82, 0.79).cgColor)
            context.fill(CGRect(x: 2, y: 4, width: 12, height: 1))
            context.fill(CGRect(x: 2, y: 4, width: 1, height: 8))
            for x in 3..<14 where noise(x, 5, 163) < 0.3 {
                pixel(context, x, 10, rgb(0.86, 0.86, 0.83))
            }

        case .bedSide:
            // A bed stands 9/16 high, so a side face only ever samples the
            // bottom nine-sixteenths of this tile: wooden frame low, the
            // blanket's hem in rows 6…9, and what is above that is never
            // reached.
            fill(context, rgb(0.72, 0.16, 0.16))
            context.setFillColor(rgb(0.52, 0.38, 0.22).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 6))
            for y in 0..<6 {
                for x in 0..<tilePixels where noise(x, y, 171) < 0.25 {
                    pixel(context, x, y, rgb(0.44, 0.32, 0.18))
                }
            }
            for x in 0..<tilePixels { pixel(context, x, 6, rgb(0.55, 0.10, 0.10)) }
            for y in 7..<10 {
                for x in 0..<tilePixels where noise(x, y, 172) < 0.35 {
                    pixel(context, x, y, rgb(0.80, 0.22, 0.22))
                }
            }
            // Stubby wooden legs at the corners.
            context.setFillColor(rgb(0.38, 0.27, 0.15).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
            context.fill(CGRect(x: 13, y: 0, width: 3, height: 3))

        default:
            drawGardenTile(tile, in: context)
        }
    }

    /// The Sleeping Garden's tiles, kept apart from the long switch above
    /// so the storyline's pictures read as one family.
    private static func drawGardenTile(_ tile: AtlasTile, in context: CGContext) {
        switch tile {
        case .radioFront, .radioFrontLit:
            // A grey cabinet with a speaker grille and one lamp — dead red
            // until it is mended, warm amber once it speaks.
            let lit = tile == .radioFrontLit
            speckle(context, base: rgb(0.40, 0.42, 0.44),
                    shades: [rgb(0.34, 0.36, 0.38), rgb(0.47, 0.49, 0.51)], density: 0.45, salt: 301)
            context.setFillColor(rgb(0.16, 0.17, 0.18).cgColor)
            context.fill(CGRect(x: 2, y: 2, width: 12, height: 8))
            for y in stride(from: 3, to: 9, by: 2) {
                for x in stride(from: 3, to: 13, by: 2) {
                    pixel(context, x, y, rgb(0.30, 0.31, 0.33))
                }
            }
            context.setFillColor((lit ? rgb(1.0, 0.78, 0.30) : rgb(0.45, 0.10, 0.08)).cgColor)
            context.fill(CGRect(x: 11, y: 11, width: 3, height: 3))
            if lit { pixel(context, 12, 12, rgb(1.0, 0.96, 0.75)) }
            // The dial and its needle.
            context.setFillColor(rgb(0.80, 0.78, 0.66).cgColor)
            context.fill(CGRect(x: 2, y: 11, width: 7, height: 3))
            pixel(context, lit ? 7 : 3, 12, rgb(0.70, 0.16, 0.12))

        case .plaque:
            // Smooth pale stone with lines of carving on it.
            speckle(context, base: rgb(0.70, 0.69, 0.64),
                    shades: [rgb(0.64, 0.63, 0.58), rgb(0.76, 0.75, 0.70)], density: 0.4, salt: 311)
            context.setStrokeColor(rgb(0.50, 0.49, 0.45).cgColor)
            context.setLineWidth(1)
            context.stroke(CGRect(x: 1.5, y: 1.5, width: 13, height: 13))
            for (y, length) in [(11, 9), (8, 10), (5, 7)] {
                for x in 3..<(3 + length) where noise(x, y, 312) < 0.8 {
                    pixel(context, x, y, rgb(0.38, 0.37, 0.34))
                }
            }

        case .meteorOre:
            // Dark scorched rock with glinting blue-violet metal in it.
            drawOre(context, blobs: [rgb(0.62, 0.66, 0.95), rgb(0.44, 0.40, 0.78)], salt: 321,
                    glow: rgb(0.30, 0.28, 0.48))

        case .padTop:
            // Steel plate with a yellow-and-black ring: a place to land.
            speckle(context, base: rgb(0.52, 0.53, 0.56),
                    shades: [rgb(0.46, 0.47, 0.50), rgb(0.58, 0.59, 0.62)], density: 0.4, salt: 331)
            let centre = 7.5
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let dx = Double(x) - centre, dy = Double(y) - centre
                    let radius = (dx * dx + dy * dy).squareRoot()
                    if radius > 4.5 && radius < 6.5 {
                        let stripe = ((x + y) / 2) % 2 == 0
                        pixel(context, x, y, stripe ? rgb(0.95, 0.78, 0.16) : rgb(0.12, 0.12, 0.13))
                    }
                }
            }
            context.setFillColor(rgb(0.86, 0.22, 0.18).cgColor)
            context.fill(CGRect(x: 6, y: 6, width: 4, height: 4))

        case .rocketHull, .rocketWindow:
            // White panels with rivet lines; the cabin's has a round
            // window looking out.
            fill(context, rgb(0.90, 0.91, 0.93))
            for i in 0..<tilePixels {
                pixel(context, i, 0, rgb(0.70, 0.72, 0.76))
                pixel(context, 0, i, rgb(0.70, 0.72, 0.76))
            }
            for i in stride(from: 2, to: tilePixels, by: 4) {
                pixel(context, i, 1, rgb(0.62, 0.64, 0.68))
                pixel(context, 1, i, rgb(0.62, 0.64, 0.68))
            }
            if tile == .rocketWindow {
                let centre = 8.0
                for y in 0..<tilePixels {
                    for x in 0..<tilePixels {
                        let dx = Double(x) + 0.5 - centre, dy = Double(y) + 0.5 - centre
                        let radius = (dx * dx + dy * dy).squareRoot()
                        if radius < 3.6 {
                            pixel(context, x, y, rgb(0.22 + dy * 0.02, 0.48, 0.78))
                        } else if radius < 5 {
                            pixel(context, x, y, rgb(0.86, 0.22, 0.18))
                        }
                    }
                }
                pixel(context, 6, 9, rgb(0.85, 0.95, 1.0))
            } else {
                // A red band, so the tank reads as part of the same craft.
                context.setFillColor(rgb(0.86, 0.22, 0.18).cgColor)
                context.fill(CGRect(x: 0, y: 6, width: 16, height: 3))
            }

        case .rocketEngine:
            // Dark metal flaring to a nozzle, with a glow inside it.
            fill(context, rgb(0.30, 0.31, 0.34))
            context.setFillColor(rgb(0.44, 0.45, 0.48).cgColor)
            context.fill(CGRect(x: 3, y: 4, width: 10, height: 12))
            context.setFillColor(rgb(0.14, 0.14, 0.16).cgColor)
            context.fill(CGRect(x: 4, y: 0, width: 8, height: 5))
            context.setFillColor(rgb(0.98, 0.58, 0.16).cgColor)
            context.fill(CGRect(x: 6, y: 0, width: 4, height: 3))
            pixel(context, 7, 1, rgb(1.0, 0.92, 0.55))
            pixel(context, 8, 1, rgb(1.0, 0.92, 0.55))

        case .airMakerSide, .airMakerTop:
            // A green-glassed tank of leaves behind iron, and a fan on top.
            speckle(context, base: rgb(0.66, 0.68, 0.70),
                    shades: [rgb(0.58, 0.60, 0.62), rgb(0.74, 0.76, 0.78)], density: 0.4, salt: 341)
            if tile == .airMakerSide {
                context.setFillColor(rgb(0.20, 0.42, 0.24).cgColor)
                context.fill(CGRect(x: 3, y: 3, width: 10, height: 10))
                for y in 3..<13 {
                    for x in 3..<13 where noise(x, y, 342) < 0.35 {
                        pixel(context, x, y, rgb(0.36, 0.66, 0.30))
                    }
                }
                for i in 3..<13 { pixel(context, i, 8, rgb(0.55, 0.57, 0.60)) }
            } else {
                context.setFillColor(rgb(0.22, 0.23, 0.25).cgColor)
                context.fillEllipse(in: CGRect(x: 2, y: 2, width: 12, height: 12))
                for i in 3..<13 {
                    pixel(context, i, i, rgb(0.70, 0.72, 0.74))
                    pixel(context, i, 15 - i, rgb(0.70, 0.72, 0.74))
                }
            }

        case .moonDust:
            speckle(context, base: rgb(0.72, 0.72, 0.70),
                    shades: [rgb(0.64, 0.64, 0.63), rgb(0.80, 0.80, 0.78), rgb(0.58, 0.58, 0.57)],
                    density: 0.7, salt: 351)

        case .moonRock:
            speckle(context, base: rgb(0.46, 0.46, 0.47),
                    shades: [rgb(0.38, 0.38, 0.40), rgb(0.54, 0.54, 0.55), rgb(0.32, 0.32, 0.34)],
                    density: 0.65, salt: 361)
            // A few small pits.
            for (x, y) in [(3, 4), (10, 11), (12, 3), (6, 12)] {
                pixel(context, x, y, rgb(0.24, 0.24, 0.26))
                pixel(context, x + 1, y, rgb(0.30, 0.30, 0.32))
            }

        case .moonBrick:
            fill(context, rgb(0.36, 0.36, 0.38))
            for row in 0..<4 {
                let offset = row % 2 == 0 ? 0 : 4
                for col in -1..<3 {
                    let x = col * 8 + offset
                    let n = noise(col, row, 371)
                    context.setFillColor(rgb(0.70 + n * 0.06, 0.70 + n * 0.06, 0.68 + n * 0.05).cgColor)
                    context.fill(CGRect(x: x, y: row * 4, width: 7, height: 3))
                }
            }

        case .prismGlass:
            // Glass with a rainbow running through it.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let t = Double((x + y) % 16) / 16
                    let colour = rgb(0.6 + 0.4 * sin(t * 6.28), 0.6 + 0.4 * sin(t * 6.28 + 2.1),
                                     0.6 + 0.4 * sin(t * 6.28 + 4.2), 0.32)
                    pixel(context, x, y, colour)
                }
            }
            context.setStrokeColor(rgb(0.85, 0.90, 1.0, 0.85).cgColor)
            context.setLineWidth(1)
            context.stroke(CGRect(x: 0.5, y: 0.5, width: 15, height: 15))
            for i in 0..<5 { pixel(context, 3 + i, 12 - i, rgb(1, 1, 1, 0.75)) }

        case .gardenSeal:
            // A heavy round door of dark metal, a leaf picked out on it.
            speckle(context, base: rgb(0.20, 0.24, 0.24),
                    shades: [rgb(0.16, 0.19, 0.19), rgb(0.26, 0.30, 0.30)], density: 0.5, salt: 381)
            context.setStrokeColor(rgb(0.48, 0.56, 0.52).cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: CGRect(x: 1.5, y: 1.5, width: 13, height: 13))
            for (x, y) in [(7, 4), (7, 5), (7, 6), (7, 7), (7, 8), (6, 8), (8, 8), (5, 9), (9, 9),
                           (6, 10), (8, 10), (7, 11)] {
                pixel(context, x, y, rgb(0.42, 0.78, 0.46))
            }

        case .silverThatch:
            // Woven silver reed, the strands crossing.
            fill(context, rgb(0.62, 0.66, 0.70))
            for y in 0..<tilePixels {
                for x in 0..<tilePixels {
                    let weave = ((x / 2) + (y / 2)) % 2 == 0
                    let n = noise(x, y, 391) * 0.08
                    pixel(context, x, y, weave ? rgb(0.80 + n, 0.83 + n, 0.88 + n) : rgb(0.56 + n, 0.60 + n, 0.65 + n))
                }
            }

        case .gardenSprout:
            // Two round leaves on a short stem — the same start for both.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let stem = rgb(0.30, 0.52, 0.26)
            for y in 0..<4 { pixel(context, 7, y, stem) }
            for (x, y) in [(5, 4), (6, 4), (6, 5), (8, 4), (9, 4), (8, 5), (4, 5), (10, 5)] {
                pixel(context, x, y, rgb(0.42, 0.74, 0.40))
            }

        case .lampBloomStage1, .lampBloomStage2, .lampBloomStage3:
            // A stalk with a bud that opens into a glowing flower.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let stage = tile.rawValue - AtlasTile.lampBloomStage1.rawValue + 1
            let height = 4 + stage * 2
            let stem = rgb(0.24, 0.50, 0.30)
            for y in 0..<height { pixel(context, 7, y, stem) }
            for (x, y) in [(5, 2), (6, 3), (9, 3), (8, 4), (5, 6), (9, 7)] where y < height {
                pixel(context, x, y, rgb(0.36, 0.66, 0.38))
            }
            let head = height
            if stage == 1 {
                pixel(context, 7, head, rgb(0.70, 0.66, 0.30))
            } else {
                let glow = stage == 3 ? rgb(1.0, 0.92, 0.50) : rgb(0.90, 0.78, 0.34)
                let petal = stage == 3 ? rgb(1.0, 0.70, 0.30) : rgb(0.80, 0.60, 0.28)
                for (dx, dy) in [(0, 0), (0, 1), (0, 2), (-1, 1), (1, 1)] {
                    pixel(context, 7 + dx, head + dy, glow)
                }
                if stage == 3 {
                    for (dx, dy) in [(-2, 1), (2, 1), (-1, 0), (1, 0), (-1, 2), (1, 2), (0, 3)] {
                        pixel(context, 7 + dx, head + dy, petal)
                    }
                }
            }

        case .silverReedStage1, .silverReedStage2, .silverReedStage3:
            // Thin blades that go from green to shining silver.
            context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
            let stage = tile.rawValue - AtlasTile.silverReedStage1.rawValue + 1
            let tall = 5 + stage * 3
            let colour = stage == 3 ? rgb(0.82, 0.86, 0.92) : (stage == 2 ? rgb(0.56, 0.70, 0.62) : rgb(0.40, 0.62, 0.40))
            for (i, x) in [2, 4, 7, 9, 12, 14].enumerated() {
                let h = max(2, tall - (i % 3) * 2)
                for y in 0..<h { pixel(context, x, y, colour) }
                if stage == 3 { pixel(context, x, h, rgb(0.96, 0.97, 1.0)) }
            }

        default:
            fill(context, rgb(0.7, 0.4, 0.8))
        }
    }

    /// The plank field both door halves are cut from: vertical boards with
    /// dark seams, so the two halves stack into one continuous door.
    /// The wooden body of a chest: planks a shade redder than the ones a
    /// house is built from, with a dark rim so the box has edges.
    private static func drawChestBoards(_ context: CGContext, salt: Int) {
        for y in 0..<tilePixels {
            for x in 0..<tilePixels {
                let n = noise(x, y, salt)
                let grain: CGFloat = y % 5 == 0 ? -0.07 : 0
                pixel(context, x, y, rgb(
                    0.52 + n * 0.08 + grain, 0.33 + n * 0.06 + grain, 0.16 + n * 0.04
                ))
            }
        }
        for i in 0..<tilePixels {
            pixel(context, i, 0, rgb(0.31, 0.19, 0.09))
            pixel(context, i, tilePixels - 1, rgb(0.31, 0.19, 0.09))
            pixel(context, 0, i, rgb(0.31, 0.19, 0.09))
            pixel(context, tilePixels - 1, i, rgb(0.31, 0.19, 0.09))
        }
    }

    private static func drawDoorBoards(_ context: CGContext, salt: Int) {
        fill(context, rgb(0.64, 0.49, 0.29))
        for y in 0..<tilePixels {
            for x in 0..<tilePixels where noise(x, y, salt) < 0.22 {
                pixel(context, x, y, rgb(0.57, 0.43, 0.25))
            }
        }
        for x in [0, 7, 15] {
            for y in 0..<tilePixels { pixel(context, x, y, rgb(0.42, 0.31, 0.17)) }
        }
    }

    /// Red woollen bedding, the base both bed tops are drawn over.
    private static func drawBedCloth(_ context: CGContext, salt: Int) {
        speckle(context, base: rgb(0.72, 0.16, 0.16),
                shades: [rgb(0.64, 0.13, 0.13), rgb(0.80, 0.22, 0.22)],
                density: 0.5, salt: salt)
        context.setStrokeColor(rgb(0.55, 0.10, 0.10).cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(x: 0.5, y: 0.5, width: 15, height: 15))
    }

    /// Stone base with a scatter of ore blobs — one generator for all four
    /// ores, differing only in the blob colours.
    /// An ore tile: stone with four flecked blobs. `glow` turns it into the
    /// luminous kind — the stone goes a shade darker so the veins carry,
    /// and each blob gets a halo of half-lit rock around it, which is the
    /// whole visual grammar of "the light is coming from inside".
    private static func drawOre(
        _ context: CGContext, blobs: [NSColor], salt: Int, glow: NSColor? = nil
    ) {
        if glow != nil {
            speckle(context, base: rgb(0.40, 0.40, 0.42),
                    shades: [rgb(0.34, 0.34, 0.36), rgb(0.46, 0.46, 0.48)], density: 0.5, salt: 21)
        } else {
            speckle(context, base: rgb(0.50, 0.50, 0.50),
                    shades: [rgb(0.44, 0.44, 0.44), rgb(0.57, 0.57, 0.57)], density: 0.5, salt: 21)
        }
        for blob in 0..<4 {
            let bx = 2 + Int(noise(blob, 0, salt) * 11)
            let by = 2 + Int(noise(blob, 1, salt) * 11)
            if let glow {
                for dy in -1..<4 {
                    for dx in -1..<4 {
                        let inBlob = dx >= 0 && dx < 3 && dy >= 0 && dy < 3
                        guard !inBlob,
                              noise(bx + dx, by + dy, salt &+ 7) < 0.6 else { continue }
                        pixel(context, bx + dx, by + dy, glow)
                    }
                }
            }
            for dy in 0..<3 {
                for dx in 0..<3 {
                    let edge = dx == 2 || dy == 2
                    guard !edge || noise(bx + dx, by + dy, salt &+ 3) < 0.5 else { continue }
                    pixel(context, bx + dx, by + dy, blobs[(dx + dy) % blobs.count])
                }
            }
        }
    }

    /// Progressive crack overlay: transparent except for dark fracture
    /// lines that multiply in count as `stage` rises 0…9.
    private static func drawCracks(_ context: CGContext, stage: Int) {
        context.clear(CGRect(x: 0, y: 0, width: tilePixels, height: tilePixels))
        context.setStrokeColor(rgb(0, 0, 0, 0.66).cgColor)
        context.setLineWidth(1)
        for stroke in 0...stage {
            // Each crack radiates from near the centre at its own angle,
            // lengthening with the stage so early cracks stay short.
            let angle = noise(stroke, 0, 201) * .pi * 2
            let length = 2.0 + Double(stage) * 0.7
            let cx = 8.0 + (noise(stroke, 1, 202) - 0.5) * 4
            let cy = 8.0 + (noise(stroke, 2, 203) - 0.5) * 4
            context.move(to: CGPoint(x: cx - cos(angle) * length, y: cy - sin(angle) * length))
            context.addLine(to: CGPoint(x: cx + cos(angle) * length, y: cy + sin(angle) * length))
            // A short branch off the midpoint, so cracks fork like real ones.
            let branch = angle + 1.1
            context.move(to: CGPoint(x: cx, y: cy))
            context.addLine(to: CGPoint(x: cx + cos(branch) * length * 0.6, y: cy + sin(branch) * length * 0.6))
        }
        context.strokePath()
    }
}
#endif

#if canImport(AppKit)
import AppKit
import CoreGraphics

/// Inventory icons. Block items are drawn as small isometric cubes built
/// from their own three visible atlas faces — the single cheapest thing
/// that makes an inventory read as the original's rather than a grid of flat
/// swatches. Tools and materials are drawn as flat sprites.
enum ItemIcons {
    static let size: CGFloat = 48

    static func icon(for item: ItemType) -> NSImage {
        if let cached = cache[item] { return cached }
        let image: NSImage
        switch item {
        // The shaped blocks have no `placedBlock` — which case they place
        // depends on where the player is standing — so they would fall
        // through to the flat sprites. Stairs and beds are boxes and read
        // best drawn as boxes, at the same isometric the cubes use.
        case .oakStairs: image = stairsIcon(material: .planks)
        case .cobbleStairs: image = stairsIcon(material: .cobblestone)
        case .bed: image = bedIcon()
        default:
            // A plant has a `placedBlock`, so without this it would fall to
            // the isometric cube path and come out as a box with a flower
            // painted on three of its sides. Its own tile, drawn flat, is
            // both the right picture and the same picture the world shows.
            if item.isPlant, let block = item.placedBlock {
                image = plantIcon(tile: block.plantTile)
                cache[item] = image
                return image
            }
            if let block = item.placedBlock {
                image = cubeIcon(for: block)
            } else {
                image = flatIcon(for: item)
            }
        }
        cache[item] = image
        return image
    }

    private static var cache: [ItemType: NSImage] = [:]

    // MARK: - Block cubes

    /// Draws a block as an isometric cube. Each visible face is the atlas
    /// tile for that face, sheared into a parallelogram and shaded so the
    /// three planes separate.
    private static func cubeIcon(for block: BlockType) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let context = NSGraphicsContext.current?.cgContext else { return image }
        NSGraphicsContext.current?.imageInterpolation = .none

        // Cube laid out in a 32×32 design space, then scaled to `size`.
        let scale = size / 32
        context.scaleBy(x: scale, y: scale)

        // Each face: the affine transform mapping the unit square onto that
        // face's parallelogram, plus a brightness.
        let faces: [(FaceKind, CGAffineTransform, CGFloat)] = [
            // Top: left corner (0,24) → right (32,24) via bottom (16,16)/top (16,32)
            (.top, CGAffineTransform(a: 16, b: -8, c: 16, d: 8, tx: 0, ty: 24), 1.0),
            // Left face
            (.side, CGAffineTransform(a: 16, b: -8, c: 0, d: 16, tx: 0, ty: 8), 0.72),
            // Right face
            (.side, CGAffineTransform(a: 16, b: 8, c: 0, d: 16, tx: 16, ty: 0), 0.55),
        ]

        for (face, transform, brightness) in faces {
            let tile = block.tile(for: face)
            context.saveGState()
            context.concatenate(transform)
            context.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            if let cg = TextureAtlas.tileImage(tile).cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            if brightness < 1 {
                context.setFillColor(NSColor(calibratedWhite: 0, alpha: 1 - brightness).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            context.restoreGState()
        }
        return image
    }

    // MARK: - Isometric boxes

    /// The isometric projection the cube icons are drawn in, expressed as a
    /// point map so shapes made of more than one box can use it too.
    ///
    /// Read straight off `cubeIcon`'s three transforms: a block's +X runs
    /// down-right, its +Z runs up-right, and its +Y runs straight up, in a
    /// 32×32 design space with the block's own origin at (0, 8).
    private static func iso(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CGPoint {
        CGPoint(x: 16 * (x + z), y: 8 + 16 * y - 8 * x + 8 * z)
    }

    /// Brightness per visible face, matching `cubeIcon` so a stair sits
    /// next to its own block in the inventory without looking lit
    /// differently.
    private static let topShade: CGFloat = 1.0
    private static let leftShade: CGFloat = 0.72
    private static let rightShade: CGFloat = 0.55

    /// Draws one axis-aligned box in the isometric above: its top, its
    /// `z = min` face and its `x = max` face, which are the three a viewer
    /// at this angle can see.
    ///
    /// `topTile` and `sideTile` are atlas tiles, drawn by mapping the unit
    /// square onto each face's parallelogram — the same trick `cubeIcon`
    /// uses, and the reason these icons are made of the game's own textures
    /// rather than flat colours.
    private static func drawIsoBox(
        _ context: CGContext,
        _ box: BlockBox,
        topTile: AtlasTile,
        sideTile: AtlasTile
    ) {
        let faces: [(AtlasTile, CGPoint, CGPoint, CGPoint, CGFloat)] = [
            // Top: origin at (minX, maxY, minZ), spanning +X and +Z.
            (topTile,
             iso(box.minX, box.maxY, box.minZ),
             iso(box.maxX, box.maxY, box.minZ),
             iso(box.minX, box.maxY, box.maxZ), topShade),
            // Left: the z = minZ wall, spanning +X and +Y.
            (sideTile,
             iso(box.minX, box.minY, box.minZ),
             iso(box.maxX, box.minY, box.minZ),
             iso(box.minX, box.maxY, box.minZ), leftShade),
            // Right: the x = maxX wall, spanning +Z and +Y.
            (sideTile,
             iso(box.maxX, box.minY, box.minZ),
             iso(box.maxX, box.minY, box.maxZ),
             iso(box.maxX, box.maxY, box.minZ), rightShade),
        ]

        for (tile, origin, alongU, alongV, brightness) in faces {
            let u = CGPoint(x: alongU.x - origin.x, y: alongU.y - origin.y)
            let v = CGPoint(x: alongV.x - origin.x, y: alongV.y - origin.y)
            context.saveGState()
            context.concatenate(
                CGAffineTransform(a: u.x, b: u.y, c: v.x, d: v.y, tx: origin.x, ty: origin.y)
            )
            context.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1))
            if let cg = TextureAtlas.tileImage(tile).cgImage(forProposedRect: nil, context: nil, hints: nil) {
                context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            if brightness < 1 {
                context.setFillColor(NSColor(calibratedWhite: 0, alpha: 1 - brightness).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            context.restoreGState()
        }
    }

    /// Sets up the 32-unit isometric design space, optionally shrunk and
    /// nudged so a shape bigger than one block still fits the icon.
    private static func isoImage(
        scale extra: CGFloat = 1, offset: CGPoint = .zero, draw: (CGContext) -> Void
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let context = NSGraphicsContext.current?.cgContext else { return image }
        NSGraphicsContext.current?.imageInterpolation = .none
        context.scaleBy(x: size / 32, y: size / 32)
        context.translateBy(x: offset.x, y: offset.y)
        context.scaleBy(x: extra, y: extra)
        draw(context)
        return image
    }

    /// A staircase: the bottom half-slab with the back quarter standing on
    /// it, which is the actual shape of the block.
    ///
    /// The upper box is drawn first because it is the further away of the
    /// two — at this angle larger Z is deeper — so the slab in front of it
    /// paints over the edge it hides.
    private static func stairsIcon(material: BlockType) -> NSImage {
        let top = material.tile(for: .top)
        let side = material.tile(for: .side)
        return isoImage(scale: 0.92, offset: CGPoint(x: 1.5, y: 1)) { context in
            drawIsoBox(context, BlockBox(0, 0.5, 0.5, 1, 1, 1), topTile: top, sideTile: side)
            drawIsoBox(context, BlockBox(0, 0, 0, 1, 0.5, 1), topTile: top, sideTile: side)
        }
    }

    /// A bed: two cells long, the near one blanket and the far one pillow,
    /// shrunk to fit the slot.
    private static func bedIcon() -> NSImage {
        isoImage(scale: 0.62, offset: CGPoint(x: 0, y: 6)) { context in
            // Head first — it is the deeper of the two cells.
            drawIsoBox(context, BlockBox(0, 0, 1, 1, BlockType.bedHeight, 2),
                       topTile: .bedPillow, sideTile: .bedSide)
            drawIsoBox(context, BlockBox(0, 0, 0, 1, BlockType.bedHeight, 1),
                       topTile: .bedBlanket, sideTile: .bedSide)
        }
    }

    /// A plant's atlas tile blown up to icon size, nearest-neighbour, on
    /// the transparent field the tile already has.
    private static func plantIcon(tile: AtlasTile) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .none
        TextureAtlas.tileImage(tile).draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: .zero, operation: .sourceOver, fraction: 1
        )
        return image
    }

    // MARK: - Flat sprites

    private static func flatIcon(for item: ItemType) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let context = NSGraphicsContext.current?.cgContext else { return image }
        let scale = size / 16
        context.scaleBy(x: scale, y: scale)

        switch item {
        case .stick:
            drawStick(context)
        case .coal:
            drawNugget(context, color: rgb(0.13, 0.13, 0.14), highlight: rgb(0.30, 0.30, 0.32))
        case .rawIron:
            drawNugget(context, color: rgb(0.76, 0.63, 0.53), highlight: rgb(0.90, 0.80, 0.72))
        case .rawGold:
            drawNugget(context, color: rgb(0.88, 0.72, 0.24), highlight: rgb(1.0, 0.88, 0.45))
        case .diamond:
            drawGem(context, color: rgb(0.40, 0.90, 0.88), highlight: rgb(0.75, 1.0, 0.99))
        case .ironIngot:
            drawIngot(context, color: rgb(0.83, 0.83, 0.86), highlight: rgb(0.95, 0.95, 0.98))
        case .goldIngot:
            drawIngot(context, color: rgb(0.95, 0.80, 0.28), highlight: rgb(1.0, 0.92, 0.55))
        case .gunpowder:
            drawDust(context, color: rgb(0.38, 0.37, 0.40), highlight: rgb(0.58, 0.57, 0.61))
        case .porkchop:
            drawMeat(context, lean: rgb(0.90, 0.47, 0.46), fat: rgb(0.98, 0.85, 0.81))
        case .beef:
            drawMeat(context, lean: rgb(0.78, 0.25, 0.24), fat: rgb(0.95, 0.71, 0.66))
        case .mutton:
            drawMeat(context, lean: rgb(0.85, 0.36, 0.35), fat: rgb(0.97, 0.79, 0.74))
        case .chicken:
            // Pale, and the palest of the four cuts, which is the only way
            // hue alone tells raw chicken from raw pork.
            drawMeat(context, lean: rgb(0.96, 0.78, 0.70), fat: rgb(0.99, 0.93, 0.88))
        case .rawCod:
            drawFish(context)
        case .feather:
            drawFeather(context)
        case .inkSac:
            drawNugget(context, color: rgb(0.13, 0.11, 0.22), highlight: rgb(0.34, 0.29, 0.52))
        case .wool:
            drawWool(context)
        case .oakDoor:
            drawDoor(context)
        case .glassPane:
            drawPane(context)
        case .rail:
            drawRail(context, accent: nil)
        case .poweredRail:
            drawRail(context, accent: rgb(0.85, 0.16, 0.16))
        case .detectorRail:
            drawRail(context, accent: rgb(0.82, 0.47, 0.24))
        case .minecart:
            drawMinecart(context)
        case .bucket:
            drawBucket(context, fluidColor: nil)
        case .waterBucket:
            drawBucket(context, fluidColor: rgb(0.24, 0.45, 0.78))
        case .lavaBucket:
            drawBucket(context, fluidColor: rgb(0.95, 0.45, 0.10))
        case .compass:
            drawCompass(context)
        case .masonLine:
            drawMasonLine(context)
        case .blueprint:
            drawBlueprint(context)
        case .pressurePlate:
            drawPressurePlate(context)
        case .ironChestplate:
            drawChestplate(context, tier: .iron)
        case .diamondChestplate:
            drawChestplate(context, tier: .diamond)
        default:
            if let toolClass = item.toolClass {
                drawTool(context, toolClass: toolClass, tier: item.toolTier)
            } else {
                context.setFillColor(rgb(0.7, 0.4, 0.8).cgColor)
                context.fill(CGRect(x: 4, y: 4, width: 8, height: 8))
            }
        }
        return image
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
    }

    private static func tierColor(_ tier: ToolTier) -> (head: NSColor, highlight: NSColor) {
        switch tier {
        case .hand, .wood: return (rgb(0.66, 0.50, 0.29), rgb(0.79, 0.63, 0.40))
        case .stone: return (rgb(0.52, 0.52, 0.52), rgb(0.67, 0.67, 0.67))
        case .iron: return (rgb(0.83, 0.83, 0.86), rgb(0.95, 0.95, 0.98))
        case .diamond: return (rgb(0.40, 0.90, 0.88), rgb(0.72, 1.0, 0.99))
        }
    }

    /// The wooden handle every tool shares, running corner to corner.
    private static func drawHandle(_ context: CGContext) {
        context.setStrokeColor(rgb(0.47, 0.33, 0.18).cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: 4, y: 3))
        context.addLine(to: CGPoint(x: 11, y: 10))
        context.strokePath()
    }

    private static func drawTool(_ context: CGContext, toolClass: ToolClass, tier: ToolTier) {
        drawHandle(context)
        let (head, highlight) = tierColor(tier)
        context.setFillColor(head.cgColor)
        context.setStrokeColor(head.cgColor)
        context.setLineWidth(2)

        switch toolClass {
        case .pickaxe:
            // A wide arc across the top, tips turned down.
            context.move(to: CGPoint(x: 7, y: 12))
            context.addLine(to: CGPoint(x: 11, y: 14))
            context.addLine(to: CGPoint(x: 14, y: 11))
            context.strokePath()
            context.fill(CGRect(x: 6, y: 10, width: 3, height: 3))
        case .axe:
            context.fill(CGRect(x: 9, y: 9, width: 5, height: 5))
            context.fill(CGRect(x: 8, y: 10, width: 2, height: 3))
        case .shovel:
            context.fill(CGRect(x: 10, y: 10, width: 4, height: 4))
        case .sword:
            // Straight blade along the diagonal with a crossguard.
            context.setStrokeColor(head.cgColor)
            context.move(to: CGPoint(x: 6, y: 5))
            context.addLine(to: CGPoint(x: 13, y: 13))
            context.strokePath()
            context.setStrokeColor(rgb(0.47, 0.33, 0.18).cgColor)
            context.move(to: CGPoint(x: 3, y: 5))
            context.addLine(to: CGPoint(x: 6, y: 2))
            context.strokePath()
        case .none:
            break
        }
        context.setFillColor(highlight.cgColor)
        context.fill(CGRect(x: 11, y: 12, width: 1, height: 1))
    }

    /// A torso silhouette rather than anything held — no handle, unlike
    /// every other item `tierColor` shades, because this is the one item
    /// that reads as worn rather than carried.
    private static func drawChestplate(_ context: CGContext, tier: ToolTier) {
        let (body, highlight) = tierColor(tier)
        context.setFillColor(body.cgColor)
        // Shoulders, a chest plate, and a gap at the neck.
        context.fill(CGRect(x: 3, y: 8, width: 3, height: 4))
        context.fill(CGRect(x: 10, y: 8, width: 3, height: 4))
        context.fill(CGRect(x: 4, y: 2, width: 8, height: 7))
        context.setFillColor(rgb(0, 0, 0, 0).cgColor)
        context.clear(CGRect(x: 6, y: 7, width: 4, height: 2))
        context.setFillColor(highlight.cgColor)
        context.fill(CGRect(x: 5, y: 3, width: 2, height: 2))
    }

    private static func drawStick(_ context: CGContext) {
        context.setStrokeColor(rgb(0.55, 0.38, 0.20).cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: 5, y: 3))
        context.addLine(to: CGPoint(x: 11, y: 13))
        context.strokePath()
        context.setStrokeColor(rgb(0.68, 0.50, 0.29).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 6, y: 4))
        context.addLine(to: CGPoint(x: 11, y: 12))
        context.strokePath()
    }

    private static func drawNugget(_ context: CGContext, color: NSColor, highlight: NSColor) {
        context.setFillColor(color.cgColor)
        // A lumpy blob rather than a circle — reads as ore, not a coin.
        context.fill(CGRect(x: 5, y: 4, width: 6, height: 8))
        context.fill(CGRect(x: 4, y: 6, width: 8, height: 4))
        context.setFillColor(highlight.cgColor)
        context.fill(CGRect(x: 6, y: 9, width: 2, height: 2))
    }

    private static func drawDust(_ context: CGContext, color: NSColor, highlight: NSColor) {
        // Loose grains rather than one lump — the whole point of powder is
        // that it isn't a solid thing.
        context.setFillColor(color.cgColor)
        for grain in [(5, 3), (8, 4), (4, 6), (7, 7), (10, 6), (6, 10), (9, 10), (11, 8)] {
            context.fill(CGRect(x: grain.0, y: grain.1, width: 2, height: 2))
        }
        context.setFillColor(highlight.cgColor)
        context.fill(CGRect(x: 8, y: 8, width: 1, height: 1))
        context.fill(CGRect(x: 5, y: 4, width: 1, height: 1))
    }

    /// A cut of meat: a rounded slab of lean with a rind of fat along the
    /// top and a streak of marbling. The rind is what makes it read as food
    /// rather than as one more coloured lump; the three cuts are told apart
    /// by hue, exactly as the original's own are.
    private static func drawMeat(_ context: CGContext, lean: NSColor, fat: NSColor) {
        context.setFillColor(lean.cgColor)
        // Corners knocked off, so it's a cut of something rather than a box.
        context.fill(CGRect(x: 4, y: 4, width: 8, height: 8))
        context.fill(CGRect(x: 3, y: 6, width: 10, height: 4))
        context.fill(CGRect(x: 5, y: 3, width: 6, height: 10))
        context.setFillColor(fat.cgColor)
        context.fill(CGRect(x: 5, y: 11, width: 6, height: 2))
        context.fill(CGRect(x: 7, y: 7, width: 3, height: 1))
    }

    /// A whole fish rather than a cut of one: the four meats are already
    /// four shades of the same slab, and a fifth would be indistinguishable
    /// in a hotbar. A silhouette with a tail on it is not.
    private static func drawFish(_ context: CGContext) {
        let body = rgb(0.60, 0.55, 0.40)
        let belly = rgb(0.86, 0.83, 0.74)
        context.setFillColor(body.cgColor)
        context.fill(CGRect(x: 4, y: 6, width: 8, height: 5))
        context.fill(CGRect(x: 5, y: 5, width: 6, height: 7))
        // Tail at the left, a wedge opening away from the body.
        context.fill(CGRect(x: 2, y: 5, width: 2, height: 7))
        context.fill(CGRect(x: 3, y: 7, width: 1, height: 3))
        context.setFillColor(belly.cgColor)
        context.fill(CGRect(x: 6, y: 5, width: 5, height: 2))
        // One dark eye, well forward, which is what fixes which end is which.
        context.setFillColor(rgb(0.12, 0.11, 0.10).cgColor)
        context.fill(CGRect(x: 10, y: 9, width: 2, height: 2))
    }

    /// A quill: a shaft up the diagonal with a vane opening off one side of
    /// it, notched so it reads as barbs rather than as a leaf.
    private static func drawFeather(_ context: CGContext) {
        context.setFillColor(rgb(0.93, 0.93, 0.95).cgColor)
        for (index, y) in stride(from: 4, to: 13, by: 1).enumerated() {
            let width = max(1, 5 - abs(index - 3))
            context.fill(CGRect(x: 5 + index / 3, y: y, width: width, height: 1))
        }
        context.setStrokeColor(rgb(0.74, 0.74, 0.78).cgColor)
        context.setLineWidth(1)
        context.move(to: CGPoint(x: 4.5, y: 3))
        context.addLine(to: CGPoint(x: 8.5, y: 13))
        context.strokePath()
    }

    /// A fleece: pale, with tufts all round the edge so the silhouette is
    /// lumpy rather than square, and curls picked out in shadow so it isn't
    /// a blank white tile.
    private static func drawWool(_ context: CGContext) {
        context.setFillColor(rgb(0.96, 0.96, 0.94).cgColor)
        context.fill(CGRect(x: 3, y: 4, width: 10, height: 8))
        for tuft in [(2, 6), (2, 9), (12, 5), (12, 8), (4, 12), (7, 12), (10, 12), (5, 2), (9, 2)] {
            context.fill(CGRect(x: tuft.0, y: tuft.1, width: 2, height: 2))
        }
        context.setFillColor(rgb(0.78, 0.78, 0.75).cgColor)
        for curl in [(5, 6), (9, 7), (6, 9), (10, 10), (4, 8)] {
            context.fill(CGRect(x: curl.0, y: curl.1, width: 2, height: 1))
        }
    }

    /// A door seen face on: a tall plank leaf with a glazed top half, the
    /// muntin cross that makes it read as a window rather than a hole, and
    /// a brass handle on the opening edge. The same three ideas the
    /// `doorTop` and `doorBottom` atlas tiles are drawn from, at a sixteenth
    /// of the pixels.
    private static func drawDoor(_ context: CGContext) {
        let frame = CGRect(x: 4, y: 1, width: 8, height: 14)
        context.setFillColor(rgb(0.60, 0.44, 0.25).cgColor)
        context.fill(frame)
        context.setFillColor(rgb(0.47, 0.33, 0.18).cgColor)
        context.stroke(frame.insetBy(dx: 0.5, dy: 0.5))

        // Glazing, top half.
        context.setFillColor(rgb(0.66, 0.83, 0.90, 0.85).cgColor)
        context.fill(CGRect(x: 5, y: 9, width: 6, height: 5))
        context.setFillColor(rgb(0.47, 0.33, 0.18).cgColor)
        context.fill(CGRect(x: 7, y: 9, width: 1, height: 5))
        context.fill(CGRect(x: 5, y: 11, width: 6, height: 1))
        context.setFillColor(rgb(0.92, 0.98, 1.0, 0.9).cgColor)
        context.fill(CGRect(x: 5, y: 12, width: 2, height: 1))

        // Routed panel, bottom half.
        context.setFillColor(rgb(0.52, 0.37, 0.20).cgColor)
        context.fill(CGRect(x: 5, y: 3, width: 6, height: 5))
        context.setFillColor(rgb(0.68, 0.51, 0.30).cgColor)
        context.fill(CGRect(x: 6, y: 4, width: 4, height: 3))

        context.setFillColor(rgb(0.92, 0.78, 0.35).cgColor)
        context.fill(CGRect(x: 10, y: 7, width: 1, height: 2))
    }

    /// A glass pane: the thin sheet, its darker rim, and one diagonal
    /// glint. Deliberately flat rather than isometric — a pane has no depth
    /// worth drawing, and the flat square is what tells it apart from the
    /// glass *block* sitting two slots away.
    private static func drawPane(_ context: CGContext) {
        let frame = CGRect(x: 3, y: 2, width: 10, height: 12)
        context.setFillColor(rgb(0.70, 0.86, 0.92, 0.55).cgColor)
        context.fill(frame)
        context.setStrokeColor(rgb(0.80, 0.92, 0.96, 0.95).cgColor)
        context.setLineWidth(1)
        context.stroke(frame.insetBy(dx: 0.5, dy: 0.5))
        context.setStrokeColor(rgb(1.0, 1.0, 1.0, 0.85).cgColor)
        context.move(to: CGPoint(x: 5, y: 4))
        context.addLine(to: CGPoint(x: 9, y: 11))
        context.strokePath()
        context.setStrokeColor(rgb(1.0, 1.0, 1.0, 0.5).cgColor)
        context.move(to: CGPoint(x: 7, y: 4))
        context.addLine(to: CGPoint(x: 10, y: 9))
        context.strokePath()
    }

    /// Track seen from above: sleepers under two rails.
    ///
    /// Drawn flat and from overhead rather than as an isometric cube,
    /// because a rail is the shape it makes on the ground — and because a
    /// rail item has no `placedBlock` to build a cube out of anyway: which
    /// of the twelve cases it becomes is decided by what it is laid next
    /// to.
    private static func drawRail(_ context: CGContext, accent: NSColor?) {
        // Sleepers first, so the rails sit on top of them.
        context.setFillColor(rgb(0.45, 0.32, 0.19).cgColor)
        for y in stride(from: 2, through: 13, by: 3) {
            context.fill(CGRect(x: 2, y: CGFloat(y), width: 12, height: 2))
        }

        // A powered or detector rail's sleepers carry a stripe of their own
        // colour — red current, copper sensing — which is the only thing
        // that tells any of the three apart in a hotbar slot.
        if let accent {
            context.setFillColor(accent.cgColor)
            for y in stride(from: 2, through: 13, by: 3) {
                context.fill(CGRect(x: 2, y: CGFloat(y), width: 12, height: 1))
            }
        }

        context.setFillColor(rgb(0.74, 0.75, 0.78).cgColor)
        context.fill(CGRect(x: 3, y: 1, width: 2, height: 14))
        context.fill(CGRect(x: 11, y: 1, width: 2, height: 14))
        // A highlight down the inside edge of each rail, which is what
        // makes them read as round steel rather than as two grey stripes.
        context.setFillColor(rgb(0.92, 0.93, 0.96).cgColor)
        context.fill(CGRect(x: 4, y: 1, width: 1, height: 14))
        context.fill(CGRect(x: 12, y: 1, width: 1, height: 14))
    }

    /// The cart, three-quarters on: an open iron tub on two wheels.
    private static func drawMinecart(_ context: CGContext) {
        // Wheels first, and the body sits high enough to leave most of them
        // showing — a tub drawn down to the baseline reads as a bucket.
        context.setFillColor(rgb(0.26, 0.27, 0.30).cgColor)
        context.fillEllipse(in: CGRect(x: 3, y: 0, width: 5, height: 5))
        context.fillEllipse(in: CGRect(x: 8, y: 0, width: 5, height: 5))
        context.setFillColor(rgb(0.50, 0.51, 0.55).cgColor)
        context.fillEllipse(in: CGRect(x: 4.5, y: 1.5, width: 2, height: 2))
        context.fillEllipse(in: CGRect(x: 9.5, y: 1.5, width: 2, height: 2))

        // The tub, open at the top: the dark inside showing over a lower
        // near wall. A closed box reads as a crate, and the one thing a
        // minecart has to look like is something you can get into.
        context.setFillColor(rgb(0.44, 0.45, 0.48).cgColor)
        context.fill(CGRect(x: 2, y: 4, width: 12, height: 8))
        context.setFillColor(rgb(0.20, 0.21, 0.24).cgColor)
        context.fill(CGRect(x: 4, y: 9, width: 8, height: 3))
        context.setFillColor(rgb(0.62, 0.63, 0.67).cgColor)
        context.fill(CGRect(x: 2, y: 11, width: 12, height: 2))
        context.fill(CGRect(x: 2, y: 4, width: 2, height: 9))
        context.fill(CGRect(x: 12, y: 4, width: 2, height: 9))
    }

    /// A tapered metal pail with a wire handle — narrower at the foot than
    /// the rim, which at sixteen pixels is the one cue that reads as
    /// "container" rather than "block." A full bucket shows water sitting
    /// inside the rim, the only thing that tells the two items apart in a
    /// hotbar slot the way a real bucket's weight would.
    private static func drawBucket(_ context: CGContext, fluidColor: NSColor? = nil) {
        context.setFillColor(rgb(0.55, 0.56, 0.60).cgColor)
        context.move(to: CGPoint(x: 3, y: 2))
        context.addLine(to: CGPoint(x: 13, y: 2))
        context.addLine(to: CGPoint(x: 11, y: 12))
        context.addLine(to: CGPoint(x: 5, y: 12))
        context.closePath()
        context.fillPath()

        context.setFillColor(rgb(0.35, 0.36, 0.39).cgColor)
        context.fill(CGRect(x: 4, y: 11, width: 8, height: 1))

        context.setStrokeColor(rgb(0.28, 0.29, 0.32).cgColor)
        context.setLineWidth(1.2)
        context.move(to: CGPoint(x: 4, y: 2))
        context.addQuadCurve(to: CGPoint(x: 12, y: 2), control: CGPoint(x: 8, y: -2.5))
        context.strokePath()

        if let fluidColor {
            context.setFillColor(fluidColor.cgColor)
            context.fill(CGRect(x: 4, y: 2, width: 8, height: 2.5))
        } else {
            context.setFillColor(rgb(0.72, 0.73, 0.77).cgColor)
            context.fill(CGRect(x: 4, y: 2, width: 8, height: 1))
        }
    }

    /// A slab seen from above, with the groove round its edge that says it
    /// is a separate piece rather than part of the floor — same read as
    /// the in-world block, at icon scale.
    private static func drawPressurePlate(_ context: CGContext) {
        context.setFillColor(rgb(0.58, 0.58, 0.61).cgColor)
        context.fill(CGRect(x: 2, y: 2, width: 12, height: 12))
        context.setStrokeColor(rgb(0.30, 0.30, 0.32).cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(x: 2.5, y: 2.5, width: 11, height: 11))
    }

    /// A brass bezel with a fixed red/white needle. The needle doesn't move
    /// here — it can't, an icon has no idea which way home is — the HUD
    /// draws the live one; this is just what sits in the slot.
    private static func drawCompass(_ context: CGContext) {
        context.setFillColor(rgb(0.62, 0.48, 0.20).cgColor)
        context.fillEllipse(in: CGRect(x: 2, y: 2, width: 12, height: 12))
        context.setFillColor(rgb(0.86, 0.83, 0.74).cgColor)
        context.fillEllipse(in: CGRect(x: 3.5, y: 3.5, width: 9, height: 9))

        context.saveGState()
        context.translateBy(x: 8, y: 8)
        context.rotate(by: .pi / 5)
        context.setFillColor(rgb(0.78, 0.16, 0.16).cgColor)
        context.move(to: CGPoint(x: 0, y: 4.5))
        context.addLine(to: CGPoint(x: 1.3, y: 0))
        context.addLine(to: CGPoint(x: -1.3, y: 0))
        context.closePath()
        context.fillPath()
        context.setFillColor(rgb(0.30, 0.31, 0.34).cgColor)
        context.move(to: CGPoint(x: 0, y: -4.5))
        context.addLine(to: CGPoint(x: 1.3, y: 0))
        context.addLine(to: CGPoint(x: -1.3, y: 0))
        context.closePath()
        context.fillPath()
        context.restoreGState()

        context.setFillColor(rgb(0.20, 0.21, 0.24).cgColor)
        context.fillEllipse(in: CGRect(x: 7, y: 7, width: 2, height: 2))
    }

    /// Two pegs and the taut line between them — a real mason's line reads
    /// at a glance as "marks two points," which is the whole tool.
    private static func drawMasonLine(_ context: CGContext) {
        context.setStrokeColor(rgb(0.86, 0.83, 0.74).cgColor)
        context.setLineWidth(1.2)
        context.move(to: CGPoint(x: 3, y: 3))
        context.addLine(to: CGPoint(x: 13, y: 13))
        context.strokePath()

        for corner in [CGPoint(x: 3, y: 3), CGPoint(x: 13, y: 13)] {
            context.setFillColor(rgb(0.45, 0.30, 0.14).cgColor)
            context.fillEllipse(in: CGRect(x: corner.x - 2, y: corner.y - 2, width: 4, height: 4))
            context.setFillColor(rgb(0.66, 0.50, 0.29).cgColor)
            context.fillEllipse(in: CGRect(x: corner.x - 1, y: corner.y - 1, width: 2, height: 2))
        }
    }

    private static func drawBlueprint(_ context: CGContext) {
        // A pale sheet ruled with a grid — a plan rather than a wall — with
        // the same diamond a mason's line was bound in pinned at one corner,
        // small enough to read as a clasp rather than a second item.
        let sheet = CGRect(x: 3, y: 2, width: 10, height: 12)
        context.setFillColor(rgb(0.80, 0.87, 0.93).cgColor)
        context.fill(sheet)
        context.setStrokeColor(rgb(0.35, 0.50, 0.58).cgColor)
        context.setLineWidth(1.0)
        context.stroke(sheet)

        context.setStrokeColor(rgb(0.45, 0.62, 0.70).cgColor)
        context.setLineWidth(0.7)
        for step in 1..<4 {
            let y = sheet.minY + CGFloat(step) * (sheet.height / 4)
            context.move(to: CGPoint(x: sheet.minX + 1, y: y))
            context.addLine(to: CGPoint(x: sheet.maxX - 1, y: y))
        }
        context.strokePath()

        context.setFillColor(rgb(0.40, 0.90, 0.88).cgColor)
        context.move(to: CGPoint(x: sheet.maxX - 1, y: sheet.maxY - 4))
        context.addLine(to: CGPoint(x: sheet.maxX + 2, y: sheet.maxY - 2))
        context.addLine(to: CGPoint(x: sheet.maxX - 1, y: sheet.maxY))
        context.addLine(to: CGPoint(x: sheet.maxX - 4, y: sheet.maxY - 2))
        context.closePath()
        context.fillPath()
    }

    private static func drawGem(_ context: CGContext, color: NSColor, highlight: NSColor) {
        context.setFillColor(color.cgColor)
        context.move(to: CGPoint(x: 8, y: 14))
        context.addLine(to: CGPoint(x: 13, y: 9))
        context.addLine(to: CGPoint(x: 8, y: 2))
        context.addLine(to: CGPoint(x: 3, y: 9))
        context.closePath()
        context.fillPath()
        context.setFillColor(highlight.cgColor)
        context.fill(CGRect(x: 6, y: 9, width: 2, height: 3))
    }

    private static func drawIngot(_ context: CGContext, color: NSColor, highlight: NSColor) {
        context.setFillColor(color.cgColor)
        context.move(to: CGPoint(x: 3, y: 5))
        context.addLine(to: CGPoint(x: 13, y: 5))
        context.addLine(to: CGPoint(x: 11, y: 11))
        context.addLine(to: CGPoint(x: 5, y: 11))
        context.closePath()
        context.fillPath()
        context.setFillColor(highlight.cgColor)
        context.fill(CGRect(x: 6, y: 9, width: 4, height: 1))
    }
}
#endif

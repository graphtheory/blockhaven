import Foundation

/// One block-face texture in the atlas.
enum AtlasTile: Int, CaseIterable {
    case grassTop = 0
    case grassSide
    case dirt
    case farmlandTop
    case stone
    case cobblestone
    case sand
    case sandstoneTop
    case sandstoneSide
    case gravel
    case logSide
    case logTop
    case planks
    case leaves
    case glass
    case bedrock
    case coalOre
    case ironOre
    case goldOre
    case diamondOre
    case snow
    case water
    case lava
    case craftingTableTop
    case craftingTableSide
    case brick
    case obsidian

    // The second and third trees, and the thing that grows in a desert.
    // These sit here, before the flat run, because a shaded tile's slot is
    // `rawValue * shadeLevels` — the shaded tiles have to stay a prefix of
    // the raw values or every slot after the gap lands somewhere else.
    // Nothing persists an `AtlasTile`, so unlike `BlockType` this enum is
    // free to be inserted into.
    case birchLogSide
    case birchLogTop
    case birchLeaves
    case spruceLogSide
    case spruceLogTop
    case spruceLeaves
    case cactusSide
    case cactusTop

    // TNT. A cube, so it shades like one and belongs in this run. Two tiles
    // rather than three: the bottom samples `tntTop` without its fuse hole,
    // which nobody has ever looked at closely enough to miss.
    case tntSide
    case tntTop

    // The pyramid's cubes: cast gold, and sandstone with glyphs cut into
    // it. Cube faces, so they belong in the shaded run — which grows the
    // sheet by exactly one row (two tiles at eight brightnesses), and the
    // flat tiles below all shift raw value, which is fine: nothing
    // persists an `AtlasTile`.
    case goldBlock
    case sandstoneCarved

    // The sunken city's cubes: sea-stone and the lamp that lights it.
    // Shaded like the pyramid pair above, and for the same reason. The
    // lantern being in the shaded run is not a contradiction of it
    // glowing: its emission is block *light*, flooded into the cells
    // around it, and its own faces sample the brightness of the cell they
    // are in — which its own light makes full.
    case seaStone
    case seaLantern

    // Solid diamond, shaded like the gold it usually sits next to.
    case diamondBlock

    // The radiant lamps: glass tiles in four hues, drawn by one helper.
    case radiantRed
    case radiantYellow
    case radiantGreen
    case radiantCyan

    // Glow Crystal: dark rock crazed with veins of light.
    case glowCrystal

    // The pearl lamp: a face that is all glow, white heart to magenta rim.
    case pearlLight

    // The painted columns: a fluted sandstone shaft, and its capital —
    // gold, red and blue bands under a ring of green lotus leaves.
    case sandstonePillar
    case pillarCapital

    // The sky city's cloth and masonry: lime plaster, the same plaster
    // crossed with dark beams, a cloud with a walkable top, and the
    // striped canvas an airship hangs from.
    case plaster
    case timberFrame
    case cloud
    case balloonCanvas

    // The chest: a banded wooden box with an iron latch. Two tiles — a lid
    // seen from above, and a front — and the front is used on all four
    // sides, so the box reads as a chest from wherever you walk up to it.
    case chestTop
    case chestFront

    // The furnace: quarried stone on every face but the front, which is
    // its whole tell — a dark mouth cold, a glowing one while something is
    // burning inside it. Like the chest, one front used on all four sides.
    case furnaceFront
    case furnaceFrontLit

    // The hopper: sheet iron on every face but the top, which is a dark
    // funnel mouth — the one visual tell that anything dropped above this
    // block is going somewhere.
    case hopperTop
    case hopperSide

    // The Sleeping Garden's cubes: the old network's radio and plaques,
    // the expedition's hardware, the Moon's own ground, and the thatch
    // the silver reed is woven into.
    case radioFront
    case radioFrontLit
    case plaque
    case meteorOre
    case padTop
    case rocketHull
    case rocketWindow
    case rocketEngine
    case airMakerTop
    case airMakerSide
    case moonDust
    case moonRock
    case moonBrick
    case prismGlass
    case gardenSeal
    case silverThatch

    // Tiles only *shaped* blocks sample. They are stored once, at full
    // brightness, rather than at `shadeLevels` brightnesses like everything
    // above — see `isShaded`.
    case doorTop
    case doorBottom
    case bedBlanket
    case bedPillow
    case bedSide

    // The cross plants. Flat like the shaped tiles above because that is
    // what they are — two thin crossed slabs — and mostly transparent,
    // which the opaque material's 0.5 opacity threshold cuts out for free.
    case tallGrass
    case poppy
    case dandelion
    case cornflower
    case deadBush

    // The sapling, one tile per species — a twig with a single tuft of
    // its own tree's leaf colour, small enough that what it promises is
    // legible at a glance without a second frame of growth.
    case sapling
    case birchSapling
    case spruceSapling

    // Wheat, four stages, each sampling the same fixed tint every other
    // flat tile does — the growth reads entirely in how much of the tile
    // is drawn and what colour it drew in, sprout green climbing to
    // harvest gold, not in any per-stage shading.
    case wheatStage0
    case wheatStage1
    case wheatStage2
    case wheatStage3

    // The torch: a post with a burning head, on a transparent field. Flat,
    // like the plants — and being flat is what makes it read as *lit*, since
    // a flat tile is stored at full brightness only and never picks up a
    // darkened variant no matter how black the cave around it is.
    case torch

    // Rails: two runners and the sleepers between them, on a transparent
    // field so the ground shows through the gaps. Flat, like the torch, so
    // a track laid through a dark tunnel stays legible — and unlike a cube
    // face there is nothing here for eight brightnesses to be useful for.
    case railStraight
    case railCurve
    case railBooster
    case railDetector

    // The switch and the wire it feeds: flat like the torch and the rail,
    // for the same reason — a shaped face carries its own shade in the
    // vertex colour and needs only the one copy.
    case leverOff
    case leverOn
    case wireOff
    case wireOn
    case pressurePlateOff
    case pressurePlateOn
    case signalTorchOff
    case signalTorchOn
    case signalRelayOff
    case signalRelayOn

    // The garden's two crops: one sprout they share, then three stages
    // each — the lamp bloom opening into light, the reed silvering.
    case gardenSprout
    case lampBloomStage1
    case lampBloomStage2
    case lampBloomStage3
    case silverReedStage1
    case silverReedStage2
    case silverReedStage3

    /// Whether the sheet holds this tile at every brightness or only at
    /// full brightness.
    ///
    /// A cube face picks a pre-darkened variant out of the sheet, because
    /// its shade is the average of four corner occlusions and can land
    /// anywhere on the scale. A shaped block's faces carry no ambient
    /// occlusion at all (see `ChunkMesher.emitShaped`) — their whole shade
    /// is the fixed per-direction tint, and that rides in the vertex
    /// colour, so a tile no cube can reach needs exactly one copy.
    ///
    /// That is not a saving for its own sake. Every UV in the game is a
    /// fraction of the sheet's height, so eight copies of five new tiles
    /// would push the sheet from fourteen rows to sixteen and move every
    /// existing texture by a fraction of a texel — enough, measured over
    /// the ten-camera battery, to flip a scatter of pixels on leaf and
    /// grass tiles where the interpolated `v` was already sitting on a
    /// texel boundary. One copy each fits in the fourteenth row's spare
    /// slots and leaves the sheet exactly the size it has always been.
    var isShaded: Bool { rawValue < AtlasTile.doorTop.rawValue }
}

/// The block texture sheet: procedurally drawn once, then sampled by every
/// chunk mesh through UVs.
///
/// Each face texture is stored at `shadeLevels` progressively darker
/// brightnesses. That is how this renderer does ambient occlusion and
/// directional face shading without a shader: the mesher picks the variant
/// matching a quad's *average* computed shade, so one unlit material draws
/// a whole chunk with baked lighting and no Metal library at all.
///
/// The smooth per-corner half of the shading lives elsewhere — the mesher
/// also writes each corner's deviation from that average into a vertex
/// colour, which `blockSurface` multiplies back in (see `ChunkMesher`).
/// Keeping the average here rather than moving all of the shading into the
/// vertices is what lets the two coexist: with no shader running, the
/// atlas alone still produces the flat-lit look this file was written for.
enum TextureAtlas {
    /// Distinct brightness steps stored per texture.
    static let shadeLevels = 8
    /// Darkest variant, as a fraction of full brightness.
    static let minimumShade: Float = 0.40

    static let columns = 16
    static let tilePixels = 16

    /// The tiles a cube face can sample, in raw-value order. They occupy
    /// `shadeLevels` slots each and start at slot 0, which is what keeps
    /// every existing tile's UV rectangle exactly where it was.
    static let shadedTiles = AtlasTile.allCases.filter(\.isShaded)
    /// The rest, one slot each, after the crack overlays.
    static let flatTiles = AtlasTile.allCases.filter { !$0.isShaded }

    /// Shaded block tiles first, then the ten crack overlays, then one slot
    /// per shaped-block tile.
    private static var shadedSlotCount: Int { shadedTiles.count * shadeLevels }
    private static var totalSlots: Int { shadedSlotCount + 10 + flatTiles.count }
    static var rows: Int { (totalSlots + columns - 1) / columns }

    static var sheetWidth: Int { columns * tilePixels }
    static var sheetHeight: Int { rows * tilePixels }

    /// Maps a 0...1 brightness onto the nearest stored variant.
    static func shadeIndex(for shade: Float) -> Int {
        guard shade < 1 else { return shadeLevels - 1 }
        let normalized = (shade - minimumShade) / (1 - minimumShade)
        let index = Int((normalized * Float(shadeLevels - 1)).rounded())
        return max(0, min(shadeLevels - 1, index))
    }

    /// The brightness actually stored in a variant — `shadeIndex`'s inverse,
    /// and the value a face that samples that variant really renders at.
    static func brightness(forIndex index: Int) -> CGFloat {
        let t = CGFloat(index) / CGFloat(shadeLevels - 1)
        return CGFloat(minimumShade) + (1 - CGFloat(minimumShade)) * t
    }

    /// A brightness put through the sheet and read back: what asking for
    /// `shade` actually gets you, once it has been snapped to one of the
    /// eight stored steps.
    ///
    /// A cube face's tint always makes that round trip, because a cube
    /// carries its shade in which variant it samples. A shaped block
    /// carries its shade in the vertex colour instead, where nothing
    /// quantises it — so the same nominal tint came out up to 4.8% away
    /// from the cube face beside it, which on a flat wall reads as an
    /// outline drawn round the staircase. Sending the shaped tint through
    /// here first puts both paths on the same value.
    static func quantizedShade(_ shade: Float) -> Float {
        Float(brightness(forIndex: shadeIndex(for: shade)))
    }

    static func slot(for tile: AtlasTile, shadeIndex: Int) -> Int {
        guard tile.isShaded else { return flatSlot(for: tile) }
        return tile.rawValue * shadeLevels + max(0, min(shadeLevels - 1, shadeIndex))
    }

    static func crackSlot(stage: Int) -> Int {
        shadedSlotCount + max(0, min(9, stage))
    }

    /// Where a tile stored only at full brightness lives. Deliberately past
    /// the crack overlays, so neither the block slots nor the crack slots
    /// move when one is added.
    static func flatSlot(for tile: AtlasTile) -> Int {
        shadedSlotCount + 10 + Int(tile.rawValue - AtlasTile.doorTop.rawValue)
    }

    /// UV rectangle for a slot, inset by half a texel so neighbouring tiles
    /// can never bleed in at the seams.
    private static func uvRect(slot: Int) -> (u0: Float, v0: Float, u1: Float, v1: Float) {
        let column = slot % columns
        let row = slot / columns
        let insetU = 0.5 / Float(sheetWidth)
        let insetV = 0.5 / Float(sheetHeight)
        let u0 = Float(column) / Float(columns) + insetU
        let u1 = Float(column + 1) / Float(columns) - insetU
        // RealityKit samples with v=0 at the *bottom* of the image, while
        // the sheet is drawn with slot row 0 at the top. So the row has to
        // be measured from the far end. `v0` stays the tile's top edge and
        // `v1` its bottom, which is what the mesher's corner order assumes.
        let v0 = 1 - Float(row) / Float(rows) - insetV
        let v1 = 1 - Float(row + 1) / Float(rows) + insetV
        return (u0, v0, u1, v1)
    }

    static func uvRect(for tile: AtlasTile, shadeIndex: Int) -> (u0: Float, v0: Float, u1: Float, v1: Float) {
        uvRect(slot: slot(for: tile, shadeIndex: shadeIndex))
    }

    static func crackUVRect(stage: Int) -> (u0: Float, v0: Float, u1: Float, v1: Float) {
        uvRect(slot: crackSlot(stage: stage))
    }
}

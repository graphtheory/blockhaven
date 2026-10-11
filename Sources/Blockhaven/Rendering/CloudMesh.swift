import Foundation

/// The geometry of the cloud deck: the original's own "fancy clouds", a field
/// of extruded flat-bottomed slabs with visible sides.
///
/// A procedural blob field is thresholded onto a grid of `cellSize` cells,
/// and every covered cell becomes a box — a top face, a bottom face, and a
/// side wall wherever the neighbouring cell is empty. That last rule is the
/// whole construction: inside a cloud mass no walls are emitted, so a
/// twelve-cell blob is one solid volume with a rim of sides around it rather
/// than twelve boxes stacked edge to edge.
///
/// The field is built **once**, at startup, and never rebuilt. It is one mesh
/// with three material slots (top / side / bottom); the layer moves by
/// transform alone. See `CloudLayer` for the drift and the grade.
///
/// ## Why the field tiles
///
/// The blob field is periodic in `tileCells`: every noise octave's lattice
/// wraps at a divisor of that, so translating the mesh by a whole
/// `tilePeriod` maps the pattern exactly onto itself. `CloudLayer` uses that
/// to keep the disc of geometry centred on the player — it snaps the layer's
/// position to whole tile periods, which moves the mesh without moving a
/// single cloud in world space.
///
/// The cost of that trick is that the rim of the disc jumps by a whole tile
/// when the player crosses a half-tile line, so `coverageRadius` — the
/// radius that is covered from *any* camera position inside a tile — is the
/// real extent of the layer, and the shader's distance fade has to finish
/// inside it.
enum CloudMesh {
    /// Blocks across one cloud cell.
    ///
    /// The original's own is twelve, but the original's deck is 128 blocks over
    /// the player's head and this one is 46: a twelve-block cell up there
    /// subtends five degrees and the same cell here subtends fifteen, which
    /// on a straight-up glance filled the screen with four squares. Eight
    /// blocks puts it back at ten degrees — still unmistakably blocky, and
    /// the cloud *masses* keep their size because the noise below is scaled
    /// in cells, not blocks.
    static let cellSize: Float = 8
    /// How thick one stacked level is.
    ///
    /// The deck used to be a single slab of this thickness and nothing
    /// else — the classic flat-bottomed, flat-topped sheet. What it is now is
    /// a stack: a cell carries as many levels as its density earns, so a
    /// mass is tall through the middle and one level thick at its rim, and
    /// its top is a terrace rather than a plane. That one change is most of
    /// the distance between plain clouds and the ones in a shader pack,
    /// and it is geometry rather than shading — no amount of lighting makes
    /// a flat sheet look like a cumulus.
    static let levelHeight: Float = 3.5
    /// The most levels a cell can carry. Seven is 24.5 blocks of cloud over
    /// a 46-block-high deck: enough that the flanks read as a wall of
    /// weather from below, not so much that the sky closes over.
    ///
    /// The number that matters is the ratio to the *width* of a mass, not
    /// the absolute height. The blob noise spans twelve cells, so a mass is
    /// roughly ninety blocks across; a cumulus is about as tall as it is
    /// wide, and this deck is nowhere near that and should not be — the
    /// clouds have to stay above a player who can fly. A quarter is enough
    /// to read as depth from the ground and stays a ceiling you can get
    /// over.
    static let maximumLevels = 7
    /// Height of the deck's flat bottom, in world blocks. The player's eye
    /// sits around 66, so this is a deck about forty-five blocks up.
    ///
    /// The bottom stays flat while the top billows, which is not a
    /// simplification — it is what cumulus actually does. Cloud base is the
    /// altitude where rising air hits its dew point, and that altitude is
    /// the same for every cloud in the same air mass, so a real sky of
    /// cumulus has one ruler-flat floor and a hundred different tops.
    static let altitude: Float = 112

    /// Cells in one period of the blob field. 48 cells is a 384-block
    /// repeat: far enough that the nearest copy of any cloud is down at
    /// seven degrees of elevation, where perspective has already crushed it.
    static let tileCells = 48
    /// Radius of the disc of geometry, in cells. Sized so `coverageRadius`
    /// clears `CloudLayer.fadeRange`'s far end; `BLOCKHAVEN_CLOUD_LOG=1`
    /// prints both numbers at startup so the relation stays checkable.
    static let fieldCells = 76

    static let tilePeriod = Float(tileCells) * cellSize
    static let fieldRadius = Float(fieldCells) * cellSize
    /// The radius that has cloud in every direction no matter where inside a
    /// tile the camera stands — the disc's radius less the furthest the
    /// re-centring can put the camera from its middle. The shader's fade
    /// must be finished by here, or the rim would show as the layer snaps.
    ///
    /// The two axes re-centre independently and each can be half a tile out,
    /// so the worst case is the *diagonal* corner of a tile, not half a tile:
    /// `√2 · tilePeriod/2`, which is 272 blocks, not 192. Getting that wrong
    /// leaves a crescent of missing cloud in one quadrant of the far band —
    /// faint, because the fade has mostly done its work by then, but there.
    static let coverageRadius = fieldRadius - tilePeriod * 0.5 * 1.4142136

    /// The three face directions, in the order the mesh's per-face material
    /// indices address them.
    enum Face: Int, CaseIterable {
        case top = 0, side = 1, bottom = 2
    }

    /// One built field: the mesh and the numbers worth reporting about it.
    struct Field {
        let positions: [SIMD3<Float>]
        let normals: [SIMD3<Float>]
        let uvs: [SIMD2<Float>]
        let indices: [UInt32]
        /// One per triangle: the `Face` it is painted as.
        let faceMaterials: [UInt32]
        let triangles: Int
        let vertices: Int
        /// Fraction of the disc's cells that carry cloud.
        let coverage: Float
        /// How long the one and only build took, in milliseconds. Reported
        /// so the claim "this is not per-frame work" carries a number.
        let buildMilliseconds: Double
    }

    /// Built once, lazily, on first use — which is the first frame the sky
    /// is assembled, on the main thread, and then never again.
    static let field: Field = build()

    // MARK: - The blob field

    /// Above this a cell carries cloud. Tuned for gaps: a cloud deck that
    /// covers the sky reads as overcast, and the shot this grade is built
    /// around wants sky between the masses.
    private static let densityThreshold: Float = 0.525

    /// Cheap positive modulo, so a negative cell index wraps into the tile.
    private static func wrap(_ value: Int, _ period: Int) -> Int {
        let remainder = value % period
        return remainder < 0 ? remainder + period : remainder
    }

    /// One octave of value noise over the cell lattice, wrapping every
    /// `tileCells` cells so the whole field tiles.
    ///
    /// `span` is how many cloud cells one lattice cell spans; it has to
    /// divide `tileCells`, which is what makes the wrap seamless — the
    /// lattice point at cell `i + tileCells` is the one at `i` again.
    private static func octave(_ i: Int, _ j: Int, span: Int, seed: UInt64) -> Float {
        let count = tileCells / span
        let fx = Float(i) / Float(span), fy = Float(j) / Float(span)
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Float(x0), ty = fy - Float(y0)

        func corner(_ a: Int, _ b: Int) -> Float {
            Float(latticeHash(wrap(a, count), wrap(b, count), seed: seed))
        }

        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let near = corner(x0, y0) + (corner(x0 + 1, y0) - corner(x0, y0)) * sx
        let far = corner(x0, y0 + 1) + (corner(x0 + 1, y0 + 1) - corner(x0, y0 + 1)) * sx
        return near + (far - near) * sy
    }

    /// Three octaves for the masses, plus an unsmoothed per-cell hash that
    /// roughens the edges — without it every blob's outline is a smooth
    /// contour of the noise, and the layer loses the single-cell nubs and
    /// notches that make a blocky cloud read as blocky.
    private static func density(_ i: Int, _ j: Int) -> Float {
        0.66 * octave(i, j, span: 12, seed: 0x9CE1)
            + 0.22 * octave(i, j, span: 6, seed: 0x41AF)
            + 0.12 * octave(i, j, span: 3, seed: 0x102B)
            + 0.05 * (Float(latticeHash(wrap(i, tileCells), wrap(j, tileCells), seed: 0x5B7D)) - 0.5)
    }

    // MARK: - Faces

    /// A face template in unit-cell coordinates: corners are 0 or 1 on each
    /// axis, wound counter-clockwise seen from outside, the same convention
    /// `ChunkMesher` uses.
    private struct Facing {
        let normal: SIMD3<Float>
        let corners: [SIMD3<Float>]
        let material: UInt32
        /// The neighbouring cell this face opens onto, or nil for the top
        /// and bottom, which are never covered by anything.
        let neighbour: (di: Int, dj: Int)?
    }

    private static let facings: [Facing] = [
        Facing(normal: SIMD3(0, 1, 0),
               corners: [SIMD3(0, 1, 1), SIMD3(1, 1, 1), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
               material: UInt32(Face.top.rawValue), neighbour: nil),
        Facing(normal: SIMD3(0, -1, 0),
               corners: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 1), SIMD3(0, 0, 1)],
               material: UInt32(Face.bottom.rawValue), neighbour: nil),
        Facing(normal: SIMD3(0, 0, 1),
               corners: [SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)],
               material: UInt32(Face.side.rawValue), neighbour: (0, 1)),
        Facing(normal: SIMD3(0, 0, -1),
               corners: [SIMD3(1, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0)],
               material: UInt32(Face.side.rawValue), neighbour: (0, -1)),
        Facing(normal: SIMD3(1, 0, 0),
               corners: [SIMD3(1, 0, 1), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(1, 1, 1)],
               material: UInt32(Face.side.rawValue), neighbour: (1, 0)),
        Facing(normal: SIMD3(-1, 0, 0),
               corners: [SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 1), SIMD3(0, 1, 0)],
               material: UInt32(Face.side.rawValue), neighbour: (-1, 0)),
    ]

    /// Every quad carries the same square UV in `y`. Nothing samples a
    /// texture off the cloud layer — the colour is entirely per-face
    /// constants — but a `CustomMaterial` wants a uv0 in the vertex layout,
    /// so the channel exists either way.
    ///
    /// `x` is not a texture coordinate at all: the builder overwrites it
    /// with how high up the stack that vertex sits, 0 at the deck's flat
    /// base and 1 at the tallest a column may reach. It is the only
    /// per-vertex channel this mesh has spare, and it is what lets
    /// `cloudSurface` brighten the crown of a billow over the crevice
    /// beside it — which no per-face constant can do, because both are the
    /// same face direction.
    private static let quadUVs: [SIMD2<Float>] = [
        SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1),
    ]

    /// The tallest a column stands, in blocks — what the height channel
    /// above is measured against.
    static let deckHeight = Float(maximumLevels) * levelHeight

    // MARK: - Building

    private static func build() -> Field {
        let started = monotonicSeconds()
        let span = 2 * fieldCells
        // Covered cells of the disc, indexed [j + fieldCells][i + fieldCells].
        var covered = [Bool](repeating: false, count: span * span)
        var cellsInDisc = 0
        var cellsCovered = 0
        let radiusSquared = fieldRadius * fieldRadius
        for j in -fieldCells..<fieldCells {
            let z = (Float(j) + 0.5) * cellSize
            for i in -fieldCells..<fieldCells {
                let x = (Float(i) + 0.5) * cellSize
                guard x * x + z * z <= radiusSquared else { continue }
                cellsInDisc += 1
                guard density(i, j) > densityThreshold else { continue }
                covered[(j + fieldCells) * span + (i + fieldCells)] = true
                cellsCovered += 1
            }
        }

        func isCovered(_ i: Int, _ j: Int) -> Bool {
            guard i >= -fieldCells, i < fieldCells, j >= -fieldCells, j < fieldCells else { return false }
            return covered[(j + fieldCells) * span + (i + fieldCells)]
        }

        // How many levels each covered cell stacks. A heightfield, not a
        // 3D field: cloud grows upward from one flat base, so a column is
        // fully described by its height and every face below its top is
        // interior by construction.
        func levels(_ i: Int, _ j: Int) -> Int {
            guard isCovered(i, j) else { return 0 }
            // How far this cell cleared the threshold, over the whole range
            // it could have cleared it by. The densest cells are the middle
            // of a mass, and the middle of a mass is where it is tallest.
            let headroom = max(0, density(i, j) - densityThreshold)
            let reach = min(1, headroom / (1 - densityThreshold))
            // A per-cell nudge on top, so the tops are lumpy rather than a
            // smooth contour of the noise — the same job the unsmoothed
            // term in `density` does for the outlines, one axis up. Without
            // it a mass is a tidy stepped pyramid and reads as terrain.
            let jitter = Float(latticeHash(
                wrap(i, tileCells), wrap(j, tileCells), seed: 0x0C1D
            )) - 0.35
            let raised = reach * Float(maximumLevels) * 1.35 + jitter
            return max(1, min(maximumLevels, Int(raised.rounded()) + 1))
        }

        // Worked out once for the whole disc rather than per face: the side
        // rule below asks each neighbour's height, so an inline `levels`
        // would recompute four octaves of noise four times per cell.
        var heights = [UInt8](repeating: 0, count: span * span)
        for j in -fieldCells..<fieldCells {
            for i in -fieldCells..<fieldCells {
                heights[(j + fieldCells) * span + (i + fieldCells)] = UInt8(levels(i, j))
            }
        }
        func height(_ i: Int, _ j: Int) -> Int {
            guard i >= -fieldCells, i < fieldCells, j >= -fieldCells, j < fieldCells else { return 0 }
            return Int(heights[(j + fieldCells) * span + (i + fieldCells)])
        }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        var faceMaterials: [UInt32] = []
        // A top, a bottom and a few steps of wall per covered cell.
        // Reserving the flat part keeps the build to a couple of
        // reallocations; the walls grow it from there.
        positions.reserveCapacity(cellsCovered * 24)
        normals.reserveCapacity(cellsCovered * 24)
        uvs.reserveCapacity(cellsCovered * 36)
        indices.reserveCapacity(cellsCovered * 36)

        for j in -fieldCells..<fieldCells {
            for i in -fieldCells..<fieldCells {
                let stack = height(i, j)
                guard stack > 0 else { continue }
                let column = SIMD3<Float>(Float(i) * cellSize, altitude, Float(j) * cellSize)

                for facing in facings {
                    // The top sits on the last level, the bottom on the
                    // first, and a wall runs from whatever the neighbour
                    // reaches up to whatever this column does — which is
                    // the step in the terrace, and is empty when the two
                    // columns are the same height.
                    let low: Int
                    let high: Int
                    if let neighbour = facing.neighbour {
                        low = min(stack, height(i + neighbour.di, j + neighbour.dj))
                        high = stack
                    } else if facing.normal.y > 0 {
                        low = stack - 1
                        high = stack
                    } else {
                        low = 0
                        high = 1
                    }
                    guard high > low else { continue }

                    let bottom = Float(low) * levelHeight
                    let span = Float(high - low) * levelHeight
                    let base = UInt32(positions.count)
                    for corner in 0..<4 {
                        let unit = facing.corners[corner]
                        let lift = bottom + unit.y * span
                        positions.append(column + SIMD3(
                            unit.x * cellSize, lift, unit.z * cellSize
                        ))
                        normals.append(facing.normal)
                        uvs.append(SIMD2(lift / deckHeight, quadUVs[corner].y))
                    }
                    indices += [base, base + 1, base + 2, base, base + 2, base + 3]
                    faceMaterials += [facing.material, facing.material]
                }
            }
        }

        return Field(
            positions: positions, normals: normals, uvs: uvs, indices: indices, faceMaterials: faceMaterials,
            triangles: indices.count / 3,
            vertices: positions.count,
            coverage: cellsInDisc == 0 ? 0 : Float(cellsCovered) / Float(cellsInDisc),
            buildMilliseconds: (monotonicSeconds() - started) * 1000
        )
    }
}

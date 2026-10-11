import Foundation

/// Turns a chunk's blocks into RealityKit meshes: one quad per block face
/// that borders something non-occluding, sampled from the shared texture
/// atlas so a whole chunk draws in two passes (opaque, then translucent).
///
/// Shading is resolved here, at mesh time, in two halves:
///
///   * the *average* of a face's four corner occlusions still picks a
///     pre-darkened variant of the texture out of the atlas, exactly as it
///     always has — so a mesh drawn with the stock `UnlitMaterial` looks
///     byte-for-byte the way it did before this file grew a vertex-colour
///     channel;
///   * each corner additionally carries the ratio of *its* occlusion to
///     that average, and how much open sky stands above it, in a per-vertex
///     colour which `blockSurface` reads. That turns the flat per-face step
///     into a smooth per-corner gradient and drops the ground under a
///     canopy into shade, wherever the custom shader is running.
///
/// Neither of those disturbs the first: the occlusion ratio of an evenly
/// lit face is exactly 1, the exposure of open ground is exactly 1, and a
/// mesh built for the `UnlitMaterial` fallback carries white in the colour
/// channel anyway.
///
/// The vertex-colour channel needs `LowLevelMesh` — `MeshDescriptor` has no
/// colour buffer at all, which is why the shade used to have to travel in
/// the UVs and nowhere else.
///
/// The work is in three stages, on purpose, because they belong on
/// different threads:
///
///   1. `gatherNeighbourhood` copies the chunk and its neighbours out of
///      the world. It reads live block arrays, so it runs where the world
///      is owned — the main thread. It is a bounded 42 KB copy.
///   2. `buildMeshData` turns that copy into vertices and indices. It is
///      pure arithmetic over bytes nobody else can see, and it is by far
///      the expensive stage, so the game runs it on a background queue.
///   3. `makeMesh` uploads the result. That touches RealityKit, so it is
///      `@MainActor` and stays on the frame.
enum ChunkMesher {
    // MARK: - Vertex layout

    /// One interleaved vertex. Written straight into a `LowLevelMesh`
    /// vertex buffer, with the attribute offsets taken from
    /// `MemoryLayout.offset(of:)` rather than hard-coded, so the Metal
    /// vertex descriptor cannot drift away from this declaration.
    ///
    /// Nine 4-byte fields, so the stride is 36 with no padding.
    struct Vertex {
        var px: Float, py: Float, pz: Float
        var nx: Float, ny: Float, nz: Float
        var u: Float, v: Float
        /// Per-corner lighting, as a `uchar4Normalized` vertex colour:
        ///
        ///   r — ambient-occlusion ratio, this corner's occlusion over the
        ///       face average the atlas variant already carries, divided by
        ///       `shadeScale`. `blockSurface` multiplies it back in.
        ///   g — sky exposure: 1 where the corner has open sky above it, 0
        ///       under a canopy or an overhang. See `skyCover`.
        ///   b — 255 on water, 0 on everything else. This is what tells
        ///       `blockSurface` which half of the shared translucent pass a
        ///       fragment belongs to; see `encodeShade`.
        ///   a — block light at this corner, 0…1, from torches and nothing
        ///       else. This lane was a constant 255 until there was a lamp
        ///       in the world to put in it.
        ///
        ///       Safe to use only because the encoded word is produced only
        ///       when `smoothShading` is on, and that is
        ///       `MaterialLibrary.usesCustomShader` — so a build with no
        ///       shader library never sees anything but `neutralShade`,
        ///       whose alpha is 255. `blockSurface` takes its opacity from
        ///       `texel.a` and never reads the vertex colour's, so nothing
        ///       in the custom path treats this as coverage. Put a stock
        ///       material on these meshes *while smooth shading is on* and
        ///       an unlit corner would come out fully transparent.
        ///
        /// See `encodeShade`. The whole word is 0xFFFFFFFF when nothing will
        /// decode it (`neutralShade`).
        var shade: UInt32
    }

    /// The widest per-corner shade ratio the encoding has to represent.
    ///
    /// The ratio is `cornerOcclusion / averageOcclusion`, and occlusion is
    /// one of 0.55 / 0.70 / 0.85 / 1.0, so the extreme is one open corner
    /// against three fully-dark ones: 1.0 / ((3·0.55 + 1)/4) ≈ 1.51.
    /// Rounded up to leave headroom, and matched by `kVertexShadeScale` in
    /// `BlockShaders.metal`.
    static let shadeScale: Float = 1.6

    /// Packs a shade ratio, a sky exposure and the water flag into the four
    /// bytes of a `uchar4Normalized` vertex colour. Quantisation is
    /// `shadeScale / 255` ≈ 0.6% of the ratio, far below a visible step in
    /// an 8-bit framebuffer.
    ///
    /// `water` rides in the blue byte because a *vertex* attribute is the
    /// only thing at this stage that survives being interpolated. The
    /// shader used to recognise water by testing the interpolated atlas
    /// `v` against the water tile's row, and that is not safe: with MSAA a
    /// pixel on a triangle's edge is shaded at a centre that can lie
    /// *outside* the triangle, so its attributes are extrapolated a little
    /// past the values any corner holds. Half a pixel of the `v` gradient
    /// is enough to leave the row — thousandths of `v`, against the
    /// ten-thousandth the band was padded by — and every block seam on a
    /// lake drew a dark hairline where the fragments failed the test. A
    /// flag every corner of every water quad holds at 1 extrapolates to
    /// exactly 1, whichever way the pixel centre falls.
    /// Block light rides in the alpha byte, which was the one lane of this
    /// word carrying nothing — it was written as a constant 255 and read by
    /// nobody. Torchlight needed a per-corner channel and there was one
    /// already paid for, so the vertex format did not have to change and
    /// nothing downstream of it had to be re-measured.
    @inline(__always)
    static func encodeShade(_ ratio: Float, sky: Float, water: Bool, torch: Float = 0) -> UInt32 {
        let normalized = max(0, min(1, ratio / shadeScale))
        let shadeByte = UInt32(normalized * 255 + 0.5)
        let skyByte = UInt32(max(0, min(1, sky)) * 255 + 0.5)
        let waterByte: UInt32 = water ? 255 : 0
        let torchByte = UInt32(max(0, min(1, torch)) * 255 + 0.5)
        return shadeByte | (skyByte << 8) | (waterByte << 16) | (torchByte << 24)
    }

    /// The colour a mesh carries when nothing will read it: opaque white,
    /// so that a stock material which *does* modulate by vertex colour is
    /// left exactly where it started. Used for the `UnlitMaterial`
    /// fallback, which has no shader to undo `shadeScale`.
    private static let neutralShade: UInt32 = 0xFFFF_FFFF

    /// A plain grey vertex colour, for the shaped blocks under the
    /// `UnlitMaterial` fallback.
    ///
    /// They sample the atlas at full brightness and carry their whole shade
    /// in the vertex colour, which the fallback has no shader to decode —
    /// so without this a staircase would be the one thing in a flat-lit
    /// capture with no directional shading at all. Grey, not the shader's
    /// encoding: a stock material that multiplies by vertex colour lands on
    /// the right answer, and one that ignores it is no worse off. The cube
    /// path is untouched and still writes white, which is ×1 either way.
    @inline(__always)
    static func flatShade(_ tint: Float) -> UInt32 {
        let level = UInt32(max(0, min(1, tint)) * 255 + 0.5)
        return level | (level << 8) | (level << 16) | (255 << 24)
    }

    // MARK: - Buffers

    /// Accumulates one draw pass' vertices and indices.
    struct Buffer: Sendable {
        var vertices: [Vertex] = []
        var indices: [UInt32] = []
        /// Tracked as the quads go in, so the `LowLevelMesh` part can be
        /// given real bounds instead of the whole chunk column — frustum
        /// culling reads them.
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        var isEmpty: Bool { indices.isEmpty }

        mutating func reserve(_ quads: Int) {
            vertices.reserveCapacity(quads * 4)
            indices.reserveCapacity(quads * 6)
        }
    }

    struct MeshData: Sendable {
        var opaque: Buffer?
        var translucent: Buffer?
        /// The opaque faces the classifier called buried. Nil unless the
        /// build was asked for them — that is the whole point of the split:
        /// an unrevealed chunk never spends the arithmetic, the vertices or
        /// the upload on geometry no camera can reach.
        var buried: Buffer?
        /// Which halves this build actually covers, so the installer knows
        /// whether a nil buffer means "empty" or "not asked for".
        var faces: FaceSet = .all

        var isEmpty: Bool { opaque == nil && translucent == nil && buried == nil }
        var vertexCount: Int {
            (opaque?.vertices.count ?? 0) + (translucent?.vertices.count ?? 0)
                + (buried?.vertices.count ?? 0)
        }
        var buriedVertexCount: Int { buried?.vertices.count ?? 0 }
        /// Buried *translucent* vertices, counted but never split off — see
        /// `buildMeshData`. Diagnostic only; the snapshot harness prints it.
        var buriedTranslucentVertexCount: Int = 0
    }

    /// Which half of a chunk's geometry a build is for.
    ///
    /// The two halves are independent meshes hanging off the same chunk, so
    /// revealing a chunk's hidden half does not disturb — or re-upload —
    /// the surface half already on screen, and re-meshing after an edit
    /// rebuilds whichever halves that chunk currently shows.
    struct FaceSet: OptionSet, Sendable {
        let rawValue: Int
        static let surface = FaceSet(rawValue: 1)
        static let buried = FaceSet(rawValue: 2)
        static let all: FaceSet = [.surface, .buried]
    }

    // MARK: - The padded neighbourhood

    // The mesher reads one cell outside the chunk in every direction: face
    // culling looks at the immediate neighbour, and ambient occlusion looks
    // at the two cells flanking each vertex plus the one diagonally between
    // them — never more than one step in x or z, one in y.
    //
    // Rather than pay `World.block()` — a dictionary lookup and a
    // floor-divide — for each of those, the 3×3 chunk neighbourhood is
    // flattened once into one padded byte volume and every lookup
    // afterwards is one integer index into it. At roughly 2,900 quads a
    // chunk that is on the order of 80,000 dictionary lookups traded for a
    // bounded copy.
    //
    // The horizontal padding is not one cell but twelve, and the extra is
    // a correctness requirement rather than a margin — see `pad`.
    /// How far outside the chunk the buried-face classifier may look for a
    /// route out to the sky, in blocks. The one knob this scheme has.
    ///
    /// Sky-openness alone is too literal a test. The air inside a cave
    /// mouth, under an overhang or beneath a canopy is not sky-open and is
    /// plainly visible from outside, so the classifier floods from the
    /// sky-open air through connected air and calls everything it reaches
    /// surface as well. The flood is *not* step-limited, and that is worth
    /// recording, because a step limit is the obvious design and it fails:
    /// a hillside seen nearly edge-on shows a viewer tens of blocks along a
    /// one-block slot, so a fixed reach leaves a sliver of sky showing
    /// through the far end of it. Raising the limit closed those slivers
    /// only asymptotically — 8, 12 and 16 steps took one camera's error
    /// from 141 pixels to 87 to 60, each step costing about 4% more
    /// geometry — which is the signature of a criterion that is wrong
    /// rather than under-tuned. Dropping the limit entirely cost almost
    /// nothing, because most cave air is a noise-carved pocket with no
    /// route to the surface at all, and made every test camera exact.
    ///
    /// What is left bounding it is this box: the flood can only find a
    /// route that stays within `pad` cells of the chunk. That bound is what
    /// keeps the answer a property of the *world* rather than of which
    /// chunk is asking — every chunk that could classify a given cell
    /// searches a box at least this big around it, so they agree, and
    /// geometry one chunk calls visible its neighbour cannot call buried.
    /// Measured on ten cameras against the pre-culling renderer: 4 and 8
    /// leave visible holes, 10 and 12 are byte-identical and identical to
    /// each other. Twelve is one step past where it converged.
    ///
    /// Vertical padding stays at one: a chunk is the full 128-block column,
    /// so there is nothing above or below to be missing.
    ///
    /// Not private, because it is also the radius `World.setBlock` has to
    /// fan an edit out over: a cell within `pad` of a seam is inside the
    /// neighbour's flooded box, so the neighbour's split depends on it.
    /// Raising this widens that fan-out with it, and it may not pass
    /// `Chunk.width` — `gatherNeighbourhood` has the `precondition` and the
    /// reasons.
    static let pad = 12
    private static let padSpan = Chunk.width + 2 * pad    // 40
    private static let padRow = padSpan                   // +1 in z
    private static let padSlice = padSpan * padSpan       // +1 in y, 1600
    private static let padHeight = Chunk.height + 2       // 194
    private static let padCount = padSlice * padHeight

    @inline(__always)
    private static func padIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
        (x + pad) + (z + pad) * padRow + (y + 1) * padSlice
    }

    // Sky exposure has its own, tighter index space. It reads one cell out
    // of the chunk and no further, so it lives in an 18x130x18 volume of
    // its own rather than riding along in the classifier's 40x130x40 one —
    // which would be 208 KB per chunk build, of which 42 KB is ever
    // written and none of the rest is ever read. Under a machine that is
    // already saturating memory bandwidth (chunk generation runs eight
    // threads wide) that difference is measurable, and it is pure waste.
    private static let coverSpan = Chunk.width + 2        // 18
    private static let coverRow = coverSpan
    private static let coverSlice = coverSpan * coverSpan // 324
    private static let coverCount = coverSlice * padHeight

    @inline(__always)
    private static func coverIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
        (x + 1) + (z + 1) * coverRow + (y + 1) * coverSlice
    }

    /// A chunk's neighbourhood, copied out of the world.
    ///
    /// This is the seam the mesher is split along. Everything upstream of
    /// it reads live `Chunk.blocks` arrays, which the main thread writes to
    /// whenever the player breaks a block or a fizzler goes off, so it has
    /// to happen on the main thread. Everything downstream reads only this
    /// value — 42 KB of bytes owned by nobody else — so it can run on any
    /// thread at all, which is where the expensive part goes.
    struct Neighbourhood: Sendable {
        fileprivate let cells: [UInt8]
        /// The same footprint's skyline — the highest occluding y in each
        /// padded column, -1 where there is none. Copied out of the chunks
        /// rather than rescanned here: see `Chunk.skyline`.
        fileprivate let skyline: [Int16]
        /// Block light, in the tight `coverIndex` space rather than the
        /// classifier's wide one. A corner samples the four cells touching
        /// it on the face's outer plane and never reaches further, so one
        /// ring is all this needs — the same reasoning, and the same 18×130×18
        /// volume, that sky cover already uses.
        fileprivate let light: [UInt8]
    }

    /// Copies the chunk and its eight horizontal neighbours into one padded
    /// volume. A neighbour that has not streamed in yet stays zero, which
    /// is air — the same answer `World.block()` gives for a missing chunk.
    ///
    /// Must be called from whichever thread owns the world.
    static func gatherNeighbourhood(chunk: Chunk, in world: World) -> Neighbourhood {
        // `pad` is the one knob this whole scheme has, and it has two
        // ceilings. The low one is right below: a neighbour's strip starts
        // at `Chunk.width - pad`, which goes negative the moment `pad`
        // passes 16 and walks an unsafe pointer off the front of that
        // chunk's storage. The high one is in `classifySurfaces`, whose
        // flood packs padded x and z into six bits each and so needs
        // `padSpan` under 64. Holding `pad` to the chunk width satisfies
        // both — `padSpan` tops out at 48 — and neither failure announces
        // itself: one reads whatever memory precedes an array, the other
        // floods the wrong cells and leaves geometry missing in scattered
        // places. The hardest symptoms in this system to trace back to a
        // constant, so the knob is checked rather than trusted. Once per
        // chunk build, and this is the first thing a build does.
        precondition(pad <= Chunk.width, "ChunkMesher.pad may not exceed Chunk.width (\(Chunk.width)): "
                     + "gatherNeighbourhood copies a neighbour's strip from Chunk.width - pad")
        var cells = [UInt8](repeating: 0, count: padCount)
        // -1 is "no occluder in this column", which is what a chunk that
        // has not streamed in yet has to look like: all air, all sky.
        var skyline = [Int16](repeating: -1, count: padSlice)

        cells.withUnsafeMutableBufferPointer { destination in
        skyline.withUnsafeMutableBufferPointer { skylineOut in
            guard let base = destination.baseAddress,
                  let skylineBase = skylineOut.baseAddress else { return }
            for dz in -1...1 {
                for dx in -1...1 {
                    let source: Chunk?
                    if dx == 0 && dz == 0 {
                        source = chunk
                    } else {
                        source = world.chunk(at: ChunkCoord(x: chunk.coord.x + dx, z: chunk.coord.z + dz))
                    }
                    guard let source else { continue }

                    // Which of this neighbour's local columns land inside
                    // the padded box: all of them for the centre chunk, a
                    // `pad`-deep strip along the shared edge for a side, a
                    // pad × pad corner for a diagonal.
                    let xStart = dx < 0 ? Chunk.width - pad : 0
                    let xCount = dx == 0 ? Chunk.width : pad
                    let zStart = dz < 0 ? Chunk.depth - pad : 0
                    let zCount = dz == 0 ? Chunk.depth : pad

                    source.blocks.withUnsafeBufferPointer { origin in
                        guard let originBase = origin.baseAddress else { return }
                        for y in 0..<Chunk.height {
                            let sourceSlice = y * (Chunk.width * Chunk.depth)
                            let destinationSlice = (y + 1) * padSlice
                            for step in 0..<zCount {
                                let lz = zStart + step
                                let from = originBase + sourceSlice + lz * Chunk.width + xStart
                                let to = base + destinationSlice
                                    + (lz + dz * Chunk.depth + pad) * padRow
                                    + (xStart + dx * Chunk.width + pad)
                                to.update(from: from, count: xCount)
                            }
                        }
                    }
                    source.skyline.withUnsafeBufferPointer { origin in
                        guard let originBase = origin.baseAddress else { return }
                        for step in 0..<zCount {
                            let lz = zStart + step
                            let from = originBase + lz * Chunk.width + xStart
                            let to = skylineBase
                                + (lz + dz * Chunk.depth + pad) * padRow
                                + (xStart + dx * Chunk.width + pad)
                            to.update(from: from, count: xCount)
                        }
                    }
                }
            }
        }
        }

        // Light, into its own tight volume. One ring rather than `pad`
        // deep: the widest reach any vertex makes into this is the four
        // cells around a corner, all of which sit within one cell of the
        // chunk. Copying it `pad` deep would be five times the bytes for
        // cells no corner can name.
        var light = [UInt8](repeating: 0, count: coverCount)
        for dz in -1...1 {
            for dx in -1...1 {
                let source = (dx == 0 && dz == 0)
                    ? chunk
                    : world.chunk(at: ChunkCoord(x: chunk.coord.x + dx, z: chunk.coord.z + dz))
                guard let source, source.isLit else { continue }
                let xRange = dx == 0 ? 0..<Chunk.width : (dx < 0 ? (Chunk.width - 1)..<Chunk.width : 0..<1)
                let zRange = dz == 0 ? 0..<Chunk.depth : (dz < 0 ? (Chunk.depth - 1)..<Chunk.depth : 0..<1)
                source.light.withUnsafeBufferPointer { origin in
                    guard let originBase = origin.baseAddress else { return }
                    light.withUnsafeMutableBufferPointer { destination in
                        guard let base = destination.baseAddress else { return }
                        for y in 0..<Chunk.height {
                            let sourceSlice = y * (Chunk.width * Chunk.depth)
                            for lz in zRange {
                                let coverZ = lz + dz * Chunk.depth
                                for lx in xRange {
                                    let coverX = lx + dx * Chunk.width
                                    base[coverIndex(coverX, y, coverZ)] =
                                        originBase[sourceSlice + lz * Chunk.width + lx]
                                }
                            }
                        }
                    }
                }
            }
        }
        return Neighbourhood(cells: cells, skyline: skyline, light: light)
    }

    private static let opaqueTable = BlockType.opaqueByRawValue
    private static let emissionTable = BlockType.emissionByRawValue

    /// Which raw values leave the cube path. One flat lookup per non-air
    /// cell decides it — deliberately a table and not `type.isShaped`, and
    /// deliberately asked once per *cell* rather than once per face, so the
    /// cube inner loop below carries a single predicted branch and nothing
    /// else for a feature it never uses.
    private static let shapedTable = BlockType.shapedByRawValue

    // MARK: - Sky exposure

    /// How far up a column is searched for cover, in blocks.
    ///
    /// Everything this finds is a *shadow caster*: a canopy, an overhang, a
    /// ceiling. Forty blocks is a tall tree plus the cliff it grows on, and
    /// stopping there is what keeps the term from being a second, redundant
    /// statement of "this is underground" — the whole 128-block column would
    /// saturate anywhere below the surface, where the corner occlusion the
    /// mesher already bakes is doing that job.
    private static let skyReach = 40

    /// Blocks of cover overhead that count as fully shaded. A tree canopy is
    /// two or three leaf layers thick, so three puts the middle of a canopy
    /// at full shade and its fringe in a soft gradient.
    private static let skyFullCover: Float = 3

    /// The four taps of the exposure tent, folded into one multiply: the
    /// quarter that averages them, over `skyFullCover`.
    private static let skyCoverScale: Float = 0.25 / skyFullCover

    /// The torch tent's divisor, indexed by how many of the four taps
    /// actually carried light: `1 / (n * maximum)`, and zero for none.
    ///
    /// A table rather than a divide, because this is read four times per
    /// face in the mesher's innermost loop and the alternative is an
    /// integer division there. See the corner loop for why the count is
    /// not simply four.
    private static let torchTapScale: [Float] = (0...4).map {
        $0 == 0 ? 0 : 1 / (Float($0) * Float(BlockLight.maximum))
    }

    /// For every cell of the padded volume, how many opaque blocks stand in
    /// the `skyReach` blocks starting at it (itself included).
    ///
    /// One downward sweep with a sliding window, so the whole 18×130×18
    /// volume costs two byte loads and a store per cell — the "column march"
    /// is a running total, not a march. Indexed exactly like the block
    /// volume, so a face can sample it with the padded index steps it
    /// already computed for ambient occlusion.
    ///
    /// The sweep goes slice by slice rather than column by column, carrying
    /// a whole slice's running totals at once, which makes every read and
    /// every write sequential. The obvious loop order — finish one column,
    /// move to the next — walks the volume in strides of a slice instead,
    /// and was measurably worse for no gain in clarity.
    ///
    /// Only the 18x18 columns a vertex can actually sample are swept, and
    /// the result lives in a volume that size — see `coverIndex`. The
    /// block volume around it is padded far wider for the buried-face
    /// classifier, and carrying exposure at that width would be most of
    /// this pass' cost spent on cells nothing reads.
    ///
    /// The world is 128 blocks tall and a chunk *is* the full column — there
    /// is no vertical chunking — so nothing casting a shadow can be above
    /// the top of this volume. The window simply runs off the end into air.
    private static func skyCover(
        in volume: UnsafeBufferPointer<UInt8>,
        occluders: UnsafeBufferPointer<Bool>
    ) -> [UInt8] {
        // Every cell is written, so the array is left uninitialised rather
        // than zero-filled: a 42 KB memset per chunk for bytes that are all
        // about to be overwritten.
        [UInt8](unsafeUninitializedCapacity: coverCount) { out, initialized in
            initialized = coverCount
            guard let outBase = out.baseAddress, let inBase = volume.baseAddress else { return }
            // Padded row 0 is world y = -1 and padded row `top` is y = 128,
            // one above the world's ceiling.
            let top = Chunk.height
            // The swept columns run from one cell outside the chunk to one
            // cell outside the far side, so the block volume is read at an
            // offset while the output is written from its own origin.
            let first = pad - 1
            withUnsafeTemporaryAllocation(of: Int32.self, capacity: coverSlice) { running in
                for cell in 0..<coverSlice { running[cell] = 0 }
                var row = top + 1
                while row >= 0 {
                    let entering = inBase + row * padSlice
                    let leavingRow = row + skyReach
                    let leaving = leavingRow <= top + 1 ? inBase + leavingRow * padSlice : nil
                    let destination = outBase + row * coverSlice
                    for line in 0..<coverSpan {
                        let source = (first + line) * padRow + first
                        let target = line * coverRow
                        for cell in 0..<coverSpan {
                            var count = running[target + cell]
                            if occluders[Int(entering[source + cell])] { count += 1 }
                            if let leaving, occluders[Int(leaving[source + cell])] { count -= 1 }
                            running[target + cell] = count
                            destination[target + cell] =
                                count > 255 ? 255 : UInt8(truncatingIfNeeded: count)
                        }
                    }
                    row -= 1
                }
            }
        }
    }

    // MARK: - Buried geometry

    /// What the flood has decided about a padded cell.
    private enum Mark {
        /// The flood has not looked at this cell.
        static let untouched: UInt8 = 0
        /// Looked at and refused: rock, or air that is sky-open already.
        static let rejected: UInt8 = 1
        /// Dark air the flood reached from sky-open air — the whole point.
        static let reached: UInt8 = 2
    }

    /// The classifier's verdict for one chunk's padded neighbourhood.
    ///
    /// A face is SURFACE when the cell it opens onto is either sky-open —
    /// strictly above the highest occluder in its own column — or was
    /// reached by the flood. Everything else is BURIED: cave walls, ore
    /// pockets, the underside of the world, all of it geometry that exists
    /// only so that a player who digs there finds something to look at.
    private struct Surfaces {
        var reached: [UInt8]
    }

    /// Builds the surface/buried classification for a padded neighbourhood.
    ///
    /// The skyline arrives already computed — `Chunk` keeps one per column
    /// and drops it only when a block changes — so all that is left here is
    /// a breadth-first flood from the sky-open cells that actually border
    /// dark ones, run until it stops finding new air.
    ///
    /// Only the *frontier* of the sky-open set is seeded, not all of it.
    /// A sky-open cell can only touch a dark one sideways (the cell below
    /// the lowest sky-open cell of a column is by definition the occluder
    /// that made it the lowest), so the seeds of a column are exactly the
    /// cells between its own top occluder and the tallest of its four
    /// neighbours' — a cliff's worth, usually none at all, rather than the
    /// sixty blocks of empty sky standing over every column.
    ///
    /// Whether a cell can be flooded into is worked out as the flood
    /// touches it rather than written into a state array first. The array
    /// would be a linear pass over a 208,000-cell volume whose interesting
    /// part — air with rock over it that the sky can still reach — is a few
    /// percent of its cells.
    private static func classifySurfaces(
        in volume: UnsafeBufferPointer<UInt8>,
        skyline: UnsafeBufferPointer<Int16>,
        occluders: UnsafeBufferPointer<Bool>
    ) -> Surfaces {
        var reached = [UInt8](repeating: 0, count: padCount)

        reached.withUnsafeMutableBufferPointer { marks in
            guard let volumeBase = volume.baseAddress,
                  let top = skyline.baseAddress,
                  let marks = marks.baseAddress else { return }

            // Coordinates travel packed rather than as raw indices, so
            // a step off the side of the padded box is a comparison
            // instead of a wrap into the neighbouring row.
            //
            // Six bits each for x and z, twelve up for the row, so `padSpan`
            // may not pass 64: past that x's high bit slides into z's field
            // and the flood marks the wrong cells — no crash and no bad
            // index, because every unpacked coordinate is still in range,
            // just geometry missing in scattered places. `gatherNeighbourhood`
            // holds `pad` to `Chunk.width`, which caps `padSpan` at 48, and
            // it runs before this does.
            @inline(__always) func pack(_ x: Int, _ row: Int, _ z: Int) -> Int32 {
                Int32(x | (z << 6) | (row << 12))
            }

            var frontier: [Int32] = []
            for cz in 0..<padSpan {
                for cx in 0..<padSpan {
                    let column = cx + cz * padRow
                    let mine = top[column]
                    var highest = mine
                    if cx > 0 { highest = max(highest, top[column - 1]) }
                    if cx < padSpan - 1 { highest = max(highest, top[column + 1]) }
                    if cz > 0 { highest = max(highest, top[column - padRow]) }
                    if cz < padSpan - 1 { highest = max(highest, top[column + padRow]) }
                    guard highest > mine else { continue }
                    for y in (Int(mine) + 1)...Int(highest) {
                        frontier.append(pack(cx, y + 1, cz))
                    }
                }
            }

            var next: [Int32] = []
            while !frontier.isEmpty {
                for packed in frontier {
                    let value = Int(packed)
                    let cx = value & 63, cz = (value >> 6) & 63, row = value >> 12

                    @inline(__always) func visit(_ nx: Int, _ nrow: Int, _ nz: Int) {
                        guard nx >= 0, nx < padSpan, nz >= 0, nz < padSpan,
                              nrow >= 0, nrow < padHeight else { return }
                        let index = nx + nz * padRow + nrow * padSlice
                        guard marks[index] == Mark.untouched else { return }
                        // Rock stops the flood, and a sky-open cell is
                        // already surface and never a target — both are
                        // marked so a neighbour does not retest them.
                        guard !occluders[Int(volumeBase[index])],
                              Int16(nrow - 1) <= top[nx + nz * padRow] else {
                            marks[index] = Mark.rejected
                            return
                        }
                        marks[index] = Mark.reached
                        next.append(pack(nx, nrow, nz))
                    }

                    visit(cx - 1, row, cz)
                    visit(cx + 1, row, cz)
                    visit(cx, row, cz - 1)
                    visit(cx, row, cz + 1)
                    visit(cx, row - 1, cz)
                    visit(cx, row + 1, cz)
                }
                swap(&frontier, &next)
                next.removeAll(keepingCapacity: true)
            }
        }

        return Surfaces(reached: reached)
    }

    // MARK: - Face tables

    /// Per-face geometry, with everything the inner loop needs already
    /// reduced to integers: padded-volume index steps, corner offsets, and
    /// the pair of index steps each corner samples its occlusion along.
    private struct Face {
        let normal: SIMD3<Float>
        let offsetX: Int, offsetY: Int, offsetZ: Int
        /// Padded index delta from a cell to the cell this face opens onto.
        let step: Int
        /// The same delta in the exposure volume's index space.
        let coverStep: Int
        /// The four corner offsets of the quad, each 0 or 1 per axis,
        /// wound counter-clockwise as seen from outside.
        let corners: [SIMD3<Float>]
        /// Per corner, the padded index deltas to the two flanking cells.
        /// The diagonal cell is the sum of the two.
        let occlusionSteps: [(a: Int, b: Int)]
        /// The same four steps in the exposure volume's tighter index
        /// space, which has a different row and slice stride.
        let coverSteps: [(a: Int, b: Int)]
        /// Fixed per-direction brightness. Top faces are brightest, the two
        /// horizontal axes differ slightly so adjoining walls read apart,
        /// and undersides are darkest.
        let tint: Float
        let kind: FaceKind
    }


    private static let faces: [Face] = {
        /// normal, four corners, and the two in-plane axes AO samples along.
        let templates: [(normal: (Int, Int, Int),
                         corners: [(Int, Int, Int)],
                         tangentA: (Int, Int, Int),
                         tangentB: (Int, Int, Int))] = [
            ((0, 1, 0), [(0, 1, 1), (1, 1, 1), (1, 1, 0), (0, 1, 0)], (1, 0, 0), (0, 0, 1)),
            ((0, -1, 0), [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)], (1, 0, 0), (0, 0, 1)),
            ((0, 0, 1), [(0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)], (1, 0, 0), (0, 1, 0)),
            ((0, 0, -1), [(1, 0, 0), (0, 0, 0), (0, 1, 0), (1, 1, 0)], (1, 0, 0), (0, 1, 0)),
            ((1, 0, 0), [(1, 0, 1), (1, 0, 0), (1, 1, 0), (1, 1, 1)], (0, 0, 1), (0, 1, 0)),
            ((-1, 0, 0), [(0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0)], (0, 0, 1), (0, 1, 0)),
        ]

        func step(_ v: (Int, Int, Int)) -> Int {
            v.0 + v.2 * padRow + v.1 * padSlice
        }
        func coverStep(_ v: (Int, Int, Int)) -> Int {
            v.0 + v.2 * coverRow + v.1 * coverSlice
        }

        return templates.map { template in
            let normal = template.normal
            // Corner offsets are 0/1; convert to -1/+1 directions along
            // each in-plane tangent so we sample the correct side.
            let tangents = template.corners.map { corner -> ((Int, Int, Int), (Int, Int, Int)) in
                func direction(_ tangent: (Int, Int, Int)) -> Int {
                    let component = tangent.0 != 0 ? corner.0 : (tangent.1 != 0 ? corner.1 : corner.2)
                    return component == 1 ? 1 : -1
                }
                let a = direction(template.tangentA), b = direction(template.tangentB)
                return ((template.tangentA.0 * a, template.tangentA.1 * a, template.tangentA.2 * a),
                        (template.tangentB.0 * b, template.tangentB.1 * b, template.tangentB.2 * b))
            }
            let occlusion = tangents.map { (a: step($0.0), b: step($0.1)) }
            let cover = tangents.map { (a: coverStep($0.0), b: coverStep($0.1)) }
            let tint: Float
            if normal.1 > 0 { tint = 1.0 }
            else if normal.1 < 0 { tint = 0.60 }
            else if normal.0 != 0 { tint = 0.76 }
            else { tint = 0.88 }

            return Face(
                normal: SIMD3<Float>(Float(normal.0), Float(normal.1), Float(normal.2)),
                offsetX: normal.0, offsetY: normal.1, offsetZ: normal.2,
                step: step(normal),
                coverStep: coverStep(normal),
                corners: template.corners.map { SIMD3<Float>(Float($0.0), Float($0.1), Float($0.2)) },
                occlusionSteps: occlusion,
                coverSteps: cover,
                tint: tint,
                kind: FaceKind(normalY: normal.1)
            )
        }
    }()

    // MARK: - Building

    /// Gathers a chunk's neighbourhood and builds its geometry in one go.
    /// Convenience for callers that are already on the world's thread and
    /// in no hurry — the snapshot harness and the streaming benchmark.
    static func buildMeshData(
        chunk: Chunk, in world: World, smoothShading: Bool, faces: FaceSet = .all
    ) -> MeshData {
        buildMeshData(
            from: gatherNeighbourhood(chunk: chunk, in: world),
            smoothShading: smoothShading, faces: faces
        )
    }

    /// Builds the geometry for a gathered neighbourhood. Pure computation
    /// over a private copy of the block bytes — it touches no `Chunk`, no
    /// `World` and no RealityKit resource, so it is safe on any thread, and
    /// the game runs it on a background queue. `makeMesh` turns the result
    /// into a `MeshResource`, and that part is `@MainActor`.
    ///
    /// `smoothShading` should be `MaterialLibrary.usesCustomShader`. When
    /// it is false the vertex colours are written white instead of encoded
    /// shade ratios: nothing will decode them, and white is the one value a
    /// stock material cannot be disturbed by.
    /// `faces` picks which half of the chunk is built. `.surface` is what
    /// every chunk gets by default; `.buried` builds only the hidden half,
    /// which is what revealing a chunk costs; `.all` builds both into
    /// separate buffers, for a chunk that is already revealed and has just
    /// been edited.
    static func buildMeshData(
        from neighbourhood: Neighbourhood, smoothShading: Bool, faces wanted: FaceSet = .all
    ) -> MeshData {
        let wantsSurface = wanted.contains(.surface)
        let wantsBuried = wanted.contains(.buried)

        var opaque = Buffer()
        var translucent = Buffer()
        var buried = Buffer()
        if wantsSurface {
            opaque.reserve(1024)
            translucent.reserve(256)
        }
        if wantsBuried { buried.reserve(3072) }
        var buriedTranslucent = 0

        neighbourhood.cells.withUnsafeBufferPointer { volume in
            opaqueTable.withUnsafeBufferPointer { occluders in
                // Only the custom shader decodes sky exposure; the flat-lit
                // fallback writes white into the colour channel and would
                // throw the whole sweep away.
                let cover = smoothShading ? skyCover(in: volume, occluders: occluders) : []
                neighbourhood.skyline.withUnsafeBufferPointer { skyline in
                let surfaces = classifySurfaces(
                    in: volume, skyline: skyline, occluders: occluders
                )
                cover.withUnsafeBufferPointer { sky in
                neighbourhood.light.withUnsafeBufferPointer { lamps in
                surfaces.reached.withUnsafeBufferPointer { reached in
                    for y in 0..<Chunk.height {
                        for z in 0..<Chunk.depth {
                            for x in 0..<Chunk.width {
                                let index = padIndex(x, y, z)
                                let coverCell = coverIndex(x, y, z)
                                let raw = volume[index]
                                guard raw != 0, let type = BlockType(rawValue: raw) else { continue }

                                // Stairs, doors, panes and beds are boxes
                                // inside a cell rather than the cell, so
                                // they leave here entirely. They only ever
                                // arrive by a player edit, and an edit
                                // reveals its chunk, so they are always
                                // built with the surface half and never
                                // split off into the buried one — a
                                // staircase nobody can see is not a case
                                // worth a second buffer.
                                if shapedTable[Int(raw)] {
                                    guard wantsSurface else { continue }
                                    if type.isTranslucent {
                                        emitShaped(type: type, at: (x, y, z), cellIndex: index,
                                                   coverCell: coverCell, volume: volume,
                                                   occluders: occluders, sky: sky, lamps: lamps,
                                                   smoothShading: smoothShading, into: &translucent)
                                    } else {
                                        emitShaped(type: type, at: (x, y, z), cellIndex: index,
                                                   coverCell: coverCell, volume: volume,
                                                   occluders: occluders, sky: sky, lamps: lamps,
                                                   smoothShading: smoothShading, into: &opaque)
                                    }
                                    continue
                                }

                                let isTranslucent = type.isTranslucent
                                let isWater = type == .water

                                for face in faces {
                                    let outside = index + face.step
                                    let neighbourRaw = volume[outside]
                                    // Opaque neighbours hide the face outright;
                                    // two translucent blocks of the same kind
                                    // hide each other's shared face so a lake
                                    // isn't a stack of internal quads.
                                    if occluders[Int(neighbourRaw)] { continue }

                                    // Can anything standing outside the
                                    // ground see the air this face opens
                                    // onto? Sky-open cells qualify outright;
                                    // the dilation covers cave mouths and
                                    // the shade under an overhang.
                                    let column = (x + face.offsetX + pad)
                                        + (z + face.offsetZ + pad) * padRow
                                    let isSurface = Int16(y + face.offsetY) > skyline[column]
                                        || reached[outside] == Mark.reached

                                    if isTranslucent {
                                        if neighbourRaw == raw { continue }
                                        if isWater, let neighbour = BlockType(rawValue: neighbourRaw),
                                           neighbour.isSolid { continue }
                                        // Water and glass are never split.
                                        // Measured over the benchmark
                                        // capture, the buried share of the
                                        // translucent pass is a rounding
                                        // error against the opaque one, and
                                        // a pass that is always whole is a
                                        // pass that can never be the reason
                                        // a lake has a hole in it.
                                        if !isSurface { buriedTranslucent += 4 }
                                        guard wantsSurface else { continue }
                                        emit(face: face, at: (x, y, z), cellIndex: index,
                                             coverCell: coverCell,
                                             volume: volume, occluders: occluders, sky: sky, lamps: lamps,
                                             tile: type.tile(for: face.kind),
                                             applyAO: false, isWater: isWater,
                                             smoothShading: smoothShading,
                                             into: &translucent)
                                    } else {
                                        guard isSurface ? wantsSurface : wantsBuried else { continue }
                                        let tile = type.tile(for: face.kind)
                                        if isSurface {
                                            emit(face: face, at: (x, y, z), cellIndex: index,
                                                 coverCell: coverCell,
                                                 volume: volume, occluders: occluders, sky: sky, lamps: lamps,
                                                 tile: tile, applyAO: true, isWater: false,
                                                 smoothShading: smoothShading, into: &opaque)
                                        } else {
                                            emit(face: face, at: (x, y, z), cellIndex: index,
                                                 coverCell: coverCell,
                                                 volume: volume, occluders: occluders, sky: sky, lamps: lamps,
                                                 tile: tile, applyAO: true, isWater: false,
                                                 smoothShading: smoothShading, into: &buried)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                }
                }
                }
            }
        }

        return MeshData(
            opaque: wantsSurface && !opaque.isEmpty ? opaque : nil,
            translucent: wantsSurface && !translucent.isEmpty ? translucent : nil,
            buried: wantsBuried && !buried.isEmpty ? buried : nil,
            faces: wanted,
            buriedTranslucentVertexCount: buriedTranslucent
        )
    }

    /// Appends one quad: the atlas variant matching the face's *average*
    /// brightness, plus each corner's deviation from that average and its
    /// sky exposure in the vertex colour.
    @inline(__always)
    private static func emit(
        face: Face,
        at local: (x: Int, y: Int, z: Int),
        cellIndex: Int,
        coverCell: Int,
        volume: UnsafeBufferPointer<UInt8>,
        occluders: UnsafeBufferPointer<Bool>,
        sky: UnsafeBufferPointer<UInt8>,
        lamps: UnsafeBufferPointer<UInt8>,
        tile: AtlasTile,
        applyAO: Bool,
        isWater: Bool,
        smoothShading: Bool,
        into buffer: inout Buffer
    ) {
        // The cell just outside the face, which all four corners sit on,
        // in each of the two index spaces that describe it.
        let outside = cellIndex + face.step
        let coverOutside = coverCell + face.coverStep

        var occlusion = SIMD4<Float>(repeating: 1)
        // How much open sky each corner has above it. Sampled on the
        // *outside* of the face — the air cell the face opens onto — and not
        // in the block's own column. That distinction is the whole thing: a
        // cliff face has ten blocks of stone directly above the block it
        // belongs to and nothing at all above the air in front of it, and it
        // is lit, not buried.
        var exposure = SIMD4<Float>(repeating: 1)
        // Torchlight, averaged over the same four cells the sky tent uses.
        // Sampled outside the face for the same reason: what lights a wall
        // is the lamp in the room, not the rock behind it — except that a
        // face of an emitting block is not a wall near a lamp, it is the
        // lamp. Its torch light is floored at the block's own emission, or
        // a sea lantern's face would render one step dimmer than the light
        // it floods over everything around it.
        let ownGlow = emissionTable[Int(volume[cellIndex])]
        var torch = SIMD4<Float>(repeating: ownGlow)
        if applyAO || smoothShading {
            // One pass over the corners for both, because they read the same
            // four padded index steps: the two cells flanking the corner in
            // the face's plane and the diagonal between them.
            for corner in 0..<4 {
                let steps = face.occlusionSteps[corner]
                if smoothShading {
                    let taps = face.coverSteps[corner]
                    let cover = Int(sky[coverOutside])
                        + Int(sky[coverOutside + taps.a])
                        + Int(sky[coverOutside + taps.b])
                        + Int(sky[coverOutside + taps.a + taps.b])
                    exposure[corner] = max(0, 1 - Float(cover) * skyCoverScale)

                    // Averaged over the taps that carry light, not over all
                    // four. A tap inside a solid block reads zero, and
                    // dividing by four regardless is what made a torch
                    // standing on a floor light almost nothing: three of
                    // the four taps at a floor corner are the slab itself,
                    // so a lamp at full strength arrived as a quarter of
                    // itself — and then the shader squares it, so a quarter
                    // became a sixteenth. Measured before this: stone a
                    // block from a torch at midnight came back 1.2x the
                    // brightness of stone twenty blocks away, with no warmth
                    // in it at all.
                    //
                    // This is also what the original's own smooth lighting
                    // does. The cost of it is that a corner with one lit tap
                    // and three buried ones reads full brightness rather
                    // than a quarter, which is the right answer: the corner
                    // *is* next to a lamp.
                    let l0 = Int(lamps[coverOutside])
                    let l1 = Int(lamps[coverOutside + taps.a])
                    let l2 = Int(lamps[coverOutside + taps.b])
                    let l3 = Int(lamps[coverOutside + taps.a + taps.b])
                    let carrying = (l0 > 0 ? 1 : 0) + (l1 > 0 ? 1 : 0)
                        + (l2 > 0 ? 1 : 0) + (l3 > 0 ? 1 : 0)
                    torch[corner] = max(
                        ownGlow, Float(l0 + l1 + l2 + l3) * torchTapScale[carrying]
                    )
                }
                guard applyAO else { continue }
                let sideA = occluders[Int(volume[outside + steps.a])]
                let sideB = occluders[Int(volume[outside + steps.b])]
                // Two flanking blocks always mean a fully-dark corner, and
                // the diagonal between them is then irrelevant.
                if sideA && sideB {
                    occlusion[corner] = 0.55
                    continue
                }
                let diagonal = occluders[Int(volume[outside + steps.a + steps.b])]
                switch (sideA ? 1 : 0) + (sideB ? 1 : 0) + (diagonal ? 1 : 0) {
                case 0: occlusion[corner] = 1.0
                case 1: occlusion[corner] = 0.85
                default: occlusion[corner] = 0.70
                }
            }
        }

        // The atlas variant is still chosen from the average, which is what
        // keeps a mesh drawn with `UnlitMaterial` identical to the one this
        // mesher produced before it had a colour channel.
        let average = (occlusion.x + occlusion.y + occlusion.z + occlusion.w) * 0.25
        let shadeIndex = TextureAtlas.shadeIndex(for: face.tint * average)
        let uv = TextureAtlas.uvRect(for: tile, shadeIndex: shadeIndex)
        let cornerUVs = [
            SIMD2(uv.u0, uv.v1), SIMD2(uv.u1, uv.v1), SIMD2(uv.u1, uv.v0), SIMD2(uv.u0, uv.v0),
        ]

        let base = UInt32(buffer.vertices.count)
        let position = SIMD3<Float>(Float(local.x), Float(local.y), Float(local.z))
        let inverseAverage = 1 / average
        for corner in 0..<4 {
            let point = position + face.corners[corner]
            let shade = smoothShading
                ? encodeShade(occlusion[corner] * inverseAverage,
                              sky: exposure[corner],
                              water: isWater,
                              torch: torch[corner])
                : neutralShade
            buffer.vertices.append(Vertex(
                px: point.x, py: point.y, pz: point.z,
                nx: face.normal.x, ny: face.normal.y, nz: face.normal.z,
                u: cornerUVs[corner].x, v: cornerUVs[corner].y,
                shade: shade
            ))
        }
        buffer.minimum = pointwiseMin(buffer.minimum, position)
        buffer.maximum = pointwiseMax(buffer.maximum, position + SIMD3<Float>(1, 1, 1))

        // Which way the quad is split matters once the corners no longer
        // share a shade: the diagonal has to run through the *darker* pair,
        // so both triangles interpolate toward it and the occlusion reads
        // as a gradient rather than a crease down one triangle. This is the
        // standard voxel-AO flip; without it a corner shows a hard seam.
        if occlusion.x + occlusion.z > occlusion.y + occlusion.w {
            buffer.indices.append(contentsOf: [
                base + 1, base + 2, base + 3,
                base + 1, base + 3, base,
            ])
        } else {
            buffer.indices.append(contentsOf: [
                base, base + 1, base + 2,
                base, base + 2, base + 3,
            ])
        }
    }

    // MARK: - Shaped blocks

    /// One face of a box, in the numbering `ShapedFace` publishes: up,
    /// down, +Z, -Z, +X, -X. The corner order and the per-direction tint
    /// are lifted straight from the cube table above, so a stair tread
    /// lights like the block beside it rather than like its own thing.
    private struct ShapedFaceInfo {
        let normal: SIMD3<Float>
        /// Which axis the face is perpendicular to, and which end of it.
        let axis: Int
        let positive: Bool
        /// Padded index delta to the cell this face opens onto.
        let step: Int
        /// Per corner, which end of the box to take on each axis:
        /// 1 for the box maximum, 0 for the minimum.
        let picks: [SIMD3<Int32>]
        /// How a corner's local position maps onto the tile. `flip` runs
        /// the axis backwards, which is what keeps a texture the right way
        /// up on the faces whose winding runs the other way.
        let uAxis: Int, uFlip: Bool
        let vAxis: Int, vFlip: Bool
        let tint: Float
        let kind: FaceKind
    }

    private static let shapedFaces: [ShapedFaceInfo] = {
        func picks(_ values: [(Int32, Int32, Int32)]) -> [SIMD3<Int32>] {
            values.map { SIMD3<Int32>($0.0, $0.1, $0.2) }
        }
        return [
            // up
            ShapedFaceInfo(
                normal: SIMD3<Float>(0, 1, 0), axis: 1, positive: true, step: padSlice,
                picks: picks([(0, 1, 1), (1, 1, 1), (1, 1, 0), (0, 1, 0)]),
                uAxis: 0, uFlip: false, vAxis: 2, vFlip: false, tint: 1.0, kind: .top),
            // down
            ShapedFaceInfo(
                normal: SIMD3<Float>(0, -1, 0), axis: 1, positive: false, step: -padSlice,
                picks: picks([(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)]),
                uAxis: 0, uFlip: false, vAxis: 2, vFlip: true, tint: 0.60, kind: .bottom),
            // +Z
            ShapedFaceInfo(
                normal: SIMD3<Float>(0, 0, 1), axis: 2, positive: true, step: padRow,
                picks: picks([(0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]),
                uAxis: 0, uFlip: false, vAxis: 1, vFlip: true, tint: 0.88, kind: .side),
            // -Z
            ShapedFaceInfo(
                normal: SIMD3<Float>(0, 0, -1), axis: 2, positive: false, step: -padRow,
                picks: picks([(1, 0, 0), (0, 0, 0), (0, 1, 0), (1, 1, 0)]),
                uAxis: 0, uFlip: true, vAxis: 1, vFlip: true, tint: 0.88, kind: .side),
            // +X
            ShapedFaceInfo(
                normal: SIMD3<Float>(1, 0, 0), axis: 0, positive: true, step: 1,
                picks: picks([(1, 0, 1), (1, 0, 0), (1, 1, 0), (1, 1, 1)]),
                uAxis: 2, uFlip: true, vAxis: 1, vFlip: true, tint: 0.76, kind: .side),
            // -X
            ShapedFaceInfo(
                normal: SIMD3<Float>(-1, 0, 0), axis: 0, positive: false, step: -1,
                picks: picks([(0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0)]),
                uAxis: 2, uFlip: false, vAxis: 1, vFlip: true, tint: 0.76, kind: .side),
        ]
    }()

    /// Appends every quad of one shaped cell.
    ///
    /// Lighting is deliberately flatter than a cube's. A cube samples its
    /// ambient occlusion from the three cells around each corner, which is
    /// a question about a corner that sits *on* the lattice; a stair tread
    /// half a block in has no such corner, and sampling the lattice anyway
    /// darkens one end of it for no reason the eye can find. So every
    /// corner takes the neutral ratio — the value an evenly lit cube face
    /// carries — and the per-direction tint the cube table already applies
    /// does the rest. Sky exposure *is* sampled, once for the whole cell,
    /// so a staircase under a roof drops into shade with the floor it
    /// stands on.
    @inline(__always)
    private static func emitShaped(
        type: BlockType,
        at local: (x: Int, y: Int, z: Int),
        cellIndex: Int,
        coverCell: Int,
        volume: UnsafeBufferPointer<UInt8>,
        occluders: UnsafeBufferPointer<Bool>,
        sky: UnsafeBufferPointer<UInt8>,
        lamps: UnsafeBufferPointer<UInt8>,
        smoothShading: Bool,
        into buffer: inout Buffer
    ) {
        // A pane's arms are decided here rather than stored in the cell:
        // it grows one toward every neighbour that is another pane or a
        // solid wall, which is what makes a row of them one sheet of glass.
        var connections: PaneConnections = []
        if type.isPane {
            for facing in BlockFacing.allCases {
                let neighbour = volume[cellIndex + facing.dx + facing.dz * padRow]
                guard let kind = BlockType(rawValue: neighbour) else { continue }
                if PaneConnections.connects(to: kind) { connections.insert(.of(facing)) }
            }
        }

        let parts = ShapedBlocks.parts(for: type, connections: connections)
        guard !parts.isEmpty else { return }

        let exposure: Float = smoothShading
            ? max(0, 1 - Float(sky[coverCell]) / skyFullCover)
            : 1
        // Sampled in the cell the shaped block stands in, not outside a
        // face: a stair or a pane occupies part of its cell and the light
        // in the rest of it is the light on the block. One tap rather than
        // the cube path's four, for the same reason the exposure above is
        // one tap — these faces carry no per-corner term at all.
        let torch: Float = smoothShading
            ? Float(lamps[coverCell]) / Float(BlockLight.maximum)
            : 0
        let origin = SIMD3<Float>(Float(local.x), Float(local.y), Float(local.z))
        buffer.minimum = pointwiseMin(buffer.minimum, origin)
        buffer.maximum = pointwiseMax(buffer.maximum, origin + SIMD3<Float>(1, 1, 1))

        for part in parts {
            let low = SIMD3<Float>(Float(part.box.minX), Float(part.box.minY), Float(part.box.minZ))
            let high = SIMD3<Float>(Float(part.box.maxX), Float(part.box.maxY), Float(part.box.maxZ))
            for index in 0..<shapedFaces.count {
                guard part.hidden & UInt8(1 << index) == 0 else { continue }
                let face = shapedFaces[index]
                // A face lying exactly on the cell wall is culled by an
                // opaque neighbour exactly as a cube's would be — a door
                // set into a wall must not draw its back.
                let onCellWall = face.positive ? high[face.axis] >= 1 : low[face.axis] <= 0
                if onCellWall, occluders[Int(volume[cellIndex + face.step])] { continue }

                // Always the full-brightness variant, and the whole shade in
                // the vertex colour instead. A cube picks a pre-darkened
                // atlas variant because its shade is a per-face average it
                // cannot know until it has looked at twelve neighbours; a
                // shaped face's shade is just the direction it points, so
                // it can go in the vertices — and the tiles only shaped
                // blocks use then need one copy in the sheet rather than
                // eight. See `AtlasTile.isShaded` for why that matters.
                let uv = TextureAtlas.uvRect(
                    for: part.tile(for: face.kind),
                    shadeIndex: TextureAtlas.shadeLevels - 1
                )
                // Through the atlas's eight steps, even though this face is
                // not fetching a darkened variant. The cube beside it gets
                // its tint quantised on the way into the sheet and nothing
                // downstream corrects for that, so a shaped face carrying
                // the exact tint lands somewhere the cube cannot — up to
                // 4.8% apart, an outline round the staircase. See
                // `TextureAtlas.quantizedShade`.
                let tint = TextureAtlas.quantizedShade(face.tint)
                let shade = smoothShading
                    ? encodeShade(tint, sky: exposure, water: false, torch: torch)
                    : flatShade(tint)
                let base = UInt32(buffer.vertices.count)
                for corner in 0..<4 {
                    let pick = face.picks[corner]
                    let point = SIMD3<Float>(
                        pick.x == 1 ? high.x : low.x,
                        pick.y == 1 ? high.y : low.y,
                        pick.z == 1 ? high.z : low.z
                    )
                    var u = point[face.uAxis], v = point[face.vAxis]
                    if face.uFlip { u = 1 - u }
                    if face.vFlip { v = 1 - v }
                    let world = origin + point
                    buffer.vertices.append(Vertex(
                        px: world.x, py: world.y, pz: world.z,
                        nx: face.normal.x, ny: face.normal.y, nz: face.normal.z,
                        u: uv.u0 + (uv.u1 - uv.u0) * u,
                        v: uv.v0 + (uv.v1 - uv.v0) * v,
                        shade: shade
                    ))
                }
                buffer.indices.append(contentsOf: [
                    base, base + 1, base + 2,
                    base, base + 2, base + 3,
                ])
            }
        }
    }
}

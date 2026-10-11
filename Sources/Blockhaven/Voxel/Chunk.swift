import Foundation
#if canImport(RealityKit)
import RealityKit
#endif

struct ChunkCoord: Hashable {
    let x: Int
    let z: Int

    /// Squared horizontal distance in chunks — cheap ordering for the
    /// "load nearest first" queue, no square root needed.
    func distanceSquared(to other: ChunkCoord) -> Int {
        let dx = x - other.x, dz = z - other.z
        return dx * dx + dz * dz
    }
}

/// One vertical column of the world: `width` × `depth` horizontally,
/// `height` tall, stored as a flat `[UInt8]` indexed
/// `x + z*width + y*width*depth`. Y-major ordering means a whole
/// horizontal slice is contiguous, which is the access pattern the
/// mesher uses.
final class Chunk {
    static let width = 16
    static let depth = 16
    /// How tall the world is.
    ///
    /// Raised from 128 to make room for a landmark that is 120 blocks tall
    /// standing on ground near sea level, which 128 could not hold at any
    /// deck height worth building on.
    ///
    /// Two things make this affordable. `index` below is
    /// `x + z*width + y*width*depth` and does not mention height at all, so
    /// every edit-journal key in every existing save still names the same
    /// cell — raising this does not invalidate a single saved world. And
    /// terrain generation loops to the *surface* height rather than to this
    /// one, so the extra 64 courses are free at generation time. Light
    /// seeding stops at `ceiling` and pays for them only where something is
    /// actually built that high. Meshing is the one pass that still sweeps
    /// the full column.
    ///
    /// What it is *not* safe to do is let this number reach the terrain
    /// generator. See `WorldGenerator.highestSurface`.
    static let height = 192

    static let blockCount = width * depth * height

    let coord: ChunkCoord
    let originX: Int
    let originZ: Int
    private(set) var blocks: [UInt8]

    /// Block light, 0…15, one byte a cell. Not sky light: the sky's
    /// contribution is the skyline-and-cover term the mesher already bakes,
    /// and this is only what lamps put out.
    ///
    /// A byte rather than the packed nibble the original uses. The nibble
    /// halves 32 KB a chunk to 16 KB, and costs a shift and a mask on every
    /// one of the several million reads a propagation sweep makes — a poor
    /// trade at this render distance, where the whole light volume across
    /// every loaded chunk is about 14 MB.
    private(set) var light: [UInt8]

    /// Set once light has been seeded for this chunk. Until then its
    /// `light` is all zeroes and meshing it would bake a black chunk, so
    /// `World` seeds before the first mesh.
    var isLit = false

    #if canImport(RealityKit)
    /// The entities currently displaying this chunk (opaque + translucent
    /// passes). Replaced wholesale whenever the chunk is remeshed.
    var opaqueEntity: Entity?
    var translucentEntity: Entity?
    /// The chunk's hidden half — cave walls and ore faces that nothing
    /// standing outside the ground can see. Nil until something reveals
    /// the chunk, which is the point: for most of the world this geometry
    /// is never built, never uploaded and never drawn.
    var buriedEntity: Entity? {
        didSet { showsBuriedHalf = buriedEntity != nil }
    }
    #endif

    /// Whatever else is drawing this chunk — the SDL front end's GPU
    /// buffers, which free themselves when the handle is let go.
    var renderHandle: AnyObject?

    /// True once that hidden half is built and on screen, so the chunk is
    /// drawing every face it has and which half the classifier would sort a
    /// face into no longer changes the picture. See
    /// `World.markClassificationDirty`. Kept by whichever front end is
    /// drawing the chunk.
    var showsBuriedHalf = false

    /// True once something has asked to see inside this chunk — an edit,
    /// the player's eye dropping under real terrain nearby, or the player
    /// holding the attack button on one of its blocks. Each of those three
    /// is a statement of intent, deliberately: this flag is sticky, so a
    /// trigger that fires for merely walking about gives the culling back a
    /// chunk at a time. Sticky, because a revealed chunk stays
    /// revealed until it unloads, because a player who has been inside a
    /// hill once is likely to be again, and re-hiding geometry behind them
    /// would be a flicker for a saving nobody would notice.
    var isRevealed = false

    /// Set once terrain generation has run. Meshing waits for a chunk and
    /// all four of its neighbours to be populated, so faces at the seams
    /// cull against real data instead of assumed air.
    var isPopulated = false
    /// Set once decorations that can spill across chunk borders (trees)
    /// have been applied.
    var isDecorated = false
    /// Marks the mesh as out of date.
    var needsRemesh = true

    /// Bumped every time the blocks change in a way that invalidates the
    /// mesh. Chunk geometry is built on a background queue, so a build that
    /// was already running when the player broke a block would otherwise
    /// land *after* the fresh mesh and put the block back. The builder
    /// records this number when it starts and the result is thrown away if
    /// it no longer matches.
    private(set) var revision = 0

    /// A number no other chunk object in this run of the game carries,
    /// handed out by `World` as the chunk is installed. `revision` alone
    /// cannot tell a stale mesh from a fresh one across an unload: a
    /// regenerated chunk at the same coordinate is a *different* object
    /// whose revision starts again at 0. See `World.nextChunkSerial`.
    private(set) var serial: UInt64 = 0

    /// Called by `World`, once, as the chunk is installed.
    func adopt(serial: UInt64) {
        self.serial = serial
    }

    func invalidateMesh() {
        needsRemesh = true
        revision &+= 1
    }

    init(coord: ChunkCoord) {
        self.coord = coord
        self.originX = coord.x * Chunk.width
        self.originZ = coord.z * Chunk.depth
        self.blocks = [UInt8](repeating: 0, count: Chunk.blockCount)
        self.light = [UInt8](repeating: 0, count: Chunk.blockCount)
    }

    @inline(__always)
    func lightLevel(localX x: Int, y: Int, localZ z: Int) -> UInt8 {
        guard x >= 0, x < Chunk.width, y >= 0, y < Chunk.height, z >= 0, z < Chunk.depth else { return 0 }
        return light[Chunk.index(x, y, z)]
    }

    /// Writes one cell's light. Returns false when the value was already
    /// there, which is what lets the propagation sweep stop early rather
    /// than re-walking a region that did not change.
    @discardableResult
    @inline(__always)
    func setLight(localX x: Int, y: Int, localZ z: Int, to level: UInt8) -> Bool {
        guard x >= 0, x < Chunk.width, y >= 0, y < Chunk.height, z >= 0, z < Chunk.depth else { return false }
        let index = Chunk.index(x, y, z)
        guard light[index] != level else { return false }
        light[index] = level
        return true
    }

    @inline(__always)
    static func index(_ x: Int, _ y: Int, _ z: Int) -> Int {
        x + z * Chunk.width + y * (Chunk.width * Chunk.depth)
    }

    @inline(__always)
    func block(localX x: Int, y: Int, localZ z: Int) -> BlockType {
        guard x >= 0, x < Chunk.width, y >= 0, y < Chunk.height, z >= 0, z < Chunk.depth else { return .air }
        return BlockType(rawValue: blocks[Chunk.index(x, y, z)]) ?? .air
    }

    @inline(__always)
    func setBlock(localX x: Int, y: Int, localZ z: Int, to type: BlockType) {
        guard x >= 0, x < Chunk.width, y >= 0, y < Chunk.height, z >= 0, z < Chunk.depth else { return }
        blocks[Chunk.index(x, y, z)] = type.rawValue
        cachedSkyline = nil
        cachedCeiling = nil
    }

    /// The highest y in each of the 256 columns holding a block that
    /// occludes, or -1 for a column with none. Everything strictly above it
    /// has open sky over it.
    ///
    /// Cached here rather than recomputed by whoever wants it, because two
    /// things want it and both are hot. `ChunkMesher`'s buried-face
    /// classifier needs the skyline of a whole 3×3 neighbourhood on every
    /// build — and a chunk is built several times over its life while its
    /// blocks change only when the player touches them — and the game loop
    /// asks every frame whether the player's eye is underground.
    ///
    /// Dropped on any write, rebuilt on the next read, which folds the
    /// hundreds of writes a tree or a crater makes into one recompute.
    var skyline: [Int16] {
        if let cachedSkyline { return cachedSkyline }
        var line = [Int16](repeating: -1, count: Chunk.width * Chunk.depth)
        let columns = Chunk.width * Chunk.depth
        blocks.withUnsafeBufferPointer { volume in
            BlockType.opaqueByRawValue.withUnsafeBufferPointer { occluders in
                guard let volume = volume.baseAddress,
                      let occluders = occluders.baseAddress else { return }
                line.withUnsafeMutableBufferPointer { line in
                    guard let line = line.baseAddress else { return }
                    // Top down, abandoned as soon as every column has an
                    // answer: on this terrain that is somewhere around
                    // y = 40, not y = 0.
                    var unresolved = columns
                    var y = Chunk.height - 1
                    while y >= 0, unresolved > 0 {
                        let slice = volume + y * columns
                        for column in 0..<columns where line[column] < 0 {
                            guard occluders[Int(slice[column])] else { continue }
                            line[column] = Int16(y)
                            unresolved -= 1
                        }
                        y -= 1
                    }
                }
            }
        }
        cachedSkyline = line
        return line
    }

    private var cachedSkyline: [Int16]?

    /// The highest y in this chunk holding anything at all, or -1 for a
    /// chunk of nothing but air.
    ///
    /// The skyline above cannot answer this. It records the highest
    /// *occluding* block in each column, and a torch occludes nothing — a
    /// torch on the face of a tower sits above its own column's skyline
    /// with no occluder under it anywhere. This counts every block, so
    /// nothing in the chunk is above it, whatever kind of block it is.
    ///
    /// Cached and dropped on the same writes as the skyline, because
    /// seeding one chunk's light reads five of these — its own and each of
    /// its four neighbours' — and an uncached scan made the sweep it was
    /// meant to shorten cost more than sweeping the whole column had.
    ///
    /// Y-major storage means every slice above the answer is one contiguous
    /// run, so this is a single backwards walk to the last non-air byte
    /// rather than a loop per course.
    var ceiling: Int {
        if let cachedCeiling { return cachedCeiling }
        let columns = Chunk.width * Chunk.depth
        var top = -1
        blocks.withUnsafeBufferPointer { volume in
            guard let volume = volume.baseAddress else { return }
            var index = Chunk.blockCount - 1
            while index >= 0 {
                if volume[index] != BlockType.air.rawValue {
                    top = index / columns
                    return
                }
                index -= 1
            }
        }
        cachedCeiling = top
        return top
    }

    private var cachedCeiling: Int?

    /// True where nothing occludes between this cell and the sky.
    func isSkyOpen(localX x: Int, y: Int, localZ z: Int) -> Bool {
        guard x >= 0, x < Chunk.width, z >= 0, z < Chunk.depth else { return true }
        return Int(skyline[x + z * Chunk.width]) < y
    }

    /// True where something that is *not foliage* stands between this cell
    /// and the sky: the difference between being under the ground and
    /// standing on grass under a tree.
    ///
    /// `isSkyOpen` cannot tell those apart, because leaves occlude on
    /// purpose — a canopy of see-through leaves would generate an internal
    /// face per leaf — so a tenth of the walkable ground on this seed is not
    /// sky-open at eye height. That is the right answer for classifying
    /// faces and the wrong one for asking whether the player is underground,
    /// which is the only question this exists for. The mesher's occluder
    /// table is untouched; only this walks past leaves.
    ///
    /// The walk goes up from the cell above, bounded by the skyline, so
    /// underground it stops on the first step and under a canopy it takes a
    /// dozen array reads before answering no.
    func hasTerrainOverhead(localX x: Int, y: Int, localZ z: Int) -> Bool {
        guard x >= 0, x < Chunk.width, z >= 0, z < Chunk.depth else { return false }
        let top = Int(skyline[x + z * Chunk.width])
        guard top > y else { return false }
        var cursor = max(y + 1, 0)
        while cursor <= top {
            let above = block(localX: x, y: cursor, localZ: z)
            if above.isOpaque && above != .leaves { return true }
            cursor += 1
        }
        return false
    }

    /// Drops whatever any front end hung on this chunk.
    func releaseRendering() {
        #if canImport(RealityKit)
        MainActor.assumeIsolated { removeEntities() }
        #endif
        renderHandle = nil
        showsBuriedHalf = false
    }

    #if canImport(RealityKit)
    @MainActor
    func removeEntities() {
        removeSurfaceEntities()
        removeBuriedEntity()
    }

    @MainActor
    func removeSurfaceEntities() {
        opaqueEntity?.removeFromParent()
        translucentEntity?.removeFromParent()
        opaqueEntity = nil
        translucentEntity = nil
    }

    @MainActor
    func removeBuriedEntity() {
        buriedEntity?.removeFromParent()
        buriedEntity = nil
    }
    #endif
}

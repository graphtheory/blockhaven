import Foundation

/// The block volume: a sparse map of chunks that streams in around the
/// player. Chunk *data* and its tree placement are generated on a
/// background queue (both are pure functions of coordinate and seed) and
/// handed back through an inbox the game loop drains once a frame, so the
/// chunk map is only ever mutated from that one thread. Meshing is
/// budgeted per frame and the geometry itself is built off-thread too —
/// see `GameViewController.dispatchMeshWork`.
final class World {
    let seed: UInt64
    let generator: WorldGenerator

    /// How far out chunks are meshed and drawn, in chunks.
    var renderDistance: Int = World.configuredRenderDistance
    /// Data is generated one ring further than it's drawn so edge chunks
    /// have real neighbours to cull their faces against.
    private var dataDistance: Int { renderDistance + 1 }

    /// The distance the game ships at, in chunks.
    ///
    /// This is the one number that decides how far you can see, and
    /// everything that dresses the horizon is sized around it: the fog ends
    /// exactly here (`MaterialLibrary.setRenderDistance`), and the fog has
    /// to finish well inside the cloud deck's fade (330 blocks) and the sky
    /// dome (340) or the haze would still be clearing when the sky shell
    /// arrives. The camera's far plane (400) is the tighter of the two
    /// limits, because the *corner* of the render square is √2 further out
    /// than this radius: at 10 chunks that corner is 226 blocks away
    /// against a 400-block plane.
    static let defaultRenderDistance = 10

    /// `BLOCKHAVEN_RENDER_DISTANCE=<chunks>` overrides it, clamped to a range
    /// the rest of the renderer can actually dress.
    ///
    /// The ceiling is not arbitrary. At 14 chunks the far corner of the
    /// render square sits at 317 blocks and the fog ends at 224 — still
    /// inside the 400-block far plane and finished long before the cloud
    /// fade — while 20 chunks would put the fog end at 320, on top of the
    /// clouds' own fade, and the corner past the far plane where chunks
    /// would be sliced off mid-air. Anything past 14 needs those shells
    /// resized too, so it is refused rather than silently broken.
    static let renderDistanceLimits = 2...14

    private static let configuredRenderDistance: Int = {
        guard let raw = ProcessInfo.processInfo.environment["BLOCKHAVEN_RENDER_DISTANCE"],
              let value = Int(raw) else { return defaultRenderDistance }
        return min(max(value, renderDistanceLimits.lowerBound), renderDistanceLimits.upperBound)
    }()

    private(set) var chunks: [ChunkCoord: Chunk] = [:]

    /// Coordinates whose data generation is in flight, so the scheduler
    /// doesn't enqueue the same chunk twice. Only ever touched from the
    /// game loop's thread.
    private var pendingGeneration: Set<ChunkCoord> = []

    /// Handed out one at a time, from `receiveGenerated` — the single place
    /// a chunk enters `chunks`, and one that only ever runs on the game
    /// loop's thread, so the increment needs no lock.
    ///
    /// This exists because `ObjectIdentifier` cannot do the job it was
    /// being used for. Geometry is built on a background queue holding no
    /// reference to the chunk, so a chunk unloaded mid-build is deallocated
    /// immediately; the next `Chunk` allocated is exactly the same size,
    /// and an allocator is entitled to hand back the block it just freed.
    /// A chunk regenerated at that coordinate could then carry the *same*
    /// `ObjectIdentifier` as the one the in-flight mesh was built for — and
    /// a fresh chunk's `revision` restarts at 0, so both guards pass and
    /// the stale mesh installs. That is precisely the race the check exists
    /// to stop. A counter cannot alias: at a chunk a microsecond it would
    /// take six hundred thousand years to wrap.
    private var nextChunkSerial: UInt64 = 1

    /// `.utility`, not `.userInitiated`.
    ///
    /// This queue is concurrent and runs up to `maxInFlight` chunks at
    /// once, so at `.userInitiated` it put eight high-priority threads up
    /// against the one thread that has a 10 ms deadline — and won often
    /// enough to matter. Measured over 900 frames of flying: the worst
    /// frame the streaming loop saw fell from 3.3–8.4 ms to 0.25–1.0 ms
    /// purely from this line, with the spikes landing in phases that do
    /// almost no work (a set iteration, a 42 KB copy), which is what being
    /// descheduled looks like rather than being slow.
    ///
    /// Nothing was given up for it. Generation is not latency-critical —
    /// it only has to keep ahead of walking speed — and it in fact got
    /// *further* ahead: 231 chunks meshed over those frames against 226,
    /// because the threads stopped fighting.
    private let generationQueue = DispatchQueue(
        label: "blockhaven.chunkgen", qos: .utility, attributes: .concurrent
    )

    /// Finished chunks waiting to be folded into `chunks`.
    ///
    /// Generation runs on a background queue but `chunks` is only ever
    /// mutated from the game loop, which drains this inbox once a frame.
    /// Handing chunks over through a lock — rather than hopping to the
    /// main queue — keeps that true no matter which thread the loop
    /// actually runs on.
    private let inboxLock = NSLock()
    private var generatedInbox: [GeneratedChunk] = []
    /// Trees whose canopy spilled into a chunk that had not been generated
    /// yet, held until it is.
    private var deferredBlocks: [ChunkCoord: [BlockPlacement]] = [:]

    /// A chunk off the generation queue, with its trees already worked out.
    ///
    /// Deciding *where* the trees go is the expensive half of decoration —
    /// a biome and a surface height for all 256 columns, then a 7×7
    /// local-maximum roll around every candidate — and it is a pure
    /// function of the seed, so it rides along on the background queue with
    /// terrain generation. Only the writing is left for the main thread,
    /// which has to do it there: a canopy can spill into a neighbouring
    /// chunk, and neighbours belong to the game loop.
    private struct GeneratedChunk {
        let chunk: Chunk
        let decoration: [BlockPlacement]
    }

    /// Chunks whose mesh is out of date and which are therefore candidates
    /// for `chunksReadyToMesh`.
    ///
    /// Kept rather than rediscovered. The scan this replaces walked all
    /// ~240 loaded chunks every single frame — allocating a four-element
    /// array per chunk to check its neighbours, then sorting the survivors
    /// — to answer a question whose answer is almost always "nothing".
    /// Every write of `Chunk.needsRemesh` goes through `markNeedsRemesh`,
    /// so this set and that flag cannot drift apart.
    private var dirtyChunks: Set<ChunkCoord> = []

    /// How far behind the mesh budget is running. Read by the streaming
    /// benchmark, which is the only thing that can watch this number move
    /// without a display attached.
    var dirtyChunkCount: Int { dirtyChunks.count }

    /// Chunks that have been revealed but whose buried half has not been
    /// built yet. Drained by the game loop, nearest first.
    ///
    /// Separate from `dirtyChunks` because the two halves are separate
    /// meshes: revealing a chunk must not re-upload the surface geometry
    /// already on screen, so it gets its own build rather than dirtying the
    /// whole chunk. A chunk that is dirty anyway skips this queue — its
    /// rebuild covers both halves.
    private var pendingBuried: Set<ChunkCoord> = []

    /// The subset of `dirtyChunks` that the player just changed, by
    /// breaking or placing a block or by standing too near a fizzler.
    ///
    /// These are pulled out because they are the one remesh the player is
    /// *watching*: a block has to vanish on the click, not two frames later
    /// when a background queue gets round to it. Streaming remeshes have no
    /// such deadline and are built off-thread.
    private var urgentChunks: Set<ChunkCoord> = []

    /// Every block written through `setBlock` — the player's edits and the
    /// craters fizzlers leave — keyed by chunk and then by `Chunk.index`
    /// packed local index. Terrain is a pure function of the seed, so this
    /// diff is the whole of what a chunk cannot regenerate for itself. It
    /// is never pruned by unloading: an edit outlives the chunk it was made
    /// in, which is what stops builds vanishing when you walk away.
    /// Generation must never write through `setBlock`, or it would land
    /// here and be replayed on top of itself forever.
    private(set) var editJournal: [ChunkCoord: [Int: BlockType]] = [:]

    /// Tracks industrial and excavation disturbance levels across chunks.
    let disturbance = DisturbanceTracker()

    init(seed: UInt64 = 20260823, edits: [ChunkCoord: [Int: BlockType]] = [:]) {
        self.seed = seed
        self.generator = WorldGenerator(seed: seed)
        self.editJournal = edits
    }

    // MARK: - Coordinates

    /// Integer floor division. Swift's `/` truncates toward zero, which
    /// puts world x = -1 in chunk 0 rather than chunk -1 and folds two
    /// columns of the world onto each other; going through `Double` and
    /// `floor` was the old fix, at the cost of a float round trip in a
    /// function the mesher, the raycaster and the physics all call in
    /// their inner loops.
    @inline(__always)
    private static func floorDivide(_ value: Int, by divisor: Int) -> Int {
        let quotient = value / divisor
        return value % divisor < 0 ? quotient - 1 : quotient
    }

    @inline(__always)
    static func chunkCoord(forWorldX x: Int, worldZ z: Int) -> ChunkCoord {
        ChunkCoord(
            x: floorDivide(x, by: Chunk.width),
            z: floorDivide(z, by: Chunk.depth)
        )
    }

    func chunk(at coord: ChunkCoord) -> Chunk? { chunks[coord] }

    // MARK: - Block access

    func block(worldX x: Int, y: Int, worldZ z: Int) -> BlockType {
        guard y >= 0, y < Chunk.height else { return .air }
        guard let chunk = chunks[World.chunkCoord(forWorldX: x, worldZ: z)] else { return .air }
        return chunk.block(localX: x - chunk.originX, y: y, localZ: z - chunk.originZ)
    }

    func isSolid(worldX x: Int, y: Int, worldZ z: Int) -> Bool {
        block(worldX: x, y: y, worldZ: z).isSolid
    }

    /// The question a mob's own coarse collision test should ask instead of
    /// `isSolid` — see `BlockType.obstructsMovement`.
    func obstructsMob(worldX x: Int, y: Int, worldZ z: Int) -> Bool {
        block(worldX: x, y: y, worldZ: z).obstructsMovement
    }

    /// True where the given cell holds water — used for swim physics.
    func isWater(worldX x: Int, y: Int, worldZ z: Int) -> Bool {
        block(worldX: x, y: y, worldZ: z) == .water
    }

    /// True where the given cell holds lava — used for burn damage, the
    /// same question `isWater` answers for swimming and drowning.
    func isLava(worldX x: Int, y: Int, worldZ z: Int) -> Bool {
        block(worldX: x, y: y, worldZ: z) == .lava
    }

    /// A booster the signal network is holding inert.
    ///
    /// Kept outside the block value on purpose, the same reasoning as a
    /// chest's contents: this is a fact about wiring, not about the rail,
    /// and a cell here still reads and drops as an ordinary powered rail —
    /// breaking a booster the network has switched off still hands back a
    /// powered rail, not a plain one. Only a booster a player has actually
    /// run wire up to is ever in this set; every booster nobody wired stays
    /// the always-on launcher it always was, which is what keeps a track
    /// built before wire existed pushing exactly as it did before.
    private struct BoosterKey: Hashable { var x: Int; var y: Int; var z: Int }
    private var suppressedBoosters: Set<BoosterKey> = []

    func setBoosterSuppressed(_ suppressed: Bool, worldX x: Int, y: Int, worldZ z: Int) {
        let key = BoosterKey(x: x, y: y, z: z)
        if suppressed { suppressedBoosters.insert(key) } else { suppressedBoosters.remove(key) }
    }

    /// Whether a cart crossing this booster gets pushed. True for every
    /// booster the signal network has never touched — see the note above.
    func boosterIsActive(worldX x: Int, y: Int, worldZ z: Int) -> Bool {
        !suppressedBoosters.contains(BoosterKey(x: x, y: y, z: z))
    }

    /// Writes a block and flags every mesh that has to be rebuilt: the
    /// owning chunk, plus any neighbour whose seam faces cull against this
    /// cell. Chunks that have not streamed in yet stash the write and
    /// apply it at generation time.
    ///
    /// Every write lands in `editJournal` first, whether or not the chunk
    /// is loaded — that record, not the chunk, is what survives unloading.
    /// This is the only entry point that journals, so terrain generation
    /// and tree decoration (which write to `Chunk` directly) stay out of it.
    @discardableResult
    func setBlock(worldX x: Int, y: Int, worldZ z: Int, to type: BlockType, remesh: Bool = true) -> Bool {
        guard y >= 0, y < Chunk.height else { return false }
        let coord = World.chunkCoord(forWorldX: x, worldZ: z)
        // Local coordinates come from the coordinate, not the chunk, so the
        // journal key is the same whether or not the chunk is loaded.
        let lx = x - coord.x * Chunk.width, lz = z - coord.z * Chunk.depth
        editJournal[coord, default: [:]][Chunk.index(lx, y, lz)] = type

        guard let chunk = chunks[coord] else {
            deferredBlocks[coord, default: []].append(BlockPlacement(x: x, y: y, z: z, block: type))
            return false
        }
        // Nothing here reads the chunk's skyline. It used to, to decide how
        // far the write reached, and that read cost a 256-column recompute
        // on *every* write — `Chunk` drops the cache on write and rebuilds
        // it on the next read, so a read wedged between two writes folds
        // nothing. A fizzler crater is a hundred-odd writes and was paying
        // for a hundred-odd rebuilds of the same array.
        let previous = chunk.block(localX: lx, y: y, localZ: lz)
        chunk.setBlock(localX: lx, y: y, localZ: lz, to: type)
        // Light before the early return: a torch placed with `remesh: false`
        // — which is how a structure builder places one — still has to light
        // the room, and the caller's own remesh sweep is what draws it.
        updateLight(atWorldX: x, y: y, worldZ: z, replacing: previous, with: type)
        guard remesh else { return true }

        // A plant standing on what was just taken away goes with it. One
        // cell up, and only when this write actually removed its footing,
        // so mining a whole hillside costs one extra block read per cell
        // and a stack of flowers cannot recurse — a plant is never valid
        // ground for another plant.
        if !BlockType.plantCanRootOn(type),
           y + 1 < Chunk.height,
           block(worldX: x, y: y + 1, worldZ: z).isPlant {
            setBlock(worldX: x, y: y + 1, worldZ: z, to: .air)
        }
        // Anyone editing a chunk is about to look inside it.
        reveal(coord)
        markNeedsRemesh(coord, urgent: true)

        // The seam, which has to be right on this frame: a face on the
        // chunk boundary culls against the cell across it, so an edit in an
        // outermost column changes what the neighbour draws *there*, now. A
        // block in a chunk *corner* is inside the diagonal neighbour's
        // volume too, and both the occlusion samples and the sky-exposure
        // march read it — missing that left one stale corner column per
        // edit at a chunk corner.
        let seamWest = lx == 0, seamEast = lx == Chunk.width - 1
        let seamSouth = lz == 0, seamNorth = lz == Chunk.depth - 1
        for dx in -1...1 where (dx == -1 && seamWest) || (dx == 0) || (dx == 1 && seamEast) {
            for dz in -1...1 where (dz == -1 && seamSouth) || (dz == 0) || (dz == 1 && seamNorth) {
                guard dx != 0 || dz != 0 else { continue }
                markNeedsRemesh(ChunkCoord(x: coord.x + dx, z: coord.z + dz), urgent: true)
            }
        }

        // The buried/surface classifier reaches very much further than the
        // seam does. `gatherNeighbourhood` copies `ChunkMesher.pad` cells of
        // each neighbour into one box and floods the whole thing, so a
        // neighbour's split can depend on any cell within `pad` of the
        // shared edge. That was one cell when the rule above was written; it
        // is twelve now, which against a 16-wide chunk means *every* column
        // of a chunk sits inside some neighbour's volume — three of them at
        // a chunk corner, five along an edge, all eight over the middle
        // 8×8. Skipping them left the neighbour holding a split computed
        // against a world that no longer exists — and since the split is
        // only recomputed when the chunk is re-meshed for some other reason,
        // and reveal is sticky, that staleness lasts until the chunk
        // unloads.
        //
        // These go on the background queue, and there is no direction in
        // which that is *safe* — no version of "the mesh they are still
        // showing is the more inclusive of the two". Breaking a block is
        // obviously not: the column's skyline drops, the flood gains seeds,
        // faces move buried → surface, and a mesh missing them is a hole.
        // Placing one is not either, though it looks like it should be.
        // `classifySurfaces` seeds the cells between a column's own top
        // occluder and the tallest of its four neighbours', so raising this
        // column's occluder *adds* seeds to the four columns beside it: the
        // flood reaches further there, and faces move buried → surface just
        // as they do for a break. Either way round, a neighbour still
        // showing the old split can be missing geometry.
        //
        // What makes the wait acceptable is that it is bounded by
        // construction, and only that. `chunksReadyToMesh` hands out the
        // *nearest* dirty chunks first and an edit is by definition within
        // arm's reach of the player, so these sit at the head of that queue
        // and clear at two a frame — four frames, inside the 0.05 s (five
        // frames at 100 Hz) creative mining floor before the next block
        // goes. The chunk being mined is urgent *and* revealed, so the only
        // hole this can leave is in a neighbour, seen across a chunk seam
        // through the opening just made. Making them all urgent instead
        // would put up to eight main-thread rebuilds — about 0.83 ms each —
        // on the frame of every break, which is the stall the urgent budget
        // exists to prevent.
        //
        // Measured rather than assumed, because held-button mining is the
        // case that could swamp this. `BLOCKHAVEN_BENCH_MINE=5` flies at
        // 11 blocks/s while breaking a block every five frames — 20 a
        // second, creative mode's floor, and faster than anyone can mine
        // *while moving*. 1500 frames at render distance 10, three runs
        // agreeing to the third digit, machine at load 65 of 12 cores:
        //
        //                   off the loop   urgent   ON-LOOP   dirty queue
        //   button up        0.59/frame     0       0.11 ms   mean 49, worst 88
        //   held, 20/s       1.45/frame     0.28    0.65 ms   mean 62, worst 155
        //
        // 1.73 rebuilds a frame against `meshBudgetPerFrame` 2, and nothing
        // starves: both runs finish with the same 433 chunks loaded, and the
        // dirty queue does not grow with the length of the walk — it is
        // bounded by how fast generation populates neighbours, not by the
        // mesh budget. Three hundred breaks cost 5.7 rebuilds each rather
        // than the nine chunks they mark, because `dirtyChunks` is a set: a
        // mark on a chunk already dirty is a bool, an increment and a set
        // insert, and a player mining forward keeps hitting the same
        // neighbours. Coalescing repeat marks per frame would buy nothing
        // that the set is not already buying across all of them.
        let reach = ChunkMesher.pad
        let west = lx < reach, east = lx >= Chunk.width - reach
        let south = lz < reach, north = lz >= Chunk.depth - reach
        for dx in -1...1 where (dx == -1 && west) || (dx == 0) || (dx == 1 && east) {
            for dz in -1...1 where (dz == -1 && south) || (dz == 0) || (dz == 1 && north) {
                guard dx != 0 || dz != 0 else { continue }
                markClassificationDirty(ChunkCoord(x: coord.x + dx, z: coord.z + dz))
            }
        }
        return true
    }

    // MARK: - Revealing what is buried

    /// Asks for a chunk's hidden half. Cheap and idempotent — the build is
    /// the expensive part and the game loop does it, `chunksNeedingBuried`
    /// at a time.
    @discardableResult
    func reveal(_ coord: ChunkCoord) -> Bool {
        guard let chunk = chunks[coord], !chunk.isRevealed else { return false }
        chunk.isRevealed = true
        pendingBuried.insert(coord)
        return true
    }

    /// Reveals a square of chunks. Used when the player's eye drops below
    /// ground: they are about to be able to see in every direction at once,
    /// so there is no point waiting to be asked one chunk at a time.
    func reveal(around center: ChunkCoord, radius: Int) {
        for dz in -radius...radius {
            for dx in -radius...radius {
                reveal(ChunkCoord(x: center.x + dx, z: center.z + dz))
            }
        }
    }

    /// Revealed chunks still waiting for their buried geometry, nearest
    /// first, at most `limit` of them.
    ///
    /// A chunk that is dirty is skipped rather than returned: its ordinary
    /// rebuild is already going to carry both halves, and building the
    /// buried one twice would be pure waste.
    func chunksNeedingBuried(around center: ChunkCoord, limit: Int) -> [Chunk] {
        guard !pendingBuried.isEmpty, limit > 0 else { return [] }
        var best: [(chunk: Chunk, distance: Int)] = []
        var gone: [ChunkCoord] = []
        for coord in pendingBuried {
            guard let chunk = chunks[coord], chunk.isDecorated else {
                if chunks[coord] == nil { gone.append(coord) }
                continue
            }
            guard !chunk.needsRemesh, neighboursPopulated(coord) else { continue }
            let distance = coord.distanceSquared(to: center)
            if best.count == limit, distance >= best[best.count - 1].distance { continue }
            let slot = best.firstIndex { distance < $0.distance } ?? best.count
            best.insert((chunk, distance), at: slot)
            if best.count > limit { best.removeLast() }
        }
        for coord in gone { pendingBuried.remove(coord) }
        return best.map(\.chunk)
    }

    /// Called once a build that covers the buried half has been handed to
    /// the mesh queue, so it isn't queued again behind itself.
    func markBuriedBuilding(_ coord: ChunkCoord) {
        pendingBuried.remove(coord)
    }

    /// How many loaded chunks are showing their buried half. Debug overlay
    /// only — it is the one number that says whether the culling is doing
    /// anything.
    var revealedChunkCount: Int {
        chunks.values.reduce(0) { $0 + ($1.isRevealed ? 1 : 0) }
    }

    /// True where nothing occludes between this cell and the sky. An
    /// unloaded column reads as open, which is the answer that reveals
    /// nothing.
    func isSkyOpen(worldX x: Int, y: Int, worldZ z: Int) -> Bool {
        guard let chunk = chunks[World.chunkCoord(forWorldX: x, worldZ: z)] else { return true }
        return chunk.isSkyOpen(localX: x - chunk.originX, y: y, localZ: z - chunk.originZ)
    }

    /// True where real terrain — anything opaque that is not a leaf — stands
    /// between this cell and the sky. See `Chunk.hasTerrainOverhead`: this
    /// is the "is the player underground" question, which a canopy must not
    /// answer yes to. An unloaded column reads as clear, which is the answer
    /// that reveals nothing.
    func hasTerrainOverhead(worldX x: Int, y: Int, worldZ z: Int) -> Bool {
        guard let chunk = chunks[World.chunkCoord(forWorldX: x, worldZ: z)] else { return false }
        return chunk.hasTerrainOverhead(localX: x - chunk.originX, y: y, localZ: z - chunk.originZ)
    }

    // MARK: - The remesh queue

    /// Flags a chunk's mesh as out of date and files it as a candidate.
    /// The single place `Chunk.needsRemesh` is ever set true, so the flag
    /// and `dirtyChunks` are one fact rather than two that can disagree.
    /// Not private only because the light sweeps live in `BlockLight.swift`
    /// and a pool of light that changes shape has to redraw the chunks it
    /// changed in. Still nobody else's to call.
    func markNeedsRemesh(_ coord: ChunkCoord, urgent: Bool) {
        guard let chunk = chunks[coord] else { return }
        chunk.invalidateMesh()
        dirtyChunks.insert(coord)
        if urgent { urgentChunks.insert(coord) }
    }

    /// Flags a chunk whose *classification* an edit nearby may have moved —
    /// which half of the split a face belongs in, rather than whether the
    /// face exists at all.
    ///
    /// Skipped for a chunk that is already showing its buried half, because
    /// then the split decides which of two meshes on screen a face lands in,
    /// and both are drawn. That is not the same test as `isRevealed`: a
    /// chunk revealed a moment ago is still waiting for its buried mesh, and
    /// its two halves would be classified at different instants — a face
    /// that moved between them in between would be in neither.
    private func markClassificationDirty(_ coord: ChunkCoord) {
        guard let chunk = chunks[coord], !chunk.showsBuriedHalf else { return }
        markNeedsRemesh(coord, urgent: false)
    }

    /// Called once a chunk's mesh has actually been built and hung in the
    /// scene, so it stops being a candidate.
    func markMeshed(_ chunk: Chunk) {
        chunk.needsRemesh = false
        dirtyChunks.remove(chunk.coord)
        urgentChunks.remove(chunk.coord)
    }

    /// True when this chunk has all four horizontal neighbours in memory,
    /// so its seam faces can be culled against real blocks instead of
    /// against assumed air.
    private func neighboursPopulated(_ coord: ChunkCoord) -> Bool {
        chunks[ChunkCoord(x: coord.x - 1, z: coord.z)]?.isPopulated == true
            && chunks[ChunkCoord(x: coord.x + 1, z: coord.z)]?.isPopulated == true
            && chunks[ChunkCoord(x: coord.x, z: coord.z - 1)]?.isPopulated == true
            && chunks[ChunkCoord(x: coord.x, z: coord.z + 1)]?.isPopulated == true
    }

    @inline(__always)
    private func isMeshable(_ chunk: Chunk, _ coord: ChunkCoord) -> Bool {
        chunk.needsRemesh && chunk.isDecorated && neighboursPopulated(coord)
    }

    /// The chunks the player's own edits just invalidated, ready to mesh
    /// on the spot rather than queued.
    ///
    /// Capped, because the set is not always small: breaking or placing a
    /// block touches one chunk and at most two more across a seam, but a
    /// fizzler's crater rewrites blocks across up to eight, and meshing all
    /// of those inside one frame would be exactly the stall this budget
    /// exists to prevent. Whatever is left over stays flagged and is picked
    /// up on the next frame — by this path or by the background one,
    /// whichever reaches it first.
    func urgentChunksToMesh(limit: Int) -> [Chunk] {
        guard !urgentChunks.isEmpty, limit > 0 else { return [] }
        var ready: [Chunk] = []
        var gone: [ChunkCoord] = []
        for coord in urgentChunks {
            guard let chunk = chunks[coord] else {
                gone.append(coord)
                continue
            }
            if isMeshable(chunk, coord) {
                ready.append(chunk)
                if ready.count == limit { break }
            }
        }
        for coord in gone { urgentChunks.remove(coord) }
        return ready
    }

    // MARK: - Streaming

    /// Chunks that have data and all four neighbours populated, so they can
    /// be meshed. Returned nearest-first relative to `center`, at most
    /// `limit` of them.
    ///
    /// Only `dirtyChunks` is considered, not the whole world, and only the
    /// `limit` nearest are kept — picked by a running insertion into a
    /// list that is never longer than the budget, so nothing is sorted and
    /// nothing outside the answer is ever allocated.
    func chunksReadyToMesh(around center: ChunkCoord, limit: Int = .max) -> [Chunk] {
        guard !dirtyChunks.isEmpty, limit > 0 else { return [] }
        let reach = renderDistance * renderDistance

        var best: [(chunk: Chunk, distance: Int)] = []
        var gone: [ChunkCoord] = []
        for coord in dirtyChunks {
            guard let chunk = chunks[coord] else {
                gone.append(coord)
                continue
            }
            let distance = coord.distanceSquared(to: center)
            // Out of range is not stale: the chunk keeps its place in the
            // queue and becomes meshable again if the player walks back.
            guard distance <= reach else { continue }
            // Cheapest rejections first — the flags are a pointer hop, the
            // neighbour check is four dictionary lookups.
            guard chunk.needsRemesh, chunk.isDecorated else { continue }
            if best.count == limit, distance >= best[best.count - 1].distance { continue }
            guard neighboursPopulated(coord) else { continue }

            let slot = best.firstIndex { distance < $0.distance } ?? best.count
            best.insert((chunk, distance), at: slot)
            if best.count > limit { best.removeLast() }
        }
        for coord in gone { dirtyChunks.remove(coord) }

        return best.map(\.chunk)
    }

    /// Kicks off generation for any chunk inside the data radius that
    /// doesn't have it yet, nearest-first, capped so a big teleport doesn't
    /// flood the queue.
    func scheduleGeneration(around center: ChunkCoord, maxInFlight: Int = 8) {
        guard pendingGeneration.count < maxInFlight else { return }

        var wanted: [ChunkCoord] = []
        for dz in -dataDistance...dataDistance {
            for dx in -dataDistance...dataDistance {
                let coord = ChunkCoord(x: center.x + dx, z: center.z + dz)
                guard coord.distanceSquared(to: center) <= dataDistance * dataDistance else { continue }
                guard chunks[coord] == nil, !pendingGeneration.contains(coord) else { continue }
                wanted.append(coord)
            }
        }
        wanted.sort { $0.distanceSquared(to: center) < $1.distanceSquared(to: center) }

        for coord in wanted.prefix(maxInFlight - pendingGeneration.count) {
            pendingGeneration.insert(coord)
            let generator = self.generator
            generationQueue.async { [weak self] in
                let chunk = Chunk(coord: coord)
                generator.generate(chunk)
                // Worked out here rather than on the game loop: it is a few
                // thousand noise samples per chunk and it depends on
                // nothing but the seed.
                let decoration = generator.decorationBlocks(in: chunk)
                guard let self else { return }
                self.inboxLock.lock()
                self.generatedInbox.append(GeneratedChunk(chunk: chunk, decoration: decoration))
                self.inboxLock.unlock()
            }
        }
    }

    /// Folds every chunk that finished generating into the world. Must be
    /// called from the game loop's thread, before anything reads `chunks`.
    func integrateGeneratedChunks() {
        inboxLock.lock()
        let finished = generatedInbox
        generatedInbox.removeAll(keepingCapacity: true)
        inboxLock.unlock()

        for generated in finished {
            receiveGenerated(generated.chunk, decoration: generated.decoration)
        }
    }

    /// Generates a chunk synchronously. Used to prime the spawn area, so
    /// the player has ground under them on the very first frame instead of
    /// falling through a world that hasn't streamed in yet.
    func forceGenerate(_ coord: ChunkCoord) {
        guard chunks[coord] == nil, !pendingGeneration.contains(coord) else { return }
        let chunk = Chunk(coord: coord)
        generator.generate(chunk)
        receiveGenerated(chunk, decoration: generator.decorationBlocks(in: chunk))
    }

    private func receiveGenerated(_ chunk: Chunk, decoration: [BlockPlacement]) {
        let coord = chunk.coord
        pendingGeneration.remove(coord)
        guard chunks[coord] == nil else { return }
        chunk.isPopulated = true
        chunk.adopt(serial: nextChunkSerial)
        nextChunkSerial &+= 1
        chunks[coord] = chunk

        // Apply anything a neighbour's tree already wrote into this space.
        if let pending = deferredBlocks.removeValue(forKey: coord) {
            for write in pending {
                chunk.setBlock(
                    localX: write.x - chunk.originX,
                    y: write.y,
                    localZ: write.z - chunk.originZ,
                    to: write.block
                )
            }
        }

        // Order is load-bearing: trees go down over the terrain, and the
        // player's journal goes down over the trees.
        plant(decoration, from: chunk)
        replayEdits(into: chunk)

        // And light goes last of all, because it reads the blocks the three
        // steps above just settled. A torch the player left here is in the
        // journal, so it exists by now; seeding before the replay would
        // light a room that has no lamp in it yet.
        seedLight(for: chunk)

        // A chunk with edits in it is a chunk somebody has dug in, and the
        // shaft they dug is buried geometry by every test the classifier
        // has. Reloading a world would otherwise fill in their tunnels
        // until they walked back into one.
        if editJournal[coord] != nil { reveal(coord) }

        // Seam faces on the neighbours were culled against assumed-air; now
        // that real data exists they have to be rebuilt. All *eight*, not
        // just the four orthogonal ones: `gatherNeighbourhood` flattens the
        // full 3×3, because the mesher's occlusion samples reach one cell
        // diagonally out of a corner column. A chunk becomes meshable as
        // soon as its four orthogonal neighbours exist, so a corner column
        // can perfectly well be meshed while its diagonal is still air —
        // and nothing would ever have re-meshed it, leaving one permanently
        // wrong AO corner per chunk seam.
        //
        // Marking eight rather than requiring eight is the cheaper of the
        // two fixes and the one that cannot stall: waiting for all eight
        // would hold every chunk on the streaming frontier unmeshed until a
        // ring further out had generated, which is a visible hole for the
        // player rather than a wrong corner. This is one extra remesh per
        // chunk, on the background queue, and it self-heals.
        for dz in -1...1 {
            for dx in -1...1 {
                markNeedsRemesh(ChunkCoord(x: coord.x + dx, z: coord.z + dz), urgent: false)
            }
        }
    }

    /// Re-applies this chunk's journal, last, so an edit beats both the
    /// terrain it was made in and any tree the generator plants over it.
    /// Runs before the chunk's first mesh, so no separate remesh is needed.
    private func replayEdits(into chunk: Chunk) {
        guard let edits = editJournal[chunk.coord] else { return }
        let slice = Chunk.width * Chunk.depth
        for (index, type) in edits {
            let y = index / slice
            let remainder = index % slice
            chunk.setBlock(localX: remainder % Chunk.width, y: y, localZ: remainder / Chunk.width, to: type)
        }
    }

    /// Writes this chunk's trees into the world. Canopy blocks that land
    /// outside the chunk go straight into the target chunk, or into
    /// `deferredBlocks` until it generates — deliberately not through
    /// `setBlock`, which would file terrain as a player edit.
    ///
    /// Only the writing happens here; `WorldGenerator.decorationBlocks`
    /// worked out *what* to write, on the generation queue. This half has
    /// to stay on the game loop because it reaches into neighbouring
    /// chunks, which the loop owns.
    private func plant(_ decoration: [BlockPlacement], from chunk: Chunk) {
        guard !chunk.isDecorated else { return }
        chunk.isDecorated = true
        for part in decoration {
            let coord = World.chunkCoord(forWorldX: part.x, worldZ: part.z)
            guard let target = chunks[coord] else {
                deferredBlocks[coord, default: []].append(part)
                continue
            }
            let lx = part.x - target.originX, lz = part.z - target.originZ
            // A canopy spilling into an already-loaded chunk must not undo
            // an edit there: that chunk won't replay its journal until it
            // next reloads, so the block would come back.
            if editJournal[coord]?[Chunk.index(lx, part.y, lz)] != nil { continue }
            // Leaves never overwrite solid blocks (a neighbouring trunk, a
            // hillside); logs always win.
            if part.block == .leaves, target.block(localX: lx, y: part.y, localZ: lz) != .air { continue }
            target.setBlock(localX: lx, y: part.y, localZ: lz, to: part.block)
            if coord != chunk.coord { markNeedsRemesh(coord, urgent: false) }
        }
    }

    /// Drops chunks that have drifted well outside the render radius,
    /// returning them so the caller can detach their nodes. `editJournal` is
    /// deliberately left untouched — it is what lets the chunk come back the
    /// way the player left it rather than the way the seed describes it.
    func unloadDistantChunks(around center: ChunkCoord) -> [Chunk] {
        let limit = (dataDistance + 2) * (dataDistance + 2)
        let stale = chunks.filter { $0.key.distanceSquared(to: center) > limit }
        for (coord, _) in stale {
            chunks.removeValue(forKey: coord)
            deferredBlocks.removeValue(forKey: coord)
            dirtyChunks.remove(coord)
            urgentChunks.remove(coord)
            pendingBuried.remove(coord)
        }
        return Array(stale.values)
    }

    /// Detaches every chunk's geometry and forgets anything the generation
    /// queue has not handed over yet.
    ///
    /// For shutting a world down when the player goes back to the menu. The
    /// blocks stay — this world is about to be released whole — but the
    /// entities have to be let go explicitly, because they are owned by the
    /// scene they were added to and not by the chunks that built them.
    /// Generation tasks still in flight hold this world weakly, so they
    /// find nothing to deliver to and quietly drop what they built.
    func releaseEntities() {
        for chunk in chunks.values { chunk.releaseRendering() }
        inboxLock.lock()
        generatedInbox.removeAll()
        inboxLock.unlock()
        pendingGeneration.removeAll()
        dirtyChunks.removeAll()
        urgentChunks.removeAll()
        pendingBuried.removeAll()
    }

    // MARK: - Spawn

    /// A standing position on solid ground near the origin, above water.
    /// Searches outward until it finds a column that isn't ocean — and,
    /// within that same search, prefers the first one that can also grow a
    /// tree. A fresh player starts with an empty inventory and a hunger
    /// clock already running: nothing else in this game hands out a
    /// starting kit, so wood within a short walk is the one thing spawn
    /// itself has to guarantee. Landing on the literal nearest dry sand
    /// regardless of biome could strand a desert or snowy start dozens of
    /// blocks from the nearest tree — a cost paid before the player has
    /// made a single decision, unlike every other cost this game charges.
    /// Falling back to the plain dry-land search if no forest or plains
    /// turns up keeps the old guarantee intact for the rare seed where
    /// none exists nearby at all, rather than searching forever.
    func spawnPosition() -> Vector3 {
        if let wooded = firstColumn(matching: { x, z, height in
            height > WorldGenerator.seaLevel + 1 && WorldGenerator.treeBiomes.contains(generator.biome(x: x, z: z))
        }) {
            return wooded
        }
        if let dry = firstColumn(matching: { _, _, height in height > WorldGenerator.seaLevel + 1 }) {
            return dry
        }
        return Vector3(0.5, CGFloat(WorldGenerator.seaLevel + 4), 0.5)
    }

    private func firstColumn(matching predicate: (Int, Int, Int) -> Bool) -> Vector3? {
        for radius in 0..<64 {
            for dz in -radius...radius {
                for dx in -radius...radius where abs(dx) == radius || abs(dz) == radius || radius == 0 {
                    let x = dx * 4, z = dz * 4
                    let height = generator.surfaceHeight(x: x, z: z)
                    guard predicate(x, z, height) else { continue }
                    return Vector3(CGFloat(x) + 0.5, CGFloat(height + 1), CGFloat(z) + 0.5)
                }
            }
        }
        return nil
    }
}

// MARK: - Thermal Simulation & Microclimates (Milestone 2)

extension World {
    /// True where the given cell holds ice.
    func isIce(worldX x: Int, y: Int, worldZ z: Int) -> Bool {
        block(worldX: x, y: y, worldZ: z) == .ice
    }

    /// Queries whether the specified coordinates are within thermal radiance reach of an active heat source.
    func isNearHeatSource(
        worldX x: Int,
        y: Int,
        worldZ z: Int,
        radius: Int = ThermalQuery.defaultRadius,
        metric: ThermalQuery.Metric = .chebyshev
    ) -> Bool {
        ThermalQuery.isNearHeatSource(world: self, worldX: x, y: y, worldZ: z, radius: radius, metric: metric)
    }

    /// True if any thermal source sits within `radius` blocks (Chebyshev metric).
    func isNearThermalSource(
        worldX x: Int,
        y: Int,
        worldZ z: Int,
        radius: Int = ThermalQuery.defaultRadius
    ) -> Bool {
        isNearHeatSource(worldX: x, y: y, worldZ: z, radius: radius, metric: .chebyshev)
    }

    /// Convenience overload taking a tuple of coordinates.
    func isNearHeatSource(
        at pos: (x: Int, y: Int, z: Int),
        radius: Int = ThermalQuery.defaultRadius,
        metric: ThermalQuery.Metric = .chebyshev
    ) -> Bool {
        isNearHeatSource(worldX: pos.x, y: pos.y, worldZ: pos.z, radius: radius, metric: metric)
    }

    /// Accessor for biome at column coordinates.
    func biome(worldX x: Int, worldZ z: Int) -> WorldGenerator.Biome {
        generator.biome(x: x, z: z)
    }

    /// Whether water at (x, y, z) satisfies freezing conditions:
    /// Still water, in snowy biome or alpine altitude (y > 85), open to sky, and unheated.
    func canFreeze(atWorldX x: Int, y: Int, worldZ z: Int) -> Bool {
        guard block(worldX: x, y: y, worldZ: z) == .water else { return false }
        guard isSkyOpen(worldX: x, y: y, worldZ: z) else { return false }
        let isCold = (generator.biome(x: x, z: z) == .snowy) || (y > 85)
        guard isCold else { return false }
        guard !isNearThermalSource(worldX: x, y: y, worldZ: z, radius: 3) else { return false }
        return true
    }

    /// Whether ice at (x, y, z) satisfies melting conditions:
    /// Ice within radius 3 of a thermal source.
    func canMelt(atWorldX x: Int, y: Int, worldZ z: Int) -> Bool {
        guard block(worldX: x, y: y, worldZ: z) == .ice else { return false }
        guard isNearThermalSource(worldX: x, y: y, worldZ: z, radius: 3) else { return false }
        return true
    }

    /// Deterministic thermal tick for a single cell: transforms water -> ice or ice -> water.
    @discardableResult
    func tickThermal(atWorldX x: Int, y: Int, worldZ z: Int) -> Bool {
        if canFreeze(atWorldX: x, y: y, worldZ: z) {
            return setBlock(worldX: x, y: y, worldZ: z, to: .ice)
        } else if canMelt(atWorldX: x, y: y, worldZ: z) {
            return setBlock(worldX: x, y: y, worldZ: z, to: .water)
        }
        return false
    }

    /// Alias for tickThermal(atWorldX:y:worldZ:).
    @discardableResult
    func tickThermal(worldX x: Int, y: Int, worldZ z: Int) -> Bool {
        tickThermal(atWorldX: x, y: y, worldZ: z)
    }

    /// Ticks thermal dynamics across all columns of a loaded chunk.
    @discardableResult
    func tickThermal(in coord: ChunkCoord) -> Int {
        guard let chunk = chunks[coord] else { return 0 }
        var transitions = 0
        let ox = chunk.originX
        let oz = chunk.originZ
        let top = chunk.ceiling
        guard top >= 0 else { return 0 }
        for lz in 0..<Chunk.depth {
            let wz = oz + lz
            for lx in 0..<Chunk.width {
                let wx = ox + lx
                for y in 0...top {
                    let b = chunk.block(localX: lx, y: y, localZ: lz)
                    if b == .water || b == .ice {
                        if tickThermal(atWorldX: wx, y: y, worldZ: wz) {
                            transitions += 1
                        }
                    }
                }
            }
        }
        return transitions
    }

    /// Stochastic random thermal tick across loaded chunks for real-time game loop.
    func randomTickThermal(in coord: ChunkCoord, samples: Int = 16) {
        guard let chunk = chunks[coord] else { return }
        let ox = chunk.originX
        let oz = chunk.originZ
        let top = max(chunk.ceiling, 1)
        for _ in 0..<samples {
            let lx = Int.random(in: 0..<Chunk.width)
            let lz = Int.random(in: 0..<Chunk.depth)
            let y = Int.random(in: 0...top)
            let b = chunk.block(localX: lx, y: y, localZ: lz)
            if b == .water || b == .ice {
                tickThermal(atWorldX: ox + lx, y: y, worldZ: oz + lz)
            }
        }
    }

    /// Whether standing water sits anywhere within reach of the given farmland cell.
    func isFarmlandHydrated(worldX x: Int, y: Int, worldZ z: Int, reach: Int = 4) -> Bool {
        for dz in -reach...reach {
            for dx in -reach...reach {
                if block(worldX: x + dx, y: y, worldZ: z + dz) == .water {
                    return true
                }
            }
        }
        return false
    }

    /// Ticks farmland: if unhydrated and untended (no crop above), reverts to dirt.
    @discardableResult
    func tickFarmland(worldX x: Int, y: Int, worldZ z: Int) -> Bool {
        guard block(worldX: x, y: y, worldZ: z) == .farmland else { return false }
        let hasCrop = block(worldX: x, y: y + 1, worldZ: z).isCrop
        if !hasCrop && !isFarmlandHydrated(worldX: x, y: y, worldZ: z) {
            return setBlock(worldX: x, y: y, worldZ: z, to: .dirt)
        }
        return false
    }

    // MARK: - Granular Falling Gravity

    @discardableResult
    func settleGranular(remesh: Bool = true) -> GranularTick.SettleResult {
        var aggregate = GranularTick.SettleResult()
        for coord in chunks.keys {
            let res = GranularTick.settleChunk(in: self, coord: coord, remesh: remesh)
            aggregate.blocksMoved += res.blocksMoved
            aggregate.columnsAffected += res.columnsAffected
            aggregate.maxFallDistance = max(aggregate.maxFallDistance, res.maxFallDistance)
            aggregate.moves.append(contentsOf: res.moves)
            aggregate.destroyed.append(contentsOf: res.destroyed)
        }
        return aggregate
    }

    @discardableResult
    func settleGranular(atWorldX x: Int, worldZ z: Int, maxFall: Int = .max, remesh: Bool = true) -> GranularTick.SettleResult {
        GranularTick.settleColumn(in: self, worldX: x, worldZ: z, startY: 1, maxFall: maxFall, remesh: remesh)
    }

    @discardableResult
    func settleGranular(atWorldX x: Int, y startY: Int, worldZ z: Int, maxFall: Int = .max, remesh: Bool = true) -> GranularTick.SettleResult {
        GranularTick.settleColumn(in: self, worldX: x, worldZ: z, startY: startY, maxFall: maxFall, remesh: remesh)
    }

    @discardableResult
    func settleGranular(in coord: ChunkCoord, remesh: Bool = true) -> GranularTick.SettleResult {
        GranularTick.settleChunk(in: self, coord: coord, remesh: remesh)
    }

    @discardableResult
    func settleGranular(around center: (x: Int, y: Int, z: Int), radius: Int, remesh: Bool = true) -> GranularTick.SettleResult {
        GranularTick.settleArea(in: self, centerX: center.x, centerY: center.y, centerZ: center.z, radius: radius, remesh: remesh)
    }

    func randomTickGravity(in coord: ChunkCoord, samples: Int = 16) {
        guard let chunk = chunks[coord] else { return }
        // Unseeded, like the thermal tick next door. A generator seeded from
        // the chunk coordinate is rebuilt identically on every call, so every
        // tick replayed the same eight columns and unsupported sand in the
        // other 248 hung in the air forever. It also had to convert a
        // coordinate that goes negative west and north of the origin to an
        // unsigned integer, which traps rather than wrapping.
        for _ in 0..<samples {
            let lx = Int.random(in: 0..<Chunk.width)
            let lz = Int.random(in: 0..<Chunk.depth)
            let wx = chunk.originX + lx
            let wz = chunk.originZ + lz
            settleGranular(atWorldX: wx, worldZ: wz, maxFall: 1, remesh: true)
        }
    }

    // MARK: - Industrial Disturbance

    func disturbance(inChunkX cx: Int, chunkZ cz: Int) -> Double {
        disturbance.level(inChunk: ChunkCoord(x: cx, z: cz))
    }

    func disturbance(atWorldX x: Int, worldZ z: Int) -> Double {
        disturbance.level(atWorldX: x, worldZ: z)
    }

    func recordDisturbance(
        atWorldX x: Int,
        worldZ z: Int,
        amount: Double,
        ceiling: Double = DisturbanceTracker.maxDisturbance
    ) {
        disturbance.record(atWorldX: x, worldZ: z, amount: amount, ceiling: ceiling)
    }
}

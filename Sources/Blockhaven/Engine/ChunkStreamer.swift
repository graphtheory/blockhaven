import Foundation

/// Keeps the chunks around the player generated and meshed: hands
/// generation to the world's queue, builds geometry on a queue of its own,
/// and passes finished meshes to whichever front end is drawing them.
///
/// The front end supplies two things — how to put a chunk's geometry on
/// screen, and how to take it off again when the chunk unloads. Everything
/// else is the same whether the result becomes a RealityKit entity or an
/// OpenGL buffer.
final class ChunkStreamer {
    let world: World
    /// Whether the mesher bakes per-corner smooth lighting — the custom
    /// block shader on the Mac reads it, the flat fallback does not.
    let smoothShading: Bool
    /// Puts freshly built geometry on screen, replacing only the halves
    /// `data.faces` covers. Called on the main thread.
    private let install: (ChunkMesher.MeshData, Chunk) -> Void
    /// Takes a chunk's geometry off screen; it is about to be dropped.
    private let unload: (Chunk) -> Void

    /// How many chunks may be handed to the mesh queue per frame.
    ///
    /// Left at two deliberately. Since geometry moved off the loop this
    /// budget is cheap enough to raise, but measurement says there is
    /// nothing to raise it for: over 900 frames of flying, meshing cleared
    /// 226 of 241 loaded chunks — eight times the rate chunks were
    /// generated at. Terrain arrives as fast as `scheduleGeneration`
    /// delivers it, not as fast as the mesher consumes it.
    private let meshBudgetPerFrame = 2

    /// How many chunks a player edit may rebuild synchronously in one
    /// frame. See `World.urgentChunksToMesh`.
    private static let urgentMeshBudget = 4

    private var lastPlayerChunk = ChunkCoord(x: Int.min, z: Int.min)

    init(
        world: World,
        smoothShading: Bool,
        install: @escaping (ChunkMesher.MeshData, Chunk) -> Void,
        unload: @escaping (Chunk) -> Void
    ) {
        self.world = world
        self.smoothShading = smoothShading
        self.install = install
        self.unload = unload
    }

    /// Waits for the mesh queue to go quiet and forgets everything in
    /// flight, so the front end can drop what it was drawing into.
    ///
    /// The work items hold no strong reference to this streamer, so they
    /// would come back to nothing and drop their results — but a barrier
    /// here means the queue is provably idle rather than probably harmless.
    func shutdown() {
        meshQueue.sync {}
        meshInboxLock.lock()
        meshInbox.removeAll()
        meshInboxLock.unlock()
        meshesInFlight.removeAll()
        buriedInFlight.removeAll()
    }

    /// One frame of streaming around `center`, the chunk the player is in,
    /// with `eye` deciding whether the buried halves around it are wanted.
    func stream(center: ChunkCoord, eye: Vector3) {
        // Fold in anything the generation queue finished before any of this
        // frame's work reads the chunk map.
        world.integrateGeneratedChunks()

        world.scheduleGeneration(around: center)

        if center != lastPlayerChunk {
            lastPlayerChunk = center
            for chunk in world.unloadDistantChunks(around: center) {
                unload(chunk)
                meshesInFlight.remove(chunk.coord)
                buriedInFlight.remove(chunk.coord)
            }
        }

        // A block the player just broke has to go now, so its chunk is
        // rebuilt on this frame rather than queued behind the horizon.
        for chunk in world.urgentChunksToMesh(limit: ChunkStreamer.urgentMeshBudget) {
            let wanted = faceSet(for: chunk)
            let data = FrameProfiler.measure(.mesh) {
                ChunkMesher.buildMeshData(
                    chunk: chunk, in: world, smoothShading: smoothShading, faces: wanted
                )
            }
            install(data, chunk)
            world.markMeshed(chunk)
            if wanted.contains(.buried) { world.markBuriedBuilding(chunk.coord) }
        }

        revealUnderfoot(eye: eye)
        installFinishedMeshes()
        dispatchMeshWork(budget: meshBudgetPerFrame, center: center)
        dispatchBuriedWork(budget: ChunkStreamer.buriedBudgetPerFrame, center: center)
    }

    // MARK: - Meshing

    /// Chunk geometry is built on this queue, not on the frame.
    ///
    /// A chunk mesh measures about a millisecond, and the budget builds two
    /// of them, so streaming used to spend a fifth of a 100 Hz frame on
    /// arithmetic that touches no RealityKit object at all. What is left on
    /// the main thread is the part that genuinely has to be: reading the
    /// world (`gatherNeighbourhood`, a bounded 42 KB copy) and uploading
    /// the result (`makeMesh`, which is `@MainActor` because it builds a
    /// `LowLevelMesh`).
    ///
    /// Serial on purpose: chunk generation already runs eight tasks wide on
    /// its own concurrent queue, and a second concurrent queue on top of
    /// that oversubscribes the machine and starts preempting the render
    /// thread — which is the one thing this change exists to protect. One
    /// worker clears the two-chunk budget in under a millisecond, well
    /// inside the frame it was queued on.
    private let meshQueue = DispatchQueue(label: "blockhaven.mesh", qos: .userInitiated)
    private let meshInboxLock = NSLock()
    /// A finished build, tagged with everything needed to prove it still
    /// describes the world.
    ///
    /// `revision` alone is not enough: it is a per-`Chunk` counter that
    /// restarts at 0 on every new object, so a chunk that unloaded and
    /// regenerated while a build was in flight presents a *fresh* object
    /// whose revision matches the one the build recorded — and the stale
    /// geometry installs over it. The object's identity is what actually
    /// distinguishes the two, so it rides along; revision then covers the
    /// remaining case of the same chunk being edited mid-build.
    private struct FinishedMesh {
        let coord: ChunkCoord
        /// The identity of the chunk this was built for — `Chunk.serial`,
        /// not `ObjectIdentifier`. See `World.nextChunkSerial` for why the
        /// address will not do.
        let serial: UInt64
        let revision: Int
        let data: ChunkMesher.MeshData
    }

    private var meshInbox: [FinishedMesh] = []
    /// Chunks a background build is running for, so a chunk is never queued
    /// twice and a stale result can be recognised after an unload.
    private var meshesInFlight: Set<ChunkCoord> = []
    /// The same, for builds that cover only a chunk's buried half. Kept
    /// apart because a chunk can have one of each in the air at once.
    private var buriedInFlight: Set<ChunkCoord> = []


    /// Hands the geometry for up to `budget` chunks to the mesh queue.
    private func dispatchMeshWork(budget: Int, center: ChunkCoord) {
        // Nothing is gained by running further ahead than the inbox can be
        // drained, and a deep queue would only mesh chunks against a world
        // that has moved on.
        let room = budget - meshesInFlight.count
        guard room > 0 else { return }

        let smooth = smoothShading
        for chunk in world.chunksReadyToMesh(around: center, limit: room) {
            let coord = chunk.coord
            guard !meshesInFlight.contains(coord) else { continue }
            let wanted = faceSet(for: chunk)
            // Gathering reads live blocks, so it belongs here; clearing the
            // flag now is what stops the chunk being picked again next
            // frame while its build is still running. A later edit sets the
            // flag again and re-queues it once this build lands.
            let neighbourhood = FrameProfiler.measure(.gather) {
                ChunkMesher.gatherNeighbourhood(chunk: chunk, in: world)
            }
            let revision = chunk.revision
            let serial = chunk.serial
            world.markMeshed(chunk)
            if wanted.contains(.buried) { world.markBuriedBuilding(coord) }
            meshesInFlight.insert(coord)
            meshQueue.async { [weak self] in
                let data = ChunkMesher.buildMeshData(
                    from: neighbourhood, smoothShading: smooth, faces: wanted
                )
                guard let self else { return }
                self.meshInboxLock.lock()
                self.meshInbox.append(
                    FinishedMesh(coord: coord, serial: serial, revision: revision, data: data)
                )
                self.meshInboxLock.unlock()
            }
        }
    }

    // MARK: - Revealing buried geometry

    /// How many chunks may have their hidden half built per frame.
    ///
    /// Higher than the streaming budget on purpose: a reveal is a burst —
    /// dropping into a shaft asks for twenty-five chunks at once — and
    /// every frame it takes is a frame with a hole in the wall. Four
    /// clears that burst in under a tenth of a second, and the work is on
    /// the mesh queue, not the frame.
    private static let buriedBudgetPerFrame = 4

    /// Chunks the player can see into if they turn around, revealed as a
    /// square rather than one at a time.
    ///
    /// Two chunks is 32 blocks of margin beyond the one they stand in,
    /// against a 160-block render distance — so a dead-straight tunnel
    /// longer than that would still run out of geometry before it runs out
    /// of fog. Caves here are carved from intersected 3D noise and do not
    /// go straight for 32 blocks; a bigger ring costs a build for every
    /// chunk in it and this is the one trigger that fires while walking.
    private static let undergroundRevealRadius = 2

    /// The buried half is built when the player's eye is under the ground.
    ///
    /// "Under the ground" used to be asked as "is the eye sky-open", which
    /// is the mesher's own test — and it is the wrong question here, because
    /// the skyline counts leaves as occluders (deliberately: a canopy of
    /// see-through leaves would cost an internal face per leaf). A tenth of
    /// the walkable ground on this seed is not sky-open at eye height, so
    /// walking under trees in broad daylight tripped this over and over —
    /// one straight 281-block surface walk fired it 35 times and revealed 65
    /// chunks — and reveal is sticky, so every one of those carried its
    /// hidden half, roughly 6.7x its geometry, for the rest of its life. The
    /// saving quietly ate itself in a forest.
    ///
    /// `hasTerrainOverhead` asks the question the name of this method makes:
    /// is there anything but foliage over the eye. A cave roof, a tunnel, a
    /// shaft, a house someone built — yes. A tree — no.
    private func revealUnderfoot(eye: Vector3) {
        let x = Int(eye.x.rounded(.down)), y = Int(eye.y.rounded(.down)), z = Int(eye.z.rounded(.down))
        guard world.hasTerrainOverhead(worldX: x, y: y, worldZ: z) else { return }
        world.reveal(
            around: World.chunkCoord(forWorldX: x, worldZ: z),
            radius: ChunkStreamer.undergroundRevealRadius
        )
    }

    /// Builds the hidden half of chunks that have been revealed but whose
    /// surface mesh is already up to date, so the geometry on screen is
    /// never touched.
    private func dispatchBuriedWork(budget: Int, center: ChunkCoord) {
        let room = budget - buriedInFlight.count
        guard room > 0 else { return }

        let smooth = smoothShading
        for chunk in world.chunksNeedingBuried(around: center, limit: room) {
            let coord = chunk.coord
            guard !buriedInFlight.contains(coord), !meshesInFlight.contains(coord) else { continue }
            let neighbourhood = FrameProfiler.measure(.gather) {
                ChunkMesher.gatherNeighbourhood(chunk: chunk, in: world)
            }
            let revision = chunk.revision
            let serial = chunk.serial
            world.markBuriedBuilding(coord)
            buriedInFlight.insert(coord)
            meshQueue.async { [weak self] in
                let data = ChunkMesher.buildMeshData(
                    from: neighbourhood, smoothShading: smooth, faces: .buried
                )
                guard let self else { return }
                self.meshInboxLock.lock()
                self.meshInbox.append(
                    FinishedMesh(coord: coord, serial: serial, revision: revision, data: data)
                )
                self.meshInboxLock.unlock()
            }
        }
    }

    /// Which halves a rebuild of this chunk has to cover. A chunk nobody
    /// has revealed gets the surface half and nothing else, which is the
    /// whole saving; a revealed one gets both, because an edit changes
    /// both.
    private func faceSet(for chunk: Chunk) -> ChunkMesher.FaceSet {
        chunk.isRevealed ? .all : .surface
    }

    /// Uploads everything the mesh queue finished since the last frame.
    private func installFinishedMeshes() {
        meshInboxLock.lock()
        let finished = meshInbox
        meshInbox.removeAll(keepingCapacity: true)
        meshInboxLock.unlock()
        guard !finished.isEmpty else { return }

        FrameProfiler.measure(.upload) {
            for result in finished {
                if result.data.faces == .buried {
                    buriedInFlight.remove(result.coord)
                } else {
                    meshesInFlight.remove(result.coord)
                }
                // The chunk may have been unloaded while this was building,
                // in which case the geometry is simply dropped.
                guard let chunk = world.chunk(at: result.coord) else { continue }
                // …or unloaded *and regenerated*, which leaves a different
                // object at the same coordinate carrying a revision that
                // restarted at 0. The serial catches that; revision alone
                // cannot, and neither could `ObjectIdentifier`, which is an
                // address the regenerated chunk may well have inherited
                // from the one it replaced.
                guard chunk.serial == result.serial else { continue }
                // …or edited while it was building, in which case this mesh
                // describes a world that no longer exists and installing it
                // would put a broken block back. The chunk is still dirty,
                // so a fresh build is already queued behind this.
                guard chunk.revision == result.revision else { continue }
                install(result.data, chunk)
            }
        }
    }
    /// Builds and installs chunks synchronously, for the spawn priming that
    /// has to finish before the first frame is drawn.
    func meshReadyChunks(budget: Int, around center: ChunkCoord) {
        let smooth = smoothShading
        for chunk in world.chunksReadyToMesh(around: center, limit: budget) {
            let wanted = faceSet(for: chunk)
            install(
                ChunkMesher.buildMeshData(
                    chunk: chunk, in: world, smoothShading: smooth, faces: wanted
                ),
                chunk
            )
            world.markMeshed(chunk)
            if wanted.contains(.buried) { world.markBuriedBuilding(chunk.coord) }
        }
    }
}

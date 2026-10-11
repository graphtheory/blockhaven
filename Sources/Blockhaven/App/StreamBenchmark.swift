import Foundation

/// Headless measurement of the per-frame streaming cost.
///
/// The frame log cannot answer "how much of the frame does streaming
/// cost?" on this machine: RealityKit waits for a 100 Hz display, so the
/// frame rate is pinned at the cap whether the loop used 2 ms or 9 ms, and
/// when the screen is locked or asleep the window is occluded and the
/// number collapses to something that says nothing about the game at all.
///
/// This runs the streaming half of `GameViewController.tick` — integrate,
/// schedule, unload, pick, mesh — over a world that walks forward at
/// flying speed, with no window, no RealityKit and no display involved,
/// and reports **milliseconds per frame** for each phase. That is the
/// number an optimisation has to move, and it is measurable with the
/// screen off.
///
/// `BLOCKHAVEN_BENCH_STREAM=<frames>` (default 600, i.e. six seconds of
/// 100 Hz play). Nothing here touches the save file.
///
/// `BLOCKHAVEN_BENCH_MINE=<frames between breaks>` holds the break button
/// down for the whole walk — unset leaves it up, and a value that will not
/// parse means 5, the 20 breaks a second creative mode's flat 0.05 s floor
/// allows. That is the load an edit puts on streaming, which the plain run
/// cannot see: every break rebuilds
/// its own chunk *on the loop* and hands the classifier fan-out — three
/// neighbours at a chunk corner, five along an edge, eight over the middle
/// 8×8 — to the same two-a-frame budget streaming is using. Run it against
/// a plain run of the same length and compare `chunks meshed` and ON-LOOP.
enum StreamBenchmark {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_BENCH_STREAM"] != nil
    }

    /// One simulated frame at 100 Hz, matching the display this is tuned
    /// for. Generation runs on a background queue, so the loop really does
    /// have to wait out the frame or it would measure a world that never
    /// finishes streaming anything.
    private static let frameInterval = 0.01
    /// Blocks per second — `PlayerController.flySpeed`, the fastest the
    /// player can make chunks arrive.
    private static let speed = 11.0

    /// Which halves a build covers, matching `GameViewController.faceSet`.
    /// Only edits reveal anything here, so without the break button held
    /// this is `.surface` for every chunk the walk ever meshes.
    private static func faces(for chunk: Chunk) -> ChunkMesher.FaceSet {
        chunk.isRevealed ? .all : .surface
    }

    private struct Phase {
        let name: String
        var seconds: Double = 0
        /// The worst single visit. A mean hides exactly the thing a player
        /// feels, so both are reported.
        var worst: Double = 0
    }

    static func run() -> Never {
        let environment = ProcessInfo.processInfo.environment
        let frames = Int(environment["BLOCKHAVEN_BENCH_STREAM"] ?? "") ?? 600
        let smooth = environment["BLOCKHAVEN_CUSTOM_SHADER"] != "0"
        // Zero means the button is not held. Anything else is the gap
        // between breaks in frames; five is creative mode's floor.
        let mineEvery = environment["BLOCKHAVEN_BENCH_MINE"] == nil
            ? 0 : max(1, Int(environment["BLOCKHAVEN_BENCH_MINE"] ?? "") ?? 5)

        let world = World()
        let spawn = world.spawnPosition()
        var x = Double(spawn.x), z = Double(spawn.z)

        // The same spawn priming the game does, so the measured frames are
        // steady-state streaming rather than the initial flood.
        let start = World.chunkCoord(forWorldX: Int(x.rounded(.down)), worldZ: Int(z.rounded(.down)))
        for dz in -2...2 {
            for dx in -2...2 {
                world.forceGenerate(ChunkCoord(x: start.x + dx, z: start.z + dz))
            }
        }

        var integrate = Phase(name: "integrate")
        var schedule = Phase(name: "schedule")
        var unload = Phase(name: "unload")
        var edit = Phase(name: "edit")
        var urgent = Phase(name: "urgent")
        var pick = Phase(name: "pick")
        var gather = Phase(name: "gather")
        var build = Phase(name: "build")
        var meshedChunks = 0
        var worstFrame = 0.0
        var lastCenter = ChunkCoord(x: Int.min, z: Int.min)
        var breaks = 0, urgentRebuilds = 0
        var dirtyTotal = 0, dirtyWorst = 0

        for frame in 0..<frames {
            // Walk on a diagonal so both chunk axes move.
            x += speed * frameInterval * 0.7071
            z += speed * frameInterval * 0.7071
            let center = World.chunkCoord(forWorldX: Int(x.rounded(.down)), worldZ: Int(z.rounded(.down)))

            let frameStarted = monotonicSeconds()
            time(&integrate) { world.integrateGeneratedChunks() }
            time(&schedule) { world.scheduleGeneration(around: center) }
            if center != lastCenter {
                lastCenter = center
                time(&unload) { _ = world.unloadDistantChunks(around: center) }
            }

            // The break goes in before the streaming half, the way
            // `updatePlay` runs before `streamChunks` in the same tick —
            // which is why the chunk being mined gets its urgent rebuild on
            // the very frame the block goes.
            if mineEvery > 0, frame % mineEvery == 0 {
                let bx = Int(x.rounded(.down)), bz = Int(z.rounded(.down))
                // Untimed: the game gets this cell from the targeting
                // raycast, not from a column scan.
                var by = Chunk.height - 1
                while by > 0, !world.block(worldX: bx, y: by, worldZ: bz).isSolid { by -= 1 }
                if by > 0 {
                    time(&edit) { world.setBlock(worldX: bx, y: by, worldZ: bz, to: .air) }
                    breaks += 1
                }
            }
            // What a player edit costs the frame itself: the game rebuilds
            // these on the main thread rather than queueing them, so gather
            // and build both land here.
            time(&urgent) {
                for chunk in world.urgentChunksToMesh(limit: 4) {
                    _ = ChunkMesher.buildMeshData(
                        chunk: chunk, in: world, smoothShading: smooth, faces: faces(for: chunk)
                    )
                    world.markMeshed(chunk)
                    urgentRebuilds += 1
                }
            }

            // How far behind the two-a-frame budget is running. This is the
            // number that says whether streaming starves: a queue that grows
            // with the walk is a horizon arriving late.
            let dirty = world.dirtyChunkCount
            dirtyTotal += dirty
            dirtyWorst = max(dirtyWorst, dirty)

            var ready: [Chunk] = []
            time(&pick) { ready = world.chunksReadyToMesh(around: center, limit: 2) }
            var gathered: [(ChunkMesher.Neighbourhood, ChunkMesher.FaceSet)] = []
            time(&gather) {
                for chunk in ready {
                    gathered.append(
                        (ChunkMesher.gatherNeighbourhood(chunk: chunk, in: world), faces(for: chunk))
                    )
                    world.markMeshed(chunk)
                    meshedChunks += 1
                }
            }
            // Timed, but *not* counted against the frame: in the game this
            // runs on `GameViewController.meshQueue`, and the whole point
            // of measuring it separately is to show what left the loop.
            let mainThreadEnd = monotonicSeconds()
            time(&build) {
                for (neighbourhood, wanted) in gathered {
                    _ = ChunkMesher.buildMeshData(
                        from: neighbourhood, smoothShading: smooth, faces: wanted
                    )
                }
            }
            worstFrame = max(worstFrame, mainThreadEnd - frameStarted)

            // Outside the timing: this stands in for the rest of the frame
            // the real game spends rendering.
            Thread.sleep(forTimeInterval: frameInterval)
        }

        let divisor = Double(frames)
        // The distance is in the header because every number under it
        // moves with it — the whole point of `BLOCKHAVEN_RENDER_DISTANCE` is
        // to compare these reports against each other, and two of them that
        // don't say which distance they were taken at cannot be compared.
        var report = String(
            format: "[bench] %d frames · render distance %d chunks (%d blocks)"
                + " · %d chunks meshed · %d loaded · worst frame %.2f ms\n",
            frames, world.renderDistance, world.renderDistance * Chunk.width,
            meshedChunks, world.chunks.count, worstFrame * 1000
        )
        var onLoop = 0.0
        for phase in [integrate, schedule, unload, edit, urgent, pick, gather, build] {
            if phase.name != "build" { onLoop += phase.seconds }
            report += line(
                phase.name, mean: phase.seconds / divisor,
                share: phase.seconds / (divisor * frameInterval), worst: phase.worst
            )
        }
        report += "[bench]   (build runs on the mesh queue in the game, not on the frame)\n"
        report += line(
            "ON-LOOP", mean: onLoop / divisor,
            share: onLoop / (divisor * frameInterval), worst: worstFrame
        )
        report += String(
            format: "[bench] mining: %@ · %d urgent rebuilds on the loop"
                + " · dirty queue mean %.1f, worst %d\n",
            mineEvery > 0
                ? String(format: "%d breaks, one every %d frames (%.0f/s)",
                         breaks, mineEvery, 1 / (Double(mineEvery) * frameInterval))
                : "button not held",
            urgentRebuilds, Double(dirtyTotal) / divisor, dirtyWorst
        )
        report += editPathCheck(world: world, near: (x, z), smooth: smooth)
        StandardError.write(Data(report.utf8))
        exit(0)
    }

    /// Checks the path a player's own edit takes, which the frame log
    /// cannot reach without a mouse.
    ///
    /// Streaming remeshes are built on a background queue now, and player
    /// edits deliberately are not — a broken block has to be gone on the
    /// click. This walks one place and one break through
    /// `setBlock` → `urgentChunksToMesh` → rebuild → `markMeshed` and
    /// checks the geometry actually followed: more vertices with the block
    /// there, exactly the original count once it is gone, and the chunk's
    /// mesh revision moving each time so an in-flight background build of
    /// the old state would be recognised as stale.
    private static func editPathCheck(
        world: World, near position: (x: Double, z: Double), smooth: Bool
    ) -> String {
        let x = Int(position.x.rounded(.down)), z = Int(position.z.rounded(.down))
        let coord = World.chunkCoord(forWorldX: x, worldZ: z)
        guard let chunk = world.chunk(at: coord) else {
            return "[bench] edit path: SKIPPED — no chunk at the finish position\n"
        }

        func vertices() -> Int {
            ChunkMesher.buildMeshData(
                chunk: chunk, in: world, smoothShading: smooth, faces: .all
            ).vertexCount
        }
        func meshUrgent() -> Int {
            let ready = world.urgentChunksToMesh(limit: 8)
            for chunk in ready { world.markMeshed(chunk) }
            return ready.count
        }

        // Somewhere unambiguously empty, so the block has six visible faces.
        let y = Chunk.height - 6
        let baseline = vertices()
        let startRevision = chunk.revision

        world.setBlock(worldX: x, y: y, worldZ: z, to: .stone)
        let placedUrgent = meshUrgent()
        let placed = vertices()

        world.setBlock(worldX: x, y: y, worldZ: z, to: .air)
        let brokenUrgent = meshUrgent()
        let broken = vertices()

        let ok = placed == baseline + 24 && broken == baseline
            && placedUrgent > 0 && brokenUrgent > 0
            && chunk.revision > startRevision
        return String(
            format: "[bench] edit path: %@ — %d verts, +%d placed, %d after breaking;"
                + " urgent rebuilds %d/%d; revision %d→%d\n",
            ok ? "ok" : "FAILED", baseline, placed - baseline, broken,
            placedUrgent, brokenUrgent, startRevision, chunk.revision
        )
            + shadeBelowCheck(world: world, chunk: chunk, at: (x, z), smooth: smooth,
                              meshUrgent: meshUrgent)
            + revealCheck(world: world, near: position, smooth: smooth)
            + fanOutCheck(world: world, near: position)
            + canopyCheck(world: world, near: position)
    }

    /// Checks that an edit reaches as far as the classifier does.
    ///
    /// A *neighbouring* chunk's buried/surface split depends on any cell
    /// within `ChunkMesher.pad` of the shared seam — twelve cells, which
    /// against a 16-wide chunk is every column of every chunk. A neighbour
    /// that is not told keeps a split computed against a world that no
    /// longer exists, and since nothing recomputes a split except a rebuild,
    /// it keeps it until it unloads. Nothing on screen says so, which is why
    /// it is checked here: an edit dead in the middle of a chunk, eight
    /// cells from the nearest seam, still has to dirty all eight neighbours.
    ///
    /// Both edits land *under* the column's skyline, digging into its side
    /// rather than off its top, and that is the whole point of the check.
    /// The rule this replaced fanned out on a cell that moved the skyline
    /// and stopped at the seam otherwise — so a break at the top of a column
    /// would satisfy the old code and the new alike, and a check written
    /// that way cannot fail on the bug it exists for. Mining horizontally
    /// into a hillside is both the case that was broken and what mining
    /// actually looks like. The break and the put-back are the two
    /// directions: neither moves the skyline, and both have to reach.
    private static func fanOutCheck(world: World, near position: (x: Double, z: Double)) -> String {
        let here = World.chunkCoord(
            forWorldX: Int(position.x.rounded(.down)), worldZ: Int(position.z.rounded(.down))
        )
        // Away from the chunks the checks above have already dug in.
        let coord = ChunkCoord(x: here.x - 2, z: here.z - 2)
        var ring: [Chunk] = []
        for dz in -1...1 {
            for dx in -1...1 where dx != 0 || dz != 0 {
                guard let neighbour = world.chunk(at: ChunkCoord(x: coord.x + dx, z: coord.z + dz))
                else { continue }
                ring.append(neighbour)
            }
        }
        guard let chunk = world.chunk(at: coord), ring.count == 8 else {
            return "[bench] edit fan-out: SKIPPED — no chunk with eight loaded neighbours\n"
        }

        // The column's skyline is the topmost *occluding* cell — the same
        // test `Chunk.skyline` uses — and the cell to edit is the next one
        // down that is solid rock rather than a gap in the hillside.
        let x = chunk.originX + Chunk.width / 2, z = chunk.originZ + Chunk.depth / 2
        var top = Chunk.height - 1
        while top > 0, !world.block(worldX: x, y: top, worldZ: z).isOpaque { top -= 1 }
        var y = top - 1
        while y > 0, !world.block(worldX: x, y: y, worldZ: z).isOpaque { y -= 1 }
        guard y > 0, y < top else {
            return "[bench] edit fan-out: SKIPPED — no buried cell under the column's skyline\n"
        }
        let was = world.block(worldX: x, y: y, worldZ: z)

        // A clean slate before each edit, so every mark counted belongs to
        // that one edit and nothing carries over from the one before.
        func marksAfter(_ edit: () -> Void) -> Int {
            world.markMeshed(chunk)
            for neighbour in ring { world.markMeshed(neighbour) }
            edit()
            return ring.filter(\.needsRemesh).count
        }
        let broke = marksAfter { world.setBlock(worldX: x, y: y, worldZ: z, to: .air) }
        let filled = marksAfter { world.setBlock(worldX: x, y: y, worldZ: z, to: was) }

        return String(
            format: "[bench] edit fan-out: %@ — %d cells inside the chunk and %d under the"
                + " column's skyline (top %d): breaking dirtied %d of 8 neighbours,"
                + " putting it back %d of 8 (classifier pad %d)\n",
            broke == 8 && filled == 8 ? "ok" : "FAILED",
            Chunk.width / 2, top - y, top, broke, filled, ChunkMesher.pad
        )
    }

    /// Checks that walking under a tree is not mistaken for going
    /// underground.
    ///
    /// The underground trigger reveals a 5×5 square of chunks and the reveal
    /// sticks until they unload, so a test that says yes under every canopy
    /// hands the whole saving back over a few minutes of ordinary walking.
    /// Leaves occlude for the mesher on purpose, so the two questions have to
    /// be asked differently — and this is what proves they are: over a
    /// standing spot under a tree the mesher's test says the sky is blocked
    /// and the trigger's says it is not, while four blocks under the ground
    /// both say blocked.
    private static func canopyCheck(world: World, near position: (x: Double, z: Double)) -> String {
        let originX = Int(position.x.rounded(.down)), originZ = Int(position.z.rounded(.down))
        var spot: (x: Int, z: Int, ground: Int)?
        search: for radius in 0..<48 {
            for dz in -radius...radius {
                for dx in -radius...radius where abs(dx) == radius || abs(dz) == radius {
                    let x = originX + dx, z = originZ + dz
                    var top = Chunk.height - 1
                    while top > 0, !world.block(worldX: x, y: top, worldZ: z).isOpaque { top -= 1 }
                    guard world.block(worldX: x, y: top, worldZ: z) == .leaves else { continue }
                    // Walkable ground under the canopy: a solid floor that
                    // is not itself part of the tree, two cells of standing
                    // room over it, and the leaves higher still. Scanning
                    // for the first solid block alone lands inside the
                    // canopy — leaves are solid — or on the trunk.
                    var ground = top - 1
                    while ground > 0 {
                        let floor = world.block(worldX: x, y: ground, worldZ: z)
                        if floor.isSolid, floor != .leaves,
                           !world.block(worldX: x, y: ground + 1, worldZ: z).isSolid,
                           !world.block(worldX: x, y: ground + 2, worldZ: z).isSolid { break }
                        ground -= 1
                    }
                    guard ground > 0, top - ground >= 3 else { continue }
                    spot = (x, z, ground)
                    break search
                }
            }
        }
        guard let spot else {
            return "[bench] canopy walk: SKIPPED — no tree over walkable ground nearby\n"
        }
        let eye = spot.ground + 2
        let skyOpen = world.isSkyOpen(worldX: spot.x, y: eye, worldZ: spot.z)
        let roofed = world.hasTerrainOverhead(worldX: spot.x, y: eye, worldZ: spot.z)
        let buried = world.hasTerrainOverhead(worldX: spot.x, y: spot.ground - 4, worldZ: spot.z)
        return String(
            format: "[bench] canopy walk: %@ — standing at %d,%d,%d under leaves:"
                + " sky open %@, terrain overhead %@; four blocks under the ground"
                + " terrain overhead %@\n",
            (!skyOpen && !roofed && buried) ? "ok" : "FAILED",
            spot.x, eye, spot.z, skyOpen ? "YES" : "no",
            roofed ? "YES" : "no", buried ? "yes" : "NO"
        )
    }

    /// Checks the buried-geometry split and the paths that undo it.
    ///
    /// This is the one part of the feature a frame log cannot reach and a
    /// snapshot cannot either: reveal is driven by the player editing,
    /// aiming and walking underground, and none of those can be scripted
    /// through a window. What *is* checkable without a mouse is that the
    /// split hides a real amount of geometry, that the skyline the
    /// classifier seeds from agrees with where the ground actually is, and
    /// that an edit flips the chunk to building both halves. Whether the
    /// underground trigger can tell a cave from a canopy is its own check,
    /// `canopyCheck`.
    private static func revealCheck(
        world: World, near position: (x: Double, z: Double), smooth: Bool
    ) -> String {
        // Two chunks over from the finish position, because the edit-path
        // check above has already dug in the one the player is standing in
        // and a chunk only becomes revealed once.
        let here = World.chunkCoord(
            forWorldX: Int(position.x.rounded(.down)), worldZ: Int(position.z.rounded(.down))
        )
        let coord = ChunkCoord(x: here.x + 2, z: here.z + 2)
        guard let chunk = world.chunk(at: coord), !chunk.isRevealed else {
            return "[bench] reveal path: SKIPPED — no untouched chunk near the finish position\n"
        }
        let x = chunk.originX + Chunk.width / 2, z = chunk.originZ + Chunk.depth / 2

        func build(_ faces: ChunkMesher.FaceSet) -> ChunkMesher.MeshData {
            ChunkMesher.buildMeshData(chunk: chunk, in: world, smoothShading: smooth, faces: faces)
        }
        let surface = build(.surface).vertexCount
        let both = build(.all)
        let buried = build(.buried).vertexCount

        // The ground under the finish position, and a cell well below it.
        var ground = Chunk.height - 1
        while ground > 0, !world.block(worldX: x, y: ground, worldZ: z).isSolid { ground -= 1 }
        let skyOpenAbove = world.isSkyOpen(worldX: x, y: ground + 1, worldZ: z)
        let skyOpenBelow = world.isSkyOpen(worldX: x, y: ground - 4, worldZ: z)

        // An edit is supposed to reveal the chunk it lands in, and a
        // revealed chunk is supposed to keep both halves from then on.
        let revealedBefore = chunk.isRevealed
        world.setBlock(worldX: x, y: ground + 3, worldZ: z, to: .stone)
        let revealedAfterEdit = chunk.isRevealed
        world.setBlock(worldX: x, y: ground + 3, worldZ: z, to: .air)
        for ready in world.urgentChunksToMesh(limit: 8) { world.markMeshed(ready) }

        // The underground trigger, which is the one path that fires from
        // walking rather than from an input event: a 5x5 square of chunks
        // around wherever the eye is when it stops seeing sky.
        let ringCentre = ChunkCoord(x: here.x + 4, z: here.z - 4)
        let radius = 2
        var alreadyRevealed = 0, loaded = 0
        for dz in -radius...radius {
            for dx in -radius...radius {
                guard let neighbour = world.chunk(at: ChunkCoord(x: ringCentre.x + dx,
                                                                 z: ringCentre.z + dz)) else { continue }
                loaded += 1
                if neighbour.isRevealed { alreadyRevealed += 1 }
            }
        }
        world.reveal(around: ringCentre, radius: radius)
        var ringRevealed = 0
        for dz in -radius...radius {
            for dx in -radius...radius {
                if world.chunk(at: ChunkCoord(x: ringCentre.x + dx, z: ringCentre.z + dz))?
                    .isRevealed == true { ringRevealed += 1 }
            }
        }

        let split = surface + buried == both.vertexCount && buried > 0
        let ok = split && !revealedBefore && revealedAfterEdit
            && skyOpenAbove && !skyOpenBelow
            && loaded > 0 && ringRevealed == loaded && alreadyRevealed < loaded
        return String(
            format: "[bench] reveal path: %@ — %d surface + %d buried = %d verts (%.0f%% hidden);"
                + " sky open over ground %@, four blocks under it %@;"
                + " edit revealed the chunk %@; underground ring revealed %d of %d loaded"
                + " (%d already were)\n",
            ok ? "ok" : "FAILED", surface, buried, both.vertexCount,
            100.0 * Double(buried) / Double(max(1, both.vertexCount)),
            skyOpenAbove ? "yes" : "NO", skyOpenBelow ? "YES" : "no",
            revealedBefore ? "(already was)" : (revealedAfterEdit ? "yes" : "NO"),
            ringRevealed, loaded, alreadyRevealed
        )
    }

    /// Checks that a block dropped *over* the ground darkens the ground.
    ///
    /// Sky exposure is the one thing the mesher measures which reaches
    /// further than one cell: `ChunkMesher.skyCover` marches forty blocks up
    /// a column, so placing a block high above a floor changes the vertex
    /// colours of faces well below it. That is more reach than face culling
    /// or ambient occlusion has ever needed, and it is worth proving the
    /// remesh the edit path schedules actually covers it rather than
    /// assuming the column stayed inside one chunk.
    private static func shadeBelowCheck(
        world: World, chunk: Chunk, at column: (x: Int, z: Int), smooth: Bool,
        meshUrgent: () -> Int
    ) -> String {
        guard smooth else {
            return "[bench] shade below: SKIPPED — flat-lit mesh carries no exposure\n"
        }
        // The ground under the finish position, whatever height it is.
        var surface = Chunk.height - 1
        while surface > 0,
              !world.block(worldX: column.x, y: surface, worldZ: column.z).isSolid {
            surface -= 1
        }
        // High enough over it to be unambiguously a roof rather than a
        // neighbour — nothing here is within an occlusion sample of the
        // ground — and well inside the forty-block reach.
        let roof = surface + 6
        guard roof < Chunk.height else {
            return "[bench] shade below: SKIPPED — no headroom over the finish position\n"
        }

        /// How many vertices carry any sky shade at all.
        ///
        /// Built with both halves. Exposure is the thing under test, and a
        /// surface-only build would confuse it with buried-face culling —
        /// a roof does not only shade the ground under it, it also takes
        /// that ground's sky away, which is exactly the classifier's cue to
        /// stop drawing it.
        func shaded() -> Int {
            let data = ChunkMesher.buildMeshData(
                chunk: chunk, in: world, smoothShading: smooth, faces: .all
            )
            var count = 0
            for buffer in [data.opaque, data.translucent, data.buried] {
                guard let buffer else { continue }
                for vertex in buffer.vertices where (vertex.shade >> 8) & 0xFF < 0xFF {
                    count += 1
                }
            }
            return count
        }

        let before = shaded()
        world.setBlock(worldX: column.x, y: roof, worldZ: column.z, to: .stone)
        _ = meshUrgent()
        let under = shaded()
        world.setBlock(worldX: column.x, y: roof, worldZ: column.z, to: .air)
        _ = meshUrgent()
        let after = shaded()

        let ok = under > before && after == before
        return String(
            format: "[bench] shade below: %@ — %d shaded verts, %d with a roof %d blocks up,"
                + " %d once it is gone\n",
            ok ? "ok" : "FAILED", before, under, roof - surface, after
        )
    }

    private static func line(_ name: String, mean: Double, share: Double, worst: Double) -> String {
        let padded = name.padding(toLength: 10, withPad: " ", startingAt: 0)
        return String(
            format: "[bench]   %@ %6.3f ms/frame · %5.1f ms/s · worst %6.2f ms\n",
            padded, mean * 1000, share * 1000, worst * 1000
        )
    }

    @inline(__always)
    private static func time(_ phase: inout Phase, _ body: () -> Void) {
        let started = monotonicSeconds()
        body()
        let elapsed = monotonicSeconds() - started
        phase.seconds += elapsed
        phase.worst = max(phase.worst, elapsed)
    }
}

import Foundation

/// Headless proof that the shaped blocks behave the way a player expects
/// to walk into them.
///
/// Stairs, doors, beds and panes are the first blocks in this game whose
/// collision is not the cell they sit in, and nothing about that is visible
/// in a snapshot: a picture of a staircase looks the same whether you can
/// walk up it or bounce off it. Nor can it be checked by hand without
/// building a house first. So it is checked here, the way the streaming
/// benchmark checks the edit path — a real `World`, the real
/// `PlayerController`, and a walk simulated a hundred frames a second.
///
/// `BLOCKHAVEN_CHECK_STAIRS=1`. Nothing here touches the save file; it never
/// opens a window and exits nonzero if any line fails.
enum ShapedBlockCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_STAIRS"] != nil
    }

    /// One simulated frame at 100 Hz, matching the display the physics is
    /// tuned for.
    private static let frameInterval: CGFloat = 0.01

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    static func run() -> Never {
        let world = World()
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dz in -2...2 {
            for dx in -2...2 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        // A flat stone deck laid clear of the terrain, so nothing measured
        // below is really a hill. It goes down through the ordinary edit
        // path, which is also the path every one of these blocks will
        // arrive by in the game.
        let originX = Int(spawn.x) - 8, originZ = Int(spawn.z) - 8
        var highest = 0
        for z in originZ...(originZ + 16) {
            for x in originX...(originX + 32) {
                var top = Chunk.height - 1
                while top > 0, !world.block(worldX: x, y: top, worldZ: z).isSolid { top -= 1 }
                highest = max(highest, top)
            }
        }
        let deck = highest + 2          // the deck's own y
        let ground = deck + 1           // where a player standing on it has their feet
        guard deck + 8 < Chunk.height else {
            StandardError.write(Data("[check] no headroom over the terrain\n".utf8))
            exit(2)
        }
        for z in originZ...(originZ + 16) {
            for x in originX...(originX + 32) {
                world.setBlock(worldX: x, y: deck, worldZ: z, to: .stone, remesh: false)
                for y in ground...(deck + 6) {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }

        var report = Report()
        let lane = originZ + 8

        // MARK: a staircase, ascending east
        //
        // Three treads, each a block further along and a block higher, which
        // is exactly how a placed run of stairs steps up.
        let stairX = originX + 6
        for step in 0..<3 {
            world.setBlock(worldX: stairX + step, y: ground + step, worldZ: lane,
                           to: .oakStairs(.east), remesh: false)
            // The block each stair stands on, so the run is a solid ramp
            // rather than three floating steps.
            for fill in 0..<step {
                world.setBlock(worldX: stairX + step, y: ground + fill, worldZ: lane,
                               to: .cobblestone, remesh: false)
            }
        }
        // A wall at the head of the run, so the climber comes to rest on
        // the top tread instead of walking off it and falling back to the
        // deck — which would leave the check reading the height of the
        // floor and calling it a failure to climb.
        for y in (ground + 3)...(ground + 5) {
            world.setBlock(worldX: stairX + 3, y: y, worldZ: lane, to: .cobblestone, remesh: false)
        }

        var climber = PlayerController(spawn: Vector3(CGFloat(stairX) - 2.5,
                                                      CGFloat(ground),
                                                      CGFloat(lane) + 0.5))
        settle(&climber, world: world)
        let startY = climber.position.y
        walk(&climber, direction: Vector3(1, 0, 0), frames: 260, world: world)
        // The top tread's upper quarter reaches ground + 3; anything past
        // two full blocks of climb can only have come from walking up.
        report.check(
            "climbs stairs without jumping",
            climber.position.y >= startY + 2.0 && climber.position.x > CGFloat(stairX + 2),
            String(format: "started at y %.2f, finished at y %.2f, x %.2f (top tread y %d)",
                   startY, climber.position.y, climber.position.x, ground + 3)
        )

        // MARK: a closed door and an open one, each in a wall
        //
        // The wall matters: a door on its own could be walked round, and
        // then "blocked" would be measuring the wrong thing.
        let doorX = originX + 14
        let closedZ = lane - 3, openZ = lane + 3
        for (z, open) in [(closedZ, false), (openZ, true)] {
            for offset in -2...2 where offset != 0 {
                for y in ground...(ground + 1) {
                    world.setBlock(worldX: doorX, y: y, worldZ: z + offset,
                                   to: .planks, remesh: false)
                }
            }
            world.setBlock(worldX: doorX, y: ground, worldZ: z,
                           to: .oakDoor(.lower, facing: .west, open: open), remesh: false)
            world.setBlock(worldX: doorX, y: ground + 1, worldZ: z,
                           to: .oakDoor(.upper, facing: .west, open: open), remesh: false)
        }

        var atClosed = PlayerController(spawn: Vector3(CGFloat(doorX) - 2.5,
                                                       CGFloat(ground),
                                                       CGFloat(closedZ) + 0.5))
        settle(&atClosed, world: world)
        walk(&atClosed, direction: Vector3(1, 0, 0), frames: 200, world: world)
        report.check(
            "blocked by a closed door",
            atClosed.position.x < CGFloat(doorX),
            String(format: "stopped at x %.2f, door cell x %d", atClosed.position.x, doorX)
        )

        var atOpen = PlayerController(spawn: Vector3(CGFloat(doorX) - 2.5,
                                                     CGFloat(ground),
                                                     CGFloat(openZ) + 0.5))
        settle(&atOpen, world: world)
        walk(&atOpen, direction: Vector3(1, 0, 0), frames: 200, world: world)
        report.check(
            "walks through an open door",
            atOpen.position.x > CGFloat(doorX + 1),
            String(format: "reached x %.2f, door cell x %d", atOpen.position.x, doorX)
        )

        // MARK: a bed, and a full block for contrast
        //
        // The bed is the case auto-step has to take and the full block is
        // the case it must refuse, so they are measured the same way and
        // read against each other.
        let bedX = originX + 22
        world.setBlock(worldX: bedX, y: ground, worldZ: lane,
                       to: .bed(.foot, facing: .east), remesh: false)
        world.setBlock(worldX: bedX + 1, y: ground, worldZ: lane,
                       to: .bed(.head, facing: .east), remesh: false)
        world.setBlock(worldX: bedX, y: ground, worldZ: lane + 4, to: .cobblestone, remesh: false)
        // Stops the walker on the bed rather than off the far end of it.
        for y in ground...(ground + 2) {
            world.setBlock(worldX: bedX + 2, y: y, worldZ: lane, to: .cobblestone, remesh: false)
        }

        var onBed = PlayerController(spawn: Vector3(CGFloat(bedX) - 2.5,
                                                    CGFloat(ground),
                                                    CGFloat(lane) + 0.5))
        settle(&onBed, world: world)
        walk(&onBed, direction: Vector3(1, 0, 0), frames: 200, world: world)
        let bedTop = CGFloat(ground) + BlockType.bedHeight

        var atCube = PlayerController(spawn: Vector3(CGFloat(bedX) - 2.5,
                                                     CGFloat(ground),
                                                     CGFloat(lane) + 4.5))
        settle(&atCube, world: world)
        walk(&atCube, direction: Vector3(1, 0, 0), frames: 200, world: world)

        report.check(
            "steps onto a bed",
            abs(onBed.position.y - bedTop) < 0.02 && onBed.position.x > CGFloat(bedX),
            String(format: "stood at y %.4f (bed top %.4f), x %.2f",
                   onBed.position.y, bedTop, onBed.position.x)
        )
        report.check(
            "does not step onto a full block",
            atCube.position.y < CGFloat(ground) + 0.01 && atCube.position.x < CGFloat(bedX),
            String(format: "stayed at y %.4f, stopped at x %.2f (block cell x %d)",
                   atCube.position.y, atCube.position.x, bedX)
        )

        // MARK: a glass pane in a wall
        let paneX = originX + 28
        for offset in -2...2 where offset != 0 {
            for y in ground...(ground + 1) {
                world.setBlock(worldX: paneX, y: y, worldZ: lane + offset,
                               to: .planks, remesh: false)
            }
        }
        for y in ground...(ground + 1) {
            world.setBlock(worldX: paneX, y: y, worldZ: lane, to: .glassPane, remesh: false)
        }

        var atPane = PlayerController(spawn: Vector3(CGFloat(paneX) - 2.5,
                                                     CGFloat(ground),
                                                     CGFloat(lane) + 0.5))
        settle(&atPane, world: world)
        walk(&atPane, direction: Vector3(1, 0, 0), frames: 200, world: world)
        report.check(
            "cannot clip through a pane",
            atPane.position.x < CGFloat(paneX) + BlockType.paneHalf,
            String(format: "stopped at x %.2f, pane cell x %d (post starts at %.4f)",
                   atPane.position.x, paneX, CGFloat(paneX) + BlockType.paneHalf)
        )

        // MARK: a free-standing run of panes, walked alongside
        //
        // The pane above sits in a wall, where the wall hides any collision
        // box that is wider than the glass. A glass fence hides nothing: a
        // pane connected only east-west draws no north-south arm, so a box
        // spanning the cell that way would stop a player walking past it
        // with 0.09 of a block of daylight between them and the glass.
        let fenceZ = lane + 6
        let fenceX = originX + 4
        for step in 0..<6 {
            world.setBlock(worldX: fenceX + step, y: ground, worldZ: fenceZ,
                           to: .glassPane, remesh: false)
        }
        // Offset north of the run by enough that the player's leading face
        // (0.3 from their centre) stops short of the glass at fenceZ + 7/16.
        let laneZ = CGFloat(fenceZ) + 0.05
        var alongside = PlayerController(spawn: Vector3(CGFloat(fenceX) - 2.5,
                                                        CGFloat(ground), laneZ))
        settle(&alongside, world: world)
        walk(&alongside, direction: Vector3(1, 0, 0), frames: 300, world: world)
        report.check(
            "walks past a run of panes without hitting anything invisible",
            alongside.position.x > CGFloat(fenceX + 6),
            String(format: "reached x %.2f past a run at x %d…%d (walker's south face %.4f, glass starts %.4f)",
                   alongside.position.x, fenceX, fenceX + 5,
                   laneZ + PlayerController.halfWidth,
                   CGFloat(fenceZ) + BlockType.paneHalf)
        )
        // …and still cannot walk *into* one of the same panes.
        var intoFence = PlayerController(spawn: Vector3(CGFloat(fenceX) + 2.5,
                                                        CGFloat(ground),
                                                        CGFloat(fenceZ) - 2.5))
        settle(&intoFence, world: world)
        walk(&intoFence, direction: Vector3(0, 0, 1), frames: 200, world: world)
        report.check(
            "still cannot walk through the run",
            intoFence.position.z < CGFloat(fenceZ) + BlockType.paneHalf,
            String(format: "stopped at z %.2f, glass starts %.4f",
                   intoFence.position.z, CGFloat(fenceZ) + BlockType.paneHalf)
        )

        // MARK: what a pane reaches for
        //
        // A pane grows an arm toward anything that looks like a wall, and
        // the things it used to miss were exactly the ones a window is
        // built out of: glass, a door frame, the stair beside it.
        let reachX = originX + 4
        let reachZ = lane + 3
        world.setBlock(worldX: reachX, y: ground, worldZ: reachZ, to: .glassPane, remesh: false)
        world.setBlock(worldX: reachX - 1, y: ground, worldZ: reachZ, to: .glass, remesh: false)
        world.setBlock(worldX: reachX + 1, y: ground, worldZ: reachZ,
                       to: .oakDoor(.lower, facing: .west, open: false), remesh: false)
        world.setBlock(worldX: reachX, y: ground, worldZ: reachZ - 1,
                       to: .oakStairs(.south), remesh: false)
        let reach = ShapedBlocks.paneConnections(atX: reachX, y: ground, z: reachZ, world: world)
        report.check(
            "a pane reaches glass, a door and a stair",
            reach.has(.west) && reach.has(.east) && reach.has(.north) && !reach.has(.south),
            "west(glass) \(reach.has(.west)), east(door) \(reach.has(.east)),"
                + " north(stair) \(reach.has(.north)), south(air) \(reach.has(.south))"
        )

        // MARK: the mesh actually has geometry for all of it
        //
        // Cheap, and it is the one thing that would otherwise be found only
        // by looking at a picture: a shaped block whose parts all cull away
        // collides correctly and draws nothing at all.
        let stairChunk = World.chunkCoord(forWorldX: stairX, worldZ: lane)
        if let chunk = world.chunk(at: stairChunk) {
            let vertices = ChunkMesher.buildMeshData(
                chunk: chunk, in: world, smoothShading: true, faces: .all
            ).vertexCount
            world.setBlock(worldX: stairX, y: ground, worldZ: lane, to: .air, remesh: false)
            let without = ChunkMesher.buildMeshData(
                chunk: chunk, in: world, smoothShading: true, faces: .all
            ).vertexCount
            world.setBlock(worldX: stairX, y: ground, worldZ: lane,
                           to: .oakStairs(.east), remesh: false)
            report.check(
                "a stair meshes to real geometry",
                vertices > without,
                "\(vertices) verts with the bottom stair, \(without) without it"
            )
        } else {
            report.check("a stair meshes to real geometry", false, "no chunk at the staircase")
        }

        // MARK: a shaped face is as bright as the cube beside it
        //
        // The two paths deliver the same per-direction tint by different
        // routes: a cube samples a pre-darkened atlas variant, a shaped
        // face samples the full-bright one and carries its whole shade in
        // the vertex colour. The sheet has eight steps, so the cube's tint
        // is quantised on the way in and the shaped one was not — up to
        // 4.8% apart on the same wall, which reads as an outline drawn
        // round the staircase. What matters is the product of the two, and
        // that is what this measures, straight out of the built mesh.
        let probe = (x: originX + 30, y: ground + 3, z: lane)
        let probeCoord = World.chunkCoord(forWorldX: probe.x, worldZ: probe.z)
        if let probeChunk = world.chunk(at: probeCoord) {
            let lx = Float(probe.x - probeChunk.originX)
            let ly = Float(probe.y)
            let lz = Float(probe.z - probeChunk.originZ)

            /// Every quad of the probe cell, by face direction, as the
            /// brightness its texels really arrive at.
            func probeFaces(_ block: BlockType) -> [Int: Float] {
                world.setBlock(worldX: probe.x, y: probe.y, worldZ: probe.z,
                               to: block, remesh: false)
                let data = ChunkMesher.buildMeshData(
                    chunk: probeChunk, in: world, smoothShading: true, faces: .all
                )
                var byDirection: [Int: Float] = [:]
                for buffer in [data.opaque, data.translucent, data.buried].compactMap({ $0 }) {
                    let vertices = buffer.vertices
                    for start in stride(from: 0, to: vertices.count - 3, by: 4) {
                        let quad = Array(vertices[start..<(start + 4)])
                        guard quad.allSatisfy({
                            $0.px >= lx - 0.001 && $0.px <= lx + 1.001
                                && $0.py >= ly - 0.001 && $0.py <= ly + 1.001
                                && $0.pz >= lz - 0.001 && $0.pz <= lz + 1.001
                        }) else { continue }
                        let direction = Int(quad[0].nx) * 9 + Int(quad[0].ny) * 3 + Int(quad[0].nz)
                        byDirection[direction] = effectiveShade(quad)
                    }
                }
                return byDirection
            }

            let cube = probeFaces(.planks)
            let stair = probeFaces(.oakStairs(.north))
            world.setBlock(worldX: probe.x, y: probe.y, worldZ: probe.z, to: .air, remesh: false)

            let shared = cube.keys.filter { stair[$0] != nil }.sorted()
            let worst = shared.map { abs(cube[$0]! - stair[$0]!) }.max() ?? 1
            report.check(
                "a shaped face lights like the cube beside it",
                shared.count == 6 && worst <= 0.01,
                shared.map {
                    String(format: "%+d: cube %.4f stair %.4f", $0, cube[$0]!, stair[$0]!)
                }.joined(separator: ", ")
                    + String(format: " — worst %.4f over %d faces", worst, shared.count)
            )
        } else {
            report.check("a shaped face lights like the cube beside it", false, "no chunk at the probe")
        }

        report.lines.append(
            "[check] " + (report.failed ? "FAILED" : "all passed")
                + " — deck y \(deck), player ground y \(ground)"
        )
        StandardError.write(Data((report.lines.joined(separator: "\n") + "\n").utf8))
        exit(report.failed ? 1 : 0)
    }

    /// What a quad's texels are multiplied by before the shader divides the
    /// baked tint back out: the brightness of the atlas variant it samples,
    /// times the ratio its vertices carry. A cube puts nearly all of that in
    /// the variant and a shaped face puts all of it in the vertices, which
    /// is exactly why the product is the thing worth measuring.
    ///
    /// The variant is recovered from the UV: a tile's eight shaded copies
    /// are consecutive slots, so the slot's remainder is its shade index.
    private static func effectiveShade(_ quad: [ChunkMesher.Vertex]) -> Float {
        let u = quad.reduce(0) { $0 + $1.u } / 4
        let v = quad.reduce(0) { $0 + $1.v } / 4
        let column = Int(u * Float(TextureAtlas.columns))
        let row = Int((1 - v) * Float(TextureAtlas.rows))
        let slot = row * TextureAtlas.columns + column
        let variant = Float(TextureAtlas.brightness(forIndex: slot % TextureAtlas.shadeLevels))
        let ratio = Float(quad[0].shade & 0xFF) / 255 * ChunkMesher.shadeScale
        return variant * ratio
    }

    /// Lets a freshly placed player fall onto whatever is under them, so a
    /// walk starts from the ground rather than mid-drop.
    private static func settle(_ player: inout PlayerController, world: World) {
        for _ in 0..<120 {
            player.step(dt: frameInterval, moveDirection: .zero,
                        wantsUp: false, wantsDown: false, world: world)
            if player.isGrounded { break }
        }
    }

    /// Holds one direction down for a while. No jump — that is the point of
    /// every stair line above.
    private static func walk(
        _ player: inout PlayerController, direction: Vector3, frames: Int, world: World
    ) {
        for _ in 0..<frames {
            player.step(dt: frameInterval, moveDirection: direction,
                        wantsUp: false, wantsDown: false, world: world)
        }
    }
}

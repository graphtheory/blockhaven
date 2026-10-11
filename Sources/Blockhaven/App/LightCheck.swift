import Foundation

/// Headless proof that torchlight is a light and not a picture of one.
///
/// A snapshot of a lit cave answers "is it orange in there" and nothing
/// else. It cannot say whether the pool falls off by one level a block,
/// whether taking the torch out puts the dark back, whether two torches
/// overlap or fight, or whether light that crossed a chunk seam survives
/// the chunk being rebuilt — and every one of those is a bug that looks
/// fine in one still frame and wrong the moment anyone plays.
///
/// The removal sweep is the reason this file exists. Spreading light is
/// easy and obvious; *unspreading* it is the half with the subtle failure,
/// where a pool left behind by a deleted torch stays lit forever because
/// nothing walked back over it.
///
/// `BLOCKHAVEN_CHECK_LIGHT=1`. Exits nonzero if any line fails.
enum LightCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_LIGHT"] != nil
    }

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

        var report = Report()

        // A room hollowed out well underground, so nothing here is sky and
        // every lit cell had to be lit by the torch. The shell goes in
        // first and it goes in as stone, because at this depth the walls
        // the hollowing leaves are not reliably dark: gold and diamond ore
        // glow now, and a vein on the room's boundary — or a lit cave the
        // room happens to nick — would strand light in a sweep whose whole
        // claim is that the torch was the only source.
        let originX = Int(spawn.x), originZ = Int(spawn.z)
        let floorY = 24
        for y in (floorY - 1)...(floorY + 5) {
            for z in (originZ - 9)...(originZ + 9) {
                for x in (originX - 9)...(originX + 9) {
                    let interior = y >= floorY && y <= floorY + 4
                        && abs(z - originZ) <= 8 && abs(x - originX) <= 8
                    world.setBlock(worldX: x, y: y, worldZ: z,
                                   to: interior ? .air : .stone, remesh: false)
                }
            }
        }

        let dark = world.lightLevel(worldX: originX, y: floorY + 1, worldZ: originZ)
        report.check(
            "an unlit room is dark",
            dark == 0,
            "light \(dark) at the middle of a hollowed room"
        )

        // The torch stands on the floor of the room.
        world.setBlock(worldX: originX, y: floorY + 1, worldZ: originZ, to: .torch)
        let atSource = world.lightLevel(worldX: originX, y: floorY + 1, worldZ: originZ)
        report.check(
            "a torch lights its own cell",
            atSource == BlockType.torch.lightEmission,
            "light \(atSource), emission \(BlockType.torch.lightEmission)"
        )

        // One level a block, along a straight open run.
        var falloff: [UInt8] = []
        for step in 0...6 {
            falloff.append(world.lightLevel(worldX: originX + step, y: floorY + 1, worldZ: originZ))
        }
        let stepsDown = zip(falloff, falloff.dropFirst()).allSatisfy { $0 == $1 + 1 }
        report.check(
            "it falls off one level a block",
            stepsDown,
            falloff.map(String.init).joined(separator: " → ")
        )

        // Light does not pass through rock. A wall one cell from the torch
        // has to leave the cell behind it darker than the cell beside it.
        world.setBlock(worldX: originX - 2, y: floorY + 1, worldZ: originZ, to: .stone)
        let shadowed = world.lightLevel(worldX: originX - 3, y: floorY + 1, worldZ: originZ)
        let open = world.lightLevel(worldX: originX + 3, y: floorY + 1, worldZ: originZ)
        report.check(
            "a wall casts a shadow",
            shadowed < open,
            "\(shadowed) behind the wall against \(open) the same distance the other way"
        )

        // And taking the wall away lets the light back in — the "a hole
        // opened in something solid" arm, which has no unwind to do and has
        // to pull light in from its neighbours instead.
        world.setBlock(worldX: originX - 2, y: floorY + 1, worldZ: originZ, to: .air)
        let refilled = world.lightLevel(worldX: originX - 3, y: floorY + 1, worldZ: originZ)
        report.check(
            "and breaking it lets the light back in",
            refilled == open,
            "\(refilled) behind where the wall was, against \(open) the other way"
        )

        // Two torches: the brighter wins where the pools overlap, and
        // neither erases the other.
        world.setBlock(worldX: originX + 6, y: floorY + 1, worldZ: originZ, to: .torch)
        let between = world.lightLevel(worldX: originX + 3, y: floorY + 1, worldZ: originZ)
        report.check(
            "two torches overlap rather than fight",
            between == BlockType.torch.lightEmission - 3,
            "light \(between) three blocks from one and three from the other"
        )

        // The removal sweep. Taking one torch out has to leave the *other*
        // one's pool intact — this is the case a naive unwind gets wrong,
        // because the cells between the two are dimmer than the torch being
        // removed and get swept to zero before anything refills them.
        world.setBlock(worldX: originX + 6, y: floorY + 1, worldZ: originZ, to: .air)
        let afterOne = world.lightLevel(worldX: originX + 3, y: floorY + 1, worldZ: originZ)
        report.check(
            "removing one torch leaves the other's pool",
            afterOne == BlockType.torch.lightEmission - 3,
            "light \(afterOne) three blocks from the torch that is still there"
        )

        // And taking the last one out puts the dark back everywhere, with
        // nothing stranded behind.
        world.setBlock(worldX: originX, y: floorY + 1, worldZ: originZ, to: .air)
        var stranded = 0
        var brightest: UInt8 = 0
        for y in floorY...(floorY + 4) {
            for z in (originZ - 8)...(originZ + 8) {
                for x in (originX - 8)...(originX + 8) {
                    let level = world.lightLevel(worldX: x, y: y, worldZ: z)
                    if level > 0 { stranded += 1 }
                    brightest = max(brightest, level)
                }
            }
        }
        report.check(
            "and removing the last one puts the dark back",
            stranded == 0,
            stranded == 0
                ? "every cell of the room back to 0"
                : "\(stranded) cells still lit, brightest \(brightest)"
        )

        // Light crosses a chunk seam. The torch goes one block from the
        // boundary and the reading is taken in the next chunk along, which
        // is a different `Chunk` object with its own light array.
        let seamCoord = ChunkCoord(x: centre.x, z: centre.z)
        let seamX = seamCoord.x * Chunk.width + Chunk.width - 1
        let seamZ = seamCoord.z * Chunk.depth + 4
        for y in floorY...(floorY + 3) {
            for x in (seamX - 3)...(seamX + 4) {
                world.setBlock(worldX: x, y: y, worldZ: seamZ, to: .air, remesh: false)
            }
        }
        world.setBlock(worldX: seamX, y: floorY + 1, worldZ: seamZ, to: .torch)
        let acrossX = seamX + 2
        let acrossCoord = World.chunkCoord(forWorldX: acrossX, worldZ: seamZ)
        let across = world.lightLevel(worldX: acrossX, y: floorY + 1, worldZ: seamZ)
        report.check(
            "light crosses a chunk seam",
            acrossCoord != seamCoord && across == BlockType.torch.lightEmission - 2,
            "light \(across) two blocks over, in chunk \(acrossCoord.x),\(acrossCoord.z)"
                + " from a torch in \(seamCoord.x),\(seamCoord.z)"
        )

        // The mesher has to actually carry it. Build the chunk the torch is
        // in and read back the alpha byte the vertices were given: this is
        // the one line that proves the light reaches the picture and not
        // just the array.
        let chunk = world.chunk(at: seamCoord)
        var litVertices = 0
        var brightestVertex: UInt32 = 0
        if let chunk {
            let neighbourhood = ChunkMesher.gatherNeighbourhood(chunk: chunk, in: world)
            let mesh = ChunkMesher.buildMeshData(from: neighbourhood, smoothShading: true)
            for buffer in [mesh.opaque, mesh.buried].compactMap({ $0 }) {
                for vertex in buffer.vertices {
                    let torch = vertex.shade >> 24
                    if torch > 0 { litVertices += 1 }
                    brightestVertex = max(brightestVertex, torch)
                }
            }
        }
        report.check(
            "and the mesh carries it into the vertices",
            litVertices > 0 && brightestVertex > 128,
            "\(litVertices) lit vertices, brightest alpha \(brightestVertex) of 255"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the light\n"
            : "[check] all passed — the light\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

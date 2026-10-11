import Foundation

/// Headless proof that water poured out goes somewhere, rather than
/// sitting exactly where it was placed forever: it falls, it pools across
/// a flat surface up to a real limit, and it stops at whatever is actually
/// in its way — the one behaviour that turns a bucket from "a way to move
/// one cube" into a way to shape where water is.
///
/// `BLOCKHAVEN_CHECK_WATERFLOW=1`. Exits nonzero if any line fails.
enum WaterFlowCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_WATERFLOW"] != nil
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
        var report = Report()
        let world = World()
        let spawn = world.spawnPosition()
        let originX = Int(spawn.x), originZ = Int(spawn.z)
        let half = 20
        for cz in stride(from: -half, through: half, by: Chunk.depth) {
            for cx in stride(from: -half, through: half, by: Chunk.width) {
                world.forceGenerate(World.chunkCoord(forWorldX: originX + cx, worldZ: originZ + cz))
            }
        }
        // A dead-flat carved slab, well clear of the real terrain, so every
        // assertion below is about the spread rule and nothing the
        // generator happened to leave lying around.
        let deckY = 60
        for dz in -half...half {
            for dx in -half...half {
                world.setBlock(worldX: originX + dx, y: deckY - 1, worldZ: originZ + dz, to: .stone, remesh: false)
                for y in deckY...(deckY + 8) {
                    world.setBlock(worldX: originX + dx, y: y, worldZ: originZ + dz, to: .air, remesh: false)
                }
            }
        }

        // MARK: falls until it lands, then pools rather than climbing back out

        let shaft = (x: originX - 15, y: deckY, z: originZ - 15)
        for dy in 1...5 {
            world.setBlock(worldX: shaft.x, y: shaft.y - dy, worldZ: shaft.z, to: .air, remesh: false)
        }
        world.setBlock(worldX: shaft.x, y: shaft.y - 6, worldZ: shaft.z, to: .stone, remesh: false)
        WaterFlow.spread(from: (shaft.x, shaft.y, shaft.z), world: world)
        var fellThrough = true
        for dy in 1...5 where world.block(worldX: shaft.x, y: shaft.y - dy, worldZ: shaft.z) != .water {
            fellThrough = false
        }
        report.check(
            "water dropped down an open shaft falls all the way to the floor",
            fellThrough,
            "column \(shaft.x),\(shaft.z) from y \(shaft.y - 1) to \(shaft.y - 5): "
                + (1...5).map { String(describing: world.block(worldX: shaft.x, y: shaft.y - $0, worldZ: shaft.z)) }.joined(separator: ",")
        )
        report.check(
            "and does not also climb back up past where it was poured",
            world.block(worldX: shaft.x, y: shaft.y + 1, worldZ: shaft.z) == .air,
            "cell above the pour point: \(String(describing: world.block(worldX: shaft.x, y: shaft.y + 1, worldZ: shaft.z)))"
        )

        // MARK: spreads across a flat surface, capped rather than endless

        let pool = (x: originX, y: deckY, z: originZ)
        WaterFlow.spread(from: pool, world: world)
        let reachedCap = world.block(
            worldX: pool.x + WaterFlow.maxHorizontalReach, y: pool.y, worldZ: pool.z
        ) == .water
        let stoppedPastCap = world.block(
            worldX: pool.x + WaterFlow.maxHorizontalReach + 1, y: pool.y, worldZ: pool.z
        ) == .air
        report.check(
            "water spreads across flat ground out to its full reach",
            reachedCap,
            "cell \(WaterFlow.maxHorizontalReach) out: \(String(describing: world.block(worldX: pool.x + WaterFlow.maxHorizontalReach, y: pool.y, worldZ: pool.z)))"
        )
        report.check(
            "and not one cell further",
            stoppedPastCap,
            "cell \(WaterFlow.maxHorizontalReach + 1) out: "
                + "\(String(describing: world.block(worldX: pool.x + WaterFlow.maxHorizontalReach + 1, y: pool.y, worldZ: pool.z)))"
        )

        // MARK: stops at whatever is actually solid, rather than passing through it

        let wallX = originX + 10
        for y in deckY...(deckY + 3) {
            world.setBlock(worldX: wallX, y: y, worldZ: originZ, to: .stone, remesh: false)
        }
        WaterFlow.spread(from: (wallX - 3, deckY, originZ), world: world)
        report.check(
            "a wall stops the spread rather than being flooded through",
            world.block(worldX: wallX + 1, y: deckY, worldZ: originZ) == .air,
            "cell just past the wall: \(String(describing: world.block(worldX: wallX + 1, y: deckY, worldZ: originZ)))"
        )

        // MARK: a bucket emptied against the world pours, not just places

        let pourCell = (x: originX - 6, y: deckY, z: originZ + 10)
        let poured = BucketInteraction.empty(at: pourCell, world: world, playerOverlaps: false)
        let spreadNeighbor = world.block(worldX: pourCell.x + 1, y: pourCell.y, worldZ: pourCell.z) == .water
        report.check(
            "emptying a bucket against open flat ground spreads, not just fills one cell",
            poured && spreadNeighbor,
            "poured: \(poured), neighbour: \(String(describing: world.block(worldX: pourCell.x + 1, y: pourCell.y, worldZ: pourCell.z)))"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the water flow\n"
            : "[check] all passed — the water flow\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

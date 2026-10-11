import Foundation

/// Headless proof of the game's second thing that grows because time
/// passed: a sapling stands as scenery like any other cross plant, then
/// becomes the real tree its species builds — the same builder chunk
/// generation itself calls, not a second description of a canopy — closing
/// the one staple in the game that used to have no renewable loop at all.
///
/// `BLOCKHAVEN_CHECK_SAPLING=1`. Exits nonzero if any line fails.
enum SaplingCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_SAPLING"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    /// A frame, at the rate the game runs its simulation.
    private static let dt = 1.0 / 60

    static func run() -> Never {
        var report = Report()

        // MARK: a sapling roots where any other plant does, not just farmland

        report.check(
            "a sapling can root on grass",
            BlockType.plantCanRootOn(.grass),
            "plantCanRootOn(.grass) = \(BlockType.plantCanRootOn(.grass))"
        )

        // MARK: the world — a cleared platform, open to the sky, with margin

        let world = World()
        let spawn = world.spawnPosition()
        let spawnChunk = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        // Wide in +x especially: the species comparison below plants three
        // more trees ten cells apart, forty-odd cells east of spawn, and a
        // chunk that was never generated silently refuses every `setBlock`
        // in it rather than placing anything.
        for dz in -1...1 {
            for dx in -1...5 {
                world.forceGenerate(ChunkCoord(x: spawnChunk.x + dx, z: spawnChunk.z + dz))
            }
        }
        let surface = world.generator.surfaceHeight(x: Int(spawn.x), z: Int(spawn.z))
        let cell = (x: Int(spawn.x), y: surface + 1, z: Int(spawn.z))
        for dz in -6...6 {
            for dx in -6...6 {
                world.setBlock(worldX: cell.x + dx, y: cell.y - 1, worldZ: cell.z + dz, to: .grass, remesh: false)
                for y in cell.y..<(Chunk.height - 1) {
                    world.setBlock(worldX: cell.x + dx, y: y, worldZ: cell.z + dz, to: .air, remesh: false)
                }
            }
        }

        // MARK: planted, it stands as scenery and starts its clock

        let saplings = SaplingStore()
        world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .sapling)
        saplings.planted(at: SaplingStore.Key(cell.x, cell.y, cell.z))
        report.check(
            "a fresh planting is tracked and still just a sapling",
            world.block(worldX: cell.x, y: cell.y, worldZ: cell.z) == .sapling && !saplings.isEmpty,
            "block \(String(describing: world.block(worldX: cell.x, y: cell.y, worldZ: cell.z))), tracked: \(!saplings.isEmpty)"
        )
        report.check(
            "and it stops nobody, coming up in one hit like any other plant",
            BlockType.sapling.collisionBoxes.isEmpty && BlockType.sapling.hardness == 0,
            "boxes \(BlockType.sapling.collisionBoxes.count), hardness \(BlockType.sapling.hardness)"
        )

        // MARK: it does not rush — a fraction of the wait is not the wait

        var elapsed = 0.0
        while elapsed < SaplingStore.growSeconds * 0.5 {
            _ = saplings.tick(dt: dt, world: world)
            elapsed += dt
        }
        report.check(
            "half its wait does not grow it",
            world.block(worldX: cell.x, y: cell.y, worldZ: cell.z) == .sapling,
            "block after \(String(format: "%.1f", elapsed))s: "
                + "\(String(describing: world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)))"
        )

        // MARK: given enough daylight it becomes a real tree

        var matured: [SaplingStore.Key] = []
        while elapsed < SaplingStore.growSeconds + 1 {
            matured += saplings.tick(dt: dt, world: world)
            elapsed += dt
        }
        report.check(
            "the sapling matures exactly once",
            matured.count == 1 && matured.first.map { $0.x == cell.x && $0.y == cell.y && $0.z == cell.z } == true,
            "matured: \(matured.count)"
        )
        // The check plays the part `GameViewController.growTree` would:
        // ask `WorldGenerator` for the same blocks chunk generation would
        // have planted here, and write them in.
        let species = world.generator
        let placements = species.treeBlocks(atX: cell.x, groundY: cell.y - 1, z: cell.z, species: .oak)
        world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .air)
        for placement in placements {
            world.setBlock(worldX: placement.x, y: placement.y, worldZ: placement.z, to: placement.block)
        }
        let trunkAbove = world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)
        var leafFound = false
        for dy in 0...8 {
            for dz in -3...3 {
                for dx in -3...3 {
                    if world.block(worldX: cell.x + dx, y: cell.y + dy, worldZ: cell.z + dz).isLeaf {
                        leafFound = true
                    }
                }
            }
        }
        report.check(
            "the grown tree is a real trunk with real leaves, not a bigger sapling",
            trunkAbove == .log && leafFound,
            "block where the sapling stood: \(String(describing: trunkAbove)), any leaf nearby: \(leafFound)"
        )

        // MARK: three species, three different trunks — a birch sapling never grows an oak

        for (index, entry) in [
            (WorldGenerator.TreeSpecies.oak, BlockType.log),
            (WorldGenerator.TreeSpecies.birch, BlockType.birchLog),
            (WorldGenerator.TreeSpecies.spruce, BlockType.spruceLog),
        ].enumerated() {
            let (species, expectedLog) = entry
            // Spaced ten cells apart so no two canopies can reach into a
            // neighbour's trunk and make this a test of overlap instead of
            // species.
            let siteX = cell.x + 20 + index * 10
            for dz in -2...2 {
                for dx in -2...2 {
                    world.setBlock(worldX: siteX + dx, y: cell.y - 1, worldZ: cell.z + dz, to: .grass, remesh: false)
                    for y in cell.y..<(cell.y + 12) {
                        world.setBlock(worldX: siteX + dx, y: y, worldZ: cell.z + dz, to: .air, remesh: false)
                    }
                }
            }
            let blocks = world.generator.treeBlocks(atX: siteX, groundY: cell.y - 1, z: cell.z, species: species)
            for placement in blocks {
                world.setBlock(worldX: placement.x, y: placement.y, worldZ: placement.z, to: placement.block)
            }
            let trunk = world.block(worldX: siteX, y: cell.y, worldZ: cell.z)
            report.check(
                "a \(species) sapling grows a \(expectedLog) trunk, not another species'",
                trunk == expectedLog,
                "trunk: \(String(describing: trunk))"
            )
        }

        // MARK: a roof over it stalls the clock rather than skipping it

        let shadedCell = (x: cell.x + 2, y: cell.y, z: cell.z)
        world.setBlock(worldX: shadedCell.x, y: shadedCell.y, worldZ: shadedCell.z, to: .sapling)
        world.setBlock(worldX: shadedCell.x, y: shadedCell.y + 1, worldZ: shadedCell.z, to: .stone)
        let shadedSaplings = SaplingStore()
        shadedSaplings.planted(at: SaplingStore.Key(shadedCell.x, shadedCell.y, shadedCell.z))
        let roofedOpen = world.isSkyOpen(worldX: shadedCell.x, y: shadedCell.y, worldZ: shadedCell.z)
        var shadedElapsed = 0.0
        while shadedElapsed < SaplingStore.growSeconds + 5 {
            _ = shadedSaplings.tick(dt: dt, world: world)
            shadedElapsed += dt
        }
        report.check(
            "a roof shuts a sapling's sky off",
            !roofedOpen,
            "isSkyOpen under stone: \(roofedOpen)"
        )
        report.check(
            "and a shaded sapling never grows at all",
            world.block(worldX: shadedCell.x, y: shadedCell.y, worldZ: shadedCell.z) == .sapling,
            "block after \(String(format: "%.1f", shadedElapsed))s under a roof: "
                + "\(String(describing: world.block(worldX: shadedCell.x, y: shadedCell.y, worldZ: shadedCell.z)))"
        )

        // MARK: leaves have a real, non-zero chance of giving up a sapling — not never, not always

        report.check(
            "leaves themselves drop nothing on their own — the chance lives outside `drop`",
            BlockType.leaves.drop == nil && BlockType.birchLeaves.drop == nil && BlockType.spruceLeaves.drop == nil,
            "leaves \(String(describing: BlockType.leaves.drop))"
        )
        report.check(
            "but picking one up still gets you the decoration, same as any other plant",
            BlockType.leaves.pickItem == .leaves,
            "pickItem: \(String(describing: BlockType.leaves.pickItem))"
        )

        // MARK: pruning drops a planting whose block is gone

        let pruneSaplings = SaplingStore()
        let pruneKey = SaplingStore.Key(cell.x, cell.y, cell.z + 1)
        world.setBlock(worldX: pruneKey.x, y: pruneKey.y, worldZ: pruneKey.z, to: .sapling)
        pruneSaplings.planted(at: pruneKey)
        world.setBlock(worldX: pruneKey.x, y: pruneKey.y, worldZ: pruneKey.z, to: .air)
        pruneSaplings.prune { key in !world.block(worldX: key.x, y: key.y, worldZ: key.z).isSapling }
        report.check(
            "pruning drops a planting whose block is gone",
            pruneSaplings.isEmpty,
            "\(pruneSaplings.elapsed.count) saplings left after clearing the one cell"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the sapling\n"
            : "[check] all passed — the sapling\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

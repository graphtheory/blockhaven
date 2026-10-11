import Foundation

/// Headless proof of the game's first simulation that runs on its own: a
/// seed roots only in tilled ground, climbs four stages while the sky can
/// reach it and stalls the moment it can't, and pays back a harvest worth
/// more than the seed it cost — the loop that makes a farm worth building
/// rather than just another crafting recipe.
///
/// `BLOCKHAVEN_CHECK_CROP=1`. Exits nonzero if any line fails.
enum CropCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_CROP"] != nil
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

        // MARK: a seed roots only in tilled ground

        report.check(
            "a wheat seed can root on farmland",
            BlockType.cropCanRootOn(.farmland),
            "cropCanRootOn(.farmland) = \(BlockType.cropCanRootOn(.farmland))"
        )
        report.check(
            "and nowhere else — plain dirt does not till itself",
            !BlockType.cropCanRootOn(.dirt) && !BlockType.cropCanRootOn(.grass),
            "dirt \(BlockType.cropCanRootOn(.dirt)), grass \(BlockType.cropCanRootOn(.grass))"
        )

        // MARK: tall grass gives up a seed, not itself, when broken by hand

        report.check(
            "breaking tall grass hands over a seed",
            BlockType.tallGrass.drop == .wheatSeeds,
            "drop: \(String(describing: BlockType.tallGrass.drop))"
        )
        report.check(
            "but picking it still gets you the decoration",
            BlockType.tallGrass.pickItem == .tallGrass,
            "pickItem: \(String(describing: BlockType.tallGrass.pickItem))"
        )

        // MARK: the world

        let world = World()
        let spawn = world.spawnPosition()
        // A margin in every direction, not just the one chunk spawn sits
        // in: the irrigation test further down plants fields ten-odd cells
        // off, which can land a chunk or two over depending on where in
        // its own chunk spawn happens to fall.
        let spawnChunk = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dz in -1...1 {
            for dx in -1...1 {
                world.forceGenerate(ChunkCoord(x: spawnChunk.x + dx, z: spawnChunk.z + dz))
            }
        }
        let surface = world.generator.surfaceHeight(x: Int(spawn.x), z: Int(spawn.z))
        let cell = (x: Int(spawn.x), y: surface + 1, z: Int(spawn.z))
        // A clear platform, open to the sky rather than merely above the
        // ground, so nothing this check plants can be shadowed by a tree
        // or a hill it did not ask for — cleared to the world ceiling, not
        // some fixed height that terrain elsewhere might still poke through.
        for dz in -2...2 {
            for dx in -2...2 {
                world.setBlock(worldX: cell.x + dx, y: cell.y - 1, worldZ: cell.z + dz, to: .farmland, remesh: false)
                for y in cell.y..<(Chunk.height - 1) {
                    world.setBlock(worldX: cell.x + dx, y: y, worldZ: cell.z + dz, to: .air, remesh: false)
                }
            }
        }

        // MARK: planted, it stands at the first stage and starts its clock

        let crops = CropStore()
        world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .wheatStage0)
        crops.planted(at: CropStore.Key(cell.x, cell.y, cell.z))
        report.check(
            "a fresh planting is tracked from stage zero",
            world.block(worldX: cell.x, y: cell.y, worldZ: cell.z) == .wheatStage0 && !crops.isEmpty,
            "block \(String(describing: world.block(worldX: cell.x, y: cell.y, worldZ: cell.z))), tracked: \(!crops.isEmpty)"
        )

        // MARK: it does not rush — a fraction of a stage is not a stage

        var elapsed = 0.0
        while elapsed < CropStore.stageSeconds * 0.5 {
            for key in crops.tick(dt: dt, world: world) {
                let current = world.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: current.rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                }
            }
            elapsed += dt
        }
        report.check(
            "half a stage's worth of daylight does not advance it",
            world.block(worldX: cell.x, y: cell.y, worldZ: cell.z) == .wheatStage0,
            "block after \(String(format: "%.1f", elapsed))s: "
                + "\(String(describing: world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)))"
        )

        // MARK: but it climbs all four stages given enough of it

        while elapsed < CropStore.stageSeconds * 3.5 {
            for key in crops.tick(dt: dt, world: world) {
                let current = world.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: current.rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                }
            }
            elapsed += dt
        }
        let ripe = world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)
        report.check(
            "three stages of daylight later it is ripe",
            ripe == .wheatStage3,
            "block after \(String(format: "%.1f", elapsed))s: \(String(describing: ripe))"
        )
        report.check(
            "a ripe planting is dropped from tracking — nothing left to grow",
            crops.tick(dt: dt, world: world).isEmpty && crops.isEmpty,
            "still tracked: \(!crops.isEmpty)"
        )

        // MARK: a roof over it stalls the clock rather than skipping it

        let shadedCell = (x: cell.x + 1, y: cell.y, z: cell.z)
        world.setBlock(worldX: shadedCell.x, y: shadedCell.y, worldZ: shadedCell.z, to: .wheatStage0)
        world.setBlock(worldX: shadedCell.x, y: shadedCell.y + 1, worldZ: shadedCell.z, to: .stone)
        let shadedCrops = CropStore()
        shadedCrops.planted(at: CropStore.Key(shadedCell.x, shadedCell.y, shadedCell.z))
        let roofedOpen = world.isSkyOpen(worldX: shadedCell.x, y: shadedCell.y, worldZ: shadedCell.z)
        elapsed = 0
        while elapsed < CropStore.stageSeconds * 1.5 {
            _ = shadedCrops.tick(dt: dt, world: world)
            elapsed += dt
        }
        report.check(
            "a roof shuts a planting's sky off",
            !roofedOpen,
            "isSkyOpen under stone: \(roofedOpen)"
        )
        report.check(
            "and a shaded planting never advances at all",
            world.block(worldX: shadedCell.x, y: shadedCell.y, worldZ: shadedCell.z) == .wheatStage0,
            "block after \(String(format: "%.1f", elapsed))s under a roof: "
                + "\(String(describing: world.block(worldX: shadedCell.x, y: shadedCell.y, worldZ: shadedCell.z)))"
        )

        // MARK: harvest pays back more than the seed it cost

        report.check(
            "ripe wheat is worth harvesting, not just replanting",
            BlockType.wheatStage3.drop == .wheat && ItemType.wheat.foodValue != nil,
            "drop \(String(describing: BlockType.wheatStage3.drop)), food value "
                + "\(String(describing: ItemType.wheat.foodValue))"
        )
        report.check(
            "breaking it early only ever gives the seed back",
            BlockType.wheatStage0.drop == .wheatSeeds && BlockType.wheatStage1.drop == .wheatSeeds
                && BlockType.wheatStage2.drop == .wheatSeeds,
            "stage0 \(String(describing: BlockType.wheatStage0.drop)), "
                + "stage1 \(String(describing: BlockType.wheatStage1.drop)), "
                + "stage2 \(String(describing: BlockType.wheatStage2.drop))"
        )

        // MARK: water nearby hurries a planting too, the same as rain does

        // Two fresh fields well clear of each other and of the platform
        // above, one with a canal dug to it, one without — otherwise
        // identical, so the gap between them is only ever the water.
        let irrigatedCell = (x: cell.x + 10, y: cell.y, z: cell.z)
        let bareCell = (x: cell.x + 10, y: cell.y, z: cell.z + 10)
        for site in [irrigatedCell, bareCell] {
            for dz in -1...1 {
                for dx in -1...1 {
                    world.setBlock(worldX: site.x + dx, y: site.y - 1, worldZ: site.z + dz, to: .farmland, remesh: false)
                    for y in site.y..<(site.y + 4) {
                        world.setBlock(worldX: site.x + dx, y: y, worldZ: site.z + dz, to: .air, remesh: false)
                    }
                }
            }
        }
        // The canal sits at farmland height, two cells off — close enough
        // to be "irrigated", not so close it would have rooted in the
        // water instead of the farmland beside it.
        world.setBlock(worldX: irrigatedCell.x + 2, y: irrigatedCell.y - 1, worldZ: irrigatedCell.z, to: .water, remesh: false)

        world.setBlock(worldX: irrigatedCell.x, y: irrigatedCell.y, worldZ: irrigatedCell.z, to: .wheatStage0)
        world.setBlock(worldX: bareCell.x, y: bareCell.y, worldZ: bareCell.z, to: .wheatStage0)
        let irrigatedCrops = CropStore()
        let bareCrops = CropStore()
        irrigatedCrops.planted(at: CropStore.Key(irrigatedCell.x, irrigatedCell.y, irrigatedCell.z))
        bareCrops.planted(at: CropStore.Key(bareCell.x, bareCell.y, bareCell.z))

        // Long enough for the irrigated planting to have crossed a stage on
        // its boosted clock but short of the bare planting's own stage time.
        var hydrationElapsed = 0.0
        let hydrationBudget = CropStore.stageSeconds / CropStore.hydratedGrowthMultiplier + 0.5
        while hydrationElapsed < hydrationBudget {
            for key in irrigatedCrops.tick(dt: dt, world: world) {
                let current = world.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: current.rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                }
            }
            for key in bareCrops.tick(dt: dt, world: world) {
                let current = world.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: current.rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                }
            }
            hydrationElapsed += dt
        }
        let irrigatedBlock = world.block(worldX: irrigatedCell.x, y: irrigatedCell.y, worldZ: irrigatedCell.z)
        let bareBlock = world.block(worldX: bareCell.x, y: bareCell.y, worldZ: bareCell.z)
        report.check(
            "a field with a canal dug to it has advanced a stage a bare one has not",
            irrigatedBlock == .wheatStage1 && bareBlock == .wheatStage0,
            "after \(String(format: "%.1f", hydrationElapsed))s: irrigated \(String(describing: irrigatedBlock)), "
                + "bare \(String(describing: bareBlock))"
        )

        // MARK: a crop is scenery — no collision, one hit to clear

        report.check(
            "a crop stops nobody and comes up in one hit",
            BlockType.wheatStage2.collisionBoxes.isEmpty && BlockType.wheatStage2.hardness == 0,
            "boxes \(BlockType.wheatStage2.collisionBoxes.count), hardness \(BlockType.wheatStage2.hardness)"
        )

        // MARK: pruning drops what the world no longer has

        let pruneCrops = CropStore()
        let pruneKey = CropStore.Key(cell.x, cell.y, cell.z + 1)
        world.setBlock(worldX: pruneKey.x, y: pruneKey.y, worldZ: pruneKey.z, to: .wheatStage0)
        pruneCrops.planted(at: pruneKey)
        world.setBlock(worldX: pruneKey.x, y: pruneKey.y, worldZ: pruneKey.z, to: .air)
        pruneCrops.prune { key in !world.block(worldX: key.x, y: key.y, worldZ: key.z).isCrop }
        report.check(
            "pruning drops a planting whose block is gone",
            pruneCrops.isEmpty,
            "\(pruneCrops.elapsed.count) plantings left after clearing the one cell"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the crop\n"
            : "[check] all passed — the crop\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

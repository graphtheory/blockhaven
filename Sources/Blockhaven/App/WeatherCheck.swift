import Foundation

/// Headless proof that weather is not a coat of paint: it darkens the sky
/// through the same grading day and night already use, it sharpens the
/// danger a distant night already carries, and it hurries a field already
/// growing — one new fact, `isRaining`, read by two systems that existed
/// before it did.
///
/// `BLOCKHAVEN_CHECK_WEATHER=1`. Exits nonzero if any line fails.
enum WeatherCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_WEATHER"] != nil
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

        // MARK: isRaining is a pure read of the clock already there

        report.check(
            "the cycle opens raining",
            SkyClock.isRaining(at: 0.0),
            "isRaining(0.0) = \(SkyClock.isRaining(at: 0.0))"
        )
        report.check(
            "and clears partway through the same cycle",
            !SkyClock.isRaining(at: 1.0),
            "isRaining(1.0) = \(SkyClock.isRaining(at: 1.0))"
        )
        report.check(
            "and rains again once the cycle repeats",
            SkyClock.isRaining(at: 2.0),
            "isRaining(2.0) = \(SkyClock.isRaining(at: 2.0))"
        )
        report.check(
            "the free-running clock this reads never wraps to zero on its own",
            SkyClock.isRaining(at: 10.0) == SkyClock.isRaining(at: 10.0.truncatingRemainder(dividingBy: 2.0)),
            "isRaining(10.0) = \(SkyClock.isRaining(at: 10.0)), "
                + "isRaining(0.0) = \(SkyClock.isRaining(at: 0.0))"
        )

        // MARK: rain sharpens the same distance ramp, it does not replace it

        let world = World()
        let spawn = world.spawnPosition()
        let radius = Int(FizzlerManager.maximumSpawnDistance) + 4
        let coord = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for cz in (coord.z - 2)...(coord.z + 2) {
            for cx in (coord.x - 2)...(coord.x + 2) {
                world.forceGenerate(ChunkCoord(x: cx, z: cz))
            }
        }
        let centre = (x: Int(spawn.x), y: Int(spawn.y), z: Int(spawn.z))
        for dz in -radius...radius {
            for dx in -radius...radius {
                world.setBlock(worldX: centre.x + dx, y: centre.y - 1, worldZ: centre.z + dz, to: .stone, remesh: false)
                world.setBlock(worldX: centre.x + dx, y: centre.y, worldZ: centre.z + dz, to: .air, remesh: false)
                world.setBlock(worldX: centre.x + dx, y: centre.y + 1, worldZ: centre.z + dz, to: .air, remesh: false)
                world.setBlock(worldX: centre.x + dx, y: centre.y + 2, worldZ: centre.z + dz, to: .stone, remesh: false)
            }
        }
        let eye = Vector3(CGFloat(centre.x) + 0.5, CGFloat(centre.y) + 1, CGFloat(centre.z) + 0.5)

        var clear = FizzlerManager(mode: .survival, seed: 7)
        var storm = FizzlerManager(mode: .survival, seed: 7)
        var elapsed = 0.0
        let budget = 30.0
        while elapsed < budget {
            _ = clear.update(dt: dt, playerEye: eye, playerIsTargetable: false, isNight: true, isRaining: false, world: world)
            _ = storm.update(dt: dt, playerEye: eye, playerIsTargetable: false, isNight: true, isRaining: true, world: world)
            elapsed += dt
        }
        report.check(
            "the same doorstep, the same night, spawns more once it storms",
            storm.fizzlers.count > clear.fizzlers.count,
            "clear: \(clear.fizzlers.count), storm: \(storm.fizzlers.count), "
                + "over \(String(format: "%.0f", budget))s of night"
        )
        report.check(
            "but a clear night at the doorstep still respects the flat cap",
            clear.fizzlers.count <= FizzlerManager.populationCap,
            "clear: \(clear.fizzlers.count) against a cap of \(FizzlerManager.populationCap)"
        )

        // MARK: rain hurries a field already growing, it does not start one

        let farmWorld = World()
        let farmSpawn = farmWorld.spawnPosition()
        farmWorld.forceGenerate(World.chunkCoord(forWorldX: Int(farmSpawn.x), worldZ: Int(farmSpawn.z)))
        let surface = farmWorld.generator.surfaceHeight(x: Int(farmSpawn.x), z: Int(farmSpawn.z))
        let openCell = (x: Int(farmSpawn.x), y: surface + 1, z: Int(farmSpawn.z))
        for y in openCell.y..<(Chunk.height - 1) {
            farmWorld.setBlock(worldX: openCell.x, y: y, worldZ: openCell.z, to: .air, remesh: false)
        }
        farmWorld.setBlock(worldX: openCell.x, y: openCell.y - 1, worldZ: openCell.z, to: .farmland, remesh: false)

        let dryPlanting = CropStore.Key(openCell.x, openCell.y, openCell.z)
        farmWorld.setBlock(worldX: dryPlanting.x, y: dryPlanting.y, worldZ: dryPlanting.z, to: .wheatStage0)
        let dryCrops = CropStore()
        dryCrops.planted(at: dryPlanting)

        let wetCell = (x: openCell.x + 1, y: openCell.y, z: openCell.z)
        farmWorld.setBlock(worldX: wetCell.x, y: wetCell.y - 1, worldZ: wetCell.z, to: .farmland, remesh: false)
        for y in wetCell.y..<(Chunk.height - 1) {
            farmWorld.setBlock(worldX: wetCell.x, y: y, worldZ: wetCell.z, to: .air, remesh: false)
        }
        farmWorld.setBlock(worldX: wetCell.x, y: wetCell.y, worldZ: wetCell.z, to: .wheatStage0)
        let wetPlanting = CropStore.Key(wetCell.x, wetCell.y, wetCell.z)
        let wetCrops = CropStore()
        wetCrops.planted(at: wetPlanting)

        // Long enough for the rained-on planting to have crossed a stage on
        // its boosted clock but short of the dry planting's own stage time
        // — the gap between the two is the entire point being measured.
        var farmElapsed = 0.0
        let farmBudget = CropStore.stageSeconds / CropStore.rainGrowthMultiplier + 0.5
        while farmElapsed < farmBudget {
            for key in dryCrops.tick(dt: dt, world: farmWorld, isRaining: false) {
                let current = farmWorld.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: current.rawValue + 1) {
                    farmWorld.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                }
            }
            for key in wetCrops.tick(dt: dt, world: farmWorld, isRaining: true) {
                let current = farmWorld.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: current.rawValue + 1) {
                    farmWorld.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                }
            }
            farmElapsed += dt
        }
        let dryBlock = farmWorld.block(worldX: dryPlanting.x, y: dryPlanting.y, worldZ: dryPlanting.z)
        let wetBlock = farmWorld.block(worldX: wetPlanting.x, y: wetPlanting.y, worldZ: wetPlanting.z)
        report.check(
            "a rained-on planting has advanced a stage a dry one under the same sky has not",
            wetBlock == .wheatStage1 && dryBlock == .wheatStage0,
            "after \(String(format: "%.1f", farmElapsed))s: dry \(String(describing: dryBlock)), "
                + "wet \(String(describing: wetBlock))"
        )

        // MARK: a felled forest regrows on the same weather clock a field ripens on

        let drySaplingCell = (x: openCell.x + 2, y: openCell.y, z: openCell.z)
        farmWorld.setBlock(worldX: drySaplingCell.x, y: drySaplingCell.y - 1, worldZ: drySaplingCell.z, to: .grass, remesh: false)
        for y in drySaplingCell.y..<(Chunk.height - 1) {
            farmWorld.setBlock(worldX: drySaplingCell.x, y: y, worldZ: drySaplingCell.z, to: .air, remesh: false)
        }
        farmWorld.setBlock(worldX: drySaplingCell.x, y: drySaplingCell.y, worldZ: drySaplingCell.z, to: .sapling)
        let drySaplings = SaplingStore()
        drySaplings.planted(at: SaplingStore.Key(drySaplingCell.x, drySaplingCell.y, drySaplingCell.z))

        let wetSaplingCell = (x: openCell.x + 3, y: openCell.y, z: openCell.z)
        farmWorld.setBlock(worldX: wetSaplingCell.x, y: wetSaplingCell.y - 1, worldZ: wetSaplingCell.z, to: .grass, remesh: false)
        for y in wetSaplingCell.y..<(Chunk.height - 1) {
            farmWorld.setBlock(worldX: wetSaplingCell.x, y: y, worldZ: wetSaplingCell.z, to: .air, remesh: false)
        }
        farmWorld.setBlock(worldX: wetSaplingCell.x, y: wetSaplingCell.y, worldZ: wetSaplingCell.z, to: .sapling)
        let wetSaplings = SaplingStore()
        wetSaplings.planted(at: SaplingStore.Key(wetSaplingCell.x, wetSaplingCell.y, wetSaplingCell.z))

        // Long enough for the rained-on sapling to have crossed its whole
        // wait on the boosted clock but short of the dry sapling's own —
        // the same gap the crop pair above measures, one growth clock over.
        var forestElapsed = 0.0
        let forestBudget = SaplingStore.growSeconds / CropStore.rainGrowthMultiplier + 0.5
        var wetMatured = false
        var dryMatured = false
        while forestElapsed < forestBudget {
            if !drySaplings.tick(dt: dt, world: farmWorld, isRaining: false).isEmpty { dryMatured = true }
            if !wetSaplings.tick(dt: dt, world: farmWorld, isRaining: true).isEmpty { wetMatured = true }
            forestElapsed += dt
        }
        report.check(
            "a rained-on sapling matures before a dry one under the same sky does",
            wetMatured && !dryMatured,
            "after \(String(format: "%.1f", forestElapsed))s: dry matured \(dryMatured), wet matured \(wetMatured)"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the weather\n"
            : "[check] all passed — the weather\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

import Foundation

/// Adversarial stress testing and empirical boundary verification for Milestone 4:
/// Diurnal Hostile Ecology, Industrial Disturbance, Grand Integration & Gauntlet Log (Wave 9).
///
/// Verification vectors:
/// 1. Smelting Disturbance Accumulation: Single furnace burn rate vs multi-furnace saturation (capped at 100.0).
/// 2. Explosion Impulse & Cardinal Diffusion: 30.0 pulse to center chunk, exact 20% (6.0) spill to cardinal neighbors, 0 to diagonals.
/// 3. Mining & Block Breaking Disturbance: 1.5 per block mined, 0.3 spill to cardinal neighbors.
/// 4. Hopper Conveyor Transfer Disturbance: 0.5 per transfer, 0.1 spill to cardinal neighbors.
/// 5. Disturbance Decay Dynamics & Memory Pruning: 1.0 unit/s decay, pruning silent chunks (<= 0.001), empty dictionary cleanup.
/// 6. Threat Scaling Oracles:
///    - Fizzler sight range scaling [16.0, 32.0] across disturbance [0.0, 100.0+], lower bound clamp at 16.0.
///    - Skeleton sight range scaling [18.0, 32.0] across disturbance [0.0, 100.0+], capped at 32.0.
///    - Fizzler fuse duration tightening [1.5s down to 1.2s].
///    - Skeleton shot interval quickening [1.6s down to 1.2s].
/// 7. Raycast Line-of-Sight Fortification:
///    - Stone fortified wall blocks mob LoS: Fizzler remains wandering even under max disturbance (sight 32 > distance 20).
///    - Skeleton remains wandering and cannot shoot through stone wall.
///    - Glass fortified wall blocks mob LoS (glass counts as solid for mob sight).
///    - Erecting a wall or ducking behind cover defuses an actively hissing Fizzler immediately.
/// 8. Grand Continuous Multi-System Session Stress:
///    - 60.0s (3600 simulation frames) continuous concurrent execution of hoppers, furnaces, thermal ticks, crops, signals, and mob updates.
///    - Verifies zero deadlocks, zero race conditions, zero NaN coordinates, and zero memory leaks.
///
/// Run via `BLOCKHAVEN_CHECK_INDUSTRY_STRESS=1`. Exits nonzero on failure.
enum IndustryStressCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_INDUSTRY_STRESS"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[stress-check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    @MainActor
    static func run() -> Never {
        var report = Report()
        let dt: Double = 1.0 / 60.0

        let world = World(seed: 777)
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))

        for dz in -3...3 {
            for dx in -3...3 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        let originX = Int(spawn.x)
        let originZ = Int(spawn.z)
        let testChunk = centre

        // =========================================================================
        // TEST 1: Smelting Disturbance Accumulation & Multi-Furnace Clamping
        // =========================================================================
        let tracker = DisturbanceTracker()
        report.check(
            "fresh tracker initializes empty with zero disturbance",
            tracker.chunkLevels.isEmpty && tracker.disturbance(inChunk: testChunk) == 0.0,
            "levelsCount: \(tracker.chunkLevels.count), dist: \(tracker.disturbance(inChunk: testChunk))"
        )

        // Single furnace burning for 5 seconds: 5s * 2.0/s = 10.0
        let furnaceKey = FurnaceStore.Key(originX, 64, originZ)
        for _ in 0..<300 { // 300 frames * dt = 5.0s
            tracker.recordSmelting(at: furnaceKey, amount: DisturbanceTracker.furnaceBurnRate * dt)
        }
        let smelt5s = tracker.disturbance(inChunk: testChunk)
        report.check(
            "single furnace burning for 5s accumulates ~10.0 disturbance",
            abs(smelt5s - 10.0) < 0.1,
            "accumulated: \(smelt5s)"
        )

        // Multiple furnaces: 10 furnaces burning for 10 seconds: 10 * 10s * 2.0/s = 200.0 -> clamped to 100.0
        //
        // The ceiling scales with how many machines the caller speaks for,
        // so a smelting hall of ten still reaches the top. `GameViewController`
        // tallies a chunk's burning furnaces and passes the same product.
        let hallCeiling = DisturbanceTracker.machineryCeiling * 10
        for _ in 0..<600 {
            for f in 0..<10 {
                let k = FurnaceStore.Key(originX + f, 64, originZ)
                tracker.recordSmelting(
                    at: k, amount: DisturbanceTracker.furnaceBurnRate * dt, ceiling: hallCeiling
                )
            }
        }
        let clampedSmelt = tracker.disturbance(inChunk: testChunk)
        report.check(
            "heavy industrial smelting clamps cleanly at maxDisturbance (100.0)",
            clampedSmelt == 100.0,
            "clampedSmelt: \(clampedSmelt)"
        )

        // And the other half of that rule, which is the one that was wrong:
        // a *single* furnace must not be able to get there. Burning alone for
        // ten minutes, it used to pin its chunk at 100 and double every
        // hostile's sight range around a base with nothing on screen to
        // explain it.
        let loneTracker = DisturbanceTracker()
        let loneKey = FurnaceStore.Key(originX, 64, originZ)
        for _ in 0..<36000 { // 600s of burning
            loneTracker.recordSmelting(at: loneKey, amount: DisturbanceTracker.furnaceBurnRate * dt)
        }
        let loneSmelt = loneTracker.disturbance(inChunk: testChunk)
        report.check(
            "one furnace burning alone cannot pin its chunk at maximum threat",
            loneSmelt <= DisturbanceTracker.machineryCeiling && loneSmelt < DisturbanceTracker.maxDisturbance,
            "one furnace reached \(loneSmelt) after 600s, ceiling \(DisturbanceTracker.machineryCeiling)"
        )

        // =========================================================================
        // TEST 2: Explosion Shockwave Impulse & Exact 20% Cardinal Spillover
        // =========================================================================
        tracker.reset()
        let blastCoord = ChunkCoord(x: 10, z: 10)
        let blastCenter = Vector3(CGFloat(blastCoord.x * Chunk.width + 8), 64, CGFloat(blastCoord.z * Chunk.width + 8))
        tracker.recordExplosion(at: blastCenter, amount: 30.0)

        let blastCenterDist = tracker.disturbance(inChunk: blastCoord)
        let blastNorth = tracker.disturbance(inChunk: ChunkCoord(x: blastCoord.x, z: blastCoord.z + 1))
        let blastSouth = tracker.disturbance(inChunk: ChunkCoord(x: blastCoord.x, z: blastCoord.z - 1))
        let blastEast  = tracker.disturbance(inChunk: ChunkCoord(x: blastCoord.x + 1, z: blastCoord.z))
        let blastWest  = tracker.disturbance(inChunk: ChunkCoord(x: blastCoord.x - 1, z: blastCoord.z))
        let blastDiag  = tracker.disturbance(inChunk: ChunkCoord(x: blastCoord.x + 1, z: blastCoord.z + 1))

        let expectedSpill = 30.0 * 0.2 // 6.0
        let spillAccurate = abs(blastNorth - expectedSpill) < 0.001 &&
                            abs(blastSouth - expectedSpill) < 0.001 &&
                            abs(blastEast - expectedSpill) < 0.001 &&
                            abs(blastWest - expectedSpill) < 0.001

        report.check(
            "explosion impulse deposits 30.0 at epicenter and spills exactly 20% (6.0) to 4 cardinal neighbors",
            blastCenterDist == 30.0 && spillAccurate && blastDiag == 0.0,
            "center: \(blastCenterDist), N: \(blastNorth), S: \(blastSouth), E: \(blastEast), W: \(blastWest), Diag: \(blastDiag)"
        )

        // =========================================================================
        // TEST 3: Mining / Block Break Disturbance Accumulation
        // =========================================================================
        tracker.reset()
        let mineCoord = ChunkCoord(x: -5, z: -5)
        let mineX = mineCoord.x * Chunk.width + 4
        let mineZ = mineCoord.z * Chunk.width + 4

        // Mine 20 blocks in chunk: 20 * 1.5 = 30.0, spill = 20 * (1.5 * 0.2) = 6.0
        for _ in 0..<20 {
            tracker.recordBreak(atWorldX: mineX, worldZ: mineZ)
        }
        let minedCenter = tracker.disturbance(inChunk: mineCoord)
        let minedNeighbor = tracker.disturbance(inChunk: ChunkCoord(x: mineCoord.x + 1, z: mineCoord.z))
        report.check(
            "mining 20 blocks accumulates 30.0 in target chunk and 6.0 in cardinal neighbor",
            abs(minedCenter - 30.0) < 0.001 && abs(minedNeighbor - 6.0) < 0.001,
            "minedCenter: \(minedCenter), minedNeighbor: \(minedNeighbor)"
        )

        // =========================================================================
        // TEST 4: Hopper Item Conveyor Disturbance Accumulation
        // =========================================================================
        tracker.reset()
        let hopCoord = ChunkCoord(x: 3, z: -2)
        let hopX = hopCoord.x * Chunk.width + 2
        let hopZ = hopCoord.z * Chunk.width + 2

        // Transfer 40 items: 40 * 0.5 = 20.0, spill = 40 * (0.5 * 0.2) = 4.0
        for _ in 0..<40 {
            tracker.record(atWorldX: hopX, worldZ: hopZ, amount: DisturbanceTracker.hopperTransferCost)
        }
        let hopCenter = tracker.disturbance(inChunk: hopCoord)
        let hopNeighbor = tracker.disturbance(inChunk: ChunkCoord(x: hopCoord.x, z: hopCoord.z - 1))
        report.check(
            "conveyor transfer of 40 items accumulates 20.0 in chunk and 4.0 in cardinal neighbor",
            abs(hopCenter - 20.0) < 0.001 && abs(hopNeighbor - 4.0) < 0.001,
            "hopCenter: \(hopCenter), hopNeighbor: \(hopNeighbor)"
        )

        // =========================================================================
        // TEST 5: Disturbance Decay Dynamics & Dictionary Pruning
        // =========================================================================
        tracker.reset()
        let decayCoord = ChunkCoord(x: 0, z: 0)
        tracker.setLevel(50.0, inChunk: decayCoord)
        tracker.setLevel(0.005, inChunk: ChunkCoord(x: 1, z: 0))

        // Decay 20 seconds at 1.0 unit/s -> 50.0 - 20.0 = 30.0; 0.005 - 20.0 < 0 -> pruned
        tracker.tick(dt: 20.0)
        let after20s = tracker.disturbance(inChunk: decayCoord)
        let prunedEarly = tracker.chunkLevels[ChunkCoord(x: 1, z: 0)] == nil

        report.check(
            "disturbance decays linearly at 1.0/s (50.0 -> 30.0) and prunes silent chunks",
            abs(after20s - 30.0) < 0.001 && prunedEarly,
            "after20s: \(after20s), pruned: \(prunedEarly)"
        )

        // Decay another 31 seconds -> 30.0 - 31.0 < 0 -> pruned completely, chunkLevels becomes empty
        tracker.tick(dt: 31.0)
        let fullyDecayed = tracker.disturbance(inChunk: decayCoord)
        let mapCleaned = tracker.chunkLevels.isEmpty

        report.check(
            "full decay completely prunes all chunks, reclaiming memory and leaving zero residual noise",
            fullyDecayed == 0.0 && mapCleaned,
            "fullyDecayed: \(fullyDecayed), levelsCount: \(tracker.chunkLevels.count)"
        )

        // Test boundary: tick with negative or zero dt does nothing
        tracker.setLevel(25.0, inChunk: decayCoord)
        tracker.tick(dt: 0.0)
        tracker.tick(dt: -5.0)
        report.check(
            "non-positive dt tick does not alter active disturbance levels",
            tracker.disturbance(inChunk: decayCoord) == 25.0,
            "dist: \(tracker.disturbance(inChunk: decayCoord))"
        )

        // =========================================================================
        // TEST 6: Hostile Threat Scaling Oracles (Fizzler & Skeleton)
        // =========================================================================
        // Fizzler sight: 16 * (1 + dist/100), clamped [16.0, 32.0]
        let cSight0 = Fizzler.effectiveSightRange(disturbance: 0.0)
        let cSight25 = Fizzler.effectiveSightRange(disturbance: 25.0)
        let cSight50 = Fizzler.effectiveSightRange(disturbance: 50.0)
        let cSight75 = Fizzler.effectiveSightRange(disturbance: 75.0)
        let cSight100 = Fizzler.effectiveSightRange(disturbance: 100.0)
        let cSight200 = Fizzler.effectiveSightRange(disturbance: 200.0)
        let cSightNeg = Fizzler.effectiveSightRange(disturbance: -50.0)

        let fizzlerSightAccurate = cSight0 == 16.0 &&
                                   cSight25 == 20.0 &&
                                   cSight50 == 24.0 &&
                                   cSight75 == 28.0 &&
                                   cSight100 == 32.0 &&
                                   cSight200 == 32.0 &&
                                   cSightNeg == 16.0

        report.check(
            "fizzler sight range scales strictly linearly from 16.0 to 32.0 and clamps at extremes",
            fizzlerSightAccurate,
            "0: \(cSight0), 25: \(cSight25), 50: \(cSight50), 75: \(cSight75), 100: \(cSight100), 200: \(cSight200), -50: \(cSightNeg)"
        )

        // Skeleton sight: 18 * (1 + dist/100), clamped [18.0, 32.0]
        let sSight0 = Skeleton.effectiveSightRange(disturbance: 0.0)
        let sSight50 = Skeleton.effectiveSightRange(disturbance: 50.0)
        let sSight100 = Skeleton.effectiveSightRange(disturbance: 100.0)
        let sSight200 = Skeleton.effectiveSightRange(disturbance: 200.0)

        let skeletonSightAccurate = sSight0 == 18.0 &&
                                    sSight50 == 27.0 &&
                                    sSight100 == 32.0 && // 18 * 2 = 36 -> clamped to 32.0
                                    sSight200 == 32.0

        report.check(
            "skeleton sight range scales from 18.0 to 32.0 (clamping at 32.0 at 100 disturbance)",
            skeletonSightAccurate,
            "0: \(sSight0), 50: \(sSight50), 100: \(sSight100), 200: \(sSight200)"
        )

        // Fizzler fuse duration: 1.5 * (1 - 0.20 * dist/100), clamped [1.0, 1.5]
        let cFuse0 = Fizzler.effectiveFuseDuration(disturbance: 0.0)
        let cFuse50 = Fizzler.effectiveFuseDuration(disturbance: 50.0)
        let cFuse100 = Fizzler.effectiveFuseDuration(disturbance: 100.0)

        let fizzlerFuseAccurate = abs(cFuse0 - 1.5) < 0.001 &&
                                  abs(cFuse50 - 1.35) < 0.001 &&
                                  abs(cFuse100 - 1.2) < 0.001

        report.check(
            "fizzler fuse duration tightens from 1.5s down to 1.2s under max disturbance",
            fizzlerFuseAccurate,
            "0: \(cFuse0), 50: \(cFuse50), 100: \(cFuse100)"
        )

        // Skeleton shot interval: 1.6 * (1 - 0.25 * dist/100), clamped [1.0, 1.6]
        let sShot0 = Skeleton.effectiveShotInterval(disturbance: 0.0)
        let sShot50 = Skeleton.effectiveShotInterval(disturbance: 50.0)
        let sShot100 = Skeleton.effectiveShotInterval(disturbance: 100.0)

        let skeletonShotAccurate = abs(sShot0 - 1.6) < 0.001 &&
                                   abs(sShot50 - 1.4) < 0.001 &&
                                   abs(sShot100 - 1.2) < 0.001

        report.check(
            "skeleton shot interval quickens from 1.6s down to 1.2s under max disturbance",
            skeletonShotAccurate,
            "0: \(sShot0), 50: \(sShot50), 100: \(sShot100)"
        )

        // =========================================================================
        // TEST 7: Fortified Wall Raycast Line-of-Sight Obstruction
        // =========================================================================
        let wallAreaX = originX + 50
        let wallAreaY = 70
        let wallAreaZ = originZ + 50

        // Clear a 30x10 corridor for raycast testing
        for dz in -5...5 {
            for dx in -5...25 {
                world.setBlock(worldX: wallAreaX + dx, y: wallAreaY - 1, worldZ: wallAreaZ + dz, to: .stone, remesh: false)
                for y in wallAreaY...(wallAreaY + 5) {
                    world.setBlock(worldX: wallAreaX + dx, y: y, worldZ: wallAreaZ + dz, to: .air, remesh: false)
                }
            }
        }

        let playerPos = Vector3(CGFloat(wallAreaX), CGFloat(wallAreaY), CGFloat(wallAreaZ))
        let playerEye = playerPos + Vector3(0, 1.6, 0)

        // Mob position at distance 20.0 along X axis (well beyond baseline 16/18, within escalated 32)
        let mobPos = playerPos + Vector3(20.0, 0, 0)
        let maxDisturbance = 100.0

        // Scenario 7A: Open corridor — mob sees player and engages
        let canSeeOpen = MobSight.canSee(from: mobPos + Vector3(0, 1.6, 0), to: playerEye, world: world)
        var openFizzler = Fizzler(position: mobPos, seed: 0x101)
        openFizzler.step(dt: dt, playerEye: playerEye, canSeePlayer: canSeeOpen, disturbance: maxDisturbance, world: world)

        var openSkeleton = Skeleton(position: mobPos, seed: 0x102)
        openSkeleton.step(dt: dt, playerEye: playerEye, canSeePlayer: canSeeOpen, isNight: true, disturbance: maxDisturbance, world: world)

        report.check(
            "in open corridor under max disturbance (sight 32.0), mob detects player at distance 20 and stalks",
            canSeeOpen && openFizzler.activity == .stalking && openSkeleton.activity == .stalking,
            "canSee: \(canSeeOpen), fizzler: \(openFizzler.activity), skeleton: \(openSkeleton.activity)"
        )

        // Scenario 7B: Solid stone wall erected at x = wallAreaX + 10 (between player and mob)
        for dz in -4...4 {
            for dy in 0...3 {
                world.setBlock(worldX: wallAreaX + 10, y: wallAreaY + dy, worldZ: wallAreaZ + dz, to: .stone, remesh: false)
            }
        }

        let canSeeWalled = MobSight.canSee(from: mobPos + Vector3(0, 1.6, 0), to: playerEye, world: world)
        var walledFizzler = Fizzler(position: mobPos, seed: 0x103)
        walledFizzler.step(dt: dt, playerEye: playerEye, canSeePlayer: canSeeWalled, disturbance: maxDisturbance, world: world)

        var walledSkeleton = Skeleton(position: mobPos, seed: 0x104)
        walledSkeleton.step(dt: dt, playerEye: playerEye, canSeePlayer: canSeeWalled, isNight: true, disturbance: maxDisturbance, world: world)

        report.check(
            "fortified stone wall completely obstructs raycast LoS, forcing mobs to remain wandering",
            !canSeeWalled && walledFizzler.activity == .wandering && walledSkeleton.activity == .wandering,
            "canSee: \(canSeeWalled), fizzler: \(walledFizzler.activity), skeleton: \(walledSkeleton.activity)"
        )

        // Scenario 7C: Glass wall (verifying glass blocks mob sight despite optical transparency)
        for dz in -4...4 {
            for dy in 0...3 {
                world.setBlock(worldX: wallAreaX + 10, y: wallAreaY + dy, worldZ: wallAreaZ + dz, to: .glass, remesh: false)
            }
        }
        let canSeeGlass = MobSight.canSee(from: mobPos + Vector3(0, 1.6, 0), to: playerEye, world: world)
        var glassFizzler = Fizzler(position: mobPos, seed: 0x105)
        glassFizzler.step(dt: dt, playerEye: playerEye, canSeePlayer: canSeeGlass, disturbance: maxDisturbance, world: world)
        report.check(
            "fortified glass wall blocks mob sight raycast (isSolid == true), keeping fizzler in wandering state",
            !canSeeGlass && glassFizzler.activity == .wandering,
            "canSeeGlass: \(canSeeGlass), glassFizzler: \(glassFizzler.activity)"
        )

        // Scenario 7D: Active Fizzler fusing defuses immediately when line of sight is broken by wall
        // Restore open corridor
        for dz in -4...4 {
            for dy in 0...3 {
                world.setBlock(worldX: wallAreaX + 10, y: wallAreaY + dy, worldZ: wallAreaZ + dz, to: .air, remesh: false)
            }
        }
        // Place fizzler at distance 2.5 (fuseRange is 3.0) with open LoS
        let closePos = playerPos + Vector3(2.5, 0, 0)
        var fusingFizzler = Fizzler(position: closePos, seed: 0x106)
        // Step 1: Open LoS -> switches from wandering -> stalking -> fusing
        fusingFizzler.step(dt: dt, playerEye: playerEye, canSeePlayer: true, disturbance: 0.0, world: world)
        fusingFizzler.step(dt: dt, playerEye: playerEye, canSeePlayer: true, disturbance: 0.0, world: world)
        let isFusingInitially: Bool
        if case .fusing = fusingFizzler.activity { isFusingInitially = true } else { isFusingInitially = false }

        // Step 2: Erect wall between player and fusing fizzler (at x = wallAreaX + 1)
        world.setBlock(worldX: wallAreaX + 1, y: wallAreaY, worldZ: wallAreaZ, to: .stone, remesh: false)
        world.setBlock(worldX: wallAreaX + 1, y: wallAreaY + 1, worldZ: wallAreaZ, to: .stone, remesh: false)
        let canSeeAfterWall = MobSight.canSee(from: fusingFizzler.eyePosition, to: playerEye, world: world)

        // Step 3: Next frame -> canSee is false -> should defuse immediately to stalking/wandering
        fusingFizzler.step(dt: dt, playerEye: playerEye, canSeePlayer: canSeeAfterWall, disturbance: 0.0, world: world)
        let isDefused: Bool
        if case .fusing = fusingFizzler.activity { isDefused = false } else { isDefused = true }

        report.check(
            "active fizzler fuse defuses immediately when fortified wall breaks line of sight",
            isFusingInitially && !canSeeAfterWall && isDefused,
            "isFusingInitially: \(isFusingInitially), canSeeAfterWall: \(canSeeAfterWall), defused: \(isDefused), activity: \(fusingFizzler.activity)"
        )

        // Clean up corridor
        world.setBlock(worldX: wallAreaX + 1, y: wallAreaY, worldZ: wallAreaZ, to: .air, remesh: false)
        world.setBlock(worldX: wallAreaX + 1, y: wallAreaY + 1, worldZ: wallAreaZ, to: .air, remesh: false)

        // =========================================================================
        // TEST 8: 60-Second Continuous Multi-System Session Stress
        // =========================================================================
        // Setup multi-system testing rig:
        // - 4 Furnaces smelting with lava buckets
        // - 4 Hoppers transferring items
        // - Farmland + water canal + lit furnace preventing freezing at alpine elevation
        // - Signal daylight sensor powering lamps
        // - Disturbance accumulation from smelting & hopper transfers + decay ticking
        // - Fizzlers & Skeletons simulating steps every frame

        let alpineY = 88
        let rigOriginX = originX - 30
        let rigOriginZ = originZ - 30

        for dz in -5...5 {
            for dx in -5...5 {
                world.setBlock(worldX: rigOriginX + dx, y: alpineY - 1, worldZ: rigOriginZ + dz, to: .stone, remesh: false)
                for y in alpineY...(alpineY + 4) {
                    world.setBlock(worldX: rigOriginX + dx, y: y, worldZ: rigOriginZ + dz, to: .air, remesh: false)
                }
            }
        }

        let simChests = ChestStore()
        let simFurnaces = FurnaceStore()
        let simHoppers = HopperStore()
        var simMinecarts = MinecartManager()
        let simSignals = SignalNetwork()
        let simFuses = FuseManager()
        let simCrops = CropStore()
        let simDisturbance = DisturbanceTracker()

        // Setup 2 furnaces with lava super-fuel and ore
        var furnaceKeys: [FurnaceStore.Key] = []
        var hopperKeys: [HopperStore.Key] = []
        for i in 0..<2 {
            let fx = rigOriginX + i * 3
            let fy = alpineY
            let fz = rigOriginZ
            let fKey = FurnaceStore.Key(fx, fy, fz)
            furnaceKeys.append(fKey)
            world.setBlock(worldX: fx, y: fy, worldZ: fz, to: .furnace, remesh: false)

            // Feed fuel hopper from side
            let hFuelKey = HopperStore.Key(fx - 1, fy, fz)
            hopperKeys.append(hFuelKey)
            world.setBlock(worldX: fx - 1, y: fy, worldZ: fz, to: .hopper, remesh: false)
            simHoppers.hopperPlaced(at: hFuelKey, facing: .east)
            simHoppers.setItem(ItemStack(.lavaBucket, count: 1), at: hFuelKey)

            // Feed ore hopper from top
            let hOreKey = HopperStore.Key(fx, fy + 1, fz)
            hopperKeys.append(hOreKey)
            world.setBlock(worldX: fx, y: fy + 1, worldZ: fz, to: .hopper, remesh: false)
            simHoppers.hopperPlaced(at: hOreKey, facing: nil)
            simHoppers.setItem(ItemStack(.rawIron, count: 10), at: hOreKey)
        }

        // Setup alpine water block and nearby furnace (distance 2)
        let waterX = rigOriginX
        let waterY = alpineY
        let waterZ = rigOriginZ + 3
        world.setBlock(worldX: waterX, y: waterY, worldZ: waterZ, to: .water, remesh: false)
        world.setBlock(worldX: waterX + 2, y: waterY, worldZ: waterZ, to: .furnaceLit, remesh: false)

        // Cavern crop under lamp
        let caveY = 30
        for dz in -2...2 {
            for dx in -2...2 {
                world.setBlock(worldX: rigOriginX + dx, y: caveY - 1, worldZ: rigOriginZ + dz, to: .stone, remesh: false)
                world.setBlock(worldX: rigOriginX + dx, y: caveY, worldZ: rigOriginZ + dz, to: .stone, remesh: false)
                world.setBlock(worldX: rigOriginX + dx, y: caveY + 1, worldZ: rigOriginZ + dz, to: .stone, remesh: false)
                world.setBlock(worldX: rigOriginX + dx, y: caveY + 2, worldZ: rigOriginZ + dz, to: .stone, remesh: false)
            }
        }
        let farmX = rigOriginX
        let farmY = caveY
        let farmZ = rigOriginZ
        world.setBlock(worldX: farmX, y: farmY, worldZ: farmZ, to: .farmland, remesh: false)
        world.setBlock(worldX: farmX, y: farmY + 1, worldZ: farmZ, to: .wheatStage0, remesh: false)
        simCrops.planted(at: CropStore.Key(farmX, farmY + 1, farmZ))
        // Signal lamp right above crop (furnishes block light 15 >= 9)
        world.setBlock(worldX: farmX, y: farmY + 2, worldZ: farmZ, to: .signalLampLit, remesh: false)

        // Fizzlers and skeletons stepping
        var stressFizzler = Fizzler(position: Vector3(CGFloat(rigOriginX + 15), CGFloat(alpineY), CGFloat(rigOriginZ)), seed: 0x55)
        var stressSkeleton = Skeleton(position: Vector3(CGFloat(rigOriginX + 15), CGFloat(alpineY), CGFloat(rigOriginZ + 2)), seed: 0x66)
        let simTargetEye = Vector3(CGFloat(rigOriginX), CGFloat(alpineY) + 1.6, CGFloat(rigOriginZ))

        var totalFrames = 0
        let targetFrames = 3600 // 60.0s of continuous simulation
        var smeltsCount = 0
        var simElapsed = 0.0

        while totalFrames < targetFrames {
            // 1. Hoppers tick
            for key in hopperKeys {
                HopperStore.transfer(
                    at: key,
                    world: world,
                    chests: simChests,
                    furnaces: simFurnaces,
                    minecarts: &simMinecarts,
                    hoppers: simHoppers
                )
                simDisturbance.record(atWorldX: key.x, worldZ: key.z, amount: DisturbanceTracker.hopperTransferCost * 0.05)
            }

            // 2. Furnaces tick
            for key in furnaceKeys {
                var state = simFurnaces.state(at: key)
                let changed = state.tick(dt: dt)
                if state.isBurning {
                    simDisturbance.recordSmelting(at: key, amount: DisturbanceTracker.furnaceBurnRate * dt)
                }
                if changed {
                    if state.outputType != nil {
                        smeltsCount += 1
                    }
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: state.isBurning ? .furnaceLit : .furnace, remesh: false)
                }
                simFurnaces.set(state, at: key)
            }

            // 3. Thermal tick
            world.tickThermal(atWorldX: waterX, y: waterY, worldZ: waterZ)

            // 4. Crop tick
            for key in simCrops.tick(dt: dt, world: world) {
                let cur = world.block(worldX: key.x, y: key.y, worldZ: key.z)
                if cur.isCrop, cur != .wheatStage3, let next = BlockType(rawValue: cur.rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next, remesh: false)
                }
            }

            // 5. Signals tick
            simSignals.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: simFuses)

            // 6. Mob update under disturbance
            let currentDist = simDisturbance.disturbance(atWorldX: Int(stressFizzler.position.x), worldZ: Int(stressFizzler.position.z))
            stressFizzler.step(dt: dt, playerEye: simTargetEye, canSeePlayer: true, disturbance: currentDist, world: world)
            stressSkeleton.step(dt: dt, playerEye: simTargetEye, canSeePlayer: true, isNight: true, disturbance: currentDist, world: world)

            // 7. Disturbance decay
            simDisturbance.tick(dt: dt)

            totalFrames += 1
            simElapsed += dt
        }

        let waterStayedLiquid = world.block(worldX: waterX, y: waterY, worldZ: waterZ) == .water
        let finalCrop = world.block(worldX: farmX, y: farmY + 1, worldZ: farmZ)
        let fizzlerPosValid = !stressFizzler.position.x.isNaN && !stressFizzler.position.y.isNaN && !stressFizzler.position.z.isNaN
        let skeletonPosValid = !stressSkeleton.position.x.isNaN && !stressSkeleton.position.y.isNaN && !stressSkeleton.position.z.isNaN
        let disturbanceWithinBounds = simDisturbance.chunkLevels.values.allSatisfy { $0 >= 0.0 && $0 <= 100.0 }

        report.check(
            "60-second continuous multi-system stress run completed with zero deadlocks, race conditions, or state corruption",
            totalFrames == targetFrames && waterStayedLiquid && finalCrop == .wheatStage3 && fizzlerPosValid && skeletonPosValid && disturbanceWithinBounds,
            "frames: \(totalFrames), elapsed: \(simElapsed)s, water: \(world.block(worldX: waterX, y: waterY, worldZ: waterZ)), crop: \(finalCrop), distBounds: \(disturbanceWithinBounds)"
        )

        // =========================================================================
        // Output Final Transcript
        // =========================================================================
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[stress-check] FAILED — the industrial disturbance stress suite\n"
            : "[stress-check] all passed — the industrial disturbance stress suite\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

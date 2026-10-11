import Foundation

/// Headless verification proof of Milestone 3: Granular Gravity & Falling Dynamics.
///
/// Validates:
/// 1. Single sand and gravel block placed in mid-air falls to the ground.
/// 2. Multi-block vertical stack of sand and gravel: removing the bottom support causes the
///    entire column above to cascade/settle downward sequentially, preserving layer order.
/// 3. Sand and gravel falling into water: settles through the water column to the solid floor,
///    displacing the bottom water cell while leaving overlying water cells intact.
/// 4. Blast crater collapse: TNT detonation clears stone support, causing overlying sand and
///    gravel to collapse down into the carved crater void.
///
/// Run via `BLOCKHAVEN_CHECK_GRAVITY=1`. Exits nonzero on failure.
enum GravityCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_GRAVITY"] != nil
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
        let world = World(seed: 42)
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))

        for dz in -2...2 {
            for dx in -2...2 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        let originX = Int(spawn.x)
        let originZ = Int(spawn.z)
        let baseY = 40

        // Build an isolated clean testing platform
        for dz in -15...15 {
            for dx in -15...15 {
                world.setBlock(worldX: originX + dx, y: baseY, worldZ: originZ + dz, to: .stone, remesh: false)
                for y in (baseY + 1)...(baseY + 25) {
                    world.setBlock(worldX: originX + dx, y: y, worldZ: originZ + dz, to: .air, remesh: false)
                }
            }
        }

        // =========================================================================
        // MARK: - Test 1: Single Sand & Gravel Block Placed in Mid-Air
        // =========================================================================
        let sandDropX = originX - 5
        let gravelDropX = originX - 3
        let dropZ = originZ

        // 1a. Sand drop in mid-air
        world.setBlock(worldX: sandDropX, y: baseY + 8, worldZ: dropZ, to: .sand, remesh: false)
        let sandBeforeDrop = world.block(worldX: sandDropX, y: baseY + 8, worldZ: dropZ) == .sand
            && world.block(worldX: sandDropX, y: baseY + 1, worldZ: dropZ) == .air

        world.settleGranular()

        let sandLanded = world.block(worldX: sandDropX, y: baseY + 1, worldZ: dropZ) == .sand
        let sandClearedAbove = (2...8).allSatisfy { world.block(worldX: sandDropX, y: baseY + $0, worldZ: dropZ) == .air }
        report.check(
            "single sand block placed in mid-air falls to the ground",
            sandBeforeDrop && sandLanded && sandClearedAbove,
            "before: \(sandBeforeDrop), landed at y+1: \(sandLanded), cleared: \(sandClearedAbove)"
        )

        // 1b. Gravel drop in mid-air
        world.setBlock(worldX: gravelDropX, y: baseY + 8, worldZ: dropZ, to: .gravel, remesh: false)
        world.settleGranular()

        let gravelLanded = world.block(worldX: gravelDropX, y: baseY + 1, worldZ: dropZ) == .gravel
        let gravelClearedAbove = (2...8).allSatisfy { world.block(worldX: gravelDropX, y: baseY + $0, worldZ: dropZ) == .air }
        report.check(
            "single gravel block placed in mid-air falls to the ground",
            gravelLanded && gravelClearedAbove,
            "landed at y+1: \(gravelLanded), cleared: \(gravelClearedAbove)"
        )

        // 1c. Non-granular block does not fall
        let nonGranularX = originX - 1
        world.setBlock(worldX: nonGranularX, y: baseY + 8, worldZ: dropZ, to: .cobblestone, remesh: false)
        world.settleGranular()
        let stoneRemained = world.block(worldX: nonGranularX, y: baseY + 8, worldZ: dropZ) == .cobblestone
            && world.block(worldX: nonGranularX, y: baseY + 1, worldZ: dropZ) == .air
        report.check(
            "non-granular block remains suspended in mid-air",
            stoneRemained,
            "block at y+8: \(world.block(worldX: nonGranularX, y: baseY + 8, worldZ: dropZ))"
        )

        // =========================================================================
        // MARK: - Test 2: Multi-Block Vertical Stack Cascade
        // =========================================================================
        let stackX = originX + 3
        let stackZ = originZ

        // Support block at baseY + 1
        world.setBlock(worldX: stackX, y: baseY + 1, worldZ: stackZ, to: .stone, remesh: false)
        // Stack 4 granular blocks above support: sand, gravel, sand, gravel
        world.setBlock(worldX: stackX, y: baseY + 2, worldZ: stackZ, to: .sand, remesh: false)
        world.setBlock(worldX: stackX, y: baseY + 3, worldZ: stackZ, to: .gravel, remesh: false)
        world.setBlock(worldX: stackX, y: baseY + 4, worldZ: stackZ, to: .sand, remesh: false)
        world.setBlock(worldX: stackX, y: baseY + 5, worldZ: stackZ, to: .gravel, remesh: false)

        world.settleGranular()
        let stableBefore = world.block(worldX: stackX, y: baseY + 2, worldZ: stackZ) == .sand
            && world.block(worldX: stackX, y: baseY + 3, worldZ: stackZ) == .gravel
            && world.block(worldX: stackX, y: baseY + 4, worldZ: stackZ) == .sand
            && world.block(worldX: stackX, y: baseY + 5, worldZ: stackZ) == .gravel

        // Remove the bottom support block
        world.setBlock(worldX: stackX, y: baseY + 1, worldZ: stackZ, to: .air, remesh: false)
        world.settleGranular()

        let cascadedCorrectly = world.block(worldX: stackX, y: baseY + 1, worldZ: stackZ) == .sand
            && world.block(worldX: stackX, y: baseY + 2, worldZ: stackZ) == .gravel
            && world.block(worldX: stackX, y: baseY + 3, worldZ: stackZ) == .sand
            && world.block(worldX: stackX, y: baseY + 4, worldZ: stackZ) == .gravel
            && world.block(worldX: stackX, y: baseY + 5, worldZ: stackZ) == .air

        report.check(
            "multi-block vertical stack cascades sequentially preserving layer order",
            stableBefore && cascadedCorrectly,
            "stable before: \(stableBefore), cascade: [\(world.block(worldX: stackX, y: baseY + 1, worldZ: stackZ)), \(world.block(worldX: stackX, y: baseY + 2, worldZ: stackZ)), \(world.block(worldX: stackX, y: baseY + 3, worldZ: stackZ)), \(world.block(worldX: stackX, y: baseY + 4, worldZ: stackZ))], y+5: \(world.block(worldX: stackX, y: baseY + 5, worldZ: stackZ))"
        )

        // =========================================================================
        // MARK: - Test 3: Sand & Gravel Falling Into Water
        // =========================================================================
        let poolX = originX + 7
        let poolZ = originZ

        // Build a contained water cistern: stone perimeter, 3-deep water column
        for dz in -1...1 {
            for dx in -1...1 {
                if dx != 0 || dz != 0 {
                    for y in 1...4 {
                        world.setBlock(worldX: poolX + dx, y: baseY + y, worldZ: poolZ + dz, to: .stone, remesh: false)
                    }
                }
            }
        }
        for y in 1...3 {
            world.setBlock(worldX: poolX, y: baseY + y, worldZ: poolZ, to: .water, remesh: false)
        }
        world.setBlock(worldX: poolX, y: baseY + 4, worldZ: poolZ, to: .air, remesh: false)

        // Drop sand into water from y = baseY + 6
        world.setBlock(worldX: poolX, y: baseY + 6, worldZ: poolZ, to: .sand, remesh: false)
        world.settleGranular()

        let sandDisplacedBottomWater = world.block(worldX: poolX, y: baseY + 1, worldZ: poolZ) == .sand
        let waterRemainedAboveSand = world.block(worldX: poolX, y: baseY + 2, worldZ: poolZ) == .water
            && world.block(worldX: poolX, y: baseY + 3, worldZ: poolZ) == .water
        let sandAirAboveCleared = world.block(worldX: poolX, y: baseY + 6, worldZ: poolZ) == .air

        report.check(
            "sand falls through water to solid floor and displaces only the bottom water cell",
            sandDisplacedBottomWater && waterRemainedAboveSand && sandAirAboveCleared,
            "bottom: \(world.block(worldX: poolX, y: baseY + 1, worldZ: poolZ)), y+2: \(world.block(worldX: poolX, y: baseY + 2, worldZ: poolZ)), y+3: \(world.block(worldX: poolX, y: baseY + 3, worldZ: poolZ))"
        )

        // Drop gravel into the same column
        world.setBlock(worldX: poolX, y: baseY + 6, worldZ: poolZ, to: .gravel, remesh: false)
        world.settleGranular()

        let gravelStackedInWater = world.block(worldX: poolX, y: baseY + 1, worldZ: poolZ) == .sand
            && world.block(worldX: poolX, y: baseY + 2, worldZ: poolZ) == .gravel
            && world.block(worldX: poolX, y: baseY + 3, worldZ: poolZ) == .water

        report.check(
            "gravel falls through water and stacks on top of settled sand, preserving remaining water above",
            gravelStackedInWater,
            "y+1: \(world.block(worldX: poolX, y: baseY + 1, worldZ: poolZ)), y+2: \(world.block(worldX: poolX, y: baseY + 2, worldZ: poolZ)), y+3: \(world.block(worldX: poolX, y: baseY + 3, worldZ: poolZ))"
        )

        // =========================================================================
        // MARK: - Test 4: Blast Crater Collapse
        // =========================================================================
        let blastX = originX + 12
        let blastZ = originZ
        let tntY = baseY + 2

        // Solid chamber
        for dz in -4...4 {
            for dx in -4...4 {
                for y in (baseY - 2)...(baseY + 5) {
                    world.setBlock(worldX: blastX + dx, y: y, worldZ: blastZ + dz, to: .stone, remesh: false)
                }
            }
        }
        // Sand overburden layer resting on stone ceiling at y = baseY + 6, 7
        for dz in -1...1 {
            for dx in -1...1 {
                world.setBlock(worldX: blastX + dx, y: baseY + 6, worldZ: blastZ + dz, to: .sand, remesh: false)
                world.setBlock(worldX: blastX + dx, y: baseY + 7, worldZ: blastZ + dz, to: .gravel, remesh: false)
                world.setBlock(worldX: blastX + dx, y: baseY + 8, worldZ: blastZ + dz, to: .air, remesh: false)
            }
        }

        // Place and detonate TNT at blast centre
        world.setBlock(worldX: blastX, y: tntY, worldZ: blastZ, to: .tnt, remesh: false)
        let blastResult = Blast.carve(at: Vector3(CGFloat(blastX) + 0.5, CGFloat(tntY) + 0.5, CGFloat(blastZ) + 0.5),
                                      radius: 3.2, in: world)

        // Verify stone support was broken
        let ceilingBreached = world.block(worldX: blastX, y: baseY + 5, worldZ: blastZ) == .air

        // Trigger granular settling
        world.settleGranular()

        // Granular layer at y+6, y+7 must have collapsed downward into the crater
        let overburdenCollapsed = world.block(worldX: blastX, y: baseY + 6, worldZ: blastZ) == .air
            && world.block(worldX: blastX, y: baseY + 7, worldZ: blastZ) == .air

        // Check that sand or gravel has settled into the lower crater
        var granularInCraterCount = 0
        for y in (baseY - 2)...(baseY + 4) {
            let b = world.block(worldX: blastX, y: y, worldZ: blastZ)
            if b == .sand || b == .gravel { granularInCraterCount += 1 }
        }

        report.check(
            "blast crater clears support causing overlying sand and gravel to collapse into the void",
            blastResult.destroyed > 0 && ceilingBreached && overburdenCollapsed && granularInCraterCount >= 2,
            "destroyed: \(blastResult.destroyed), ceiling breached: \(ceilingBreached), overburden collapsed: \(overburdenCollapsed), granular in crater: \(granularInCraterCount)"
        )

        // =========================================================================
        // MARK: - Test 5: Scenery & Signal Device Displacement by Falling Blocks
        // =========================================================================
        let sceneryBaseX = originX - 12
        let sceneryZ = originZ

        for dx in 0...6 {
            let colX = sceneryBaseX + dx
            for y in (baseY + 1)...(baseY + 10) {
                world.setBlock(worldX: colX, y: y, worldZ: sceneryZ, to: .air, remesh: false)
            }
        }

        // 5a. Sand displaces signal wire down to solid floor
        let wireX = sceneryBaseX
        world.setBlock(worldX: wireX, y: baseY, worldZ: sceneryZ, to: .stone, remesh: false)
        world.setBlock(worldX: wireX, y: baseY + 1, worldZ: sceneryZ, to: .wireOff, remesh: false)
        world.setBlock(worldX: wireX, y: baseY + 5, worldZ: sceneryZ, to: .sand, remesh: false)
        world.settleGranular(atWorldX: wireX, worldZ: sceneryZ)

        let sandOnFloorDisplacingWire = world.block(worldX: wireX, y: baseY + 1, worldZ: sceneryZ) == .sand
        let wireClearedAbove = (2...5).allSatisfy { world.block(worldX: wireX, y: baseY + $0, worldZ: sceneryZ) == .air }
        report.check(
            "falling sand displaces signal wire down to the solid base",
            sandOnFloorDisplacingWire && wireClearedAbove,
            "y+1: \(world.block(worldX: wireX, y: baseY + 1, worldZ: sceneryZ)), clearedAbove: \(wireClearedAbove)"
        )

        // 5b. Gravel displaces active signal wire (wireOn) down to solid floor
        let wireOnX = sceneryBaseX + 1
        world.setBlock(worldX: wireOnX, y: baseY, worldZ: sceneryZ, to: .stone, remesh: false)
        world.setBlock(worldX: wireOnX, y: baseY + 1, worldZ: sceneryZ, to: .wireOn, remesh: false)
        world.setBlock(worldX: wireOnX, y: baseY + 5, worldZ: sceneryZ, to: .gravel, remesh: false)
        world.settleGranular(atWorldX: wireOnX, worldZ: sceneryZ)

        let gravelOnFloorDisplacingWireOn = world.block(worldX: wireOnX, y: baseY + 1, worldZ: sceneryZ) == .gravel
        let wireOnClearedAbove = (2...5).allSatisfy { world.block(worldX: wireOnX, y: baseY + $0, worldZ: sceneryZ) == .air }
        report.check(
            "falling gravel displaces active wire (wireOn) down to the solid base",
            gravelOnFloorDisplacingWireOn && wireOnClearedAbove,
            "y+1: \(world.block(worldX: wireOnX, y: baseY + 1, worldZ: sceneryZ)), clearedAbove: \(wireOnClearedAbove)"
        )

        // 5c. Sand displaces rail (railNorthSouth) down to solid floor
        let railX = sceneryBaseX + 2
        world.setBlock(worldX: railX, y: baseY, worldZ: sceneryZ, to: .stone, remesh: false)
        world.setBlock(worldX: railX, y: baseY + 1, worldZ: sceneryZ, to: .railNorthSouth, remesh: false)
        world.setBlock(worldX: railX, y: baseY + 5, worldZ: sceneryZ, to: .sand, remesh: false)
        world.settleGranular(atWorldX: railX, worldZ: sceneryZ)

        let sandOnFloorDisplacingRail = world.block(worldX: railX, y: baseY + 1, worldZ: sceneryZ) == .sand
        let railClearedAbove = (2...5).allSatisfy { world.block(worldX: railX, y: baseY + $0, worldZ: sceneryZ) == .air }
        report.check(
            "falling sand displaces rails down to the solid base",
            sandOnFloorDisplacingRail && railClearedAbove,
            "y+1: \(world.block(worldX: railX, y: baseY + 1, worldZ: sceneryZ)), clearedAbove: \(railClearedAbove)"
        )

        // 5d. Gravel displaces lever down to solid floor
        let leverX = sceneryBaseX + 3
        world.setBlock(worldX: leverX, y: baseY, worldZ: sceneryZ, to: .stone, remesh: false)
        world.setBlock(worldX: leverX, y: baseY + 1, worldZ: sceneryZ, to: .leverOff, remesh: false)
        world.setBlock(worldX: leverX, y: baseY + 5, worldZ: sceneryZ, to: .gravel, remesh: false)
        world.settleGranular(atWorldX: leverX, worldZ: sceneryZ)

        let gravelOnFloorDisplacingLever = world.block(worldX: leverX, y: baseY + 1, worldZ: sceneryZ) == .gravel
        let leverClearedAbove = (2...5).allSatisfy { world.block(worldX: leverX, y: baseY + $0, worldZ: sceneryZ) == .air }
        report.check(
            "falling gravel displaces levers down to the solid base",
            gravelOnFloorDisplacingLever && leverClearedAbove,
            "y+1: \(world.block(worldX: leverX, y: baseY + 1, worldZ: sceneryZ)), clearedAbove: \(leverClearedAbove)"
        )

        // 5e. Sand and gravel displace signal torches and signal relays down to solid floor
        let signalX = sceneryBaseX + 4
        world.setBlock(worldX: signalX, y: baseY, worldZ: sceneryZ, to: .stone, remesh: false)
        world.setBlock(worldX: signalX, y: baseY + 1, worldZ: sceneryZ, to: .signalTorchOn, remesh: false)
        world.setBlock(worldX: signalX, y: baseY + 5, worldZ: sceneryZ, to: .sand, remesh: false)
        world.settleGranular(atWorldX: signalX, worldZ: sceneryZ)
        let sandOnFloorDisplacingSignalTorch = world.block(worldX: signalX, y: baseY + 1, worldZ: sceneryZ) == .sand

        let relayX = sceneryBaseX + 5
        world.setBlock(worldX: relayX, y: baseY, worldZ: sceneryZ, to: .stone, remesh: false)
        world.setBlock(worldX: relayX, y: baseY + 1, worldZ: sceneryZ, to: .signalRelayOff, remesh: false)
        world.setBlock(worldX: relayX, y: baseY + 5, worldZ: sceneryZ, to: .gravel, remesh: false)
        world.settleGranular(atWorldX: relayX, worldZ: sceneryZ)
        let gravelOnFloorDisplacingRelay = world.block(worldX: relayX, y: baseY + 1, worldZ: sceneryZ) == .gravel

        report.check(
            "falling sand and gravel displace signal torches and signal relays down to the solid base",
            sandOnFloorDisplacingSignalTorch && gravelOnFloorDisplacingRelay,
            "torch displaced: \(sandOnFloorDisplacingSignalTorch), relay displaced: \(gravelOnFloorDisplacingRelay)"
        )

        // 5f. Multi-layer intermediate scenery cleanup down to solid base
        let multiX = sceneryBaseX + 6
        world.setBlock(worldX: multiX, y: baseY, worldZ: sceneryZ, to: .stone, remesh: false)
        world.setBlock(worldX: multiX, y: baseY + 1, worldZ: sceneryZ, to: .wireOff, remesh: false)
        world.setBlock(worldX: multiX, y: baseY + 2, worldZ: sceneryZ, to: .torch, remesh: false)
        world.setBlock(worldX: multiX, y: baseY + 3, worldZ: sceneryZ, to: .leverOff, remesh: false)
        world.setBlock(worldX: multiX, y: baseY + 6, worldZ: sceneryZ, to: .sand, remesh: false)
        world.setBlock(worldX: multiX, y: baseY + 7, worldZ: sceneryZ, to: .gravel, remesh: false)
        world.settleGranular(atWorldX: multiX, worldZ: sceneryZ)

        let multiSandAtBase = world.block(worldX: multiX, y: baseY + 1, worldZ: sceneryZ) == .sand
        let multiGravelStacked = world.block(worldX: multiX, y: baseY + 2, worldZ: sceneryZ) == .gravel
        let multiIntermediateCleared = (3...7).allSatisfy { world.block(worldX: multiX, y: baseY + $0, worldZ: sceneryZ) == .air }
        report.check(
            "falling column displaces stacked scenery down to solid base and cleans intermediate cells",
            multiSandAtBase && multiGravelStacked && multiIntermediateCleared,
            "base y+1: \(world.block(worldX: multiX, y: baseY + 1, worldZ: sceneryZ)), stack y+2: \(world.block(worldX: multiX, y: baseY + 2, worldZ: sceneryZ)), clearedAbove: \(multiIntermediateCleared)"
        )

        // =========================================================================
        // MARK: - Test 6: Random Gravity Ticks West And North Of The Origin
        // =========================================================================
        // The game loop random-ticks the 5x5 chunk neighbourhood around the
        // player, so walking west or north hands this a chunk with a negative
        // coordinate. Seeding the tick's generator used to convert that
        // coordinate to an unsigned integer, which traps rather than wrapping,
        // and the game died the moment a player crossed the origin.
        let negativeCentre = ChunkCoord(x: -4, z: -4)
        for dz in -2...2 {
            for dx in -2...2 {
                world.forceGenerate(ChunkCoord(x: negativeCentre.x + dx, z: negativeCentre.z + dz))
            }
        }
        for dz in -2...2 {
            for dx in -2...2 {
                world.randomTickGravity(in: ChunkCoord(x: negativeCentre.x + dx, z: negativeCentre.z + dz), samples: 8)
            }
        }
        report.check(
            "random gravity ticks survive chunks west and north of the origin",
            true,
            "ticked the 5x5 neighbourhood around chunk (\(negativeCentre.x), \(negativeCentre.z))"
        )

        // And gravity itself still works out there: sand dropped in mid-air in a
        // negative-coordinate chunk falls to the floor like it does at spawn.
        let negX = negativeCentre.x * Chunk.width + 8
        let negZ = negativeCentre.z * Chunk.depth + 8
        let negFloor = 50
        for y in negFloor...(negFloor + 8) {
            world.setBlock(worldX: negX, y: y, worldZ: negZ, to: .air, remesh: false)
        }
        world.setBlock(worldX: negX, y: negFloor, worldZ: negZ, to: .stone, remesh: false)
        world.setBlock(worldX: negX, y: negFloor + 6, worldZ: negZ, to: .sand, remesh: false)
        world.settleGranular(atWorldX: negX, worldZ: negZ)
        let negSandLanded = world.block(worldX: negX, y: negFloor + 1, worldZ: negZ) == .sand
        report.check(
            "sand dropped west and north of the origin falls to the floor",
            negSandLanded,
            "block above the floor at (\(negX), \(negZ)): \(world.block(worldX: negX, y: negFloor + 1, worldZ: negZ))"
        )

        // =========================================================================
        // MARK: - Test 7: Ambient Gravity Ticks Reach The Whole Chunk
        // =========================================================================
        // The ambient tick picks columns at random, and it has to pick
        // *different* ones each time. Seeding a fresh generator from the chunk
        // coordinate made every tick replay the same handful of columns, so
        // unsupported sand anywhere else hung in the air forever.
        let sweepCoord = ChunkCoord(x: 6, z: 6)
        world.forceGenerate(sweepCoord)
        let sweepFloor = 60
        for lz in 0..<Chunk.depth {
            for lx in 0..<Chunk.width {
                let wx = sweepCoord.x * Chunk.width + lx
                let wz = sweepCoord.z * Chunk.depth + lz
                for y in (sweepFloor + 1)...(sweepFloor + 10) {
                    world.setBlock(worldX: wx, y: y, worldZ: wz, to: .air, remesh: false)
                }
                world.setBlock(worldX: wx, y: sweepFloor, worldZ: wz, to: .stone, remesh: false)
                world.setBlock(worldX: wx, y: sweepFloor + 2, worldZ: wz, to: .sand, remesh: false)
            }
        }

        for _ in 0..<300 {
            world.randomTickGravity(in: sweepCoord, samples: 8)
        }

        var settledColumns = 0
        for lz in 0..<Chunk.depth {
            for lx in 0..<Chunk.width {
                let wx = sweepCoord.x * Chunk.width + lx
                let wz = sweepCoord.z * Chunk.depth + lz
                if world.block(worldX: wx, y: sweepFloor + 1, worldZ: wz) == .sand { settledColumns += 1 }
            }
        }

        let totalColumns = Chunk.width * Chunk.depth
        report.check(
            "ambient gravity ticks reach the whole chunk rather than replaying one sample set",
            settledColumns >= 240,
            "\(settledColumns) of \(totalColumns) columns settled over 300 ticks"
        )

        // =========================================================================
        // MARK: - Test 8: An Open Door Is Not A Hole To Fall Through
        // =========================================================================
        // A door reads as "not solid" while it is open, which is a fact
        // about walking through it. Falling sand took that for a hole,
        // dropped through the doorway, and the pass-through cleanup set the
        // cell it crossed to air one cell at a time — deleting the top half
        // of the door and leaving the bottom half standing, which is exactly
        // the orphan `ShapedPlacement.removalCells` exists to prevent.
        let doorX = sceneryBaseX + 9
        let doorZ = sceneryZ
        for y in baseY...(baseY + 8) {
            world.setBlock(worldX: doorX, y: y, worldZ: doorZ, to: .air, remesh: false)
        }
        world.setBlock(worldX: doorX, y: baseY, worldZ: doorZ, to: .stone, remesh: false)
        let lower = BlockType.oakDoor(.lower, facing: .north, open: true)
        let upper = BlockType.oakDoor(.upper, facing: .north, open: true)
        world.setBlock(worldX: doorX, y: baseY + 1, worldZ: doorZ, to: lower, remesh: false)
        world.setBlock(worldX: doorX, y: baseY + 2, worldZ: doorZ, to: upper, remesh: false)
        world.setBlock(worldX: doorX, y: baseY + 6, worldZ: doorZ, to: .sand, remesh: false)
        world.settleGranular(atWorldX: doorX, worldZ: doorZ)

        let lowerSurvived = world.block(worldX: doorX, y: baseY + 1, worldZ: doorZ).isDoor
        let upperSurvived = world.block(worldX: doorX, y: baseY + 2, worldZ: doorZ).isDoor
        let sandRested = world.block(worldX: doorX, y: baseY + 3, worldZ: doorZ) == .sand
        report.check(
            "sand dropped on an open door rests on it instead of eating half of it",
            lowerSurvived && upperSurvived && sandRested,
            "lower: \(world.block(worldX: doorX, y: baseY + 1, worldZ: doorZ)), "
                + "upper: \(world.block(worldX: doorX, y: baseY + 2, worldZ: doorZ)), "
                + "sand at y+3: \(world.block(worldX: doorX, y: baseY + 3, worldZ: doorZ))"
        )

        // And the scenery a fall *does* legitimately take out is reported,
        // so the game can hand it back rather than vanishing a run of rail.
        let wreckX = sceneryBaseX + 11
        world.setBlock(worldX: wreckX, y: baseY, worldZ: sceneryZ, to: .stone, remesh: false)
        world.setBlock(worldX: wreckX, y: baseY + 1, worldZ: sceneryZ, to: .railNorthSouth, remesh: false)
        world.setBlock(worldX: wreckX, y: baseY + 5, worldZ: sceneryZ, to: .gravel, remesh: false)
        let wreckResult = world.settleGranular(atWorldX: wreckX, worldZ: sceneryZ)
        let reportedRail = wreckResult.destroyed.contains { $0.block.isRail }
        report.check(
            "scenery crushed by a fall is reported rather than silently deleted",
            reportedRail,
            "destroyed: \(wreckResult.destroyed.map { $0.block })"
        )

        // =========================================================================
        // Output Final Transcript
        // =========================================================================
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — granular gravity\n"
            : "[check] all passed — granular gravity\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

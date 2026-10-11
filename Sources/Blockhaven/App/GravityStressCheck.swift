import Foundation
import Foundation

/// Adversarial stress testing and empirical boundary verification for Milestone 3:
/// Granular Gravity & Falling Dynamics.
///
/// Exercises:
/// 1. High multi-block vertical columns (10, 20, 50 blocks tall) of alternating sand and gravel
///    falling into air, water, and onto stairs/scenery.
/// 2. Verification that column settling preserves vertical layer sequence bottom-to-top without
///    block duplication or destruction (conservation of mass).
/// 3. Verification of non-solid scenery (torches, signal wire, saplings, etc.) being properly
///    broken or displaced by falling blocks.
/// 4. Verification of crushing damage bounds against player and mobs (fizzlers, skeletons, animals).
/// 5. Blast crater settling behavior and mass conservation.
///
/// Run via `BLOCKHAVEN_CHECK_GRAVITY_STRESS=1`. Exits nonzero on failure.
enum GravityStressCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_GRAVITY_STRESS"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[gravity-stress] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    static func run() -> Never {
        var report = Report()
        let world = World(seed: 4242)
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))

        // Force generate surrounding chunks
        for dz in -4...4 {
            for dx in -4...4 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        let originX = Int(spawn.x)
        let originZ = Int(spawn.z)
        let baseY = 10

        // Helper to clear a column
        func clearColumn(x: Int, z: Int, fromY: Int = 1, toY: Int = 120) {
            for y in fromY...toY {
                world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
            }
        }

        // =========================================================================
        // SUITE 1: High Multi-Block Vertical Columns in Air
        // =========================================================================
        // Test 1a: 10-block column of alternating sand and gravel falling through air
        do {
            let cx = originX + 10
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)

            // 10 blocks: y=31..40 (10 blocks tall, 20 blocks of air underneath: y=11..30)
            let columnHeight = 10
            let airGap = 20
            let startY = baseY + 1 + airGap
            var expectedPattern: [BlockType] = []
            for i in 0..<columnHeight {
                let block: BlockType = (i % 2 == 0) ? .sand : .gravel
                expectedPattern.append(block)
                world.setBlock(worldX: cx, y: startY + i, worldZ: cz, to: block, remesh: false)
            }

            let result = world.settleGranular(atWorldX: cx, worldZ: cz)

            // Verify landing and order
            var actualPattern: [BlockType] = []
            for i in 0..<columnHeight {
                actualPattern.append(world.block(worldX: cx, y: baseY + 1 + i, worldZ: cz))
            }

            let orderMatches = (expectedPattern == actualPattern)
            let clearedAbove = (startY..<(startY + columnHeight)).allSatisfy {
                world.block(worldX: cx, y: $0, worldZ: cz) == .air
            }
            let countMatches = result.blocksMoved == columnHeight

            report.check(
                "10-block alternating column falls in air, preserving layer sequence without duplication",
                orderMatches && clearedAbove && countMatches,
                "orderMatches: \(orderMatches), clearedAbove: \(clearedAbove), blocksMoved: \(result.blocksMoved)/\(columnHeight)"
            )
        }

        // Test 1b: 20-block column of alternating sand and gravel falling through air
        do {
            let cx = originX + 11
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)

            let columnHeight = 20
            let airGap = 15
            let startY = baseY + 1 + airGap
            var expectedPattern: [BlockType] = []
            for i in 0..<columnHeight {
                let block: BlockType = (i % 3 == 0) ? .sand : .gravel
                expectedPattern.append(block)
                world.setBlock(worldX: cx, y: startY + i, worldZ: cz, to: block, remesh: false)
            }

            let result = world.settleGranular(atWorldX: cx, worldZ: cz)

            var actualPattern: [BlockType] = []
            for i in 0..<columnHeight {
                actualPattern.append(world.block(worldX: cx, y: baseY + 1 + i, worldZ: cz))
            }

            let orderMatches = (expectedPattern == actualPattern)
            let clearedAbove = ((baseY + 1 + columnHeight)..<(startY + columnHeight)).allSatisfy {
                world.block(worldX: cx, y: $0, worldZ: cz) == .air
            }
            let countMatches = result.blocksMoved == columnHeight

            report.check(
                "20-block alternating column falls in air, preserving layer sequence without duplication",
                orderMatches && clearedAbove && countMatches,
                "orderMatches: \(orderMatches), clearedAbove: \(clearedAbove), blocksMoved: \(result.blocksMoved)/\(columnHeight)"
            )
        }

        // Test 1c: Extreme 50-block vertical column (tall column stress)
        do {
            let cx = originX + 12
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)

            let columnHeight = 50
            let startY = baseY + 10
            var expectedPattern: [BlockType] = []
            for i in 0..<columnHeight {
                let block: BlockType = (i % 2 == 0) ? .sand : .gravel
                expectedPattern.append(block)
                world.setBlock(worldX: cx, y: startY + i, worldZ: cz, to: block, remesh: false)
            }

            let result = world.settleGranular(atWorldX: cx, worldZ: cz)

            var actualPattern: [BlockType] = []
            for i in 0..<columnHeight {
                actualPattern.append(world.block(worldX: cx, y: baseY + 1 + i, worldZ: cz))
            }

            let orderMatches = (expectedPattern == actualPattern)
            let clearedAbove = ((baseY + 1 + columnHeight)..<(startY + columnHeight)).allSatisfy {
                world.block(worldX: cx, y: $0, worldZ: cz) == .air
            }
            let countMatches = result.blocksMoved == columnHeight

            report.check(
                "50-block extreme column falls in air, preserving layer sequence without loss",
                orderMatches && clearedAbove && countMatches,
                "orderMatches: \(orderMatches), clearedAbove: \(clearedAbove), blocksMoved: \(result.blocksMoved)/\(columnHeight)"
            )
        }

        // =========================================================================
        // SUITE 2: High Columns Falling Into Water
        // =========================================================================
        // Test 2a: 15-block column falling into 5-block deep water
        do {
            let cx = originX + 14
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            // Enclose the water column with glass so it doesn't spread
            for dy in 0...10 {
                for dx in -1...1 {
                    for dz in -1...1 {
                        if dx != 0 || dz != 0 {
                            world.setBlock(worldX: cx + dx, y: baseY + dy, worldZ: cz + dz, to: .glass, remesh: false)
                        }
                    }
                }
            }
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)

            // 5 blocks of water at y = baseY + 1 ... baseY + 5
            let waterDepth = 5
            for y in 1...waterDepth {
                world.setBlock(worldX: cx, y: baseY + y, worldZ: cz, to: .water, remesh: false)
            }

            // 15 blocks of sand/gravel at y = baseY + 10 ... baseY + 24
            let columnHeight = 15
            let startY = baseY + 10
            var expectedPattern: [BlockType] = []
            for i in 0..<columnHeight {
                let block: BlockType = (i % 2 == 0) ? .sand : .gravel
                expectedPattern.append(block)
                world.setBlock(worldX: cx, y: startY + i, worldZ: cz, to: block, remesh: false)
            }

            let result = world.settleGranular(atWorldX: cx, worldZ: cz)

            var actualPattern: [BlockType] = []
            for i in 0..<columnHeight {
                actualPattern.append(world.block(worldX: cx, y: baseY + 1 + i, worldZ: cz))
            }

            let orderMatches = (expectedPattern == actualPattern)
            let clearedAbove = ((baseY + 1 + columnHeight)..<(startY + columnHeight)).allSatisfy {
                world.block(worldX: cx, y: $0, worldZ: cz) == .air
            }
            let allMoved = result.blocksMoved == columnHeight

            report.check(
                "15-block column falling into 5-deep water displaces water and preserves sequence",
                orderMatches && clearedAbove && allMoved,
                "orderMatches: \(orderMatches), clearedAbove: \(clearedAbove), blocksMoved: \(result.blocksMoved)/\(columnHeight)"
            )
        }

        // Test 2b: 5-block column falling into 10-block deep water (partial fill of water)
        do {
            let cx = originX + 17
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)

            let waterDepth = 10
            for y in 1...waterDepth {
                world.setBlock(worldX: cx, y: baseY + y, worldZ: cz, to: .water, remesh: false)
            }

            let columnHeight = 5
            let startY = baseY + 15
            var expectedPattern: [BlockType] = []
            for i in 0..<columnHeight {
                let block: BlockType = (i % 2 == 0) ? .sand : .gravel
                expectedPattern.append(block)
                world.setBlock(worldX: cx, y: startY + i, worldZ: cz, to: block, remesh: false)
            }

            _ = world.settleGranular(atWorldX: cx, worldZ: cz)

            var actualPattern: [BlockType] = []
            for i in 0..<columnHeight {
                actualPattern.append(world.block(worldX: cx, y: baseY + 1 + i, worldZ: cz))
            }

            let remainingWaterIntact = ((baseY + columnHeight + 1)...(baseY + waterDepth)).allSatisfy {
                world.block(worldX: cx, y: $0, worldZ: cz) == .water
            }
            let orderMatches = (expectedPattern == actualPattern)

            report.check(
                "5-block column in 10-deep water settles to bottom, remaining 5 water layers intact",
                orderMatches && remainingWaterIntact,
                "orderMatches: \(orderMatches), waterRemaining: \(remainingWaterIntact)"
            )
        }

        // =========================================================================
        // SUITE 3: Columns Falling onto Stairs (Partial Slabs)
        // =========================================================================
        do {
            let cx = originX + 20
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 1, worldZ: cz, to: .oakStairsNorth, remesh: false)

            // 5 blocks of sand above stairs
            for y in (baseY + 4)...(baseY + 8) {
                world.setBlock(worldX: cx, y: y, worldZ: cz, to: .sand, remesh: false)
            }

            world.settleGranular(atWorldX: cx, worldZ: cz)

            let stairsIntact = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .oakStairsNorth
            let sandOnStairs = (2...6).allSatisfy { world.block(worldX: cx, y: baseY + $0, worldZ: cz) == .sand }
            let clearedAbove = (7...8).allSatisfy { world.block(worldX: cx, y: baseY + $0, worldZ: cz) == .air }

            report.check(
                "column falling onto stairs rests on stairs without destroying or falling through them",
                stairsIntact && sandOnStairs && clearedAbove,
                "stairsIntact: \(stairsIntact), sandOnStairs: \(sandOnStairs), clearedAbove: \(clearedAbove)"
            )
        }

        // =========================================================================
        // SUITE 4: Non-Solid Scenery (Torches, Signal Wire, Saplings)
        // =========================================================================
        // 4a. Torch
        do {
            let cx = originX + 23
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 1, worldZ: cz, to: .torch, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 5, worldZ: cz, to: .sand, remesh: false)

            world.settleGranular(atWorldX: cx, worldZ: cz)

            let sandAtY1 = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .sand
            let y5Air = world.block(worldX: cx, y: baseY + 5, worldZ: cz) == .air

            report.check(
                "sand falls through and destroys/displaces torch",
                sandAtY1 && y5Air,
                "block at y+1: \(world.block(worldX: cx, y: baseY + 1, worldZ: cz))"
            )
        }

        // 4b. Sapling
        do {
            let cx = originX + 25
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .dirt, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 1, worldZ: cz, to: .sapling, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 4, worldZ: cz, to: .gravel, remesh: false)

            world.settleGranular(atWorldX: cx, worldZ: cz)

            let gravelAtY1 = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .gravel
            let y4Air = world.block(worldX: cx, y: baseY + 4, worldZ: cz) == .air

            report.check(
                "gravel falls through and destroys/displaces sapling",
                gravelAtY1 && y4Air,
                "block at y+1: \(world.block(worldX: cx, y: baseY + 1, worldZ: cz))"
            )
        }

        // 4c. Birch Sapling and Spruce Sapling
        do {
            let cx = originX + 27
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .dirt, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 1, worldZ: cz, to: .birchSapling, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 4, worldZ: cz, to: .sand, remesh: false)

            world.settleGranular(atWorldX: cx, worldZ: cz)

            let sandAtY1 = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .sand

            report.check(
                "sand falls through and destroys/displaces birch sapling",
                sandAtY1,
                "block at y+1: \(world.block(worldX: cx, y: baseY + 1, worldZ: cz))"
            )
        }

        // 4d. Signal Wire (wireOff and wireOn)
        do {
            let cx = originX + 29
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 1, worldZ: cz, to: .wireOff, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 5, worldZ: cz, to: .sand, remesh: false)

            world.settleGranular(atWorldX: cx, worldZ: cz)

            let sandAtY1 = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .sand
            let wireDestroyed = world.block(worldX: cx, y: baseY + 1, worldZ: cz) != .wireOff
            let sandAtY2 = world.block(worldX: cx, y: baseY + 2, worldZ: cz) == .sand

            report.check(
                "sand falls through and destroys/displaces signal wire (wireOff)",
                sandAtY1 && wireDestroyed,
                "block at y+1: \(world.block(worldX: cx, y: baseY + 1, worldZ: cz)), block at y+2: \(world.block(worldX: cx, y: baseY + 2, worldZ: cz)) (sand resting on wire = \(sandAtY2))"
            )
        }

        // 4e. Signal Wire (wireOn)
        do {
            let cx = originX + 31
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 1, worldZ: cz, to: .wireOn, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 5, worldZ: cz, to: .gravel, remesh: false)

            world.settleGranular(atWorldX: cx, worldZ: cz)

            let gravelAtY1 = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .gravel
            let wireDestroyed = world.block(worldX: cx, y: baseY + 1, worldZ: cz) != .wireOn

            report.check(
                "gravel falls through and destroys/displaces signal wire (wireOn)",
                gravelAtY1 && wireDestroyed,
                "block at y+1: \(world.block(worldX: cx, y: baseY + 1, worldZ: cz))"
            )
        }

        // 4f. Other non-solid scenery: flowers (poppy), tallGrass, pressurePlateOff
        do {
            let cx = originX + 33
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .dirt, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 1, worldZ: cz, to: .poppy, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 3, worldZ: cz, to: .sand, remesh: false)

            world.settleGranular(atWorldX: cx, worldZ: cz)
            let poppyDisplaced = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .sand

            world.setBlock(worldX: cx, y: baseY + 2, worldZ: cz, to: .pressurePlateOff, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 5, worldZ: cz, to: .gravel, remesh: false)

            world.settleGranular(atWorldX: cx, worldZ: cz)
            let plateDisplaced = world.block(worldX: cx, y: baseY + 2, worldZ: cz) == .gravel

            report.check(
                "sand/gravel displaces flowers and pressure plates",
                poppyDisplaced && plateDisplaced,
                "poppyDisplaced: \(poppyDisplaced), plateDisplaced: \(plateDisplaced)"
            )
        }

        // 4f2. Other non-solid scenery: rails, levers, signal torches
        do {
            let cx = originX + 34
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 1, worldZ: cz, to: .railNorthSouth, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 3, worldZ: cz, to: .sand, remesh: false)

            world.settleGranular(atWorldX: cx, worldZ: cz)
            let railBroken = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .sand

            report.check(
                "sand falls through and destroys/displaces rail (railNorthSouth)",
                railBroken,
                "block at y+1: \(world.block(worldX: cx, y: baseY + 1, worldZ: cz))"
            )

            world.setBlock(worldX: cx, y: baseY + 1, worldZ: cz, to: .leverOff, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 3, worldZ: cz, to: .gravel, remesh: false)
            world.settleGranular(atWorldX: cx, worldZ: cz)
            let leverBroken = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .gravel

            report.check(
                "gravel falls through and destroys/displaces lever (leverOff)",
                leverBroken,
                "block at y+1: \(world.block(worldX: cx, y: baseY + 1, worldZ: cz))"
            )

            world.setBlock(worldX: cx, y: baseY + 1, worldZ: cz, to: .signalTorchOn, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 3, worldZ: cz, to: .sand, remesh: false)
            world.settleGranular(atWorldX: cx, worldZ: cz)
            let signalTorchBroken = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .sand

            report.check(
                "sand falls through and destroys/displaces signal torch (signalTorchOn)",
                signalTorchBroken,
                "block at y+1: \(world.block(worldX: cx, y: baseY + 1, worldZ: cz))"
            )

            world.setBlock(worldX: cx, y: baseY + 1, worldZ: cz, to: .signalRelayOff, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 3, worldZ: cz, to: .gravel, remesh: false)
            world.settleGranular(atWorldX: cx, worldZ: cz)
            let signalRelayBroken = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .gravel

            report.check(
                "gravel falls through and destroys/displaces signal relay (signalRelayOff)",
                signalRelayBroken,
                "block at y+1: \(world.block(worldX: cx, y: baseY + 1, worldZ: cz))"
            )
        }

        // 4g. Multiple scenery items in one column
        do {
            let cx = originX + 35
            let cz = originZ + 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 1, worldZ: cz, to: .torch, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 2, worldZ: cz, to: .torch, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 3, worldZ: cz, to: .torch, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 5, worldZ: cz, to: .sand, remesh: false)

            world.settleGranular(atWorldX: cx, worldZ: cz)

            let sandLanded = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .sand
            let intermediateCleared = world.block(worldX: cx, y: baseY + 2, worldZ: cz) == .air
                && world.block(worldX: cx, y: baseY + 3, worldZ: cz) == .air

            report.check(
                "sand falls through multiple stacked torches clearing them all",
                sandLanded && intermediateCleared,
                "y+1: \(world.block(worldX: cx, y: baseY + 1, worldZ: cz)), y+2: \(world.block(worldX: cx, y: baseY + 2, worldZ: cz)), y+3: \(world.block(worldX: cx, y: baseY + 3, worldZ: cz))"
            )
        }

        // =========================================================================
        // SUITE 5: Crushing Damage Bounds Against Player and Mobs
        // =========================================================================
        // 5a. Player damage formula and bounds
        do {
            let pPos = Vector3(CGFloat(originX) + 0.5, CGFloat(baseY + 1), CGFloat(originZ) + 0.5)
            let player = PlayerController(spawn: pPos)

            // Fall distance 1: no damage. One cell is the distance a block
            // settles when you merely *place* it on uneven ground, so
            // charging two half-hearts for it meant putting a block of sand
            // down beside a pig hurt the pig. A fall has to be a fall before
            // it is a crushing — see `GranularTick.crushingFallThreshold`.
            var stats1: PlayerStats? = PlayerStats()
            var c1: FizzlerManager? = nil
            var s1: SkeletonManager? = nil
            var a1: AnimalManager? = nil
            let move1 = GranularTick.Move(block: .sand, x: originX, fromY: baseY + 2, toY: baseY + 1, z: originZ)
            let hitCount1 = GranularTick.applyCrushingDamage(
                moves: [move1], player: player, playerStats: &stats1,
                fizzlers: &c1, skeletons: &s1, animals: &a1
            )
            let d1 = PlayerStats.maxHealth - (stats1?.health ?? 0)

            // Fall distance 3: 3 * 2 = 6 damage
            var stats3: PlayerStats? = PlayerStats()
            let move3 = GranularTick.Move(block: .sand, x: originX, fromY: baseY + 4, toY: baseY + 1, z: originZ)
            _ = GranularTick.applyCrushingDamage(
                moves: [move3], player: player, playerStats: &stats3,
                fizzlers: &c1, skeletons: &s1, animals: &a1
            )
            let d3 = PlayerStats.maxHealth - (stats3?.health ?? 0)

            // Fall distance 6: 6 * 2 = 12 damage (cap)
            var stats6: PlayerStats? = PlayerStats()
            let move6 = GranularTick.Move(block: .sand, x: originX, fromY: baseY + 7, toY: baseY + 1, z: originZ)
            _ = GranularTick.applyCrushingDamage(
                moves: [move6], player: player, playerStats: &stats6,
                fizzlers: &c1, skeletons: &s1, animals: &a1
            )
            let d6 = PlayerStats.maxHealth - (stats6?.health ?? 0)

            // Fall distance 20: capped at 12 damage
            var stats20: PlayerStats? = PlayerStats()
            let move20 = GranularTick.Move(block: .sand, x: originX, fromY: baseY + 21, toY: baseY + 1, z: originZ)
            _ = GranularTick.applyCrushingDamage(
                moves: [move20], player: player, playerStats: &stats20,
                fizzlers: &c1, skeletons: &s1, animals: &a1
            )
            let d20 = PlayerStats.maxHealth - (stats20?.health ?? 0)

            let boundsCorrect = (hitCount1 == 0 && d1 == 0 && d3 == 6 && d6 == 12 && d20 == 12)

            report.check(
                "player crushing damage ignores a one-cell settle, scales (dist*2) and caps at 12",
                boundsCorrect,
                "d(1)=\(d1) [expected 0], d(3)=\(d3) [expected 6], d(6)=\(d6) [expected 12], d(20)=\(d20) [expected 12]"
            )

            // 5b. Armored player damage reduction
            var statsArmor: PlayerStats? = PlayerStats()
            statsArmor?.equip(.diamondChestplate)
            let diamondReduction = ItemType.diamondChestplate.armorReduction // 0.8
            _ = GranularTick.applyCrushingDamage(
                moves: [move6], player: player, playerStats: &statsArmor,
                fizzlers: &c1, skeletons: &s1, animals: &a1
            )
            // 12 * (1 - 0.8) = 2.4 -> 2 damage
            let expectedArmoredDmg = max(1, Int((Double(12) * (1.0 - diamondReduction)).rounded(.down)))
            let actualArmoredDmg = PlayerStats.maxHealth - (statsArmor?.health ?? 0)

            report.check(
                "armored player mitigates crushing damage",
                actualArmoredDmg == expectedArmoredDmg && actualArmoredDmg < d6,
                "unarmored: \(d6), armored: \(actualArmoredDmg), expected: \(expectedArmoredDmg)"
            )

            // 5c. Lethal damage does not cause health underflow
            var statsLethal: PlayerStats? = PlayerStats()
            // Apply 12 damage twice
            _ = GranularTick.applyCrushingDamage(
                moves: [move6, move6], player: player, playerStats: &statsLethal,
                fizzlers: &c1, skeletons: &s1, animals: &a1
            )
            report.check(
                "player health clamps to 0 upon lethal crushing damage",
                statsLethal?.health == 0 && (statsLethal?.isDead ?? false),
                "health: \(statsLethal?.health ?? -1), isDead: \(statsLethal?.isDead ?? false)"
            )

            // 5d. Player outside column takes no damage
            var statsFar: PlayerStats? = PlayerStats()
            let farMove = GranularTick.Move(block: .sand, x: originX + 5, fromY: baseY + 10, toY: baseY + 1, z: originZ)
            let hitFar = GranularTick.applyCrushingDamage(
                moves: [farMove], player: player, playerStats: &statsFar,
                fizzlers: &c1, skeletons: &s1, animals: &a1
            )
            report.check(
                "player outside falling column takes no damage",
                hitFar == 0 && statsFar?.health == PlayerStats.maxHealth,
                "hitFar: \(hitFar), health: \(statsFar?.health ?? 0)"
            )
        }

        // 5e. Mobs crushing damage (Fizzler, Skeleton, Animal)
        do {
            var cm: FizzlerManager? = FizzlerManager(mode: .survival, seed: 1)
            var sm: SkeletonManager? = SkeletonManager(mode: .survival, seed: 2)
            var am: AnimalManager? = AnimalManager(mode: .survival, seed: 3)

            let mobPos = Vector3(CGFloat(originX) + 0.5, CGFloat(baseY + 1), CGFloat(originZ) + 0.5)
            cm?.adopt([Fizzler(position: mobPos, seed: 10)])
            sm?.adopt([Skeleton(position: mobPos, seed: 20)])
            am?.adopt([Animal(kind: .cow, position: mobPos, seed: 30)])

            var nilStats: PlayerStats? = nil
            let move = GranularTick.Move(block: .sand, x: originX, fromY: baseY + 5, toY: baseY + 1, z: originZ)
            // fall distance 4 -> 8 damage
            let hits = GranularTick.applyCrushingDamage(
                moves: [move], player: nil, playerStats: &nilStats,
                fizzlers: &cm, skeletons: &sm, animals: &am
            )

            let fizzlerHp = cm?.fizzlers.values.first?.health ?? 0
            let skeletonHp = sm?.skeletons.values.first?.health ?? 0
            let cowHp = am?.animals.values.first?.health ?? 0

            report.check(
                "mobs take crushing damage proportional to fall distance",
                hits == 3 && fizzlerHp == (Fizzler.maxHealth - 8) && skeletonHp == (Skeleton.maxHealth - 8) && cowHp == (AnimalKind.cow.maxHealth - 8),
                "hits: \(hits), fizzler: \(fizzlerHp)/\(Fizzler.maxHealth), skeleton: \(skeletonHp)/\(Skeleton.maxHealth), cow: \(cowHp)/\(AnimalKind.cow.maxHealth)"
            )

            // Test mob kill from crushing
            let bigMove = GranularTick.Move(block: .sand, x: originX, fromY: baseY + 20, toY: baseY + 1, z: originZ)
            // 12 damage each time, hit twice
            _ = GranularTick.applyCrushingDamage(
                moves: [bigMove, bigMove], player: nil, playerStats: &nilStats,
                fizzlers: &cm, skeletons: &sm, animals: &am
            )

            let fizzlerDead = cm?.fizzlers.values.first?.isDead ?? false
            let skeletonDead = sm?.skeletons.values.first?.isDead ?? false
            let cowDead = am?.animals.values.first?.isDead ?? false

            report.check(
                "mobs die when crushing damage exceeds maximum health",
                fizzlerDead && skeletonDead && cowDead,
                "fizzlerDead: \(fizzlerDead), skeletonDead: \(skeletonDead), cowDead: \(cowDead)"
            )
        }

        // =========================================================================
        // SUITE 6: Blast Crater Settling Behavior & Mass Conservation
        // =========================================================================
        do {
            let bx = originX - 30
            let bz = originZ - 30
            let by = baseY + 10

            // Construct 11x11 ground area:
            // y = baseY ... by + 2: stone
            // y = by + 3 ... by + 5: sand and gravel layers (overburden)
            // y = by + 6 ... by + 10: air
            for dz in -5...5 {
                for dx in -5...5 {
                    for y in baseY...(by + 2) {
                        world.setBlock(worldX: bx + dx, y: y, worldZ: bz + dz, to: .stone, remesh: false)
                    }
                    world.setBlock(worldX: bx + dx, y: by + 3, worldZ: bz + dz, to: .sand, remesh: false)
                    world.setBlock(worldX: bx + dx, y: by + 4, worldZ: bz + dz, to: .gravel, remesh: false)
                    world.setBlock(worldX: bx + dx, y: by + 5, worldZ: bz + dz, to: .sand, remesh: false)
                    for y in (by + 6)...(by + 10) {
                        world.setBlock(worldX: bx + dx, y: y, worldZ: bz + dz, to: .air, remesh: false)
                    }
                }
            }

            // Detonate TNT at center: (bx, by + 1, bz) with radius 3.5
            world.setBlock(worldX: bx, y: by + 1, worldZ: bz, to: .tnt, remesh: false)
            _ = Blast.carve(
                at: Vector3(CGFloat(bx) + 0.5, CGFloat(by + 1) + 0.5, CGFloat(bz) + 0.5),
                radius: 3.5,
                in: world
            )

            // Count remaining granular blocks directly after blast (before settling)
            var postBlastGranularCount = 0
            for dz in -5...5 {
                for dx in -5...5 {
                    for y in baseY...(by + 6) {
                        let b = world.block(worldX: bx + dx, y: y, worldZ: bz + dz)
                        if b.hasGravity { postBlastGranularCount += 1 }
                    }
                }
            }

            // Trigger settleArea
            let radius = Int(ceil(3.5)) + 1
            let settleRes = world.settleGranular(around: (bx, by + 1, bz), radius: radius)

            // Count granular blocks after settling
            var postSettleGranularCount = 0
            for dz in -5...5 {
                for dx in -5...5 {
                    for y in baseY...(by + 6) {
                        let b = world.block(worldX: bx + dx, y: y, worldZ: bz + dz)
                        if b.hasGravity { postSettleGranularCount += 1 }
                    }
                }
            }

            // 6a. Conservation of mass in blast settling: post-blast count MUST equal post-settle count
            let massConserved = (postBlastGranularCount == postSettleGranularCount)

            // 6b. Blocks moved into crater
            let blocksMoved = settleRes.blocksMoved > 0

            // 6c. Cavity at blast center now has fallen granular material at its bottom
            var granularInCrater = 0
            for y in baseY...(by + 2) {
                let b = world.block(worldX: bx, y: y, worldZ: bz)
                if b.hasGravity { granularInCrater += 1 }
            }

            // 6d. Peripheral columns outside blast radius remained unchanged
            let cornerUnchanged = world.block(worldX: bx + 5, y: by + 3, worldZ: bz + 5) == .sand
                && world.block(worldX: bx + 5, y: by + 4, worldZ: bz + 5) == .gravel
                && world.block(worldX: bx + 5, y: by + 5, worldZ: bz + 5) == .sand

            report.check(
                "blast crater settling conserves mass (no lost/duplicated blocks)",
                massConserved,
                "pre-settle: \(postBlastGranularCount), post-settle: \(postSettleGranularCount)"
            )

            report.check(
                "overburden collapses into blast crater void",
                blocksMoved && granularInCrater > 0,
                "blocksMoved: \(settleRes.blocksMoved), granularInCrater: \(granularInCrater)"
            )

            report.check(
                "undisturbed perimeter remains intact after blast crater settling",
                cornerUnchanged,
                "corner intact: \(cornerUnchanged)"
            )
        }

        // =========================================================================
        // SUITE 7: Disjoint and Complex Vertical Column Structures
        // =========================================================================
        // Test 7a: Multiple air gaps within a single column
        do {
            let cx = originX - 10
            let cz = originZ - 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)

            // y=baseY: stone
            // y+1: air
            // y+2: air
            // y+3: sand
            // y+4: air
            // y+5: air
            // y+6: gravel
            // y+7: air
            // y+8: sand
            world.setBlock(worldX: cx, y: baseY + 3, worldZ: cz, to: .sand, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 6, worldZ: cz, to: .gravel, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 8, worldZ: cz, to: .sand, remesh: false)

            world.settleGranular(atWorldX: cx, worldZ: cz)

            let y1Sand = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .sand
            let y2Gravel = world.block(worldX: cx, y: baseY + 2, worldZ: cz) == .gravel
            let y3Sand = world.block(worldX: cx, y: baseY + 3, worldZ: cz) == .sand
            let y4Air = world.block(worldX: cx, y: baseY + 4, worldZ: cz) == .air
            let y6Air = world.block(worldX: cx, y: baseY + 6, worldZ: cz) == .air
            let y8Air = world.block(worldX: cx, y: baseY + 8, worldZ: cz) == .air

            report.check(
                "column with multiple air gaps consolidates to bottom in correct sequence",
                y1Sand && y2Gravel && y3Sand && y4Air && y6Air && y8Air,
                "y+1: \(world.block(worldX: cx, y: baseY + 1, worldZ: cz)), y+2: \(world.block(worldX: cx, y: baseY + 2, worldZ: cz)), y+3: \(world.block(worldX: cx, y: baseY + 3, worldZ: cz))"
            )
        }

        // Test 7b: Solid block barrier divides column
        do {
            let cx = originX - 12
            let cz = originZ - 10
            clearColumn(x: cx, z: cz)
            world.setBlock(worldX: cx, y: baseY, worldZ: cz, to: .stone, remesh: false)
            // y+1: air
            // y+2: sand
            // y+3: cobblestone (floating solid block)
            // y+4: air
            // y+5: gravel
            world.setBlock(worldX: cx, y: baseY + 2, worldZ: cz, to: .sand, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 3, worldZ: cz, to: .cobblestone, remesh: false)
            world.setBlock(worldX: cx, y: baseY + 5, worldZ: cz, to: .gravel, remesh: false)

            world.settleGranular(atWorldX: cx, worldZ: cz)

            let y1Sand = world.block(worldX: cx, y: baseY + 1, worldZ: cz) == .sand
            let y2Air = world.block(worldX: cx, y: baseY + 2, worldZ: cz) == .air
            let y3Cobble = world.block(worldX: cx, y: baseY + 3, worldZ: cz) == .cobblestone
            let y4Gravel = world.block(worldX: cx, y: baseY + 4, worldZ: cz) == .gravel
            let y5Air = world.block(worldX: cx, y: baseY + 5, worldZ: cz) == .air

            report.check(
                "solid barrier retains block above while lower block falls to floor",
                y1Sand && y2Air && y3Cobble && y4Gravel && y5Air,
                "y+1=\(world.block(worldX: cx, y: baseY + 1, worldZ: cz)), y+3=\(world.block(worldX: cx, y: baseY + 3, worldZ: cz)), y+4=\(world.block(worldX: cx, y: baseY + 4, worldZ: cz))"
            )
        }

        // Test 7c: Idempotency - running settleGranular on already settled world moves 0 blocks
        do {
            _ = world.settleGranular()
            let res = world.settleGranular()
            report.check(
                "settleGranular is idempotent (second run moves 0 blocks)",
                res.blocksMoved == 0,
                "blocksMoved on 2nd pass: \(res.blocksMoved)"
            )
        }

        // =========================================================================
        // Output Final Transcript
        // =========================================================================
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[gravity-stress] FAILED — granular gravity stress\n"
            : "[gravity-stress] all passed — granular gravity stress\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

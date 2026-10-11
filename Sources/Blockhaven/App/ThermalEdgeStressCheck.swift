import Foundation

/// Adversarial stress testing and edge-case verification for Milestone 2:
/// Thermal Microclimates & Subterranean Farming (Wave 9).
///
/// Exercises:
/// 1. Chunk boundary transitions: thermal radiance across X, Z, negative, and diagonal chunk seams,
///    whole-chunk thermal sweeping across borders, and cross-boundary farmland hydration.
/// 2. World persistence & journal replay: ice placement/breaking journal records, WorldSave JSON round-trip
///    serialization, dynamic freeze/thaw persistence, untended farmland reversion persistence, and 5-cycle mutation stability.
/// 3. Multiple heat sources: sub-threshold multi-source superposition, redundant source shielding with sequential
///    extinguishing, stacked thermal emitters, and 5x5 pool thermal array thawing.
/// 4. Boundary coordinates & climate thresholds: bedrock (y=0) and ceiling (y=127) query bounds, exact alpine
///    threshold (y=85 vs y=86), and snowy biome lowland vs roofed cavern freezing.
/// 5. Agricultural physics & photosynthetic boundaries: Chebyshev reach (4 vs 5), crop protection of dry farmland,
///    sharp light threshold (8 vs 9) for wheat and saplings, and light transmission through ice.
///
/// Run via `BLOCKHAVEN_CHECK_THERMAL_EDGE_STRESS=1`. Exits nonzero on failure.
enum ThermalEdgeStressCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_THERMAL_EDGE_STRESS"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[stress-check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    private static let dt = 1.0 / 60

    static func run() -> Never {
        var report = Report()
        let world = World(seed: 8888)
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))

        // Force generate 7x7 chunk grid around spawn
        for dz in -3...3 {
            for dx in -3...3 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        let originX = Int(spawn.x)
        let originZ = Int(spawn.z)

        // =========================================================================
        // MARK: - Section 1: Chunk Boundary Thermal Transitions
        // =========================================================================

        // 1a. Positive X-seam transition: Chunk (0,0) [x=0..15] and Chunk (1,0) [x=16..31]
        // Seam is between x=15 and x=16.
        let seamChunk0 = ChunkCoord(x: 0, z: 0)
        let seamChunk1 = ChunkCoord(x: 1, z: 0)
        world.forceGenerate(seamChunk0)
        world.forceGenerate(seamChunk1)

        let alpineY = 88
        // Clear platform across seam
        for z in 5...11 {
            for x in 12...20 {
                world.setBlock(worldX: x, y: alpineY - 1, worldZ: z, to: .stone, remesh: false)
                for y in alpineY..<Chunk.height {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }

        // Water at x=15 (Chunk 0), Torch at x=16 (Chunk 1) -> dx = 1 <= 3
        let xSeamWater = (x: 15, y: alpineY, z: 8)
        let xSeamTorch = (x: 16, y: alpineY, z: 8)
        world.setBlock(worldX: xSeamWater.x, y: xSeamWater.y, worldZ: xSeamWater.z, to: .water)
        world.setBlock(worldX: xSeamTorch.x, y: xSeamTorch.y, worldZ: xSeamTorch.z, to: .torch)

        let xSeamNearHeat = world.isNearThermalSource(worldX: xSeamWater.x, y: xSeamWater.y, worldZ: xSeamWater.z, radius: 3)
        world.tickThermal(atWorldX: xSeamWater.x, y: xSeamWater.y, worldZ: xSeamWater.z)
        let xSeamWaterProtected = world.block(worldX: xSeamWater.x, y: xSeamWater.y, worldZ: xSeamWater.z) == .water

        // Move torch to x=19 (Chunk 1) -> dx = 4 > 3 (beyond thermal reach)
        world.setBlock(worldX: xSeamTorch.x, y: xSeamTorch.y, worldZ: xSeamTorch.z, to: .air)
        world.setBlock(worldX: 19, y: alpineY, worldZ: 8, to: .torch)
        let xSeamNearDist4 = world.isNearThermalSource(worldX: xSeamWater.x, y: xSeamWater.y, worldZ: xSeamWater.z, radius: 3)
        world.tickThermal(atWorldX: xSeamWater.x, y: xSeamWater.y, worldZ: xSeamWater.z)
        let xSeamWaterFrozeAtDist4 = world.block(worldX: xSeamWater.x, y: xSeamWater.y, worldZ: xSeamWater.z) == .ice

        // Cross-seam thawing: Ice at x=15 (Chunk 0), Lit Furnace at x=17 (Chunk 1) -> dx = 2 <= 3
        world.setBlock(worldX: 19, y: alpineY, worldZ: 8, to: .air)
        world.setBlock(worldX: 17, y: alpineY, worldZ: 8, to: .furnaceLit)
        world.tickThermal(atWorldX: xSeamWater.x, y: xSeamWater.y, worldZ: xSeamWater.z)
        let xSeamIceThawed = world.block(worldX: xSeamWater.x, y: xSeamWater.y, worldZ: xSeamWater.z) == .water

        report.check(
            "cross-seam thermal radiance: positive X chunk boundary shielding, cutoff, and thawing",
            xSeamNearHeat && xSeamWaterProtected && !xSeamNearDist4 && xSeamWaterFrozeAtDist4 && xSeamIceThawed,
            "nearHeat: \(xSeamNearHeat), protected: \(xSeamWaterProtected), dist4Near: \(xSeamNearDist4), froze: \(xSeamWaterFrozeAtDist4), thawed: \(xSeamIceThawed)"
        )

        // 1b. Positive Z-seam transition: Chunk (0,0) [z=0..15] and Chunk (0,1) [z=16..31]
        // Seam is between z=15 and z=16.
        let seamChunkZ1 = ChunkCoord(x: 0, z: 1)
        world.forceGenerate(seamChunkZ1)
        for z in 12...20 {
            for x in 5...11 {
                world.setBlock(worldX: x, y: alpineY - 1, worldZ: z, to: .stone, remesh: false)
                for y in alpineY..<Chunk.height {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }
        let zSeamWater = (x: 8, y: alpineY, z: 15)
        let zSeamLava = (x: 8, y: alpineY, z: 17) // dz = 2 in Chunk (0,1)
        world.setBlock(worldX: zSeamWater.x, y: zSeamWater.y, worldZ: zSeamWater.z, to: .water)
        world.setBlock(worldX: zSeamLava.x, y: zSeamLava.y, worldZ: zSeamLava.z, to: .lava)

        let zSeamNearLava = world.isNearThermalSource(worldX: zSeamWater.x, y: zSeamWater.y, worldZ: zSeamWater.z, radius: 3)
        world.tickThermal(atWorldX: zSeamWater.x, y: zSeamWater.y, worldZ: zSeamWater.z)
        let zSeamWaterProtected = world.block(worldX: zSeamWater.x, y: zSeamWater.y, worldZ: zSeamWater.z) == .water

        report.check(
            "cross-seam thermal radiance: positive Z chunk boundary lava shielding",
            zSeamNearLava && zSeamWaterProtected,
            "nearLava: \(zSeamNearLava), protected: \(zSeamWaterProtected)"
        )

        // 1c. Negative X-seam transition: Chunk (-1,0) [x=-16..-1] and Chunk (0,0) [x=0..15]
        // Seam is between x=-1 and x=0.
        let seamChunkNegX = ChunkCoord(x: -1, z: 0)
        world.forceGenerate(seamChunkNegX)
        for z in 5...11 {
            for x in -5...5 {
                world.setBlock(worldX: x, y: alpineY - 1, worldZ: z, to: .stone, remesh: false)
                for y in alpineY..<Chunk.height {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }
        let negXWater = (x: -1, y: alpineY, z: 8)
        let negXLamp = (x: 1, y: alpineY, z: 8) // dx = 2 across origin seam
        world.setBlock(worldX: negXWater.x, y: negXWater.y, worldZ: negXWater.z, to: .water)
        world.setBlock(worldX: negXLamp.x, y: negXLamp.y, worldZ: negXLamp.z, to: .signalLampLit)

        let negXNearLamp = world.isNearThermalSource(worldX: negXWater.x, y: negXWater.y, worldZ: negXWater.z, radius: 3)
        world.tickThermal(atWorldX: negXWater.x, y: negXWater.y, worldZ: negXWater.z)
        let negXProtected = world.block(worldX: negXWater.x, y: negXWater.y, worldZ: negXWater.z) == .water

        // Turn lamp unlit: water freezes
        world.setBlock(worldX: negXLamp.x, y: negXLamp.y, worldZ: negXLamp.z, to: .signalLamp)
        world.tickThermal(atWorldX: negXWater.x, y: negXWater.y, worldZ: negXWater.z)
        let negXFroze = world.block(worldX: negXWater.x, y: negXWater.y, worldZ: negXWater.z) == .ice

        report.check(
            "cross-seam thermal radiance: negative-origin X chunk boundary lamp shielding & freeze",
            negXNearLamp && negXProtected && negXFroze,
            "nearLamp: \(negXNearLamp), protected: \(negXProtected), froze: \(negXFroze)"
        )

        // 1d. Diagonal 4-way corner transition: Chunk (0,0) (15, y, 15) to Chunk (1,1) (16, y, 16)
        let diagChunk11 = ChunkCoord(x: 1, z: 1)
        world.forceGenerate(diagChunk11)
        for z in 14...18 {
            for x in 14...18 {
                world.setBlock(worldX: x, y: alpineY - 1, worldZ: z, to: .stone, remesh: false)
                for y in alpineY..<Chunk.height {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }
        let diagWater = (x: 15, y: alpineY, z: 15)
        let diagTorch = (x: 16, y: alpineY, z: 16) // max(|16-15|, |16-15|) = 1 <= 3
        world.setBlock(worldX: diagWater.x, y: diagWater.y, worldZ: diagWater.z, to: .water)
        world.setBlock(worldX: diagTorch.x, y: diagTorch.y, worldZ: diagTorch.z, to: .torch)

        let diagNearTorch = world.isNearThermalSource(worldX: diagWater.x, y: diagWater.y, worldZ: diagWater.z, radius: 3)
        world.tickThermal(atWorldX: diagWater.x, y: diagWater.y, worldZ: diagWater.z)
        let diagProtected = world.block(worldX: diagWater.x, y: diagWater.y, worldZ: diagWater.z) == .water

        report.check(
            "cross-seam thermal radiance: diagonal chunk vertex corner torch shielding",
            diagNearTorch && diagProtected,
            "diagNear: \(diagNearTorch), protected: \(diagProtected)"
        )

        // 1e. Whole-chunk thermal ticking across border
        // In Chunk (0,0), place ice at (15, 70, 4). In Chunk (1,0), place torch at (16, 70, 4).
        world.setBlock(worldX: 15, y: 69, worldZ: 4, to: .stone, remesh: false)
        world.setBlock(worldX: 16, y: 69, worldZ: 4, to: .stone, remesh: false)
        world.setBlock(worldX: 15, y: 70, worldZ: 4, to: .ice)
        world.setBlock(worldX: 16, y: 70, worldZ: 4, to: .torch)

        let transitions = world.tickThermal(in: ChunkCoord(x: 0, z: 0))
        let chunkSweepThawed = world.block(worldX: 15, y: 70, worldZ: 4) == .water

        report.check(
            "whole-chunk sweep tickThermal(in:) thaws seam ice from neighbor chunk heat source",
            transitions >= 1 && chunkSweepThawed,
            "transitions: \(transitions), thawed: \(chunkSweepThawed)"
        )

        // 1f. Farmland hydration across chunk boundary: Water in Chunk (1,0) at x=16 hydrates Farmland in Chunk (0,0) at x=15
        world.setBlock(worldX: 15, y: 69, worldZ: 2, to: .farmland, remesh: false)
        world.setBlock(worldX: 16, y: 69, worldZ: 2, to: .water, remesh: false)
        let seamHydrated = world.isFarmlandHydrated(worldX: 15, y: 69, worldZ: 2, reach: 4)

        // Farmland at x=11 (dx = 5 > reach 4) is NOT hydrated
        world.setBlock(worldX: 11, y: 69, worldZ: 2, to: .farmland, remesh: false)
        let seamBeyondReach = !world.isFarmlandHydrated(worldX: 11, y: 69, worldZ: 2, reach: 4)

        report.check(
            "farmland hydration across chunk boundary seam (reach 4 vs 5)",
            seamHydrated && seamBeyondReach,
            "seamHydrated: \(seamHydrated), seamBeyondReach: \(seamBeyondReach)"
        )

        // =========================================================================
        // MARK: - Section 2: World Persistence & Journal Replay
        // =========================================================================

        // 2a. Direct ice block placement and journal replay
        let persistPos = (x: originX + 2, y: 72, z: originZ + 2)
        world.setBlock(worldX: persistPos.x, y: persistPos.y, worldZ: persistPos.z, to: .ice)
        let journal1 = world.editJournal
        let restoredWorld1 = World(seed: world.seed, edits: journal1)
        let restoredCoord1 = World.chunkCoord(forWorldX: persistPos.x, worldZ: persistPos.z)
        restoredWorld1.forceGenerate(restoredCoord1)

        let restoredBlock1 = restoredWorld1.block(worldX: persistPos.x, y: persistPos.y, worldZ: persistPos.z)
        let iceIsSolid = restoredBlock1.isSolid
        let iceIsOpaque = restoredBlock1.isOpaque
        let iceIsTranslucent = restoredBlock1.isTranslucent

        report.check(
            "world journal replay restores ice block and preserves optical/physical properties",
            restoredBlock1 == .ice && iceIsSolid && !iceIsOpaque && iceIsTranslucent,
            "block: \(restoredBlock1), solid: \(iceIsSolid), opaque: \(iceIsOpaque), translucent: \(iceIsTranslucent)"
        )

        // 2b. Breaking ice and journal replay
        world.setBlock(worldX: persistPos.x, y: persistPos.y, worldZ: persistPos.z, to: .air)
        let journal2 = world.editJournal
        let restoredWorld2 = World(seed: world.seed, edits: journal2)
        restoredWorld2.forceGenerate(restoredCoord1)
        let restoredBlock2 = restoredWorld2.block(worldX: persistPos.x, y: persistPos.y, worldZ: persistPos.z)

        report.check(
            "breaking ice to air persists through journal replay",
            restoredBlock2 == .air,
            "block: \(restoredBlock2)"
        )

        // 2c. Thermal transition journal persistence via WorldSave JSON encoding/decoding
        let freezePos = (x: originX - 5, y: alpineY, z: originZ - 5)
        world.setBlock(worldX: freezePos.x, y: freezePos.y - 1, worldZ: freezePos.z, to: .stone, remesh: false)
        for y in freezePos.y..<Chunk.height {
            world.setBlock(worldX: freezePos.x, y: y, worldZ: freezePos.z, to: .air, remesh: false)
        }
        world.setBlock(worldX: freezePos.x, y: freezePos.y, worldZ: freezePos.z, to: .water)
        world.tickThermal(atWorldX: freezePos.x, y: freezePos.y, worldZ: freezePos.z)
        let frozeToIce = world.block(worldX: freezePos.x, y: freezePos.y, worldZ: freezePos.z) == .ice

        // Encode to WorldSave JSON
        let saveSnapshot1 = WorldSave(
            seed: world.seed,
            mode: .survival,
            name: "ThermalStress1",
            lastPlayed: 1000.0,
            edits: world.editJournal,
            position: Vector3(CGFloat(freezePos.x), CGFloat(freezePos.y), CGFloat(freezePos.z)),
            yaw: 0,
            pitch: 0,
            inventory: Inventory(),
            stats: PlayerStats(),
            timeOfDay: 0.25
        )

        var jsonRoundTripSuccess = false
        var restoredSaveIce = false
        if let encodedData = try? JSONEncoder().encode(saveSnapshot1),
           let decodedSave = try? JSONDecoder().decode(WorldSave.self, from: encodedData) {
            jsonRoundTripSuccess = true
            let restoredWorldFromSave = World(seed: decodedSave.seed, edits: decodedSave.editJournal)
            restoredWorldFromSave.forceGenerate(World.chunkCoord(forWorldX: freezePos.x, worldZ: freezePos.z))
            restoredSaveIce = restoredWorldFromSave.block(worldX: freezePos.x, y: freezePos.y, worldZ: freezePos.z) == .ice
        }

        report.check(
            "thermally frozen ice survives WorldSave JSON serialization round-trip",
            frozeToIce && jsonRoundTripSuccess && restoredSaveIce,
            "froze: \(frozeToIce), jsonSuccess: \(jsonRoundTripSuccess), restoredIce: \(restoredSaveIce)"
        )

        // 2d. Untended dry farmland reversion persistence in WorldSave
        let dryFarmPos = (x: originX - 5, y: 70, z: originZ + 5)
        world.setBlock(worldX: dryFarmPos.x, y: dryFarmPos.y, worldZ: dryFarmPos.z, to: .farmland)
        world.setBlock(worldX: dryFarmPos.x + 2, y: dryFarmPos.y, worldZ: dryFarmPos.z, to: .ice) // Ice does not hydrate
        world.tickFarmland(worldX: dryFarmPos.x, y: dryFarmPos.y, worldZ: dryFarmPos.z)
        let revertedToDirt = world.block(worldX: dryFarmPos.x, y: dryFarmPos.y, worldZ: dryFarmPos.z) == .dirt

        let saveSnapshot2 = WorldSave(
            seed: world.seed,
            mode: .survival,
            name: "ThermalStress2",
            lastPlayed: 1000.0,
            edits: world.editJournal,
            position: Vector3(CGFloat(dryFarmPos.x), CGFloat(dryFarmPos.y), CGFloat(dryFarmPos.z)),
            yaw: 0,
            pitch: 0,
            inventory: Inventory(),
            stats: PlayerStats(),
            timeOfDay: 0.25
        )

        var restoredRevertedDirt = false
        if let encoded = try? JSONEncoder().encode(saveSnapshot2),
           let decoded = try? JSONDecoder().decode(WorldSave.self, from: encoded) {
            let restored = World(seed: decoded.seed, edits: decoded.editJournal)
            restored.forceGenerate(World.chunkCoord(forWorldX: dryFarmPos.x, worldZ: dryFarmPos.z))
            restoredRevertedDirt = restored.block(worldX: dryFarmPos.x, y: dryFarmPos.y, worldZ: dryFarmPos.z) == .dirt
        }

        report.check(
            "untended dry farmland reversion to dirt persists through WorldSave round-trip",
            revertedToDirt && restoredRevertedDirt,
            "reverted: \(revertedToDirt), restoredDirt: \(restoredRevertedDirt)"
        )

        // 2e. 5-cycle mutation and persistence stress
        var cycleJournal = world.editJournal
        var cyclePass = true
        let testCell = (x: originX + 10, y: 75, z: originZ + 10)
        let cycleStates: [BlockType] = [.water, .ice, .air, .ice, .water]

        for (cycleIdx, targetState) in cycleStates.enumerated() {
            let cWorld = World(seed: 12345, edits: cycleJournal)
            cWorld.forceGenerate(World.chunkCoord(forWorldX: testCell.x, worldZ: testCell.z))
            cWorld.setBlock(worldX: testCell.x, y: testCell.y, worldZ: testCell.z, to: targetState)

            let save = WorldSave(
                seed: 12345,
                mode: .survival,
                name: "CycleSave_\(cycleIdx)",
                lastPlayed: Double(cycleIdx),
                edits: cWorld.editJournal,
                position: .zero,
                yaw: 0,
                pitch: 0,
                inventory: Inventory(),
                stats: PlayerStats(),
                timeOfDay: 0.5
            )

            guard let enc = try? JSONEncoder().encode(save),
                  let dec = try? JSONDecoder().decode(WorldSave.self, from: enc) else {
                cyclePass = false
                break
            }

            cycleJournal = dec.editJournal
            let verifiedWorld = World(seed: 12345, edits: cycleJournal)
            verifiedWorld.forceGenerate(World.chunkCoord(forWorldX: testCell.x, worldZ: testCell.z))
            if verifiedWorld.block(worldX: testCell.x, y: testCell.y, worldZ: testCell.z) != targetState {
                cyclePass = false
                break
            }
        }

        report.check(
            "5-cycle mutation and WorldSave persistence stability across thermal block states",
            cyclePass,
            "cyclePass: \(cyclePass)"
        )

        // =========================================================================
        // MARK: - Section 3: Multiple Heat Sources Interacting & Superposition
        // =========================================================================

        // 3a. Sub-threshold multi-source superposition: 4 torches at distance 4 do NOT sum to protect water
        let multiPos = (x: originX + 20, y: alpineY, z: originZ + 20)
        world.setBlock(worldX: multiPos.x, y: multiPos.y - 1, worldZ: multiPos.z, to: .stone, remesh: false)
        for y in multiPos.y..<Chunk.height {
            world.setBlock(worldX: multiPos.x, y: y, worldZ: multiPos.z, to: .air, remesh: false)
        }
        world.setBlock(worldX: multiPos.x, y: multiPos.y, worldZ: multiPos.z, to: .water)

        // Surround with 4 torches at distance dx = ±4, dz = ±4 (outside R=3)
        let offsets = [(4, 0), (-4, 0), (0, 4), (0, -4)]
        for (dx, dz) in offsets {
            world.setBlock(worldX: multiPos.x + dx, y: multiPos.y - 1, worldZ: multiPos.z + dz, to: .stone, remesh: false)
            world.setBlock(worldX: multiPos.x + dx, y: multiPos.y, worldZ: multiPos.z + dz, to: .torch)
        }

        let multiNearHeat = world.isNearThermalSource(worldX: multiPos.x, y: multiPos.y, worldZ: multiPos.z, radius: 3)
        world.tickThermal(atWorldX: multiPos.x, y: multiPos.y, worldZ: multiPos.z)
        let multiFroze = world.block(worldX: multiPos.x, y: multiPos.y, worldZ: multiPos.z) == .ice

        report.check(
            "sub-threshold thermal superposition: 4 torches at distance 4 do not prevent freeze",
            !multiNearHeat && multiFroze,
            "nearHeat: \(multiNearHeat), froze: \(multiFroze)"
        )

        // 3b. Redundant source shielding with sequential extinguishing
        let redunPos = (x: originX - 20, y: alpineY, z: originZ + 20)
        world.setBlock(worldX: redunPos.x, y: redunPos.y - 1, worldZ: redunPos.z, to: .stone, remesh: false)
        for y in redunPos.y..<Chunk.height {
            world.setBlock(worldX: redunPos.x, y: y, worldZ: redunPos.z, to: .air, remesh: false)
        }
        world.setBlock(worldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z, to: .water)

        // Place 3 active heat sources laterally so overhead sky remains completely open:
        // Torch at dx=+2, Lit Furnace at dz=+2, Lit Lamp at dx=-2
        world.setBlock(worldX: redunPos.x + 2, y: redunPos.y - 1, worldZ: redunPos.z, to: .stone, remesh: false)
        world.setBlock(worldX: redunPos.x + 2, y: redunPos.y, worldZ: redunPos.z, to: .torch)

        world.setBlock(worldX: redunPos.x, y: redunPos.y - 1, worldZ: redunPos.z + 2, to: .stone, remesh: false)
        world.setBlock(worldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z + 2, to: .furnaceLit)

        world.setBlock(worldX: redunPos.x - 2, y: redunPos.y - 1, worldZ: redunPos.z, to: .stone, remesh: false)
        world.setBlock(worldX: redunPos.x - 2, y: redunPos.y, worldZ: redunPos.z, to: .signalLampLit)

        // Step 1: All 3 active -> water protected
        world.tickThermal(atWorldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z)
        let step1Protected = world.block(worldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z) == .water

        // Step 2: Extinguish lamp (turn to unlit .signalLamp) -> Torch and Furnace still protect
        world.setBlock(worldX: redunPos.x - 2, y: redunPos.y, worldZ: redunPos.z, to: .signalLamp)
        world.tickThermal(atWorldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z)
        let step2Protected = world.block(worldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z) == .water

        // Step 3: Extinguish furnace (turn to unlit .furnace) -> Torch still protects
        world.setBlock(worldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z + 2, to: .furnace)
        world.tickThermal(atWorldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z)
        let step3Protected = world.block(worldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z) == .water

        // Step 4: Remove torch -> NO active heat source remains AND sky is open -> freezes to ice
        world.setBlock(worldX: redunPos.x + 2, y: redunPos.y, worldZ: redunPos.z, to: .air)
        world.tickThermal(atWorldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z)
        let step4Froze = world.block(worldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z) == .ice

        // Step 5: Re-ignite lamp -> thaws back to water
        world.setBlock(worldX: redunPos.x - 2, y: redunPos.y, worldZ: redunPos.z, to: .signalLampLit)
        world.tickThermal(atWorldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z)
        let step5Thawed = world.block(worldX: redunPos.x, y: redunPos.y, worldZ: redunPos.z) == .water

        report.check(
            "redundant multi-source protection with sequential extinguishing and re-ignition",
            step1Protected && step2Protected && step3Protected && step4Froze && step5Thawed,
            "s1: \(step1Protected), s2: \(step2Protected), s3: \(step3Protected), s4: \(step4Froze), s5: \(step5Thawed)"
        )

        // 3c. 5x5 ice sheet thawed by 4 corner torches
        let poolCenter = (x: originX + 25, y: 70, z: originZ - 20)
        for dz in -2...2 {
            for dx in -2...2 {
                world.setBlock(worldX: poolCenter.x + dx, y: poolCenter.y - 1, worldZ: poolCenter.z + dz, to: .stone, remesh: false)
                world.setBlock(worldX: poolCenter.x + dx, y: poolCenter.y, worldZ: poolCenter.z + dz, to: .ice)
            }
        }
        // Place 4 torches at (±2, ±2) inside the pool platform at elevation y
        world.setBlock(worldX: poolCenter.x + 2, y: poolCenter.y, worldZ: poolCenter.z + 2, to: .torch)
        world.setBlock(worldX: poolCenter.x + 2, y: poolCenter.y, worldZ: poolCenter.z - 2, to: .torch)
        world.setBlock(worldX: poolCenter.x - 2, y: poolCenter.y, worldZ: poolCenter.z + 2, to: .torch)
        world.setBlock(worldX: poolCenter.x - 2, y: poolCenter.y, worldZ: poolCenter.z - 2, to: .torch)

        // Tick all ice cells in the 5x5 sheet
        var allThawed = true
        for dz in -2...2 {
            for dx in -2...2 {
                if abs(dx) == 2 && abs(dz) == 2 { continue } // skip the torch blocks
                world.tickThermal(atWorldX: poolCenter.x + dx, y: poolCenter.y, worldZ: poolCenter.z + dz)
                if world.block(worldX: poolCenter.x + dx, y: poolCenter.y, worldZ: poolCenter.z + dz) != .water {
                    allThawed = false
                }
            }
        }

        report.check(
            "5x5 ice sheet thermal field coverage thaws all 21 interior/edge cells",
            allThawed,
            "allThawed: \(allThawed)"
        )

        // =========================================================================
        // MARK: - Section 4: Boundary Coordinates & Climate Thresholds
        // =========================================================================

        // 4a. Extreme vertical coordinates: y = 0 and y = Chunk.height - 1
        let nearBedrock = world.isNearThermalSource(worldX: originX, y: 0, worldZ: originZ, radius: 3)
        let nearCeiling = world.isNearThermalSource(worldX: originX, y: Chunk.height - 1, worldZ: originZ, radius: 3)

        report.check(
            "extreme vertical coordinate bounds safety (y=0 and y=Chunk.height-1)",
            !nearBedrock && !nearCeiling,
            "nearBedrock: \(nearBedrock), nearCeiling: \(nearCeiling)"
        )

        // 4b. Strict alpine threshold: y = 85 (lowland) vs y = 86 (alpine) in temperate biome
        let temperateX = originX + 30
        let temperateZ = originZ + 30
        // Find a temperate column if needed
        var tempCol: (x: Int, z: Int) = (temperateX, temperateZ)
        if world.generator.biome(x: tempCol.x, z: tempCol.z) == .snowy {
            tempCol = (originX, originZ)
        }

        // Test y = 85
        world.setBlock(worldX: tempCol.x, y: 84, worldZ: tempCol.z, to: .stone, remesh: false)
        for y in 85..<Chunk.height {
            world.setBlock(worldX: tempCol.x, y: y, worldZ: tempCol.z, to: .air, remesh: false)
        }
        world.setBlock(worldX: tempCol.x, y: 85, worldZ: tempCol.z, to: .water)
        let canFreeze85 = world.canFreeze(atWorldX: tempCol.x, y: 85, worldZ: tempCol.z)
        world.tickThermal(atWorldX: tempCol.x, y: 85, worldZ: tempCol.z)
        let remainsWaterAt85 = world.block(worldX: tempCol.x, y: 85, worldZ: tempCol.z) == .water

        // Test y = 86
        world.setBlock(worldX: tempCol.x + 1, y: 85, worldZ: tempCol.z, to: .stone, remesh: false)
        for y in 86..<Chunk.height {
            world.setBlock(worldX: tempCol.x + 1, y: y, worldZ: tempCol.z, to: .air, remesh: false)
        }
        world.setBlock(worldX: tempCol.x + 1, y: 86, worldZ: tempCol.z, to: .water)
        let canFreeze86 = world.canFreeze(atWorldX: tempCol.x + 1, y: 86, worldZ: tempCol.z)
        world.tickThermal(atWorldX: tempCol.x + 1, y: 86, worldZ: tempCol.z)
        let freezesToIceAt86 = world.block(worldX: tempCol.x + 1, y: 86, worldZ: tempCol.z) == .ice

        report.check(
            "strict alpine elevation threshold boundary: y=85 remains liquid vs y=86 freezes",
            !canFreeze85 && remainsWaterAt85 && canFreeze86 && freezesToIceAt86,
            "freeze85: \(canFreeze85), water85: \(remainsWaterAt85), freeze86: \(canFreeze86), ice86: \(freezesToIceAt86)"
        )

        // 4c. Biome.snowy: lowland freezing vs roofed cavern protection
        var snowyCoord: (x: Int, z: Int)?
        for r in 0..<150 {
            for dz in -r...r {
                for dx in -r...r where abs(dx) == r || abs(dz) == r || r == 0 {
                    let cx = originX + dx * 8, cz = originZ + dz * 8
                    if world.generator.biome(x: cx, z: cz) == .snowy {
                        snowyCoord = (cx, cz)
                        break
                    }
                }
                if snowyCoord != nil { break }
            }
            if snowyCoord != nil { break }
        }

        if let snowy = snowyCoord {
            let sc = World.chunkCoord(forWorldX: snowy.x, worldZ: snowy.z)
            world.forceGenerate(sc)

            // Open lowland water at y=70 freezes
            world.setBlock(worldX: snowy.x, y: 69, worldZ: snowy.z, to: .stone, remesh: false)
            for y in 70..<Chunk.height { world.setBlock(worldX: snowy.x, y: y, worldZ: snowy.z, to: .air, remesh: false) }
            world.setBlock(worldX: snowy.x, y: 70, worldZ: snowy.z, to: .water)
            world.tickThermal(atWorldX: snowy.x, y: 70, worldZ: snowy.z)
            let snowyLowlandFroze = world.block(worldX: snowy.x, y: 70, worldZ: snowy.z) == .ice

            // Roofed lowland water at y=70 with stone roof at y=71 remains liquid
            world.setBlock(worldX: snowy.x + 2, y: 69, worldZ: snowy.z, to: .stone, remesh: false)
            world.setBlock(worldX: snowy.x + 2, y: 70, worldZ: snowy.z, to: .water)
            world.setBlock(worldX: snowy.x + 2, y: 71, worldZ: snowy.z, to: .stone)
            world.tickThermal(atWorldX: snowy.x + 2, y: 70, worldZ: snowy.z)
            let snowyRoofedRemainedWater = world.block(worldX: snowy.x + 2, y: 70, worldZ: snowy.z) == .water

            // Deep underground cavern at y=20 in Biome.snowy remains liquid
            world.setBlock(worldX: snowy.x, y: 19, worldZ: snowy.z, to: .stone, remesh: false)
            world.setBlock(worldX: snowy.x, y: 20, worldZ: snowy.z, to: .water)
            world.setBlock(worldX: snowy.x, y: 21, worldZ: snowy.z, to: .stone)
            world.tickThermal(atWorldX: snowy.x, y: 20, worldZ: snowy.z)
            let snowyDeepCavernRemainedWater = world.block(worldX: snowy.x, y: 20, worldZ: snowy.z) == .water

            report.check(
                "Biome.snowy microclimate: open lowland freezes, roofed and deep subterranean water remain liquid",
                snowyLowlandFroze && snowyRoofedRemainedWater && snowyDeepCavernRemainedWater,
                "lowlandFroze: \(snowyLowlandFroze), roofedWater: \(snowyRoofedRemainedWater), deepWater: \(snowyDeepCavernRemainedWater)"
            )
        }

        // =========================================================================
        // MARK: - Section 5: Agricultural Physics & Photosynthetic Boundaries
        // =========================================================================

        // 5a. Farmland Chebyshev reach: reach 4 hydrates, reach 5 does not
        let farmTestPos = (x: originX - 30, y: 70, z: originZ - 30)
        world.setBlock(worldX: farmTestPos.x, y: farmTestPos.y, worldZ: farmTestPos.z, to: .farmland)

        // Water at dx=4, dz=4 -> max(|4|, |4|) = 4 <= 4
        world.setBlock(worldX: farmTestPos.x + 4, y: farmTestPos.y, worldZ: farmTestPos.z + 4, to: .water)
        let reach4Hydrated = world.isFarmlandHydrated(worldX: farmTestPos.x, y: farmTestPos.y, worldZ: farmTestPos.z, reach: 4)

        // Remove water at (4,4), place at dx=5, dz=0 -> max(|5|, |0|) = 5 > 4
        world.setBlock(worldX: farmTestPos.x + 4, y: farmTestPos.y, worldZ: farmTestPos.z + 4, to: .stone)
        world.setBlock(worldX: farmTestPos.x + 5, y: farmTestPos.y, worldZ: farmTestPos.z, to: .water)
        let reach5Hydrated = world.isFarmlandHydrated(worldX: farmTestPos.x, y: farmTestPos.y, worldZ: farmTestPos.z, reach: 4)

        report.check(
            "farmland Chebyshev reach precision (dx=4,dz=4 hydrates; dx=5 does not)",
            reach4Hydrated && !reach5Hydrated,
            "reach4: \(reach4Hydrated), reach5: \(reach5Hydrated)"
        )

        // 5b. Crop protects unhydrated farmland from reverting
        let cropProtectFarm = (x: farmTestPos.x - 2, y: farmTestPos.y, z: farmTestPos.z)
        world.setBlock(worldX: cropProtectFarm.x, y: cropProtectFarm.y, worldZ: cropProtectFarm.z, to: .farmland)
        world.setBlock(worldX: cropProtectFarm.x, y: cropProtectFarm.y + 1, worldZ: cropProtectFarm.z, to: .wheatStage1)

        // Farmland is unhydrated, but has crop above -> tickFarmland must NOT revert
        let tickedProtected = world.tickFarmland(worldX: cropProtectFarm.x, y: cropProtectFarm.y, worldZ: cropProtectFarm.z)
        let farmStillExists = world.block(worldX: cropProtectFarm.x, y: cropProtectFarm.y, worldZ: cropProtectFarm.z) == .farmland

        report.check(
            "planted crop protects unhydrated farmland from reversion to dirt",
            !tickedProtected && farmStillExists,
            "ticked: \(tickedProtected), stillFarmland: \(farmStillExists)"
        )

        // 5c. Subterranean sapling photosynthetic threshold (light >= 9 vs light <= 8)
        let saplingCaveOrigin = (x: originX + 40, y: 20, z: originZ + 40)
        for y in 19...26 {
            for z in (saplingCaveOrigin.z - 4)...(saplingCaveOrigin.z + 10) {
                for x in (saplingCaveOrigin.x - 4)...(saplingCaveOrigin.x + 4) {
                    let isCav = y >= 20 && y <= 25 && abs(x - saplingCaveOrigin.x) <= 3
                    world.setBlock(worldX: x, y: y, worldZ: z, to: isCav ? .air : .stone, remesh: false)
                }
            }
        }

        // Torch at saplingCaveOrigin: emission = 14
        world.setBlock(worldX: saplingCaveOrigin.x, y: 20, worldZ: saplingCaveOrigin.z, to: .torch)

        // Distance 5 along Z -> light = 14 - 5 = 9 (Sapling A)
        let saplingPos9 = (x: saplingCaveOrigin.x, y: 20, z: saplingCaveOrigin.z + 5)
        world.setBlock(worldX: saplingPos9.x, y: 19, worldZ: saplingPos9.z, to: .dirt, remesh: false)
        world.setBlock(worldX: saplingPos9.x, y: 20, worldZ: saplingPos9.z, to: .sapling)

        // Distance 6 along Z -> light = 14 - 6 = 8 (Sapling B)
        let saplingPos8 = (x: saplingCaveOrigin.x, y: 20, z: saplingCaveOrigin.z + 6)
        world.setBlock(worldX: saplingPos8.x, y: 19, worldZ: saplingPos8.z, to: .dirt, remesh: false)
        world.setBlock(worldX: saplingPos8.x, y: 20, worldZ: saplingPos8.z, to: .sapling)

        let sapLight9 = world.lightLevel(worldX: saplingPos9.x, y: saplingPos9.y, worldZ: saplingPos9.z)
        let sapLight8 = world.lightLevel(worldX: saplingPos8.x, y: saplingPos8.y, worldZ: saplingPos8.z)

        let sapStore = SaplingStore()
        let keySap9 = SaplingStore.Key(saplingPos9.x, saplingPos9.y, saplingPos9.z)
        let keySap8 = SaplingStore.Key(saplingPos8.x, saplingPos8.y, saplingPos8.z)
        sapStore.planted(at: keySap9)
        sapStore.planted(at: keySap8)

        var sapElapsed = 0.0
        var sap9Matured = false
        var sap8Matured = false
        while sapElapsed < SaplingStore.growSeconds * 1.5 {
            let maturedKeys = sapStore.tick(dt: dt, world: world)
            if maturedKeys.contains(keySap9) { sap9Matured = true }
            if maturedKeys.contains(keySap8) { sap8Matured = true }
            sapElapsed += dt
        }

        report.check(
            "subterranean sapling photosynthetic threshold: grows at light 9, stalls at light 8",
            sapLight9 == 9 && sapLight8 == 8 && sap9Matured && !sap8Matured,
            "light9: \(sapLight9), light8: \(sapLight8), matured9: \(sap9Matured), matured8: \(sap8Matured)"
        )

        // 5d. Light transmission through ice vs stone partition wall
        let opticalTorch = (x: originX - 40, y: 20, z: originZ - 40)
        // Clear a corridor from x-2 to x+4
        for y in 19...23 {
            for z in (opticalTorch.z - 2)...(opticalTorch.z + 2) {
                for x in (opticalTorch.x - 2)...(opticalTorch.x + 4) {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: y == 19 ? .stone : .air, remesh: false)
                }
            }
        }
        // Build a complete partition wall at x = opticalTorch.x + 1 across all y and z
        for y in 20...23 {
            for z in (opticalTorch.z - 2)...(opticalTorch.z + 2) {
                world.setBlock(worldX: opticalTorch.x + 1, y: y, worldZ: z, to: .stone, remesh: false)
            }
        }

        world.setBlock(worldX: opticalTorch.x, y: opticalTorch.y, worldZ: opticalTorch.z, to: .torch)

        // Case A: Aperture in wall is .ice -> light transmits straight through wall
        world.setBlock(worldX: opticalTorch.x + 1, y: opticalTorch.y, worldZ: opticalTorch.z, to: .ice)
        let lightThroughIce = world.lightLevel(worldX: opticalTorch.x + 2, y: opticalTorch.y, worldZ: opticalTorch.z)

        // Case B: Aperture in wall is .stone -> wall is completely solid, light = 0
        world.setBlock(worldX: opticalTorch.x + 1, y: opticalTorch.y, worldZ: opticalTorch.z, to: .stone)
        let lightThroughStone = world.lightLevel(worldX: opticalTorch.x + 2, y: opticalTorch.y, worldZ: opticalTorch.z)

        report.check(
            "optical transmission: ice transmits light (level >= 12) whereas stone occludes to 0",
            lightThroughIce >= 12 && lightThroughStone == 0,
            "lightIce: \(lightThroughIce), lightStone: \(lightThroughStone)"
        )

        // =========================================================================
        // MARK: - Verdict Reporting
        // =========================================================================
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[stress-check] FAILED — thermal edge stress\n"
            : "[stress-check] all passed — thermal edge stress\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

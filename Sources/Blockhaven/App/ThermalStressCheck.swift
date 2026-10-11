import Foundation

/// Adversarial stress testing and empirical boundary verification for Milestone 2:
/// Thermal Microclimates & Subterranean Farming (Wave 9).
///
/// Exhaustively verifies:
/// 1. Elevation Freezing Boundary: Exactly y=85 vs y=86 in non-snowy biomes, and contrast with snowy biomes.
/// 2. Heat Source Distance Cutoff: Exactly distance 3 vs distance 4 across all 4 heat sources (.torch, .furnaceLit, .lava, .signalLampLit) along all axes and diagonals.
/// 3. Inactive / Cold Blocks: Unlit furnace, unlit signal lamp, and other blocks do NOT prevent freeze and do NOT melt ice.
/// 4. Farmland Hydration: Ice NEVER hydrates; water ALWAYS hydrates within reach 4; untended farmland reversion.
/// 5. Photosynthetic Lighting Threshold: Exactly light 8 (dormant) vs light 9 (active growth) underground for wheat and all sapling varieties (.sapling, .birchSapling, .spruceSapling).
/// 6. Distance Metrics: Manhattan vs Chebyshev metric divergence.
/// 7. Chunk Boundary Crossings: Thermal radiance and hydration across chunk seams.
/// 8. Negative Coordinate Robustness: Thermal simulation and hydration at negative world coordinates.
///
/// Run via `BLOCKHAVEN_CHECK_THERMAL_STRESS=1`. Exits nonzero on failure.
enum ThermalStressCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_THERMAL_STRESS"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[stress-check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    private static let dt = 1.0 / 60.0

    private static func ensureLoaded(world: World, x: Int, z: Int, radius: Int = 1) {
        let center = World.chunkCoord(forWorldX: x, worldZ: z)
        for dz in -radius...radius {
            for dx in -radius...radius {
                world.forceGenerate(ChunkCoord(x: center.x + dx, z: center.z + dz))
            }
        }
    }

    static func run() -> Never {
        var report = Report()
        let world = World(seed: 12345)
        let spawn = world.spawnPosition()
        let originX = Int(spawn.x)
        let originZ = Int(spawn.z)

        // Ensure origin region is loaded
        ensureLoaded(world: world, x: originX, z: originZ, radius: 2)

        // =========================================================================
        // MARK: - Suite 1: Elevation Freezing Boundary (y=85 vs y=86) in Non-Snowy Biome
        // =========================================================================
        var nonSnowyCoord: (x: Int, z: Int)?
        for r in 0..<50 {
            for dz in -r...r {
                for dx in -r...r where abs(dx) == r || abs(dz) == r || r == 0 {
                    let cx = originX + dx * 4, cz = originZ + dz * 4
                    let b = world.generator.biome(x: cx, z: cz)
                    if b != .snowy {
                        nonSnowyCoord = (cx, cz)
                        break
                    }
                }
                if nonSnowyCoord != nil { break }
            }
            if nonSnowyCoord != nil { break }
        }

        guard let nonSnowy = nonSnowyCoord else {
            report.check("non-snowy column located", false, "no non-snowy biome found near spawn")
            exit(1)
        }

        ensureLoaded(world: world, x: nonSnowy.x, z: nonSnowy.z, radius: 1)
        let nonSnowyBiome = world.generator.biome(x: nonSnowy.x, z: nonSnowy.z)
        report.check("non-snowy column located", nonSnowyBiome != .snowy, "biome: \(nonSnowyBiome)")

        // Clear vertical columns for testing
        let baseY = 80
        for y in baseY..<Chunk.height {
            for dz in -2...2 {
                for dx in -2...2 {
                    world.setBlock(worldX: nonSnowy.x + dx, y: y, worldZ: nonSnowy.z + dz, to: .air, remesh: false)
                }
            }
        }

        // Test y = 84: open to sky, unheated in non-snowy biome -> must NOT freeze
        world.setBlock(worldX: nonSnowy.x, y: 83, worldZ: nonSnowy.z, to: .stone, remesh: false)
        world.setBlock(worldX: nonSnowy.x, y: 84, worldZ: nonSnowy.z, to: .water)
        let canFreeze84 = world.canFreeze(atWorldX: nonSnowy.x, y: 84, worldZ: nonSnowy.z)
        world.tickThermal(atWorldX: nonSnowy.x, y: 84, worldZ: nonSnowy.z)
        let remainsWater84 = world.block(worldX: nonSnowy.x, y: 84, worldZ: nonSnowy.z) == .water

        report.check(
            "elevation boundary y=84 does not freeze in non-snowy biome",
            !canFreeze84 && remainsWater84,
            "canFreeze: \(canFreeze84), block: \(world.block(worldX: nonSnowy.x, y: 84, worldZ: nonSnowy.z))"
        )

        // Test y = 85: exact boundary -> y > 85 is FALSE -> must NOT freeze!
        world.setBlock(worldX: nonSnowy.x, y: 84, worldZ: nonSnowy.z, to: .stone, remesh: false)
        world.setBlock(worldX: nonSnowy.x, y: 85, worldZ: nonSnowy.z, to: .water)
        let canFreeze85 = world.canFreeze(atWorldX: nonSnowy.x, y: 85, worldZ: nonSnowy.z)
        world.tickThermal(atWorldX: nonSnowy.x, y: 85, worldZ: nonSnowy.z)
        let remainsWater85 = world.block(worldX: nonSnowy.x, y: 85, worldZ: nonSnowy.z) == .water

        report.check(
            "exact boundary y=85 does NOT freeze in non-snowy biome",
            !canFreeze85 && remainsWater85,
            "canFreeze: \(canFreeze85), block: \(world.block(worldX: nonSnowy.x, y: 85, worldZ: nonSnowy.z))"
        )

        // Test y = 86: exact boundary -> y > 85 is TRUE -> MUST freeze!
        world.setBlock(worldX: nonSnowy.x, y: 85, worldZ: nonSnowy.z, to: .stone, remesh: false)
        world.setBlock(worldX: nonSnowy.x, y: 86, worldZ: nonSnowy.z, to: .water)
        let canFreeze86 = world.canFreeze(atWorldX: nonSnowy.x, y: 86, worldZ: nonSnowy.z)
        world.tickThermal(atWorldX: nonSnowy.x, y: 86, worldZ: nonSnowy.z)
        let freezesAt86 = world.block(worldX: nonSnowy.x, y: 86, worldZ: nonSnowy.z) == .ice

        report.check(
            "exact boundary y=86 DOES freeze in non-snowy biome",
            canFreeze86 && freezesAt86,
            "canFreeze: \(canFreeze86), block: \(world.block(worldX: nonSnowy.x, y: 86, worldZ: nonSnowy.z))"
        )

        // Test y = 87: alpine altitude -> MUST freeze!
        world.setBlock(worldX: nonSnowy.x, y: 86, worldZ: nonSnowy.z, to: .stone, remesh: false)
        world.setBlock(worldX: nonSnowy.x, y: 87, worldZ: nonSnowy.z, to: .water)
        let canFreeze87 = world.canFreeze(atWorldX: nonSnowy.x, y: 87, worldZ: nonSnowy.z)
        world.tickThermal(atWorldX: nonSnowy.x, y: 87, worldZ: nonSnowy.z)
        let freezesAt87 = world.block(worldX: nonSnowy.x, y: 87, worldZ: nonSnowy.z) == .ice

        report.check(
            "elevation y=87 freezes in non-snowy biome",
            canFreeze87 && freezesAt87,
            "canFreeze: \(canFreeze87), block: \(world.block(worldX: nonSnowy.x, y: 87, worldZ: nonSnowy.z))"
        )

        // Test roof at y=86: sky access blocked -> must NOT freeze even though y=86
        let roofCell = (x: nonSnowy.x + 1, y: 86, z: nonSnowy.z + 1)
        world.setBlock(worldX: roofCell.x, y: 85, worldZ: roofCell.z, to: .stone, remesh: false)
        world.setBlock(worldX: roofCell.x, y: 86, worldZ: roofCell.z, to: .water)
        world.setBlock(worldX: roofCell.x, y: 87, worldZ: roofCell.z, to: .stone) // roof directly above
        let roofCanFreeze = world.canFreeze(atWorldX: roofCell.x, y: 86, worldZ: roofCell.z)
        world.tickThermal(atWorldX: roofCell.x, y: 86, worldZ: roofCell.z)
        let roofRemainsWater = world.block(worldX: roofCell.x, y: 86, worldZ: roofCell.z) == .water

        report.check(
            "sheltered water at alpine y=86 does not freeze under roof",
            !roofCanFreeze && roofRemainsWater,
            "canFreeze: \(roofCanFreeze), block: \(world.block(worldX: roofCell.x, y: 86, worldZ: roofCell.z))"
        )

        // Snowy biome contrast at standard elevation (y = 70 and y = 85)
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
            ensureLoaded(world: world, x: snowy.x, z: snowy.z, radius: 1)
            for y in 65..<Chunk.height {
                world.setBlock(worldX: snowy.x, y: y, worldZ: snowy.z, to: .air, remesh: false)
                world.setBlock(worldX: snowy.x + 2, y: y, worldZ: snowy.z, to: .air, remesh: false)
            }
            // In snowy biome, y=70 (<= 85) MUST freeze
            world.setBlock(worldX: snowy.x, y: 69, worldZ: snowy.z, to: .stone, remesh: false)
            world.setBlock(worldX: snowy.x, y: 70, worldZ: snowy.z, to: .water)
            let snowyCanFreeze70 = world.canFreeze(atWorldX: snowy.x, y: 70, worldZ: snowy.z)
            world.tickThermal(atWorldX: snowy.x, y: 70, worldZ: snowy.z)
            let snowyFroze70 = world.block(worldX: snowy.x, y: 70, worldZ: snowy.z) == .ice

            // In snowy biome, y=85 MUST freeze
            world.setBlock(worldX: snowy.x + 2, y: 84, worldZ: snowy.z, to: .stone, remesh: false)
            world.setBlock(worldX: snowy.x + 2, y: 85, worldZ: snowy.z, to: .water)
            let snowyCanFreeze85 = world.canFreeze(atWorldX: snowy.x + 2, y: 85, worldZ: snowy.z)
            world.tickThermal(atWorldX: snowy.x + 2, y: 85, worldZ: snowy.z)
            let snowyFroze85 = world.block(worldX: snowy.x + 2, y: 85, worldZ: snowy.z) == .ice

            report.check(
                "snowy biome freezes both y=70 and y=85 when open to sky",
                snowyCanFreeze70 && snowyFroze70 && snowyCanFreeze85 && snowyFroze85,
                "y70: \(snowyFroze70), y85: \(snowyFroze85)"
            )
        }

        // =========================================================================
        // MARK: - Suite 2: Heat Source Distance Boundaries (Distance 3 vs Distance 4)
        // =========================================================================
        let heatSources: [BlockType] = [.torch, .furnaceLit, .lava, .signalLampLit]
        let waterY = 88 // Alpine altitude, freezing condition

        for (sourceIdx, source) in heatSources.enumerated() {
            // A. Freezing Prevention at distance 3 (along X, Y, Z, and 3D diagonal)
            let offsetsDist3 = [
                (3, 0, 0),
                (-3, 0, 0),
                (0, 0, 3),
                (0, 0, -3),
                (3, 3, 3)   // 3D Chebyshev diagonal: max(|dx|, |dy|, |dz|) == 3
            ]

            var allDist3Prevented = true
            var dist3Details: [String] = []

            for (idx, offset) in offsetsDist3.enumerated() {
                let cellX = originX + 10 + sourceIdx * 20 + idx * 3
                let cellZ = originZ + 10
                ensureLoaded(world: world, x: cellX + offset.0, z: cellZ + offset.2, radius: 1)

                // Clear sky column above water cell and heat cell
                for y in (waterY - 1)..<Chunk.height {
                    world.setBlock(worldX: cellX, y: y, worldZ: cellZ, to: .air, remesh: false)
                    world.setBlock(worldX: cellX + offset.0, y: y, worldZ: cellZ + offset.2, to: .air, remesh: false)
                }
                world.setBlock(worldX: cellX, y: waterY - 1, worldZ: cellZ, to: .stone, remesh: false)
                world.setBlock(worldX: cellX, y: waterY, worldZ: cellZ, to: .water)

                let srcPos = (x: cellX + offset.0, y: waterY + offset.1, z: cellZ + offset.2)
                world.setBlock(worldX: srcPos.x, y: srcPos.y - 1, worldZ: srcPos.z, to: .stone, remesh: false)
                world.setBlock(worldX: srcPos.x, y: srcPos.y, worldZ: srcPos.z, to: source)

                let near = world.isNearThermalSource(worldX: cellX, y: waterY, worldZ: cellZ, radius: 3)
                let canFreeze = world.canFreeze(atWorldX: cellX, y: waterY, worldZ: cellZ)
                world.tickThermal(atWorldX: cellX, y: waterY, worldZ: cellZ)
                let remainsWater = world.block(worldX: cellX, y: waterY, worldZ: cellZ) == .water

                let pass = near && !canFreeze && remainsWater
                if !pass { allDist3Prevented = false }
                dist3Details.append("off\(offset):\(pass)")

                world.setBlock(worldX: srcPos.x, y: srcPos.y, worldZ: srcPos.z, to: .air)
                world.setBlock(worldX: cellX, y: waterY, worldZ: cellZ, to: .air)
            }

            report.check(
                "\(source) at distance 3 prevents freezing across all axes & Chebyshev diagonal",
                allDist3Prevented,
                dist3Details.joined(separator: ", ")
            )

            // B. Distance 4 cutoff: heat source does NOT prevent freeze
            let offsetsDist4 = [
                (4, 0, 0),
                (-4, 0, 0),
                (0, 0, 4),
                (0, 0, -4),
                (4, 4, 4)
            ]

            var allDist4Froze = true
            var dist4Details: [String] = []

            for (idx, offset) in offsetsDist4.enumerated() {
                let cellX = originX - 10 - sourceIdx * 20 - idx * 3
                let cellZ = originZ + 10
                ensureLoaded(world: world, x: cellX + offset.0, z: cellZ + offset.2, radius: 1)

                for y in (waterY - 1)..<Chunk.height {
                    world.setBlock(worldX: cellX, y: y, worldZ: cellZ, to: .air, remesh: false)
                    world.setBlock(worldX: cellX + offset.0, y: y, worldZ: cellZ + offset.2, to: .air, remesh: false)
                }
                world.setBlock(worldX: cellX, y: waterY - 1, worldZ: cellZ, to: .stone, remesh: false)
                world.setBlock(worldX: cellX, y: waterY, worldZ: cellZ, to: .water)

                let srcPos = (x: cellX + offset.0, y: waterY + offset.1, z: cellZ + offset.2)
                world.setBlock(worldX: srcPos.x, y: srcPos.y - 1, worldZ: srcPos.z, to: .stone, remesh: false)
                world.setBlock(worldX: srcPos.x, y: srcPos.y, worldZ: srcPos.z, to: source)

                let near = world.isNearThermalSource(worldX: cellX, y: waterY, worldZ: cellZ, radius: 3)
                let canFreeze = world.canFreeze(atWorldX: cellX, y: waterY, worldZ: cellZ)
                world.tickThermal(atWorldX: cellX, y: waterY, worldZ: cellZ)
                let frozeToIce = world.block(worldX: cellX, y: waterY, worldZ: cellZ) == .ice

                let pass = !near && canFreeze && frozeToIce
                if !pass { allDist4Froze = false }
                dist4Details.append("off\(offset):\(pass)")

                world.setBlock(worldX: srcPos.x, y: srcPos.y, worldZ: srcPos.z, to: .air)
                world.setBlock(worldX: cellX, y: waterY, worldZ: cellZ, to: .air)
            }

            report.check(
                "\(source) cutoff: heat source at distance 4 does NOT prevent freeze",
                allDist4Froze,
                dist4Details.joined(separator: ", ")
            )

            // C. Ice Thawing at distance 3 vs distance 4
            let thawX = originX + 15 + sourceIdx * 5
            let thawZ = originZ - 15
            ensureLoaded(world: world, x: thawX, z: thawZ, radius: 1)

            world.setBlock(worldX: thawX, y: 70, worldZ: thawZ, to: .ice)
            world.setBlock(worldX: thawX + 3, y: 69, worldZ: thawZ, to: .stone, remesh: false)
            world.setBlock(worldX: thawX + 3, y: 70, worldZ: thawZ, to: source)
            let canMelt3 = world.canMelt(atWorldX: thawX, y: 70, worldZ: thawZ)
            world.tickThermal(atWorldX: thawX, y: 70, worldZ: thawZ)
            let thawedAt3 = world.block(worldX: thawX, y: 70, worldZ: thawZ) == .water

            // Cutoff at distance 4
            world.setBlock(worldX: thawX, y: 70, worldZ: thawZ, to: .ice)
            world.setBlock(worldX: thawX + 3, y: 70, worldZ: thawZ, to: .air)
            world.setBlock(worldX: thawX + 4, y: 69, worldZ: thawZ, to: .stone, remesh: false)
            world.setBlock(worldX: thawX + 4, y: 70, worldZ: thawZ, to: source)
            let canMelt4 = world.canMelt(atWorldX: thawX, y: 70, worldZ: thawZ)
            world.tickThermal(atWorldX: thawX, y: 70, worldZ: thawZ)
            let remainsIceAt4 = world.block(worldX: thawX, y: 70, worldZ: thawZ) == .ice

            world.setBlock(worldX: thawX + 4, y: 70, worldZ: thawZ, to: .air)
            world.setBlock(worldX: thawX, y: 70, worldZ: thawZ, to: .air)

            report.check(
                "\(source) thaws ice at distance 3, leaves ice solid at distance 4",
                canMelt3 && thawedAt3 && !canMelt4 && remainsIceAt4,
                "d3Melt: \(canMelt3)/\(thawedAt3), d4Melt: \(canMelt4)/\(remainsIceAt4)"
            )
        }

        // =========================================================================
        // MARK: - Suite 3: Inactive / Cold Blocks (.furnace, .signalLamp, inert)
        // =========================================================================
        let inertCandidates: [BlockType] = [
            .furnace,          // unlit furnace
            .signalLamp,      // unlit signal lamp
            .signalTorchOn,    // signal torch (electrical signal, not heat)
            .glowCrystal,        // luminescent mineral, not active thermal source
            .seaLantern,       // cold underwater luminary
            .stone             // ordinary stone
        ]

        for (idx, inert) in inertCandidates.enumerated() {
            let inertCell = (x: originX - 15 - idx * 3, y: waterY, z: originZ - 15)
            ensureLoaded(world: world, x: inertCell.x, z: inertCell.z, radius: 1)

            for y in (waterY - 1)..<Chunk.height {
                world.setBlock(worldX: inertCell.x, y: y, worldZ: inertCell.z, to: .air, remesh: false)
                world.setBlock(worldX: inertCell.x + 1, y: y, worldZ: inertCell.z, to: .air, remesh: false)
            }
            world.setBlock(worldX: inertCell.x, y: waterY - 1, worldZ: inertCell.z, to: .stone, remesh: false)
            world.setBlock(worldX: inertCell.x, y: waterY, worldZ: inertCell.z, to: .water)
            world.setBlock(worldX: inertCell.x + 1, y: waterY - 1, worldZ: inertCell.z, to: .stone, remesh: false)
            world.setBlock(worldX: inertCell.x + 1, y: waterY, worldZ: inertCell.z, to: inert)

            let nearInert = world.isNearThermalSource(worldX: inertCell.x, y: waterY, worldZ: inertCell.z, radius: 3)
            let canFreezeInert = world.canFreeze(atWorldX: inertCell.x, y: waterY, worldZ: inertCell.z)
            world.tickThermal(atWorldX: inertCell.x, y: waterY, worldZ: inertCell.z)
            let frozeBesideInert = world.block(worldX: inertCell.x, y: waterY, worldZ: inertCell.z) == .ice

            // Ice placed next to inert block must NOT melt
            world.setBlock(worldX: inertCell.x, y: waterY, worldZ: inertCell.z, to: .ice)
            let canMeltInert = world.canMelt(atWorldX: inertCell.x, y: waterY, worldZ: inertCell.z)
            world.tickThermal(atWorldX: inertCell.x, y: waterY, worldZ: inertCell.z)
            let remainsIceBesideInert = world.block(worldX: inertCell.x, y: waterY, worldZ: inertCell.z) == .ice

            report.check(
                "inert block \(inert) does NOT prevent freeze and does NOT melt ice",
                !nearInert && canFreezeInert && frozeBesideInert && !canMeltInert && remainsIceBesideInert,
                "near: \(nearInert), froze: \(frozeBesideInert), canMelt: \(canMeltInert), remainsIce: \(remainsIceBesideInert)"
            )

            world.setBlock(worldX: inertCell.x + 1, y: waterY, worldZ: inertCell.z, to: .air)
            world.setBlock(worldX: inertCell.x, y: waterY, worldZ: inertCell.z, to: .air)
        }

        // =========================================================================
        // MARK: - Suite 4: Farmland Hydration (Ice Never Hydrates, Water Hydrates to Reach 4)
        // =========================================================================
        let farmTestX = originX + 25
        let farmTestZ = originZ + 25
        let farmY = 70
        ensureLoaded(world: world, x: farmTestX, z: farmTestZ, radius: 2)

        // Clear area
        for y in (farmY - 2)...(farmY + 5) {
            for dz in -10...10 {
                for dx in -10...10 {
                    world.setBlock(worldX: farmTestX + dx, y: y, worldZ: farmTestZ + dz, to: .air, remesh: false)
                }
            }
        }

        // 4a. Ice surrounded test: farmland at center, ice at distances 1, 2, 3, 4
        let iceFarmCenter = (x: farmTestX, y: farmY, z: farmTestZ)
        world.setBlock(worldX: iceFarmCenter.x, y: iceFarmCenter.y, worldZ: iceFarmCenter.z, to: .farmland)

        // Surround with ice within reach 4
        for dz in -4...4 {
            for dx in -4...4 {
                if dx == 0 && dz == 0 { continue }
                world.setBlock(worldX: iceFarmCenter.x + dx, y: iceFarmCenter.y, worldZ: iceFarmCenter.z + dz, to: .ice)
            }
        }

        let iceHydrated = world.isFarmlandHydrated(worldX: iceFarmCenter.x, y: iceFarmCenter.y, worldZ: iceFarmCenter.z, reach: 4)
        world.tickFarmland(worldX: iceFarmCenter.x, y: iceFarmCenter.y, worldZ: iceFarmCenter.z)
        let iceFarmReverted = world.block(worldX: iceFarmCenter.x, y: iceFarmCenter.y, worldZ: iceFarmCenter.z) == .dirt

        report.check(
            "ice within reach 4 NEVER hydrates farmland and untended farmland reverts to dirt",
            !iceHydrated && iceFarmReverted,
            "hydrated: \(iceHydrated), block: \(world.block(worldX: iceFarmCenter.x, y: iceFarmCenter.y, worldZ: iceFarmCenter.z))"
        )

        // Clean up ice
        for dz in -4...4 {
            for dx in -4...4 {
                world.setBlock(worldX: iceFarmCenter.x + dx, y: iceFarmCenter.y, worldZ: iceFarmCenter.z + dz, to: .air)
            }
        }

        // 4b. Water distance reach: test reach 1, 2, 3, 4 (hydrates) vs reach 5 (fails)
        for dist in 1...5 {
            let testFarm = (x: farmTestX + dist * 3, y: farmY, z: farmTestZ + 8)
            world.setBlock(worldX: testFarm.x, y: testFarm.y, worldZ: testFarm.z, to: .farmland)
            let waterPos = (x: testFarm.x + dist, y: testFarm.y, z: testFarm.z)
            world.setBlock(worldX: waterPos.x, y: waterPos.y, worldZ: waterPos.z, to: .water)

            let hydrated = world.isFarmlandHydrated(worldX: testFarm.x, y: testFarm.y, worldZ: testFarm.z, reach: 4)
            world.tickFarmland(worldX: testFarm.x, y: testFarm.y, worldZ: testFarm.z)
            let currentBlock = world.block(worldX: testFarm.x, y: testFarm.y, worldZ: testFarm.z)

            if dist <= 4 {
                let pass = hydrated && (currentBlock == .farmland)
                report.check(
                    "water at distance \(dist) hydrates farmland and preserves tilled soil",
                    pass,
                    "hydrated: \(hydrated), block: \(currentBlock)"
                )
            } else {
                let pass = !hydrated && (currentBlock == .dirt)
                report.check(
                    "water at distance \(dist) (beyond reach 4) does NOT hydrate and farmland reverts to dirt",
                    pass,
                    "hydrated: \(hydrated), block: \(currentBlock)"
                )
            }

            world.setBlock(worldX: testFarm.x, y: testFarm.y, worldZ: testFarm.z, to: .air)
            world.setBlock(worldX: waterPos.x, y: waterPos.y, worldZ: waterPos.z, to: .air)
        }

        // 4c. Corner reach: (dx=4, dz=4) -> Chebyshev distance 4 -> hydrates
        let cornerFarm = (x: farmTestX - 5, y: farmY, z: farmTestZ - 5)
        world.setBlock(worldX: cornerFarm.x, y: cornerFarm.y, worldZ: cornerFarm.z, to: .farmland)
        world.setBlock(worldX: cornerFarm.x + 4, y: cornerFarm.y, worldZ: cornerFarm.z + 4, to: .water)
        let cornerHydrated = world.isFarmlandHydrated(worldX: cornerFarm.x, y: cornerFarm.y, worldZ: cornerFarm.z, reach: 4)
        world.tickFarmland(worldX: cornerFarm.x, y: cornerFarm.y, worldZ: cornerFarm.z)
        let cornerStayed = world.block(worldX: cornerFarm.x, y: cornerFarm.y, worldZ: cornerFarm.z) == .farmland

        report.check(
            "water at Chebyshev corner (dx=4, dz=4) hydrates farmland",
            cornerHydrated && cornerStayed,
            "hydrated: \(cornerHydrated), block: \(world.block(worldX: cornerFarm.x, y: cornerFarm.y, worldZ: cornerFarm.z))"
        )
        world.setBlock(worldX: cornerFarm.x, y: cornerFarm.y, worldZ: cornerFarm.z, to: .air)
        world.setBlock(worldX: cornerFarm.x + 4, y: cornerFarm.y, worldZ: cornerFarm.z + 4, to: .air)

        // 4d. Tended farmland protection: unhydrated farmland with a crop above does NOT revert to dirt
        let tendedFarm = (x: farmTestX - 8, y: farmY, z: farmTestZ - 8)
        world.setBlock(worldX: tendedFarm.x, y: tendedFarm.y, worldZ: tendedFarm.z, to: .farmland)
        world.setBlock(worldX: tendedFarm.x, y: tendedFarm.y + 1, worldZ: tendedFarm.z, to: .wheatStage0)
        let tendedHydrated = world.isFarmlandHydrated(worldX: tendedFarm.x, y: tendedFarm.y, worldZ: tendedFarm.z)
        world.tickFarmland(worldX: tendedFarm.x, y: tendedFarm.y, worldZ: tendedFarm.z)
        let tendedFarmlandStayed = world.block(worldX: tendedFarm.x, y: tendedFarm.y, worldZ: tendedFarm.z) == .farmland

        report.check(
            "unhydrated farmland with active crop does NOT revert to dirt when ticked",
            !tendedHydrated && tendedFarmlandStayed,
            "hydrated: \(tendedHydrated), block: \(world.block(worldX: tendedFarm.x, y: tendedFarm.y, worldZ: tendedFarm.z))"
        )
        world.setBlock(worldX: tendedFarm.x, y: tendedFarm.y + 1, worldZ: tendedFarm.z, to: .air)
        world.setBlock(worldX: tendedFarm.x, y: tendedFarm.y, worldZ: tendedFarm.z, to: .air)

        // =========================================================================
        // MARK: - Suite 5: Photosynthetic Lighting Threshold (Light 8 vs Light 9)
        // =========================================================================
        let caveOriginX = originX - 25
        let caveOriginZ = originZ - 25
        let caveFloorY = 15
        let caveCeilingY = 22
        ensureLoaded(world: world, x: caveOriginX, z: caveOriginZ, radius: 2)

        // Excavate sealed underground cavern in solid stone
        for y in (caveFloorY - 1)...(caveCeilingY + 1) {
            for z in (caveOriginZ - 10)...(caveOriginZ + 10) {
                for x in (caveOriginX - 10)...(caveOriginX + 10) {
                    let isInterior = y >= caveFloorY && y <= caveCeilingY
                        && abs(x - caveOriginX) <= 8 && abs(z - caveOriginZ) <= 8
                    world.setBlock(worldX: x, y: y, worldZ: z, to: isInterior ? .air : .stone, remesh: false)
                }
            }
        }

        // Verify sky is 100% occluded across cavern
        var skyFullySealed = true
        for z in (caveOriginZ - 6)...(caveOriginZ + 6) {
            for x in (caveOriginX - 6)...(caveOriginX + 6) {
                if world.isSkyOpen(worldX: x, y: caveFloorY + 1, worldZ: z) {
                    skyFullySealed = false
                }
            }
        }
        report.check("underground cavern sky access sealed", skyFullySealed, "isSkyOpen false everywhere")

        // 5a. Darkness (light 0): wheat and saplings remain completely dormant
        let darkWheatPos = (x: caveOriginX - 6, y: caveFloorY + 1, z: caveOriginZ - 6)
        world.setBlock(worldX: darkWheatPos.x, y: darkWheatPos.y - 1, worldZ: darkWheatPos.z, to: .farmland, remesh: false)
        world.setBlock(worldX: darkWheatPos.x, y: darkWheatPos.y, worldZ: darkWheatPos.z, to: .wheatStage0)

        let darkSaplingPos = (x: caveOriginX - 5, y: caveFloorY + 1, z: caveOriginZ - 6)
        world.setBlock(worldX: darkSaplingPos.x, y: darkSaplingPos.y - 1, worldZ: darkSaplingPos.z, to: .dirt, remesh: false)
        world.setBlock(worldX: darkSaplingPos.x, y: darkSaplingPos.y, worldZ: darkSaplingPos.z, to: .sapling)

        let darkWheatLight = world.lightLevel(worldX: darkWheatPos.x, y: darkWheatPos.y, worldZ: darkWheatPos.z)
        let darkSaplingLight = world.lightLevel(worldX: darkSaplingPos.x, y: darkSaplingPos.y, worldZ: darkSaplingPos.z)

        let darkCrops = CropStore()
        let darkSaplings = SaplingStore()
        let darkWKey = CropStore.Key(darkWheatPos.x, darkWheatPos.y, darkWheatPos.z)
        let darkSKey = SaplingStore.Key(darkSaplingPos.x, darkSaplingPos.y, darkSaplingPos.z)
        darkCrops.planted(at: darkWKey)
        darkSaplings.planted(at: darkSKey)

        var darkTimer = 0.0
        while darkTimer < CropStore.stageSeconds * 2.0 {
            _ = darkCrops.tick(dt: dt, world: world)
            _ = darkSaplings.tick(dt: dt, world: world)
            darkTimer += dt
        }

        let darkWheatDormant = world.block(worldX: darkWheatPos.x, y: darkWheatPos.y, worldZ: darkWheatPos.z) == .wheatStage0
        let darkSaplingDormant = world.block(worldX: darkSaplingPos.x, y: darkSaplingPos.y, worldZ: darkSaplingPos.z) == .sapling

        report.check(
            "crops and saplings remain completely dormant in pitch black (light 0)",
            darkWheatLight == 0 && darkSaplingLight == 0 && darkWheatDormant && darkSaplingDormant,
            "light: \(darkWheatLight), wheat: \(world.block(worldX: darkWheatPos.x, y: darkWheatPos.y, worldZ: darkWheatPos.z)), sapling: \(world.block(worldX: darkSaplingPos.x, y: darkSaplingPos.y, worldZ: darkSaplingPos.z))"
        )

        // 5b. Torch light threshold: Torch emission is 14
        // Distance 5 -> light = 14 - 5 = 9
        // Distance 6 -> light = 14 - 6 = 8
        let torchOrigin = (x: caveOriginX, y: caveFloorY + 1, z: caveOriginZ)
        world.setBlock(worldX: torchOrigin.x, y: torchOrigin.y, worldZ: torchOrigin.z, to: .torch)

        let pos9 = (x: torchOrigin.x, y: caveFloorY + 1, z: torchOrigin.z + 5)
        let pos8 = (x: torchOrigin.x, y: caveFloorY + 1, z: torchOrigin.z + 6)

        world.setBlock(worldX: pos9.x, y: pos9.y - 1, worldZ: pos9.z, to: .farmland, remesh: false)
        world.setBlock(worldX: pos9.x, y: pos9.y, worldZ: pos9.z, to: .wheatStage0)

        world.setBlock(worldX: pos8.x, y: pos8.y - 1, worldZ: pos8.z, to: .farmland, remesh: false)
        world.setBlock(worldX: pos8.x, y: pos8.y, worldZ: pos8.z, to: .wheatStage0)

        let measuredLight9 = world.lightLevel(worldX: pos9.x, y: pos9.y, worldZ: pos9.z)
        let measuredLight8 = world.lightLevel(worldX: pos8.x, y: pos8.y, worldZ: pos8.z)

        let threshCrops = CropStore()
        let key9 = CropStore.Key(pos9.x, pos9.y, pos9.z)
        let key8 = CropStore.Key(pos8.x, pos8.y, pos8.z)
        threshCrops.planted(at: key9)
        threshCrops.planted(at: key8)

        var threshTimer = 0.0
        while threshTimer < CropStore.stageSeconds * 1.2 {
            for k in threshCrops.tick(dt: dt, world: world) {
                let curr = world.block(worldX: k.x, y: k.y, worldZ: k.z)
                if let next = BlockType(rawValue: curr.rawValue + 1) {
                    world.setBlock(worldX: k.x, y: k.y, worldZ: k.z, to: next)
                }
            }
            threshTimer += dt
        }

        let wheatAt9 = world.block(worldX: pos9.x, y: pos9.y, worldZ: pos9.z)
        let wheatAt8 = world.block(worldX: pos8.x, y: pos8.y, worldZ: pos8.z)

        report.check(
            "crop photosynthetic threshold: light 9 advances to stage 1, light 8 remains stage 0",
            measuredLight9 == 9 && measuredLight8 == 8 && wheatAt9 == .wheatStage1 && wheatAt8 == .wheatStage0,
            "light9: \(measuredLight9) -> \(wheatAt9), light8: \(measuredLight8) -> \(wheatAt8)"
        )

        // 5c. Multi-species sapling validation under light 9 vs light 8
        let saplingTypes: [BlockType] = [.sapling, .birchSapling, .spruceSapling]
        var allSaplingsCompliant = true
        var saplingDetails: [String] = []

        for sapType in saplingTypes {
            let sPos9 = (x: torchOrigin.x, y: caveFloorY + 1, z: torchOrigin.z + 5)
            let sPos8 = (x: torchOrigin.x, y: caveFloorY + 1, z: torchOrigin.z + 6)

            world.setBlock(worldX: sPos9.x, y: sPos9.y - 1, worldZ: sPos9.z, to: .dirt, remesh: false)
            world.setBlock(worldX: sPos9.x, y: sPos9.y, worldZ: sPos9.z, to: sapType)

            world.setBlock(worldX: sPos8.x, y: sPos8.y - 1, worldZ: sPos8.z, to: .dirt, remesh: false)
            world.setBlock(worldX: sPos8.x, y: sPos8.y, worldZ: sPos8.z, to: sapType)

            let l9 = world.lightLevel(worldX: sPos9.x, y: sPos9.y, worldZ: sPos9.z)
            let l8 = world.lightLevel(worldX: sPos8.x, y: sPos8.y, worldZ: sPos8.z)

            let sStore = SaplingStore()
            let sk9 = SaplingStore.Key(sPos9.x, sPos9.y, sPos9.z)
            let sk8 = SaplingStore.Key(sPos8.x, sPos8.y, sPos8.z)
            sStore.planted(at: sk9)
            sStore.planted(at: sk8)

            var sTimer = 0.0
            var s9Matured = false
            var s8Matured = false

            while sTimer < SaplingStore.growSeconds * 1.2 {
                let matured = sStore.tick(dt: dt, world: world)
                if matured.contains(sk9) { s9Matured = true }
                if matured.contains(sk8) { s8Matured = true }
                sTimer += dt
            }

            let s8Remains = world.block(worldX: sPos8.x, y: sPos8.y, worldZ: sPos8.z) == sapType
            let pass = (l9 == 9) && (l8 == 8) && s9Matured && !s8Matured && s8Remains
            if !pass { allSaplingsCompliant = false }
            saplingDetails.append("\(sapType): l9=\(l9)/\(s9Matured), l8=\(l8)/\(s8Matured)")

            world.setBlock(worldX: sPos9.x, y: sPos9.y, worldZ: sPos9.z, to: .air)
            world.setBlock(worldX: sPos8.x, y: sPos8.y, worldZ: sPos8.z, to: .air)
        }

        report.check(
            "all sapling varieties (.sapling, .birchSapling, .spruceSapling) grow at light >= 9 and stall at light <= 8",
            allSaplingsCompliant,
            saplingDetails.joined(separator: "; ")
        )

        // =========================================================================
        // MARK: - Suite 6: Distance Metrics (Manhattan vs Chebyshev)
        // =========================================================================
        let metricTestCenter = (x: originX + 5, y: 70, z: originZ + 5)
        ensureLoaded(world: world, x: metricTestCenter.x, z: metricTestCenter.z, radius: 1)
        world.setBlock(worldX: metricTestCenter.x, y: 70, worldZ: metricTestCenter.z, to: .torch)

        let targetCell = (x: metricTestCenter.x + 2, y: 70, z: metricTestCenter.z + 2)
        let nearManhattan = ThermalQuery.isNearHeatSource(world: world, worldX: targetCell.x, y: targetCell.y, worldZ: targetCell.z, radius: 3, metric: .manhattan)
        let nearChebyshev = ThermalQuery.isNearHeatSource(world: world, worldX: targetCell.x, y: targetCell.y, worldZ: targetCell.z, radius: 3, metric: .chebyshev)
        let nearDefault = world.isNearThermalSource(worldX: targetCell.x, y: targetCell.y, worldZ: targetCell.z, radius: 3)

        report.check(
            "metric discrimination: diagonal (2,2,0) is outside Manhattan radius 3 but inside Chebyshev radius 3",
            !nearManhattan && nearChebyshev && nearDefault,
            "manhattan: \(nearManhattan), chebyshev: \(nearChebyshev), worldDefault: \(nearDefault)"
        )
        world.setBlock(worldX: metricTestCenter.x, y: 70, worldZ: metricTestCenter.z, to: .air)

        // =========================================================================
        // MARK: - Suite 7: Chunk Boundary Crossing
        // =========================================================================
        let seamChunk0X = 15
        let seamChunk1X = 16
        let seamZ = 30
        let seamY = 88 // alpine freezing

        let c0 = World.chunkCoord(forWorldX: seamChunk0X, worldZ: seamZ)
        let c1 = World.chunkCoord(forWorldX: seamChunk1X, worldZ: seamZ)
        world.forceGenerate(c0)
        world.forceGenerate(c1)

        for y in (seamY - 2)..<Chunk.height {
            world.setBlock(worldX: seamChunk0X, y: y, worldZ: seamZ, to: .air, remesh: false)
            world.setBlock(worldX: seamChunk1X, y: y, worldZ: seamZ, to: .air, remesh: false)
        }
        world.setBlock(worldX: seamChunk0X, y: seamY - 1, worldZ: seamZ, to: .stone, remesh: false)
        world.setBlock(worldX: seamChunk1X, y: seamY - 1, worldZ: seamZ, to: .stone, remesh: false)

        world.setBlock(worldX: seamChunk0X, y: seamY, worldZ: seamZ, to: .torch)
        world.setBlock(worldX: seamChunk1X, y: seamY, worldZ: seamZ, to: .water)

        let seamNearHeat = world.isNearThermalSource(worldX: seamChunk1X, y: seamY, worldZ: seamZ, radius: 3)
        let seamCanFreeze = world.canFreeze(atWorldX: seamChunk1X, y: seamY, worldZ: seamZ)
        world.tickThermal(atWorldX: seamChunk1X, y: seamY, worldZ: seamZ)
        let seamRemainsWater = world.block(worldX: seamChunk1X, y: seamY, worldZ: seamZ) == .water

        world.setBlock(worldX: seamChunk0X, y: 70, worldZ: seamZ, to: .farmland)
        world.setBlock(worldX: seamChunk1X, y: 70, worldZ: seamZ, to: .water)
        let seamFarmlandHydrated = world.isFarmlandHydrated(worldX: seamChunk0X, y: 70, worldZ: seamZ, reach: 4)

        report.check(
            "thermal radiance and farmland hydration propagate seamlessly across chunk boundaries",
            seamNearHeat && !seamCanFreeze && seamRemainsWater && seamFarmlandHydrated,
            "seamNearHeat: \(seamNearHeat), seamCanFreeze: \(seamCanFreeze), seamWater: \(seamRemainsWater), hydrated: \(seamFarmlandHydrated)"
        )

        // =========================================================================
        // MARK: - Suite 8: Negative Coordinate Robustness
        // =========================================================================
        let negX = -200
        let negZ = -200
        let negChunk = World.chunkCoord(forWorldX: negX, worldZ: negZ)
        world.forceGenerate(negChunk)

        for y in 85..<Chunk.height {
            world.setBlock(worldX: negX, y: y, worldZ: negZ, to: .air, remesh: false)
            world.setBlock(worldX: negX + 2, y: y, worldZ: negZ, to: .air, remesh: false)
        }
        world.setBlock(worldX: negX, y: 87, worldZ: negZ, to: .stone, remesh: false)
        world.setBlock(worldX: negX, y: 88, worldZ: negZ, to: .water)

        world.tickThermal(atWorldX: negX, y: 88, worldZ: negZ)
        let negFroze = world.block(worldX: negX, y: 88, worldZ: negZ) == .ice

        world.setBlock(worldX: negX + 2, y: 87, worldZ: negZ, to: .stone, remesh: false)
        world.setBlock(worldX: negX + 2, y: 88, worldZ: negZ, to: .torch)
        world.tickThermal(atWorldX: negX, y: 88, worldZ: negZ)
        let negThawed = world.block(worldX: negX, y: 88, worldZ: negZ) == .water

        report.check(
            "thermal freezing and thawing operate correctly at negative world coordinates",
            negFroze && negThawed,
            "negFroze: \(negFroze), negThawed: \(negThawed)"
        )

        // =========================================================================
        // MARK: - Verdict Reporting
        // =========================================================================
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[stress-check] FAILED — thermal-stress\n"
            : "[stress-check] all passed — thermal-stress\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

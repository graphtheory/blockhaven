import Foundation

/// Headless verification proof for Milestone 2: Thermal Microclimates & Subterranean Farming.
///
/// Validates:
/// 1. Water freezing in `Biome.snowy` and alpine altitudes (y > 85) when open to sky and unheated.
/// 2. Sheltered water (!isSkyOpen) does not freeze even in freezing conditions.
/// 3. Water near heat sources (.torch, .furnaceLit, .lava, .signalLampLit within R <= 3) does not freeze.
/// 4. Ice placed near a heat source (R <= 3) thaws into water upon thermal tick.
/// 5. Farmland hydration: farmland next to water hydrates and boosts crop growth; farmland next to ice does not hydrate.
/// 6. Subterranean farming: Wheat and sapling placed in a closed underground cavern (y=20, no sky access)
///    remain dormant in darkness / under unlit lamp (light 0), but grow under artificial light (light >= 9).
///
/// Run via `BLOCKHAVEN_CHECK_THERMAL=1`. Exits nonzero on failure.
enum ThermalCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_THERMAL"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    private static let dt = 1.0 / 60

    static func run() -> Never {
        var report = Report()
        let world = World(seed: 42)
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))

        // Force generate central area around spawn
        for dz in -2...2 {
            for dx in -2...2 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        let originX = Int(spawn.x)
        let originZ = Int(spawn.z)

        // =========================================================================
        // MARK: - Test 1: Water Freezing in Biome.snowy and Alpine Altitudes (y > 85)
        // =========================================================================

        // 1a. Alpine altitude freezing: y = 88 (> 85), open to sky, unheated
        let alpineY = 88
        let alpineDeckY = alpineY - 1
        for dz in -2...2 {
            for dx in -2...2 {
                world.setBlock(worldX: originX + dx, y: alpineDeckY, worldZ: originZ + dz, to: .stone, remesh: false)
                for y in alpineY..<Chunk.height {
                    world.setBlock(worldX: originX + dx, y: y, worldZ: originZ + dz, to: .air, remesh: false)
                }
            }
        }

        let alpineWaterCell = (x: originX, y: alpineY, z: originZ)
        world.setBlock(worldX: alpineWaterCell.x, y: alpineWaterCell.y, worldZ: alpineWaterCell.z, to: .water)
        let alpineSkyOpen = world.isSkyOpen(worldX: alpineWaterCell.x, y: alpineWaterCell.y, worldZ: alpineWaterCell.z)
        let alpineUnheated = !world.isNearThermalSource(worldX: alpineWaterCell.x, y: alpineWaterCell.y, worldZ: alpineWaterCell.z, radius: 3)

        // Thermal tick execution
        world.tickThermal(atWorldX: alpineWaterCell.x, y: alpineWaterCell.y, worldZ: alpineWaterCell.z)
        let alpineFroze = world.block(worldX: alpineWaterCell.x, y: alpineWaterCell.y, worldZ: alpineWaterCell.z) == .ice

        report.check(
            "water freezes into ice at alpine altitude (y > 85) when open to sky and unheated",
            alpineSkyOpen && alpineUnheated && alpineFroze,
            "skyOpen: \(alpineSkyOpen), unheated: \(alpineUnheated), block: \(world.block(worldX: alpineWaterCell.x, y: alpineWaterCell.y, worldZ: alpineWaterCell.z))"
        )

        // 1b. Biome.snowy freezing at standard elevation (y = 70 <= 85)
        var snowyFound: (x: Int, z: Int)?
        for r in 0..<120 {
            for dz in -r...r {
                for dx in -r...r where abs(dx) == r || abs(dz) == r || r == 0 {
                    let cx = originX + dx * 8, cz = originZ + dz * 8
                    if world.generator.biome(x: cx, z: cz) == .snowy {
                        snowyFound = (cx, cz)
                        break
                    }
                }
                if snowyFound != nil { break }
            }
            if snowyFound != nil { break }
        }

        if let snowyPos = snowyFound {
            let snowyChunk = World.chunkCoord(forWorldX: snowyPos.x, worldZ: snowyPos.z)
            world.forceGenerate(snowyChunk)
            let standardY = 70
            world.setBlock(worldX: snowyPos.x, y: standardY - 1, worldZ: snowyPos.z, to: .stone, remesh: false)
            for y in standardY..<Chunk.height {
                world.setBlock(worldX: snowyPos.x, y: y, worldZ: snowyPos.z, to: .air, remesh: false)
            }
            world.setBlock(worldX: snowyPos.x, y: standardY, worldZ: snowyPos.z, to: .water)
            world.tickThermal(atWorldX: snowyPos.x, y: standardY, worldZ: snowyPos.z)
            let snowyFroze = world.block(worldX: snowyPos.x, y: standardY, worldZ: snowyPos.z) == .ice

            report.check(
                "water freezes into ice in Biome.snowy at standard elevation (y <= 85) open to sky",
                snowyFroze,
                "pos: (\(snowyPos.x), \(standardY), \(snowyPos.z)), block: \(world.block(worldX: snowyPos.x, y: standardY, worldZ: snowyPos.z))"
            )
        } else {
            // Altitude threshold validation at y = 86
            let alt86 = (x: originX + 5, y: 86, z: originZ)
            world.setBlock(worldX: alt86.x, y: alt86.y - 1, worldZ: alt86.z, to: .stone, remesh: false)
            for y in alt86.y..<Chunk.height { world.setBlock(worldX: alt86.x, y: y, worldZ: alt86.z, to: .air, remesh: false) }
            world.setBlock(worldX: alt86.x, y: alt86.y, worldZ: alt86.z, to: .water)
            world.tickThermal(atWorldX: alt86.x, y: alt86.y, worldZ: alt86.z)
            let altFroze = world.block(worldX: alt86.x, y: alt86.y, worldZ: alt86.z) == .ice
            report.check(
                "water freezes into ice at alpine altitude threshold y=86",
                altFroze,
                "block: \(world.block(worldX: alt86.x, y: alt86.y, worldZ: alt86.z))"
            )
        }

        // 1c. Temperate lowland control (y = 70 <= 85, plains/forest): does NOT freeze
        let tempCell = (x: originX + 12, y: 70, z: originZ)
        world.setBlock(worldX: tempCell.x, y: tempCell.y - 1, worldZ: tempCell.z, to: .stone, remesh: false)
        for y in tempCell.y..<Chunk.height { world.setBlock(worldX: tempCell.x, y: y, worldZ: tempCell.z, to: .air, remesh: false) }
        world.setBlock(worldX: tempCell.x, y: tempCell.y, worldZ: tempCell.z, to: .water)
        world.tickThermal(atWorldX: tempCell.x, y: tempCell.y, worldZ: tempCell.z)
        let tempRemainsWater = world.block(worldX: tempCell.x, y: tempCell.y, worldZ: tempCell.z) == .water

        report.check(
            "water in temperate lowland (y <= 85) open to sky remains liquid",
            tempRemainsWater,
            "block: \(world.block(worldX: tempCell.x, y: tempCell.y, worldZ: tempCell.z))"
        )

        // =========================================================================
        // MARK: - Test 2: Sheltered Water (!isSkyOpen) Does Not Freeze
        // =========================================================================
        let shelteredCell = (x: originX + 4, y: alpineY, z: originZ + 4)
        world.setBlock(worldX: shelteredCell.x, y: shelteredCell.y - 1, worldZ: shelteredCell.z, to: .stone, remesh: false)
        world.setBlock(worldX: shelteredCell.x, y: shelteredCell.y, worldZ: shelteredCell.z, to: .water)
        // Place stone roof block directly overhead
        world.setBlock(worldX: shelteredCell.x, y: shelteredCell.y + 1, worldZ: shelteredCell.z, to: .stone)

        let skyBlocked = !world.isSkyOpen(worldX: shelteredCell.x, y: shelteredCell.y, worldZ: shelteredCell.z)
        world.tickThermal(atWorldX: shelteredCell.x, y: shelteredCell.y, worldZ: shelteredCell.z)
        let shelteredRemainsWater = world.block(worldX: shelteredCell.x, y: shelteredCell.y, worldZ: shelteredCell.z) == .water

        // Uncover the shelter: removing stone restores sky access and allows freeze
        world.setBlock(worldX: shelteredCell.x, y: shelteredCell.y + 1, worldZ: shelteredCell.z, to: .air)
        let skyUnblocked = world.isSkyOpen(worldX: shelteredCell.x, y: shelteredCell.y, worldZ: shelteredCell.z)
        world.tickThermal(atWorldX: shelteredCell.x, y: shelteredCell.y, worldZ: shelteredCell.z)
        let unroofedFroze = world.block(worldX: shelteredCell.x, y: shelteredCell.y, worldZ: shelteredCell.z) == .ice

        report.check(
            "sheltered water under roof does not freeze, and freezes once uncovered",
            skyBlocked && shelteredRemainsWater && skyUnblocked && unroofedFroze,
            "skyBlocked: \(skyBlocked), liquidUnderRoof: \(shelteredRemainsWater), frozeUnroofed: \(unroofedFroze)"
        )

        // =========================================================================
        // MARK: - Test 3: Water Near Heat Sources (R <= 3) Does Not Freeze
        // =========================================================================
        // 3a. Torch at distance 2
        let torchWater = (x: originX + 8, y: alpineY, z: originZ)
        world.setBlock(worldX: torchWater.x, y: torchWater.y - 1, worldZ: torchWater.z, to: .stone, remesh: false)
        world.setBlock(worldX: torchWater.x, y: torchWater.y, worldZ: torchWater.z, to: .water)
        world.setBlock(worldX: torchWater.x + 2, y: torchWater.y - 1, worldZ: torchWater.z, to: .stone, remesh: false)
        world.setBlock(worldX: torchWater.x + 2, y: torchWater.y, worldZ: torchWater.z, to: .torch)

        let nearTorch = world.isNearThermalSource(worldX: torchWater.x, y: torchWater.y, worldZ: torchWater.z, radius: 3)
        world.tickThermal(atWorldX: torchWater.x, y: torchWater.y, worldZ: torchWater.z)
        let torchProtected = world.block(worldX: torchWater.x, y: torchWater.y, worldZ: torchWater.z) == .water

        report.check(
            "water within radius 3 of a torch does not freeze in alpine altitude",
            nearTorch && torchProtected,
            "nearTorch: \(nearTorch), block: \(world.block(worldX: torchWater.x, y: torchWater.y, worldZ: torchWater.z))"
        )

        // 3b. Lit furnace vs unlit furnace
        let furnaceWater = (x: originX + 8, y: alpineY, z: originZ + 4)
        world.setBlock(worldX: furnaceWater.x, y: furnaceWater.y - 1, worldZ: furnaceWater.z, to: .stone, remesh: false)
        world.setBlock(worldX: furnaceWater.x, y: furnaceWater.y, worldZ: furnaceWater.z, to: .water)
        world.setBlock(worldX: furnaceWater.x + 1, y: furnaceWater.y, worldZ: furnaceWater.z, to: .furnaceLit)

        let nearLitFurnace = world.isNearThermalSource(worldX: furnaceWater.x, y: furnaceWater.y, worldZ: furnaceWater.z, radius: 3)
        world.tickThermal(atWorldX: furnaceWater.x, y: furnaceWater.y, worldZ: furnaceWater.z)
        let litFurnaceProtected = world.block(worldX: furnaceWater.x, y: furnaceWater.y, worldZ: furnaceWater.z) == .water

        // Extinguish furnace: unlit furnace emits no heat -> water freezes
        world.setBlock(worldX: furnaceWater.x + 1, y: furnaceWater.y, worldZ: furnaceWater.z, to: .furnace)
        let nearColdFurnace = world.isNearThermalSource(worldX: furnaceWater.x, y: furnaceWater.y, worldZ: furnaceWater.z, radius: 3)
        world.tickThermal(atWorldX: furnaceWater.x, y: furnaceWater.y, worldZ: furnaceWater.z)
        let coldFurnaceFroze = world.block(worldX: furnaceWater.x, y: furnaceWater.y, worldZ: furnaceWater.z) == .ice

        report.check(
            "water near lit furnace remains liquid, but freezes near cold unlit furnace",
            nearLitFurnace && litFurnaceProtected && !nearColdFurnace && coldFurnaceFroze,
            "litProtected: \(litFurnaceProtected), coldFroze: \(coldFurnaceFroze)"
        )

        // 3c. Lava at distance 2
        let lavaWater = (x: originX + 8, y: alpineY, z: originZ + 8)
        world.setBlock(worldX: lavaWater.x, y: lavaWater.y - 1, worldZ: lavaWater.z, to: .stone, remesh: false)
        world.setBlock(worldX: lavaWater.x, y: lavaWater.y, worldZ: lavaWater.z, to: .water)
        world.setBlock(worldX: lavaWater.x, y: lavaWater.y - 1, worldZ: lavaWater.z + 2, to: .stone, remesh: false)
        world.setBlock(worldX: lavaWater.x, y: lavaWater.y, worldZ: lavaWater.z + 2, to: .lava)

        let nearLava = world.isNearThermalSource(worldX: lavaWater.x, y: lavaWater.y, worldZ: lavaWater.z, radius: 3)
        world.tickThermal(atWorldX: lavaWater.x, y: lavaWater.y, worldZ: lavaWater.z)
        let lavaProtected = world.block(worldX: lavaWater.x, y: lavaWater.y, worldZ: lavaWater.z) == .water

        report.check(
            "water near lava does not freeze",
            nearLava && lavaProtected,
            "nearLava: \(nearLava), block: \(world.block(worldX: lavaWater.x, y: lavaWater.y, worldZ: lavaWater.z))"
        )

        // 3d. Lit signal lamp vs unlit lamp
        let lampWater = (x: originX - 8, y: alpineY, z: originZ)
        world.setBlock(worldX: lampWater.x, y: lampWater.y - 1, worldZ: lampWater.z, to: .stone, remesh: false)
        world.setBlock(worldX: lampWater.x, y: lampWater.y, worldZ: lampWater.z, to: .water)
        world.setBlock(worldX: lampWater.x - 3, y: lampWater.y, worldZ: lampWater.z, to: .signalLampLit)

        let nearLitLamp = world.isNearThermalSource(worldX: lampWater.x, y: lampWater.y, worldZ: lampWater.z, radius: 3)
        world.tickThermal(atWorldX: lampWater.x, y: lampWater.y, worldZ: lampWater.z)
        let litLampProtected = world.block(worldX: lampWater.x, y: lampWater.y, worldZ: lampWater.z) == .water

        world.setBlock(worldX: lampWater.x - 3, y: lampWater.y, worldZ: lampWater.z, to: .signalLamp)
        let nearUnlitLamp = world.isNearThermalSource(worldX: lampWater.x, y: lampWater.y, worldZ: lampWater.z, radius: 3)
        world.tickThermal(atWorldX: lampWater.x, y: lampWater.y, worldZ: lampWater.z)
        let unlitLampFroze = world.block(worldX: lampWater.x, y: lampWater.y, worldZ: lampWater.z) == .ice

        report.check(
            "water near lit signal lamp remains liquid, but freezes near unlit lamp",
            nearLitLamp && litLampProtected && !nearUnlitLamp && unlitLampFroze,
            "litLampProtected: \(litLampProtected), unlitFroze: \(unlitLampFroze)"
        )

        // 3e. Distance threshold: R=3 protected, R=4 freezes
        let distWater = (x: originX - 8, y: alpineY, z: originZ + 6)
        world.setBlock(worldX: distWater.x, y: distWater.y - 1, worldZ: distWater.z, to: .stone, remesh: false)
        world.setBlock(worldX: distWater.x, y: distWater.y, worldZ: distWater.z, to: .water)
        // Torch at distance 4 (beyond R <= 3)
        world.setBlock(worldX: distWater.x + 4, y: distWater.y - 1, worldZ: distWater.z, to: .stone, remesh: false)
        world.setBlock(worldX: distWater.x + 4, y: distWater.y, worldZ: distWater.z, to: .torch)

        let nearAtDist4 = world.isNearThermalSource(worldX: distWater.x, y: distWater.y, worldZ: distWater.z, radius: 3)
        world.tickThermal(atWorldX: distWater.x, y: distWater.y, worldZ: distWater.z)
        let dist4Froze = world.block(worldX: distWater.x, y: distWater.y, worldZ: distWater.z) == .ice

        report.check(
            "thermal radiance cutoff: heat source at distance 4 does not prevent freeze",
            !nearAtDist4 && dist4Froze,
            "nearAtDist4: \(nearAtDist4), block: \(world.block(worldX: distWater.x, y: distWater.y, worldZ: distWater.z))"
        )

        // =========================================================================
        // MARK: - Test 4: Ice Placed Near Heat Source (R <= 3) Thaws into Water
        // =========================================================================
        // 4a. Torch thawing
        let thawTorchIce = (x: originX + 12, y: 70, z: originZ)
        world.setBlock(worldX: thawTorchIce.x, y: thawTorchIce.y - 1, worldZ: thawTorchIce.z, to: .stone, remesh: false)
        world.setBlock(worldX: thawTorchIce.x, y: thawTorchIce.y, worldZ: thawTorchIce.z, to: .ice)
        world.setBlock(worldX: thawTorchIce.x + 2, y: thawTorchIce.y - 1, worldZ: thawTorchIce.z, to: .stone, remesh: false)
        world.setBlock(worldX: thawTorchIce.x + 2, y: thawTorchIce.y, worldZ: thawTorchIce.z, to: .torch)

        world.tickThermal(atWorldX: thawTorchIce.x, y: thawTorchIce.y, worldZ: thawTorchIce.z)
        let torchThawed = world.block(worldX: thawTorchIce.x, y: thawTorchIce.y, worldZ: thawTorchIce.z) == .water

        // 4b. Lit furnace thawing
        let thawFurnaceIce = (x: originX + 12, y: 70, z: originZ + 4)
        world.setBlock(worldX: thawFurnaceIce.x, y: thawFurnaceIce.y - 1, worldZ: thawFurnaceIce.z, to: .stone, remesh: false)
        world.setBlock(worldX: thawFurnaceIce.x, y: thawFurnaceIce.y, worldZ: thawFurnaceIce.z, to: .ice)
        world.setBlock(worldX: thawFurnaceIce.x + 1, y: thawFurnaceIce.y, worldZ: thawFurnaceIce.z, to: .furnaceLit)

        world.tickThermal(atWorldX: thawFurnaceIce.x, y: thawFurnaceIce.y, worldZ: thawFurnaceIce.z)
        let furnaceThawed = world.block(worldX: thawFurnaceIce.x, y: thawFurnaceIce.y, worldZ: thawFurnaceIce.z) == .water

        // 4c. Lava thawing
        let thawLavaIce = (x: originX + 12, y: 70, z: originZ + 8)
        world.setBlock(worldX: thawLavaIce.x, y: thawLavaIce.y - 1, worldZ: thawLavaIce.z, to: .stone, remesh: false)
        world.setBlock(worldX: thawLavaIce.x, y: thawLavaIce.y, worldZ: thawLavaIce.z, to: .ice)
        world.setBlock(worldX: thawLavaIce.x, y: thawLavaIce.y - 1, worldZ: thawLavaIce.z + 2, to: .stone, remesh: false)
        world.setBlock(worldX: thawLavaIce.x, y: thawLavaIce.y, worldZ: thawLavaIce.z + 2, to: .lava)

        world.tickThermal(atWorldX: thawLavaIce.x, y: thawLavaIce.y, worldZ: thawLavaIce.z)
        let lavaThawed = world.block(worldX: thawLavaIce.x, y: thawLavaIce.y, worldZ: thawLavaIce.z) == .water

        // 4d. Lit signal lamp thawing
        let thawLampIce = (x: originX - 12, y: 70, z: originZ)
        world.setBlock(worldX: thawLampIce.x, y: thawLampIce.y - 1, worldZ: thawLampIce.z, to: .stone, remesh: false)
        world.setBlock(worldX: thawLampIce.x, y: thawLampIce.y, worldZ: thawLampIce.z, to: .ice)
        world.setBlock(worldX: thawLampIce.x - 3, y: thawLampIce.y, worldZ: thawLampIce.z, to: .signalLampLit)

        world.tickThermal(atWorldX: thawLampIce.x, y: thawLampIce.y, worldZ: thawLampIce.z)
        let lampThawed = world.block(worldX: thawLampIce.x, y: thawLampIce.y, worldZ: thawLampIce.z) == .water

        // 4e. Thawing distance cutoff: ice at distance 4 does not thaw; moving torch to distance 3 thaws it
        let thawDistIce = (x: originX - 12, y: 70, z: originZ + 6)
        world.setBlock(worldX: thawDistIce.x, y: thawDistIce.y - 1, worldZ: thawDistIce.z, to: .stone, remesh: false)
        world.setBlock(worldX: thawDistIce.x, y: thawDistIce.y, worldZ: thawDistIce.z, to: .ice)
        world.setBlock(worldX: thawDistIce.x + 4, y: thawDistIce.y - 1, worldZ: thawDistIce.z, to: .stone, remesh: false)
        world.setBlock(worldX: thawDistIce.x + 4, y: thawDistIce.y, worldZ: thawDistIce.z, to: .torch)

        world.tickThermal(atWorldX: thawDistIce.x, y: thawDistIce.y, worldZ: thawDistIce.z)
        let dist4RemainsIce = world.block(worldX: thawDistIce.x, y: thawDistIce.y, worldZ: thawDistIce.z) == .ice

        // Move torch to distance 3
        world.setBlock(worldX: thawDistIce.x + 4, y: thawDistIce.y, worldZ: thawDistIce.z, to: .air)
        world.setBlock(worldX: thawDistIce.x + 3, y: thawDistIce.y - 1, worldZ: thawDistIce.z, to: .stone, remesh: false)
        world.setBlock(worldX: thawDistIce.x + 3, y: thawDistIce.y, worldZ: thawDistIce.z, to: .torch)

        world.tickThermal(atWorldX: thawDistIce.x, y: thawDistIce.y, worldZ: thawDistIce.z)
        let dist3Thawed = world.block(worldX: thawDistIce.x, y: thawDistIce.y, worldZ: thawDistIce.z) == .water

        report.check(
            "ice thaws into water near heat sources (torch, furnace, lava, lamp) within R <= 3",
            torchThawed && furnaceThawed && lavaThawed && lampThawed && dist4RemainsIce && dist3Thawed,
            "torch: \(torchThawed), furnace: \(furnaceThawed), lava: \(lavaThawed), lamp: \(lampThawed), d4Ice: \(dist4RemainsIce), d3Thawed: \(dist3Thawed)"
        )

        // =========================================================================
        // MARK: - Test 5: Farmland Hydration (Water Hydrates, Ice Does NOT)
        // =========================================================================
        let farmWater = (x: originX + 16, y: 70, z: originZ)
        let farmIce = (x: originX + 16, y: 70, z: originZ + 6)

        // Clear sky access above test fields
        for y in farmWater.y..<Chunk.height {
            for dx in 0...2 {
                world.setBlock(worldX: farmWater.x + dx, y: y, worldZ: farmWater.z, to: .air, remesh: false)
                world.setBlock(worldX: farmIce.x + dx, y: y, worldZ: farmIce.z, to: .air, remesh: false)
            }
        }

        // Farmland layout
        world.setBlock(worldX: farmWater.x, y: farmWater.y - 1, worldZ: farmWater.z, to: .farmland, remesh: false)
        world.setBlock(worldX: farmWater.x + 2, y: farmWater.y - 1, worldZ: farmWater.z, to: .water, remesh: false)
        world.setBlock(worldX: farmWater.x, y: farmWater.y, worldZ: farmWater.z, to: .wheatStage0)

        world.setBlock(worldX: farmIce.x, y: farmIce.y - 1, worldZ: farmIce.z, to: .farmland, remesh: false)
        world.setBlock(worldX: farmIce.x + 2, y: farmIce.y - 1, worldZ: farmIce.z, to: .ice, remesh: false)
        world.setBlock(worldX: farmIce.x, y: farmIce.y, worldZ: farmIce.z, to: .wheatStage0)

        let cropsWater = CropStore()
        let cropsIce = CropStore()
        let keyWater = CropStore.Key(farmWater.x, farmWater.y, farmWater.z)
        let keyIce = CropStore.Key(farmIce.x, farmIce.y, farmIce.z)
        cropsWater.planted(at: keyWater)
        cropsIce.planted(at: keyIce)

        let waterIsHydrated = world.isFarmlandHydrated(worldX: farmWater.x, y: farmWater.y - 1, worldZ: farmWater.z)
        let iceIsNotHydrated = !world.isFarmlandHydrated(worldX: farmIce.x, y: farmIce.y - 1, worldZ: farmIce.z)

        var elapsedHydration = 0.0
        let hydrationBudget = CropStore.stageSeconds / CropStore.hydratedGrowthMultiplier + 0.5
        while elapsedHydration < hydrationBudget {
            for key in cropsWater.tick(dt: dt, world: world) {
                let curr = world.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: curr.rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                }
            }
            for key in cropsIce.tick(dt: dt, world: world) {
                let curr = world.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: curr.rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                }
            }
            elapsedHydration += dt
        }

        let wheatWaterStage = world.block(worldX: farmWater.x, y: farmWater.y, worldZ: farmWater.z)
        let wheatIceStage = world.block(worldX: farmIce.x, y: farmIce.y, worldZ: farmIce.z)

        // Untended farmland reversion check: unplanted farmland next to ice reverts to dirt, next to water remains farmland
        let untendedWaterFarmland = (x: farmWater.x + 1, y: farmWater.y - 1, z: farmWater.z)
        let untendedIceFarmland = (x: farmIce.x + 1, y: farmIce.y - 1, z: farmIce.z)
        world.setBlock(worldX: untendedWaterFarmland.x, y: untendedWaterFarmland.y, worldZ: untendedWaterFarmland.z, to: .farmland, remesh: false)
        world.setBlock(worldX: untendedIceFarmland.x, y: untendedIceFarmland.y, worldZ: untendedIceFarmland.z, to: .farmland, remesh: false)

        world.tickFarmland(worldX: untendedWaterFarmland.x, y: untendedWaterFarmland.y, worldZ: untendedWaterFarmland.z)
        world.tickFarmland(worldX: untendedIceFarmland.x, y: untendedIceFarmland.y, worldZ: untendedIceFarmland.z)

        let waterFarmlandStayed = world.block(worldX: untendedWaterFarmland.x, y: untendedWaterFarmland.y, worldZ: untendedWaterFarmland.z) == .farmland
        let iceFarmlandReverted = world.block(worldX: untendedIceFarmland.x, y: untendedIceFarmland.y, worldZ: untendedIceFarmland.z) == .dirt

        report.check(
            "farmland next to water hydrates and accelerates growth; farmland next to ice does not hydrate and reverts to dirt if untended",
            waterIsHydrated && iceIsNotHydrated && wheatWaterStage == .wheatStage1 && wheatIceStage == .wheatStage0
                && waterFarmlandStayed && iceFarmlandReverted,
            "waterHydrated: \(waterIsHydrated), iceHydrated: \(!iceIsNotHydrated), waterCrop: \(wheatWaterStage), iceCrop: \(wheatIceStage), waterFarmland: \(waterFarmlandStayed), iceFarmlandReverted: \(iceFarmlandReverted)"
        )

        // =========================================================================
        // MARK: - Test 6: Subterranean Farming in Closed Cavern (y=20, No Sky Access)
        // =========================================================================
        let caveOriginX = originX - 20
        let caveOriginZ = originZ - 20
        let caveFloorY = 20
        let caveCeilingY = 25

        // Hollow out a sealed underground cavern in solid stone
        for y in (caveFloorY - 1)...(caveCeilingY + 1) {
            for z in (caveOriginZ - 6)...(caveOriginZ + 6) {
                for x in (caveOriginX - 6)...(caveOriginX + 6) {
                    let isInterior = y >= caveFloorY && y <= caveCeilingY
                        && abs(x - caveOriginX) <= 5 && abs(z - caveOriginZ) <= 5
                    world.setBlock(worldX: x, y: y, worldZ: z, to: isInterior ? .air : .stone, remesh: false)
                }
            }
        }

        // Verify total absence of sky access
        var caveSkyClosed = true
        for z in (caveOriginZ - 4)...(caveOriginZ + 4) {
            for x in (caveOriginX - 4)...(caveOriginX + 4) {
                if world.isSkyOpen(worldX: x, y: caveFloorY + 1, worldZ: z) {
                    caveSkyClosed = false
                }
            }
        }

        // 6a. Subterranean dormancy under unlit lamp (light 0)
        let lampCell = (x: caveOriginX, y: caveFloorY + 3, z: caveOriginZ)
        world.setBlock(worldX: lampCell.x, y: lampCell.y, worldZ: lampCell.z, to: .signalLamp)

        let wheatCell = (x: caveOriginX, y: caveFloorY + 1, z: caveOriginZ)
        world.setBlock(worldX: wheatCell.x, y: wheatCell.y - 1, worldZ: wheatCell.z, to: .farmland, remesh: false)
        world.setBlock(worldX: wheatCell.x, y: wheatCell.y, worldZ: wheatCell.z, to: .wheatStage0)

        let saplingCell = (x: caveOriginX + 2, y: caveFloorY + 1, z: caveOriginZ)
        world.setBlock(worldX: saplingCell.x, y: saplingCell.y - 1, worldZ: saplingCell.z, to: .dirt, remesh: false)
        world.setBlock(worldX: saplingCell.x, y: saplingCell.y, worldZ: saplingCell.z, to: .sapling)

        let darkWheatLight = world.lightLevel(worldX: wheatCell.x, y: wheatCell.y, worldZ: wheatCell.z)
        let darkSaplingLight = world.lightLevel(worldX: saplingCell.x, y: saplingCell.y, worldZ: saplingCell.z)

        let darkCrops = CropStore()
        let darkSaplings = SaplingStore()
        let caveWheatKey = CropStore.Key(wheatCell.x, wheatCell.y, wheatCell.z)
        let caveSaplingKey = SaplingStore.Key(saplingCell.x, saplingCell.y, saplingCell.z)
        darkCrops.planted(at: caveWheatKey)
        darkSaplings.planted(at: caveSaplingKey)

        var darkElapsed = 0.0
        while darkElapsed < CropStore.stageSeconds * 1.5 {
            _ = darkCrops.tick(dt: dt, world: world)
            _ = darkSaplings.tick(dt: dt, world: world)
            darkElapsed += dt
        }

        let darkWheatDormant = world.block(worldX: wheatCell.x, y: wheatCell.y, worldZ: wheatCell.z) == .wheatStage0
        let darkSaplingDormant = world.block(worldX: saplingCell.x, y: saplingCell.y, worldZ: saplingCell.z) == .sapling

        report.check(
            "crops and saplings in dark cavern (light 0, unlit lamp) remain completely dormant",
            caveSkyClosed && darkWheatLight == 0 && darkSaplingLight == 0 && darkWheatDormant && darkSaplingDormant,
            "skyClosed: \(caveSkyClosed), light: \(darkWheatLight), wheat: \(world.block(worldX: wheatCell.x, y: wheatCell.y, worldZ: wheatCell.z)), sapling: \(world.block(worldX: saplingCell.x, y: saplingCell.y, worldZ: saplingCell.z))"
        )

        // 6b. Active growth under lit signal lamp (light >= 9)
        world.setBlock(worldX: lampCell.x, y: lampCell.y, worldZ: lampCell.z, to: .signalLampLit)
        let litWheatLight = world.lightLevel(worldX: wheatCell.x, y: wheatCell.y, worldZ: wheatCell.z)
        let litSaplingLight = world.lightLevel(worldX: saplingCell.x, y: saplingCell.y, worldZ: saplingCell.z)

        let litCrops = CropStore()
        let litSaplings = SaplingStore()
        litCrops.planted(at: caveWheatKey)
        litSaplings.planted(at: caveSaplingKey)

        // Advance 1 stage under lit lamp
        var litElapsed = 0.0
        while litElapsed < CropStore.stageSeconds * 1.1 {
            for key in litCrops.tick(dt: dt, world: world) {
                let curr = world.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: curr.rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                }
            }
            _ = litSaplings.tick(dt: dt, world: world)
            litElapsed += dt
        }
        let litWheatAdvanced = world.block(worldX: wheatCell.x, y: wheatCell.y, worldZ: wheatCell.z) == .wheatStage1

        // Continue until crops reach full maturity (ripe stage 3) and sapling matures
        while litElapsed < CropStore.stageSeconds * 3.5 {
            for key in litCrops.tick(dt: dt, world: world) {
                let curr = world.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: curr.rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                }
            }
            let matured = litSaplings.tick(dt: dt, world: world)
            if matured.contains(caveSaplingKey) {
                // Sapling successfully triggered growth under artificial lamp
                world.setBlock(worldX: saplingCell.x, y: saplingCell.y, worldZ: saplingCell.z, to: .log)
            }
            litElapsed += dt
        }

        let litWheatRipe = world.block(worldX: wheatCell.x, y: wheatCell.y, worldZ: wheatCell.z) == .wheatStage3
        let litSaplingGrown = world.block(worldX: saplingCell.x, y: saplingCell.y, worldZ: saplingCell.z) == .log

        report.check(
            "crops and saplings grow under lit signal lamp (light >= 9) to full maturity without sky access",
            litWheatLight >= 9 && litSaplingLight >= 9 && litWheatAdvanced && litWheatRipe && litSaplingGrown,
            "wheatLight: \(litWheatLight), saplingLight: \(litSaplingLight), advanced: \(litWheatAdvanced), ripe: \(litWheatRipe), saplingGrown: \(litSaplingGrown)"
        )

        // 6c. Growth under torch and light threshold cutoff (light 8 stalls, light 9 grows)
        let torchPos = (x: caveOriginX - 3, y: caveFloorY + 1, z: caveOriginZ)
        world.setBlock(worldX: torchPos.x, y: torchPos.y, worldZ: torchPos.z, to: .torch)

        // Torch emission is 14.
        // Distance 5 along Z -> light = 14 - 5 = 9 (growth enabled)
        // Distance 6 along Z -> light = 14 - 6 = 8 (growth disabled)
        let threshold9Cell = (x: torchPos.x, y: caveFloorY + 1, z: torchPos.z + 5)
        let threshold8Cell = (x: torchPos.x, y: caveFloorY + 1, z: torchPos.z + 6)

        world.setBlock(worldX: threshold9Cell.x, y: threshold9Cell.y - 1, worldZ: threshold9Cell.z, to: .farmland, remesh: false)
        world.setBlock(worldX: threshold9Cell.x, y: threshold9Cell.y, worldZ: threshold9Cell.z, to: .wheatStage0)

        world.setBlock(worldX: threshold8Cell.x, y: threshold8Cell.y - 1, worldZ: threshold8Cell.z, to: .farmland, remesh: false)
        world.setBlock(worldX: threshold8Cell.x, y: threshold8Cell.y, worldZ: threshold8Cell.z, to: .wheatStage0)

        let level9 = world.lightLevel(worldX: threshold9Cell.x, y: threshold9Cell.y, worldZ: threshold9Cell.z)
        let level8 = world.lightLevel(worldX: threshold8Cell.x, y: threshold8Cell.y, worldZ: threshold8Cell.z)

        let thresholdCrops = CropStore()
        let key9 = CropStore.Key(threshold9Cell.x, threshold9Cell.y, threshold9Cell.z)
        let key8 = CropStore.Key(threshold8Cell.x, threshold8Cell.y, threshold8Cell.z)
        thresholdCrops.planted(at: key9)
        thresholdCrops.planted(at: key8)

        var threshElapsed = 0.0
        while threshElapsed < CropStore.stageSeconds * 1.2 {
            for key in thresholdCrops.tick(dt: dt, world: world) {
                let curr = world.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: curr.rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                }
            }
            threshElapsed += dt
        }

        let stageAtLevel9 = world.block(worldX: threshold9Cell.x, y: threshold9Cell.y, worldZ: threshold9Cell.z)
        let stageAtLevel8 = world.block(worldX: threshold8Cell.x, y: threshold8Cell.y, worldZ: threshold8Cell.z)

        report.check(
            "photosynthetic threshold: crop grows at light 9 but remains dormant at light 8",
            level9 == 9 && level8 == 8 && stageAtLevel9 == .wheatStage1 && stageAtLevel8 == .wheatStage0,
            "level9: \(level9) -> \(stageAtLevel9), level8: \(level8) -> \(stageAtLevel8)"
        )

        // =========================================================================
        // MARK: - Verdict Reporting
        // =========================================================================
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — thermal\n"
            : "[check] all passed — thermal\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

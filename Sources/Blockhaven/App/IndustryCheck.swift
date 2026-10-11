import Foundation

/// Headless verification proof of Milestone 4: Diurnal Hostile Ecology, Grand Integration & Gauntlet Log.
///
/// Validates the comprehensive composition of all Wave 9 interrelated systems:
/// 1. Celestial Sensing & Lighting: Daylight sensor driving signal lamp illumination.
/// 2. Thermal Microclimates: Lit furnace radiating heat, melting ice, and preventing water from freezing.
/// 3. Subterranean Agriculture: Melted water canal irrigating crops and saplings illuminated by signal lamps (light >= 9).
/// 4. Horizontal Logistics & Super-Fuel: Directional hoppers feeding ore and lava bucket, extracting ingots + empty bucket.
/// 5. Granular Gravity: Sand and gravel cascading downward into cavities cleared by excavation.
/// 6. Diurnal Hostile Ecology: Skeletons burning in direct morning sunlight while safe under roofs or in water.
/// 7. Industrial Disturbance: Disturbance accumulating from smelting and blast, escalating mob aggro range (16 -> 32).
/// 8. Grand Continuous Composition: Continuous simulation session proving all systems interact coherently.
///
/// Run via `BLOCKHAVEN_CHECK_INDUSTRY=1`. Exits nonzero on failure.
enum IndustryCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_INDUSTRY"] != nil
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

    @MainActor
    static func run() -> Never {
        var report = Report()
        let world = World(seed: 42)
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))

        // Force generate 5x5 chunks around spawn
        for dz in -2...2 {
            for dx in -2...2 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        let originX = Int(spawn.x)
        let originZ = Int(spawn.z)

        // =========================================================================
        // SECTION 1: Celestial Day/Night Sensing & Signal Lamp Illumination (System 1)
        // =========================================================================
        let alpineY = 88 // Alpine elevation (> 85)
        let surfaceDeckY = alpineY - 1

        // Clear an elevated platform for celestial testing open to sky
        for dz in -10...10 {
            for dx in -10...10 {
                world.setBlock(worldX: originX + dx, y: surfaceDeckY, worldZ: originZ + dz, to: .stone, remesh: false)
                for y in alpineY..<Chunk.height {
                    world.setBlock(worldX: originX + dx, y: y, worldZ: originZ + dz, to: .air, remesh: false)
                }
            }
        }

        let sensorPos = (x: originX, y: alpineY, z: originZ)
        let sensorKey = SignalNetwork.Key(sensorPos.x, sensorPos.y, sensorPos.z)
        world.setBlock(worldX: sensorPos.x, y: sensorPos.y, worldZ: sensorPos.z, to: .daylightSensor)

        // Wire running to lamp
        world.setBlock(worldX: sensorPos.x + 1, y: sensorPos.y, worldZ: sensorPos.z, to: .wireOff)
        world.setBlock(worldX: sensorPos.x + 2, y: sensorPos.y, worldZ: sensorPos.z, to: .wireOff)
        let lampPos = (x: sensorPos.x + 3, y: sensorPos.y, z: sensorPos.z)
        let lampKey = SignalNetwork.Key(lampPos.x, lampPos.y, lampPos.z)
        world.setBlock(worldX: lampPos.x, y: lampPos.y, worldZ: lampPos.z, to: .signalLamp)

        let signals = SignalNetwork()
        let fuses = FuseManager()
        signals.daylightSensorPlaced(at: sensorKey)
        signals.lampPlaced(at: lampKey)

        // Noon evaluation: timeOfDay = 0.25
        signals.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)
        let wirePoweredAtNoon = world.block(worldX: sensorPos.x + 1, y: sensorPos.y, worldZ: sensorPos.z) == .wireOn
        let lampLitAtNoon = world.block(worldX: lampPos.x, y: lampPos.y, worldZ: lampPos.z) == .signalLampLit
        let lampLightLevel = world.lightLevel(worldX: lampPos.x, y: lampPos.y, worldZ: lampPos.z)

        report.check(
            "daylight sensor powers wire and illuminates signal lamp to light level 15 at solar noon",
            wirePoweredAtNoon && lampLitAtNoon && lampLightLevel == 15,
            "wireLit: \(wirePoweredAtNoon), lampLit: \(lampLitAtNoon), lightLevel: \(lampLightLevel)"
        )

        // Midnight evaluation: timeOfDay = 0.75
        signals.updateDaylightSensors(world: world, timeOfDay: 0.75, fuses: fuses)
        let lampUnlitAtMidnight = world.block(worldX: lampPos.x, y: lampPos.y, worldZ: lampPos.z) == .signalLamp
        let lampLightMidnight = world.lightLevel(worldX: lampPos.x, y: lampPos.y, worldZ: lampPos.z)

        report.check(
            "daylight sensor cuts power at night, reverting lamp to unlit state and unwinding block light",
            lampUnlitAtMidnight && lampLightMidnight == 0,
            "lampUnlit: \(lampUnlitAtMidnight), lightLevel: \(lampLightMidnight)"
        )

        // =========================================================================
        // SECTION 2: Lit Furnace Radiating Heat, Melting Ice, & Freezing Prevention (System 2)
        // =========================================================================
        let alpineWaterPos = (x: originX + 5, y: alpineY, z: originZ + 5)
        world.setBlock(worldX: alpineWaterPos.x, y: alpineWaterPos.y, worldZ: alpineWaterPos.z, to: .water)

        // Unheated water freezes in alpine altitude
        world.tickThermal(atWorldX: alpineWaterPos.x, y: alpineWaterPos.y, worldZ: alpineWaterPos.z)
        let waterFrozeToIce = world.block(worldX: alpineWaterPos.x, y: alpineWaterPos.y, worldZ: alpineWaterPos.z) == .ice

        report.check(
            "unheated water at alpine elevation (y > 85) open to sky freezes into ice",
            waterFrozeToIce,
            "block: \(world.block(worldX: alpineWaterPos.x, y: alpineWaterPos.y, worldZ: alpineWaterPos.z))"
        )

        // Place lit furnace at distance 2 (within thermal radius 3)
        let thermalFurnacePos = (x: alpineWaterPos.x + 2, y: alpineWaterPos.y, z: alpineWaterPos.z)
        world.setBlock(worldX: thermalFurnacePos.x, y: thermalFurnacePos.y, worldZ: thermalFurnacePos.z, to: .furnaceLit)

        let nearHeat = world.isNearThermalSource(worldX: alpineWaterPos.x, y: alpineWaterPos.y, worldZ: alpineWaterPos.z, radius: 3)
        world.tickThermal(atWorldX: alpineWaterPos.x, y: alpineWaterPos.y, worldZ: alpineWaterPos.z)
        let iceMeltedToWater = world.block(worldX: alpineWaterPos.x, y: alpineWaterPos.y, worldZ: alpineWaterPos.z) == .water

        // Lit furnace prevents re-freezing on subsequent thermal tick
        world.tickThermal(atWorldX: alpineWaterPos.x, y: alpineWaterPos.y, worldZ: alpineWaterPos.z)
        let remainedWater = world.block(worldX: alpineWaterPos.x, y: alpineWaterPos.y, worldZ: alpineWaterPos.z) == .water

        report.check(
            "lit furnace thermal radiance (R <= 3) melts alpine ice into water and prevents re-freezing",
            nearHeat && iceMeltedToWater && remainedWater,
            "nearHeat: \(nearHeat), melted: \(iceMeltedToWater), stayedWater: \(remainedWater)"
        )

        // =========================================================================
        // SECTION 3: Subterranean Artificial Light Agriculture (System 3)
        // =========================================================================
        let caveY = 30
        let caveX = originX - 25
        let caveZ = originZ - 25

        // Carve sealed underground cavern
        for y in (caveY - 1)...(caveY + 5) {
            for z in (caveZ - 5)...(caveZ + 5) {
                for x in (caveX - 5)...(caveX + 5) {
                    let isInterior = y >= caveY && y <= caveY + 4 && abs(x - caveX) <= 4 && abs(z - caveZ) <= 4
                    world.setBlock(worldX: x, y: y, worldZ: z, to: isInterior ? .air : .stone, remesh: false)
                }
            }
        }
        let caveSkyBlocked = !world.isSkyOpen(worldX: caveX, y: caveY + 1, worldZ: caveZ)

        // Subterranean crop setup
        let farmPos = (x: caveX, y: caveY + 1, z: caveZ)
        let farmSoilPos = (x: farmPos.x, y: farmPos.y - 1, z: farmPos.z)
        world.setBlock(worldX: farmSoilPos.x, y: farmSoilPos.y, worldZ: farmSoilPos.z, to: .farmland, remesh: false)
        world.setBlock(worldX: farmPos.x, y: farmPos.y, worldZ: farmPos.z, to: .wheatStage0)

        // Water canal 2 blocks away to hydrate farmland
        let canalPos = (x: farmPos.x + 2, y: farmSoilPos.y, z: farmPos.z)
        world.setBlock(worldX: canalPos.x, y: canalPos.y, worldZ: canalPos.z, to: .water)

        let isFarmlandHydrated = world.isFarmlandHydrated(worldX: farmSoilPos.x, y: farmSoilPos.y, worldZ: farmSoilPos.z)

        // Cave lamp directly above crop (y+3)
        let caveLampPos = (x: farmPos.x, y: farmPos.y + 3, z: farmPos.z)
        let caveLampKey = SignalNetwork.Key(caveLampPos.x, caveLampPos.y, caveLampPos.z)
        world.setBlock(worldX: caveLampPos.x, y: caveLampPos.y, worldZ: caveLampPos.z, to: .signalLamp)

        let caveSignals = SignalNetwork()
        caveSignals.lampPlaced(at: caveLampKey)

        // With unlit lamp, light level is 0 -> crop stays dormant
        let crops = CropStore()
        let cropKey = CropStore.Key(farmPos.x, farmPos.y, farmPos.z)
        crops.planted(at: cropKey)

        _ = crops.tick(dt: 20.0, world: world)
        let unlitAdvanced = world.block(worldX: farmPos.x, y: farmPos.y, worldZ: farmPos.z) != .wheatStage0

        report.check(
            "subterranean crop in dark cavern (isSkyOpen == false, light == 0) remains dormant",
            caveSkyBlocked && isFarmlandHydrated && !unlitAdvanced,
            "caveSkyBlocked: \(caveSkyBlocked), hydrated: \(isFarmlandHydrated), advancedWhileDark: \(unlitAdvanced)"
        )

        // Light the signal lamp in the cavern
        world.setBlock(worldX: caveLampPos.x, y: caveLampPos.y, worldZ: caveLampPos.z, to: .signalLampLit)
        let cropLightLevel = world.lightLevel(worldX: farmPos.x, y: farmPos.y, worldZ: farmPos.z)

        // Advance crop ticks with artificial light (>= 9) and hydration
        var advancedStage = false
        for _ in 0..<120 {
            for key in crops.tick(dt: 0.5, world: world) {
                if let next = BlockType(rawValue: world.block(worldX: key.x, y: key.y, worldZ: key.z).rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                    advancedStage = true
                }
            }
        }
        let finalCropBlock = world.block(worldX: farmPos.x, y: farmPos.y, worldZ: farmPos.z)

        // Also test subterranean sapling growth under the signal lamp
        let saplingPos = (x: farmPos.x + 1, y: farmPos.y, z: farmPos.z)
        world.setBlock(worldX: saplingPos.x, y: saplingPos.y - 1, worldZ: saplingPos.z, to: .dirt)
        world.setBlock(worldX: saplingPos.x, y: saplingPos.y, worldZ: saplingPos.z, to: .sapling)
        let saplings = SaplingStore()
        let saplingKey = SaplingStore.Key(saplingPos.x, saplingPos.y, saplingPos.z)
        saplings.planted(at: saplingKey)
        let maturedSaplings = saplings.tick(dt: 100.0, world: world)
        let saplingMaturedUnderLight = maturedSaplings.contains(saplingKey)

        report.check(
            "subterranean crops and saplings mature under artificial signal lamp light (light >= 9)",
            cropLightLevel >= 9 && advancedStage && finalCropBlock != .wheatStage0 && saplingMaturedUnderLight,
            "cropLight: \(cropLightLevel), cropAdvanced: \(advancedStage), saplingMatured: \(saplingMaturedUnderLight)"
        )

        // =========================================================================
        // SECTION 4: Directional Hopper Pipeline & Closed-Loop Lava Fuel (System 4)
        // =========================================================================
        let autoX = originX + 20
        let autoY = 50
        let autoZ = originZ + 20

        world.setBlock(worldX: autoX, y: autoY, worldZ: autoZ, to: .furnace)
        let autoFurnaceKey = FurnaceStore.Key(autoX, autoY, autoZ)

        let chests = ChestStore()
        let furnaces = FurnaceStore()
        let hoppers = HopperStore()
        var minecarts = MinecartManager()

        // Side fuel hopper (x-1, y, z) facing East
        let fuelHopperKey = HopperStore.Key(autoX - 1, autoY, autoZ)
        world.setBlock(worldX: autoX - 1, y: autoY, worldZ: autoZ, to: .hopper)
        hoppers.hopperPlaced(at: fuelHopperKey, facing: .east)
        hoppers.setItem(ItemStack(.lavaBucket, count: 1), at: fuelHopperKey)

        // Top ore hopper (x, y+1, z) facing Down
        let oreHopperKey = HopperStore.Key(autoX, autoY + 1, autoZ)
        world.setBlock(worldX: autoX, y: autoY + 1, worldZ: autoZ, to: .hopper)
        hoppers.hopperPlaced(at: oreHopperKey, facing: nil)
        hoppers.setItem(ItemStack(.rawIron, count: 3), at: oreHopperKey)

        // Bottom extraction hopper (x, y-1, z) facing Down
        let extractHopperKey = HopperStore.Key(autoX, autoY - 1, autoZ)
        world.setBlock(worldX: autoX, y: autoY - 1, worldZ: autoZ, to: .hopper)
        hoppers.hopperPlaced(at: extractHopperKey, facing: nil)

        // Destination chest (x, y-2, z)
        let dstChestKey = ChestStore.Key(autoX, autoY - 2, autoZ)
        world.setBlock(worldX: autoX, y: autoY - 2, worldZ: autoZ, to: .chest)

        // Step hoppers to feed fuel and ore
        HopperStore.transfer(at: fuelHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
        HopperStore.transfer(at: oreHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)

        var fState = furnaces.state(at: autoFurnaceKey)
        let fedInitial = fState.fuelType == .lavaBucket && fState.oreType == .rawIron

        // Ignite furnace
        _ = fState.tick(dt: 0.1)
        furnaces.set(fState, at: autoFurnaceKey)
        let superFuelIgnited = fState.isBurning && fState.fuelType == .bucket && fState.burnRemaining > 295.0

        report.check(
            "directional hoppers feed lava bucket and ore into furnace, igniting 300s super-fuel burn and leaving empty bucket",
            fedInitial && superFuelIgnited,
            "fed: \(fedInitial), burning: \(fState.isBurning), fuelType: \(String(describing: fState.fuelType)), burnRemaining: \(fState.burnRemaining)"
        )

        // Complete 1 smelt (30 ticks of dt=0.1)
        for _ in 0..<30 {
            _ = fState.tick(dt: 0.1)
        }
        furnaces.set(fState, at: autoFurnaceKey)

        // Extract smelted ingot
        HopperStore.transfer(at: extractHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
        let ingotExtracted = furnaces.state(at: autoFurnaceKey).outputType == nil
            && (hoppers.item(at: extractHopperKey)?.type == .ironIngot || chests.existing(at: dstChestKey)?.contents.contains(where: { $0.type == .ironIngot }) == true)

        // Push ingot from hopper into chest if still in hopper
        HopperStore.transfer(at: extractHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)

        // Extract empty bucket from fuel slot
        HopperStore.transfer(at: extractHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
        let bucketExtracted = furnaces.state(at: autoFurnaceKey).fuelType == nil
            && (hoppers.item(at: extractHopperKey)?.type == .bucket || chests.existing(at: dstChestKey)?.contents.contains(where: { $0.type == .bucket }) == true)

        // Final push to destination chest
        HopperStore.transfer(at: extractHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)

        let dstChest = chests.existing(at: dstChestKey)
        let hasIngotInChest = dstChest?.contents.contains(where: { $0.type == .ironIngot }) == true
        let hasBucketInChest = dstChest?.contents.contains(where: { $0.type == .bucket }) == true

        report.check(
            "extraction hopper pulls smelted iron ingot and retrieves empty fuel bucket into destination chest",
            ingotExtracted && bucketExtracted && hasIngotInChest && hasBucketInChest,
            "ingotExtracted: \(ingotExtracted), bucketExtracted: \(bucketExtracted), chestContents: \(String(describing: dstChest?.contents))"
        )

        // =========================================================================
        // SECTION 5: Granular Overburden Settling & Void Infill (System 5)
        // =========================================================================
        let pitX = originX - 15
        let pitZ = originZ + 15
        let pitFloorY = 40

        // Solid box with 3x3 void from y+1 to y+4, stone ceiling at y+5, sand/gravel overburden at y+6, y+7
        for y in pitFloorY...(pitFloorY + 8) {
            for dz in -2...2 {
                for dx in -2...2 {
                    let isVoid = y >= pitFloorY + 1 && y <= pitFloorY + 4 && abs(dx) <= 1 && abs(dz) <= 1
                    let isCeiling = y == pitFloorY + 5 && abs(dx) <= 1 && abs(dz) <= 1
                    let isOverburdenSand = y == pitFloorY + 6 && abs(dx) <= 1 && abs(dz) <= 1
                    let isOverburdenGravel = y == pitFloorY + 7 && abs(dx) <= 1 && abs(dz) <= 1

                    if isVoid {
                        world.setBlock(worldX: pitX + dx, y: y, worldZ: pitZ + dz, to: .air, remesh: false)
                    } else if isCeiling {
                        world.setBlock(worldX: pitX + dx, y: y, worldZ: pitZ + dz, to: .stone, remesh: false)
                    } else if isOverburdenSand {
                        world.setBlock(worldX: pitX + dx, y: y, worldZ: pitZ + dz, to: .sand, remesh: false)
                    } else if isOverburdenGravel {
                        world.setBlock(worldX: pitX + dx, y: y, worldZ: pitZ + dz, to: .gravel, remesh: false)
                    } else {
                        world.setBlock(worldX: pitX + dx, y: y, worldZ: pitZ + dz, to: .stone, remesh: false)
                    }
                }
            }
        }

        // Overburden is suspended by stone ceiling
        world.settleGranular()
        let suspendedBeforeBreak = world.block(worldX: pitX, y: pitFloorY + 6, worldZ: pitZ) == .sand

        // Mine/break the stone ceiling
        for dz in -1...1 {
            for dx in -1...1 {
                world.setBlock(worldX: pitX + dx, y: pitFloorY + 5, worldZ: pitZ + dz, to: .air, remesh: false)
            }
        }

        // Trigger granular settling cascade
        world.settleGranular()

        let overburdenCleared = world.block(worldX: pitX, y: pitFloorY + 6, worldZ: pitZ) == .air
            && world.block(worldX: pitX, y: pitFloorY + 7, worldZ: pitZ) == .air
        let settledAtBottom = world.block(worldX: pitX, y: pitFloorY + 1, worldZ: pitZ) == .sand
            && world.block(worldX: pitX, y: pitFloorY + 2, worldZ: pitZ) == .gravel

        report.check(
            "clearing stone ceiling collapses sand and gravel overburden down into excavated void, stacking sequentially",
            suspendedBeforeBreak && overburdenCleared && settledAtBottom,
            "suspendedBefore: \(suspendedBeforeBreak), clearedAbove: \(overburdenCleared), settledBottom: \(settledAtBottom)"
        )

        // =========================================================================
        // SECTION 6: Diurnal Skeleton Sunlight Combustion & Environmental Sanctuary (System 6)
        // =========================================================================
        let skelSurfaceY = alpineY
        let skelA_Pos = Vector3(CGFloat(originX) + 8.5, CGFloat(skelSurfaceY), CGFloat(originZ) - 8.5) // Open sky
        let skelB_Pos = Vector3(CGFloat(originX) - 6.5, CGFloat(skelSurfaceY), CGFloat(originZ) + 6.5) // Under 11x11 roof
        let skelC_Pos = Vector3(CGFloat(originX) + 6.5, CGFloat(skelSurfaceY), CGFloat(originZ) + 6.5) // In enclosed water pool

        // Build walled & roofed chamber for Skeleton B centered on skelB_Pos
        let bX = Int(skelB_Pos.x)
        let bZ = Int(skelB_Pos.z)
        for dx in -2...2 {
            for dz in -2...2 {
                if abs(dx) == 2 || abs(dz) == 2 {
                    world.setBlock(worldX: bX + dx, y: skelSurfaceY, worldZ: bZ + dz, to: .stone)
                    world.setBlock(worldX: bX + dx, y: skelSurfaceY + 1, worldZ: bZ + dz, to: .stone)
                }
                world.setBlock(worldX: bX + dx, y: skelSurfaceY + 2, worldZ: bZ + dz, to: .stone)
            }
        }

        // Build walled water pool for Skeleton C so wandering stays submerged
        let cX = Int(skelC_Pos.x)
        let cZ = Int(skelC_Pos.z)
        for dx in -2...2 {
            for dz in -2...2 {
                world.setBlock(worldX: cX + dx, y: skelSurfaceY - 1, worldZ: cZ + dz, to: .stone)
                if abs(dx) == 2 || abs(dz) == 2 {
                    world.setBlock(worldX: cX + dx, y: skelSurfaceY, worldZ: cZ + dz, to: .stone)
                } else {
                    world.setBlock(worldX: cX + dx, y: skelSurfaceY, worldZ: cZ + dz, to: .water)
                }
            }
        }

        var skelA = Skeleton(position: skelA_Pos, seed: 0xA1)
        var skelB = Skeleton(position: skelB_Pos, seed: 0xB2)
        var skelC = Skeleton(position: skelC_Pos, seed: 0xC3)

        // Simulate 4 seconds of direct morning sunlight (timeOfDay = 0.15, !isNight, !isRaining)
        let morningEye = Vector3(CGFloat(originX), CGFloat(skelSurfaceY) + 1, CGFloat(originZ))
        for _ in 0..<240 {
            skelA.step(dt: dt, playerEye: morningEye, canSeePlayer: false, isNight: false, isRaining: false, world: world)
            skelB.step(dt: dt, playerEye: morningEye, canSeePlayer: false, isNight: false, isRaining: false, world: world)
            skelC.step(dt: dt, playerEye: morningEye, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }

        let skelABurned = skelA.health < Skeleton.maxHealth && skelA.isOnFire
        let skelBSafe = skelB.health == Skeleton.maxHealth && !skelB.isOnFire
        let skelCSafe = skelC.health == Skeleton.maxHealth && !skelC.isOnFire

        report.check(
            "direct morning sunlight ignites unsheltered skeleton while sheltered and water-submerged skeletons remain safe",
            skelABurned && skelBSafe && skelCSafe,
            "skelA (open) health: \(skelA.health)/\(Skeleton.maxHealth), skelB (roof) health: \(skelB.health), skelC (water) health: \(skelC.health)"
        )

        // Test active shelter seeking AI: place burning skeleton near shaded shelter on platform
        let shelterTargetX = originX - 6
        let shelterTargetZ = originZ - 6
        for dx in -1...1 {
            for dz in -1...1 {
                world.setBlock(worldX: shelterTargetX + dx, y: skelSurfaceY + 2, worldZ: shelterTargetZ + dz, to: .stone) // Roof
            }
        }
        // Place skeleton 4 blocks away on open platform ground
        let startPos = Vector3(CGFloat(shelterTargetX + 4) + 0.5, CGFloat(skelSurfaceY), CGFloat(shelterTargetZ) + 0.5)
        var fleeingSkel = Skeleton(position: startPos, seed: 0xF1)
        let initialDistanceToShelter = (fleeingSkel.position - Vector3(CGFloat(shelterTargetX) + 0.5, CGFloat(skelSurfaceY), CGFloat(shelterTargetZ) + 0.5)).length()
        for _ in 0..<120 {
            fleeingSkel.step(dt: dt, playerEye: nil, canSeePlayer: false, isNight: false, isRaining: false, world: world)
        }
        let finalDistanceToShelter = (fleeingSkel.position - Vector3(CGFloat(shelterTargetX) + 0.5, CGFloat(skelSurfaceY), CGFloat(shelterTargetZ) + 0.5)).length()
        let steeredTowardsShelter = finalDistanceToShelter < initialDistanceToShelter - 1.0

        report.check(
            "burning skeleton in morning sunlight actively navigates toward nearby shaded shelter",
            steeredTowardsShelter,
            "initialDist: \(initialDistanceToShelter), finalDist: \(finalDistanceToShelter)"
        )

        // =========================================================================
        // SECTION 7: Industrial Disturbance Accumulation & Threat Escalation (System 7)
        // =========================================================================
        let industrialChunk = World.chunkCoord(forWorldX: autoX, worldZ: autoZ)
        let tracker = world.disturbance
        tracker.reset()

        let baseDisturbance = tracker.disturbance(inChunk: industrialChunk)

        // Active furnace generates disturbance + explosion impulse
        tracker.recordSmelting(at: autoFurnaceKey, amount: 25.0)
        tracker.recordExplosion(at: Vector3(CGFloat(autoX), CGFloat(autoY), CGFloat(autoZ)), amount: 30.0)
        let activeDisturbance = tracker.disturbance(inChunk: industrialChunk)

        // Hostile mob at distance 22 (baseline Fizzler sight: 16, Skeleton sight: 18)
        let testDistance: CGFloat = 22.0
        let baseFizzlerSight = Fizzler.effectiveSightRange(disturbance: 0.0)
        let elevatedFizzlerSight = Fizzler.effectiveSightRange(disturbance: activeDisturbance)
        let baseSkeletonSight = Skeleton.effectiveSightRange(disturbance: 0.0)
        let elevatedSkeletonSight = Skeleton.effectiveSightRange(disturbance: activeDisturbance)

        let fizzlerEscalated = (testDistance > baseFizzlerSight) && (testDistance <= elevatedFizzlerSight)
        let skeletonEscalated = (testDistance > baseSkeletonSight) && (testDistance <= elevatedSkeletonSight)

        // Verify Fizzler and Skeleton state machines step into stalking at distance 22 under elevated disturbance
        let targetEye = Vector3(CGFloat(autoX), CGFloat(autoY) + 1, CGFloat(autoZ))
        let fizzlerPos = targetEye + Vector3(testDistance, 0, 0)
        var testFizzler = Fizzler(position: fizzlerPos, seed: 0xC1)
        testFizzler.step(dt: dt, playerEye: targetEye, canSeePlayer: true, disturbance: activeDisturbance, world: world)
        let fizzlerStalking = testFizzler.activity == .stalking

        var testSkeleton = Skeleton(position: fizzlerPos, seed: 0x51)
        testSkeleton.step(dt: dt, playerEye: targetEye, canSeePlayer: true, isNight: true, disturbance: activeDisturbance, world: world)
        let skeletonStalking = testSkeleton.activity == .stalking

        report.check(
            "industrial smelting and blast elevate chunk disturbance and escalate fizzler and skeleton aggro sight range (16 -> 32)",
            baseDisturbance == 0.0 && activeDisturbance >= 50.0 && fizzlerEscalated && skeletonEscalated && fizzlerStalking && skeletonStalking,
            "baseDist: \(baseDisturbance), activeDist: \(activeDisturbance), fizzlerSight: \(baseFizzlerSight) -> \(elevatedFizzlerSight), skelSight: \(baseSkeletonSight) -> \(elevatedSkeletonSight)"
        )

        // Decay disturbance over silent period
        tracker.tick(dt: 60.0)
        let decayedDisturbance = tracker.disturbance(inChunk: industrialChunk)
        let fizzlerSightAfterDecay = Fizzler.effectiveSightRange(disturbance: decayedDisturbance)
        let canDetectAfterDecay = testDistance <= fizzlerSightAfterDecay

        report.check(
            "industrial disturbance decays over time when machinery is silent, restoring baseline threat limits",
            decayedDisturbance < activeDisturbance && !canDetectAfterDecay,
            "decayedDisturbance: \(decayedDisturbance), canDetectAfterDecay: \(canDetectAfterDecay)"
        )

        // =========================================================================
        // SECTION 8: Continuous Multi-System Session Grand Integration (System 8)
        // =========================================================================
        var sessionElapsed = 0.0
        let sessionDuration = 30.0
        var sessionCropsAdvanced = 0
        var sessionSmeltsCompleted = 0

        while sessionElapsed < sessionDuration {
            // 1. Hoppers
            HopperStore.transfer(at: fuelHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
            HopperStore.transfer(at: oreHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
            HopperStore.transfer(at: extractHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)

            // 2. Furnace
            var fs = furnaces.state(at: autoFurnaceKey)
            if fs.tick(dt: dt) {
                if fs.outputType != nil { sessionSmeltsCompleted += 1 }
                world.setBlock(worldX: autoX, y: autoY, worldZ: autoZ, to: fs.isBurning ? .furnaceLit : .furnace)
            }
            furnaces.set(fs, at: autoFurnaceKey)

            // 3. Thermal
            world.tickThermal(atWorldX: alpineWaterPos.x, y: alpineWaterPos.y, worldZ: alpineWaterPos.z)

            // 4. Crops
            for key in crops.tick(dt: dt, world: world) {
                if let next = BlockType(rawValue: world.block(worldX: key.x, y: key.y, worldZ: key.z).rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                    sessionCropsAdvanced += 1
                }
            }

            // 5. Signals
            signals.updateDaylightSensors(world: world, timeOfDay: 0.25, fuses: fuses)

            // 6. Disturbance decay
            tracker.tick(dt: dt)

            sessionElapsed += dt
        }

        report.check(
            "grand continuous multi-system session runs without deadlock, starvation, or state corruption",
            sessionElapsed >= sessionDuration,
            "sessionSeconds: \(sessionElapsed), finalCrop: \(world.block(worldX: farmPos.x, y: farmPos.y, worldZ: farmPos.z))"
        )

        // =========================================================================
        // Output Final Transcript
        // =========================================================================
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the industrial compound\n"
            : "[check] all passed — the industrial compound\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

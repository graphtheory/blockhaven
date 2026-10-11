import Foundation

/// Headless verification proof of Milestone 3: Horizontal Pipeline Logistics & Lava Fuel.
///
/// Validates:
/// 1. Horizontal hopper transfer between adjacent hoppers in a conveyor pipeline.
/// 2. Bidirectional container transfer: chest into hopper (pull) and hopper into chest (push).
/// 3. Signal inhibition: powering a hopper with signal locks it, preventing pushing and pulling.
/// 4. Lava bucket in furnace: accepts lava bucket as super-fuel (100 smelts / 300.0s),
///    smelts ore, and leaves an empty ItemType.bucket in the fuel slot.
///
/// Run via `BLOCKHAVEN_CHECK_CONVEYOR=1`. Exits nonzero on failure.
enum ConveyorCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_CONVEYOR"] != nil
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
        let originY = 60

        let chests = ChestStore()
        let furnaces = FurnaceStore()
        let hoppers = HopperStore()
        var minecarts = MinecartManager()
        let signals = SignalNetwork()

        // Helper to perform a full hopper network transfer step
        func stepHoppers() {
            for key in Array(hoppers.cooldown.keys) {
                guard !signals.isPowered(at: SignalNetwork.Key(key.x, key.y, key.z)) else { continue }
                HopperStore.transfer(at: key, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
            }
        }

        // =========================================================================
        // MARK: - Test 1: Horizontal Hopper Conveyor Pipeline
        // =========================================================================
        let pipeStartX = originX
        let pipeY = originY
        let pipeZ = originZ

        // Source chest at (pipeStartX, pipeY + 1, pipeZ)
        world.setBlock(worldX: pipeStartX, y: pipeY + 1, worldZ: pipeZ, to: .chest)
        let srcChestKey = ChestStore.Key(pipeStartX, pipeY + 1, pipeZ)
        chests.chest(at: srcChestKey)[0] = ItemStack(.ironIngot, count: 5)

        // 3 consecutive hoppers along +X direction
        for i in 0..<3 {
            let hx = pipeStartX + i
            world.setBlock(worldX: hx, y: pipeY, worldZ: pipeZ, to: .hopper)
            let hKey = HopperStore.Key(hx, pipeY, pipeZ)
            hoppers.hopperPlaced(at: hKey)
            hoppers.setFacing(.east, at: hKey)
        }

        // Destination chest at (pipeStartX + 3, pipeY, pipeZ)
        let dstChestX = pipeStartX + 3
        world.setBlock(worldX: dstChestX, y: pipeY, worldZ: pipeZ, to: .chest)
        let dstChestKey = ChestStore.Key(dstChestX, pipeY, pipeZ)

        // Advance pipeline cycles until items flow through to destination
        for _ in 0..<20 {
            stepHoppers()
        }

        let srcEmpty = chests.existing(at: srcChestKey)?.isEmpty == true
        let dstReceived = chests.existing(at: dstChestKey)?.contents.first?.type == .ironIngot
            && chests.existing(at: dstChestKey)?.contents.first?.count == 5

        report.check(
            "horizontal hopper conveyor pipeline transfers items between adjacent hoppers into destination chest",
            srcEmpty && dstReceived,
            "src empty: \(srcEmpty), dst contents: \(String(describing: chests.existing(at: dstChestKey)?.contents.first))"
        )

        // =========================================================================
        // MARK: - Test 2: Hopper Into Chest and Chest Into Hopper
        // =========================================================================
        let bidiX = originX + 10
        let bidiZ = originZ

        // 2a. Chest into Hopper (Pull)
        world.setBlock(worldX: bidiX, y: originY + 1, worldZ: bidiZ, to: .chest)
        world.setBlock(worldX: bidiX, y: originY, worldZ: bidiZ, to: .hopper)
        let bidiChestKey = ChestStore.Key(bidiX, originY + 1, bidiZ)
        let bidiHopperKey = HopperStore.Key(bidiX, originY, bidiZ)
        chests.chest(at: bidiChestKey)[0] = ItemStack(.diamond, count: 3)
        hoppers.hopperPlaced(at: bidiHopperKey)

        HopperStore.transfer(at: bidiHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)

        let pulledToHopper = chests.existing(at: bidiChestKey)?[0]?.count == 2
            && hoppers.item(at: bidiHopperKey)?.type == .diamond
            && hoppers.item(at: bidiHopperKey)?.count == 1

        report.check(
            "hopper pulls item from chest into its internal buffer",
            pulledToHopper,
            "chest count: \(chests.existing(at: bidiChestKey)?[0]?.count ?? -1), hopper item: \(String(describing: hoppers.item(at: bidiHopperKey)))"
        )

        // 2b. Hopper into Chest (Push horizontally)
        let pushHopperX = originX + 14
        world.setBlock(worldX: pushHopperX, y: originY, worldZ: bidiZ, to: .hopper)
        world.setBlock(worldX: pushHopperX + 1, y: originY, worldZ: bidiZ, to: .chest)
        let pushHopperKey = HopperStore.Key(pushHopperX, originY, bidiZ)
        let pushChestKey = ChestStore.Key(pushHopperX + 1, originY, bidiZ)
        hoppers.hopperPlaced(at: pushHopperKey)
        hoppers.setFacing(.east, at: pushHopperKey)
        hoppers.setItem(ItemStack(.goldIngot, count: 1), at: pushHopperKey)

        HopperStore.transfer(at: pushHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)

        let pushedToChest = hoppers.item(at: pushHopperKey) == nil
            && chests.existing(at: pushChestKey)?.contents.first?.type == .goldIngot
            && chests.existing(at: pushChestKey)?.contents.first?.count == 1

        report.check(
            "hopper pushes item horizontally from its buffer into an adjacent chest",
            pushedToChest,
            "hopper item: \(String(describing: hoppers.item(at: pushHopperKey))), chest contents: \(String(describing: chests.existing(at: pushChestKey)?.contents.first))"
        )

        // =========================================================================
        // MARK: - Test 3: Signal Inhibition
        // =========================================================================
        let redX = originX + 18
        let redZ = originZ

        world.setBlock(worldX: redX, y: originY + 1, worldZ: redZ, to: .chest)
        world.setBlock(worldX: redX, y: originY, worldZ: redZ, to: .hopper)
        world.setBlock(worldX: redX, y: originY - 1, worldZ: redZ, to: .chest)

        let redSrcKey = ChestStore.Key(redX, originY + 1, redZ)
        let redHopperKey = HopperStore.Key(redX, originY, redZ)
        let redDstKey = ChestStore.Key(redX, originY - 1, redZ)

        chests.chest(at: redSrcKey)[0] = ItemStack(.wire, count: 10)
        hoppers.hopperPlaced(at: redHopperKey)

        // 3a. Power the hopper via signal wire
        world.setBlock(worldX: redX + 1, y: originY, worldZ: redZ, to: .wireOff)
        world.setBlock(worldX: redX + 2, y: originY, worldZ: redZ, to: .leverOn)
        let leverKey = SignalNetwork.Key(redX + 2, originY, redZ)
        let fuses = FuseManager()
        signals.leverPlaced(at: leverKey)
        signals.recompute(world: world, fuses: fuses)

        let isHopperPowered = signals.isPowered(at: SignalNetwork.Key(redX, originY, redZ))

        // Attempt 5 transfer cycles while powered
        for _ in 0..<5 {
            stepHoppers()
        }

        let transferInhibited = chests.existing(at: redSrcKey)?[0]?.count == 10
            && chests.existing(at: redDstKey)?.isEmpty != false

        report.check(
            "signal power inhibits hopper transfer, locking items in place",
            isHopperPowered && transferInhibited,
            "powered: \(isHopperPowered), src count: \(chests.existing(at: redSrcKey)?[0]?.count ?? -1), dst empty: \(chests.existing(at: redDstKey)?.isEmpty != false)"
        )

        // 3b. Unpower signal wire and verify flow resumes
        world.setBlock(worldX: redX + 2, y: originY, worldZ: redZ, to: .leverOff)
        signals.recompute(world: world, fuses: fuses)

        let isHopperUnpowered = !signals.isPowered(at: SignalNetwork.Key(redX, originY, redZ))

        for _ in 0..<3 {
            stepHoppers()
        }

        let transferResumed = (chests.existing(at: redSrcKey)?[0]?.count ?? 10) < 10
            && (chests.existing(at: redDstKey)?.contents.first?.count ?? 0) > 0

        report.check(
            "cutting signal power releases hopper inhibition and resumes conveyor flow",
            isHopperUnpowered && transferResumed,
            "unpowered: \(isHopperUnpowered), src count: \(chests.existing(at: redSrcKey)?[0]?.count ?? -1), dst count: \(chests.existing(at: redDstKey)?.contents.first?.count ?? 0)"
        )

        // =========================================================================
        // MARK: - Test 4: Lava Bucket in Furnace as Super-Fuel
        // =========================================================================
        let fX = originX + 24
        let fZ = originZ
        world.setBlock(worldX: fX, y: originY, worldZ: fZ, to: .furnace)

        var furnaceState = FurnaceState()
        furnaceState.oreType = .rawIron
        furnaceState.oreCount = 5
        furnaceState.fuelType = .lavaBucket
        furnaceState.fuelCount = 1

        let burnDuration = FurnaceRecipe.burnSeconds(for: .lavaBucket) ?? 0
        let expectedBurn = FurnaceRecipe.smeltSeconds * 100 // 300.0s for 100 smelts

        // Ignite the furnace
        _ = furnaceState.tick(dt: 0.1)

        let ignited = furnaceState.isBurning && furnaceState.burnRemaining > 295.0
        let bucketPreserved = furnaceState.fuelType == .bucket && furnaceState.fuelCount == 1

        report.check(
            "furnace accepts lava bucket as super-fuel (100 smelts) and preserves an empty bucket in the fuel slot",
            burnDuration == expectedBurn && ignited && bucketPreserved,
            "burnSeconds: \(burnDuration), isBurning: \(furnaceState.isBurning), burnRemaining: \(furnaceState.burnRemaining), fuelType: \(String(describing: furnaceState.fuelType)), fuelCount: \(furnaceState.fuelCount)"
        )

        // Advance smelting simulation to complete 2 smelts (6.0s)
        for _ in 0..<60 {
            _ = furnaceState.tick(dt: 0.1)
        }

        let smeltsCompleted = furnaceState.outputType == .ironIngot && furnaceState.outputCount == 2
            && furnaceState.oreCount == 3
            && furnaceState.fuelType == .bucket
            && furnaceState.isBurning

        report.check(
            "furnace continues smelting with high remaining burn time while keeping empty bucket in fuel slot",
            smeltsCompleted,
            "output: \(String(describing: furnaceState.outputType))×\(furnaceState.outputCount), ore left: \(furnaceState.oreCount), fuel: \(String(describing: furnaceState.fuelType)), burnRemaining: \(furnaceState.burnRemaining)"
        )

        // =========================================================================
        // MARK: - Test 5: Empty Bucket Extraction & Continuous Automation Chaining
        // =========================================================================
        let autoX = originX + 30
        let autoY = originY
        let autoZ = originZ

        world.setBlock(worldX: autoX, y: autoY, worldZ: autoZ, to: .furnace)
        let autoFurnaceKey = FurnaceStore.Key(autoX, autoY, autoZ)

        // Side Fuel Hopper (x-1, y) facing East
        let autoFuelHopperX = autoX - 1
        world.setBlock(worldX: autoFuelHopperX, y: autoY, worldZ: autoZ, to: .hopper)
        let autoFuelHopperKey = HopperStore.Key(autoFuelHopperX, autoY, autoZ)
        hoppers.hopperPlaced(at: autoFuelHopperKey, facing: .east)
        hoppers.setItem(ItemStack(.lavaBucket, count: 2), at: autoFuelHopperKey)

        // Top Ore Hopper (x, y+1) facing Down
        let autoOreHopperY = autoY + 1
        world.setBlock(worldX: autoX, y: autoOreHopperY, worldZ: autoZ, to: .hopper)
        let autoOreHopperKey = HopperStore.Key(autoX, autoOreHopperY, autoZ)
        hoppers.hopperPlaced(at: autoOreHopperKey, facing: nil)
        hoppers.setItem(ItemStack(.rawIron, count: 10), at: autoOreHopperKey)

        // Bottom Extraction Hopper (x, y-1) facing Down
        let autoExtractHopperY = autoY - 1
        world.setBlock(worldX: autoX, y: autoExtractHopperY, worldZ: autoZ, to: .hopper)
        let autoExtractHopperKey = HopperStore.Key(autoX, autoExtractHopperY, autoZ)
        hoppers.hopperPlaced(at: autoExtractHopperKey, facing: nil)

        // Destination Chest (x, y-2)
        let autoDstChestY = autoY - 2
        world.setBlock(worldX: autoX, y: autoDstChestY, worldZ: autoZ, to: .chest)
        let autoDstChestKey = ChestStore.Key(autoX, autoDstChestY, autoZ)

        // 5a. Feed initial ore and initial lava bucket
        HopperStore.transfer(at: autoFuelHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
        HopperStore.transfer(at: autoOreHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)

        var fState = furnaces.state(at: autoFurnaceKey)
        let initialFed = fState.fuelType == .lavaBucket && fState.fuelCount == 1
            && fState.oreType == .rawIron && fState.oreCount == 1

        // 5b. Ignite first lava bucket
        _ = fState.tick(dt: 0.1)
        furnaces.set(fState, at: autoFurnaceKey)

        let firstIgnited = fState.isBurning && fState.fuelType == .bucket && fState.fuelCount == 1

        // 5c. Complete 1 smelt (30 ticks of dt=0.1) to produce iron ingot in output slot
        for _ in 0..<30 {
            _ = fState.tick(dt: 0.1)
        }
        furnaces.set(fState, at: autoFurnaceKey)
        let hasOutputAndBucket = fState.outputType == .ironIngot && fState.fuelType == .bucket

        // 5d. Extraction hopper tick 1: must prioritize output ingot over fuel bucket
        HopperStore.transfer(at: autoExtractHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
        let stateAfterFirstExtract = furnaces.state(at: autoFurnaceKey)
        let ingotExtractedFirst = stateAfterFirstExtract.outputType == nil
            && stateAfterFirstExtract.fuelType == .bucket

        // 5e. Extraction hopper tick 2: output is now empty, must pull empty bucket from fuel slot
        HopperStore.transfer(at: autoExtractHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
        let stateAfterSecondExtract = furnaces.state(at: autoFurnaceKey)
        let bucketExtracted = stateAfterSecondExtract.fuelType == nil
            && (hoppers.item(at: autoExtractHopperKey)?.type == .bucket || (chests.existing(at: autoDstChestKey)?.contents.contains(where: { $0.type == .bucket }) ?? false))

        // 5f. Subsequent lava bucket is fed into cleared fuel slot, and next ore is fed
        HopperStore.transfer(at: autoFuelHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
        HopperStore.transfer(at: autoOreHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
        let stateAfterSecondFuel = furnaces.state(at: autoFurnaceKey)
        let secondLavaBucketFed = stateAfterSecondFuel.fuelType == .lavaBucket && stateAfterSecondFuel.fuelCount == 1
        let secondOreFed = stateAfterSecondFuel.oreType == .rawIron && stateAfterSecondFuel.oreCount == 1

        // 5g. Advance furnace until first burn finishes, then tick to verify second lava bucket ignites
        var continuousFurnace = furnaces.state(at: autoFurnaceKey)
        continuousFurnace.burnRemaining = 0.05
        _ = continuousFurnace.tick(dt: 0.1) // burn expires, isBurning becomes false
        let firstBurnExpired = !continuousFurnace.isBurning && continuousFurnace.fuelType == .lavaBucket

        _ = continuousFurnace.tick(dt: 0.1) // ignites second lava bucket
        let secondIgnited = continuousFurnace.isBurning
            && continuousFurnace.fuelType == .bucket
            && continuousFurnace.burnRemaining > 295.0
        furnaces.set(continuousFurnace, at: autoFurnaceKey)

        report.check(
            "hopper below furnace extracts empty bucket from fuel slot and feeding subsequent lava bucket refuels and reignites furnace",
            initialFed && firstIgnited && hasOutputAndBucket && ingotExtractedFirst && bucketExtracted && secondLavaBucketFed && secondOreFed && firstBurnExpired && secondIgnited,
            "ingotExtractedFirst: \(ingotExtractedFirst), bucketExtracted: \(bucketExtracted), secondFed: \(secondLavaBucketFed), secondIgnited: \(secondIgnited)"
        )

        // =========================================================================
        // Output Final Transcript
        // =========================================================================
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — conveyor logistics & lava fuel\n"
            : "[check] all passed — conveyor logistics & lava fuel\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

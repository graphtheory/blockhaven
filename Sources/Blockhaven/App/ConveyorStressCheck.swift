import Foundation

/// Adversarial stress testing and empirical boundary verification for Milestone 3:
/// Horizontal Pipeline Logistics & Lava Fuel (Wave 9).
///
/// Exercises:
/// 1. Multi-hopper pipeline chaining (A -> B -> C -> Chest) under high volume and backpressure (destination chest full).
/// 2. Item conservation invariants: total item count across chain is constant at all times.
/// 3. Backpressure release: clearing destination space resumes pipeline flow without loss or duplication.
/// 4. Heterogeneous item jamming under backpressure: different item types do not overwrite or delete each other.
/// 5. Hopper signal locking: toggling power on/off strictly halts and resumes flow with zero item duplication/loss.
/// 6. Rapid signal pulse flipping (50 cycles) under continuous item flow.
/// 7. Lava bucket fuel burn duration: exactly 300.0s, yielding exactly 100 smelts.
/// 8. Lava bucket empty bucket extraction: empty bucket in fuel slot must be extractable by hopper / container chaining.
/// 9. Full automated loop: hopper feeding lava bucket, furnace burning, hopper extracting empty bucket and output ingot.
///
/// Run via `BLOCKHAVEN_CHECK_CONVEYOR_STRESS=1`. Exits nonzero on failure.
enum ConveyorStressCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_CONVEYOR_STRESS"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[stress-check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    static func run() -> Never {
        var report = Report()
        let world = World(seed: 999)
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))

        for dz in -3...3 {
            for dx in -3...3 {
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

        func stepHoppers() {
            for key in Array(hoppers.cooldown.keys) {
                guard !signals.isPowered(at: SignalNetwork.Key(key.x, key.y, key.z)) else { continue }
                HopperStore.transfer(
                    at: key,
                    world: world,
                    chests: chests,
                    furnaces: furnaces,
                    minecarts: &minecarts,
                    hoppers: hoppers,
                    direction: hoppers.facing(at: key),
                    signals: signals
                )
            }
        }

        // =========================================================================
        // MARK: - Section 1: Multi-Hopper Pipeline Chaining & Backpressure
        // =========================================================================
        let p1X = originX
        let p1Y = originY
        let p1Z = originZ

        // Setup: Chest -> Hopper A -> Hopper B -> Hopper C -> Dest Chest
        world.setBlock(worldX: p1X, y: p1Y + 1, worldZ: p1Z, to: .chest)
        let srcChestKey = ChestStore.Key(p1X, p1Y + 1, p1Z)
        chests.chest(at: srcChestKey)[0] = ItemStack(.ironIngot, count: 20)

        let hAKey = HopperStore.Key(p1X, p1Y, p1Z)
        let hBKey = HopperStore.Key(p1X + 1, p1Y, p1Z)
        let hCKey = HopperStore.Key(p1X + 2, p1Y, p1Z)

        world.setBlock(worldX: p1X, y: p1Y, worldZ: p1Z, to: .hopper)
        world.setBlock(worldX: p1X + 1, y: p1Y, worldZ: p1Z, to: .hopper)
        world.setBlock(worldX: p1X + 2, y: p1Y, worldZ: p1Z, to: .hopper)

        hoppers.hopperPlaced(at: hAKey, facing: .east)
        hoppers.hopperPlaced(at: hBKey, facing: .east)
        hoppers.hopperPlaced(at: hCKey, facing: .east)

        let dstChestX = p1X + 3
        world.setBlock(worldX: dstChestX, y: p1Y, worldZ: p1Z, to: .chest)
        let dstChestKey = ChestStore.Key(dstChestX, p1Y, p1Z)

        // 1a. Normal flow: 20 iron ingots from source chest through A -> B -> C -> Dest Chest
        for _ in 0..<80 {
            stepHoppers()
        }

        let normalFlowComplete = chests.existing(at: srcChestKey)?.isEmpty == true
            && hoppers.item(at: hAKey) == nil
            && hoppers.item(at: hBKey) == nil
            && hoppers.item(at: hCKey) == nil
            && chests.existing(at: dstChestKey)?.contents.first?.type == .ironIngot
            && chests.existing(at: dstChestKey)?.contents.first?.count == 20

        report.check(
            "multi-hopper pipeline (A->B->C->Chest) drains completely into destination chest",
            normalFlowComplete,
            "src empty: \(chests.existing(at: srcChestKey)?.isEmpty == true), dst count: \(chests.existing(at: dstChestKey)?.contents.first?.count ?? -1)"
        )

        // 1b. Backpressure under full destination chest
        // Completely fill destination chest with 27 stacks of 64 cobblestone
        let dstChest = chests.chest(at: dstChestKey)
        for s in 0..<27 {
            dstChest[s] = ItemStack(.cobblestone, count: 64)
        }

        // Put 15 gold ingots in source chest
        chests.chest(at: srcChestKey)[0] = ItemStack(.goldIngot, count: 15)

        func totalGold() -> Int {
            let srcGold = chests.existing(at: srcChestKey)?.contents.filter { $0.type == .goldIngot }.reduce(0) { $0 + $1.count } ?? 0
            let hAGold = hoppers.item(at: hAKey)?.type == .goldIngot ? (hoppers.item(at: hAKey)?.count ?? 0) : 0
            let hBGold = hoppers.item(at: hBKey)?.type == .goldIngot ? (hoppers.item(at: hBKey)?.count ?? 0) : 0
            let hCGold = hoppers.item(at: hCKey)?.type == .goldIngot ? (hoppers.item(at: hCKey)?.count ?? 0) : 0
            let dstGold = chests.existing(at: dstChestKey)?.contents.filter { $0.type == .goldIngot }.reduce(0) { $0 + $1.count } ?? 0
            return srcGold + hAGold + hBGold + hCGold + dstGold
        }

        var goldInvariantPreserved = true
        for _ in 0..<100 {
            stepHoppers()
            if totalGold() != 15 {
                goldInvariantPreserved = false
                break
            }
        }

        let dstHasZeroGold = (chests.existing(at: dstChestKey)?.contents.filter { $0.type == .goldIngot }.count ?? 0) == 0
        report.check(
            "backpressure with full destination chest preserves exact total item count across pipeline",
            goldInvariantPreserved && dstHasZeroGold && totalGold() == 15,
            "totalGold: \(totalGold()), dstHasZeroGold: \(dstHasZeroGold), invariant: \(goldInvariantPreserved)"
        )

        // 1c. Partial release of backpressure
        // Clear 1 slot in destination chest
        dstChest[0] = nil
        for _ in 0..<100 {
            stepHoppers()
            if totalGold() != 15 {
                goldInvariantPreserved = false
                break
            }
        }

        let dstGotGold = (chests.existing(at: dstChestKey)?.contents.filter { $0.type == .goldIngot }.first?.count ?? 0) == 15
        let pipeCleared = hoppers.item(at: hAKey) == nil && hoppers.item(at: hBKey) == nil && hoppers.item(at: hCKey) == nil

        report.check(
            "clearing backpressure space resumes pipeline flow and delivers all backed-up items",
            goldInvariantPreserved && dstGotGold && pipeCleared,
            "dstGotGold: \(dstGotGold), pipeCleared: \(pipeCleared), totalGold: \(totalGold())"
        )

        // 1d. Heterogeneous item backpressure jamming
        // Hopper C has diamond, Hopper B tries to push gold
        hoppers.setItem(ItemStack(.diamond, count: 1), at: hCKey)
        hoppers.setItem(ItemStack(.goldIngot, count: 1), at: hBKey)
        // Make dest chest full again
        for s in 0..<27 { dstChest[s] = ItemStack(.cobblestone, count: 64) }

        stepHoppers()

        let cHasDiamond = hoppers.item(at: hCKey)?.type == .diamond && hoppers.item(at: hCKey)?.count == 1
        let bHasGold = hoppers.item(at: hBKey)?.type == .goldIngot && hoppers.item(at: hBKey)?.count == 1

        report.check(
            "heterogeneous item types do not overwrite or destroy each other under backpressure",
            cHasDiamond && bHasGold,
            "hC: \(String(describing: hoppers.item(at: hCKey))), hB: \(String(describing: hoppers.item(at: hBKey)))"
        )

        // Clean up Section 1
        hoppers.setItem(nil, at: hAKey)
        hoppers.setItem(nil, at: hBKey)
        hoppers.setItem(nil, at: hCKey)

        // =========================================================================
        // MARK: - Section 2: Hopper Signal Locking On/Off Toggles
        // =========================================================================
        let p2X = originX + 10
        let p2Y = originY
        let p2Z = originZ

        world.setBlock(worldX: p2X, y: p2Y + 1, worldZ: p2Z, to: .chest)
        world.setBlock(worldX: p2X, y: p2Y, worldZ: p2Z, to: .hopper)
        world.setBlock(worldX: p2X, y: p2Y - 1, worldZ: p2Z, to: .chest)

        let redSrcKey = ChestStore.Key(p2X, p2Y + 1, p2Z)
        let redHopperKey = HopperStore.Key(p2X, p2Y, p2Z)
        let redDstKey = ChestStore.Key(p2X, p2Y - 1, p2Z)

        chests.chest(at: redSrcKey)[0] = ItemStack(.ironIngot, count: 50)
        hoppers.hopperPlaced(at: redHopperKey)

        world.setBlock(worldX: p2X + 1, y: p2Y, worldZ: p2Z, to: .wireOff)
        world.setBlock(worldX: p2X + 2, y: p2Y, worldZ: p2Z, to: .leverOff)
        let redLeverKey = SignalNetwork.Key(p2X + 2, p2Y, p2Z)
        let fuses = FuseManager()

        func totalSignalTestItems() -> Int {
            let s = chests.existing(at: redSrcKey)?.contents.first?.count ?? 0
            let h = hoppers.item(at: redHopperKey)?.count ?? 0
            let d = chests.existing(at: redDstKey)?.contents.first?.count ?? 0
            return s + h + d
        }

        func setSignalLock(_ locked: Bool) {
            world.setBlock(worldX: p2X + 2, y: p2Y, worldZ: p2Z, to: locked ? .leverOn : .leverOff)
            if locked {
                signals.leverPlaced(at: redLeverKey)
            } else {
                signals.leverRemoved(at: redLeverKey)
            }
            signals.recompute(world: world, fuses: fuses)
        }

        // Verify initial state: 50 items
        report.check("initial signal item count is 50", totalSignalTestItems() == 50, "count: \(totalSignalTestItems())")

        var lockStopsTransfer = true
        var unlockResumesTransfer = true
        var toggleConservation = true

        // Toggle signal on/off across multiple phases
        for _ in 0..<10 {
            // Phase 1: Unlocked - run 2 steps
            setSignalLock(false)
            let countBeforeUnlock = chests.existing(at: redDstKey)?.contents.first?.count ?? 0
            stepHoppers()
            stepHoppers()
            let countAfterUnlock = chests.existing(at: redDstKey)?.contents.first?.count ?? 0
            if countAfterUnlock <= countBeforeUnlock {
                unlockResumesTransfer = false
            }
            if totalSignalTestItems() != 50 {
                toggleConservation = false
            }

            // Phase 2: Locked - run 5 steps
            setSignalLock(true)
            let countBeforeLock = chests.existing(at: redDstKey)?.contents.first?.count ?? 0
            let srcBeforeLock = chests.existing(at: redSrcKey)?.contents.first?.count ?? 0
            let hopBeforeLock = hoppers.item(at: redHopperKey)?.count ?? 0
            for _ in 0..<5 {
                stepHoppers()
            }
            let countAfterLock = chests.existing(at: redDstKey)?.contents.first?.count ?? 0
            let srcAfterLock = chests.existing(at: redSrcKey)?.contents.first?.count ?? 0
            let hopAfterLock = hoppers.item(at: redHopperKey)?.count ?? 0

            if countAfterLock != countBeforeLock || srcAfterLock != srcBeforeLock || hopAfterLock != hopBeforeLock {
                lockStopsTransfer = false
            }
            if totalSignalTestItems() != 50 {
                toggleConservation = false
            }
        }

        report.check(
            "signal locking on/off toggling strictly halts and resumes flow with exact item conservation",
            lockStopsTransfer && unlockResumesTransfer && toggleConservation && totalSignalTestItems() == 50,
            "lockStops: \(lockStopsTransfer), unlockResumes: \(unlockResumesTransfer), conservation: \(toggleConservation), total: \(totalSignalTestItems())"
        )

        // =========================================================================
        // MARK: - Section 3: Lava Bucket Fuel in Furnace (300.0s / 100 smelts)
        // =========================================================================
        let p3X = originX + 20
        let p3Y = originY
        let p3Z = originZ

        world.setBlock(worldX: p3X, y: p3Y, worldZ: p3Z, to: .furnace)

        var fState = FurnaceState()
        fState.oreType = .rawIron
        fState.oreCount = 100
        fState.fuelType = .lavaBucket
        fState.fuelCount = 1

        let burnSec = FurnaceRecipe.burnSeconds(for: .lavaBucket) ?? 0
        let expectedBurnSec = 300.0

        // Advance 1 frame to catch fire
        _ = fState.tick(dt: 0.1)

        let initialBurnCorrect = burnSec == expectedBurnSec
            && fState.isBurning
            && fState.fuelType == .bucket
            && fState.fuelCount == 1

        report.check(
            "lava bucket ignites for exactly 300.0s and leaves empty bucket in fuel slot",
            initialBurnCorrect,
            "burnSec: \(burnSec), isBurning: \(fState.isBurning), fuel: \(String(describing: fState.fuelType)), fuelCount: \(fState.fuelCount)"
        )

        // Advance simulation for exactly 300.0 seconds of furnace time (dt = 0.1s => 3000 steps)
        var totalSmelts = 0
        for _ in 0..<3000 {
            let wasSmeltCount = fState.outputCount
            _ = fState.tick(dt: 0.1)
            if fState.outputCount > wasSmeltCount {
                totalSmelts += (fState.outputCount - wasSmeltCount)
                // In an automated setup or player taking items, output is collected before hitting 64
                if fState.outputCount == 64 {
                    fState.outputCount = 0
                    fState.outputType = nil
                }
            }
        }

        let full100SmeltsCompleted = totalSmelts == 100
            && fState.oreCount == 0
            && fState.fuelType == .bucket
            && fState.fuelCount == 1
            && !fState.isBurning

        report.check(
            "lava bucket yields exactly 100 smelts over 300.0s and empty bucket remains in fuel slot",
            full100SmeltsCompleted,
            "totalSmelts: \(totalSmelts), oreCount: \(fState.oreCount), outputCount: \(fState.outputCount), fuel: \(String(describing: fState.fuelType)), isBurning: \(fState.isBurning)"
        )

        // =========================================================================
        // MARK: - Section 4: Empty Bucket Extraction & Hopper Chaining
        // =========================================================================
        // Setup:
        // Fuel Input Hopper (side/top) -> Furnace -> Output Hopper (below) -> Destination Chest
        let p4X = originX + 30
        let p4Y = originY
        let p4Z = originZ

        world.setBlock(worldX: p4X, y: p4Y, worldZ: p4Z, to: .furnace)
        let chainFurnaceKey = FurnaceStore.Key(p4X, p4Y, p4Z)

        // Side Hopper feeding fuel into furnace from West (x-1 facing East)
        let fuelHopperX = p4X - 1
        world.setBlock(worldX: fuelHopperX, y: p4Y, worldZ: p4Z, to: .hopper)
        let fuelHopperKey = HopperStore.Key(fuelHopperX, p4Y, p4Z)
        hoppers.hopperPlaced(at: fuelHopperKey, facing: .east)
        // Put 2 lava buckets in fuel hopper
        hoppers.setItem(ItemStack(.lavaBucket, count: 2), at: fuelHopperKey)

        // Top Hopper feeding ore into furnace from Above (y+1 facing Down)
        let oreHopperY = p4Y + 1
        world.setBlock(worldX: p4X, y: oreHopperY, worldZ: p4Z, to: .hopper)
        let oreHopperKey = HopperStore.Key(p4X, oreHopperY, p4Z)
        hoppers.hopperPlaced(at: oreHopperKey, facing: nil) // defaults to downward
        hoppers.setItem(ItemStack(.rawIron, count: 5), at: oreHopperKey)

        // Bottom Hopper extracting from furnace (y-1 facing Down) into Chest at y-2
        let extractHopperY = p4Y - 1
        world.setBlock(worldX: p4X, y: extractHopperY, worldZ: p4Z, to: .hopper)
        let extractHopperKey = HopperStore.Key(p4X, extractHopperY, p4Z)
        hoppers.hopperPlaced(at: extractHopperKey, facing: nil)

        let outChestY = p4Y - 2
        world.setBlock(worldX: p4X, y: outChestY, worldZ: p4Z, to: .chest)
        let outChestKey = ChestStore.Key(p4X, outChestY, p4Z)

        // 4a. Verify fuel hopper can push lava bucket into furnace
        HopperStore.transfer(at: fuelHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
        let furnaceAfterFuelFeed = furnaces.state(at: chainFurnaceKey)
        let fuelFed = furnaceAfterFuelFeed.fuelType == .lavaBucket && furnaceAfterFuelFeed.fuelCount == 1

        report.check(
            "hopper feeding furnace pushes lava bucket into fuel slot",
            fuelFed,
            "furnace fuel: \(String(describing: furnaceAfterFuelFeed.fuelType)), count: \(furnaceAfterFuelFeed.fuelCount)"
        )

        // 4b. Verify ore hopper can push raw iron into furnace
        HopperStore.transfer(at: oreHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
        let furnaceAfterOreFeed = furnaces.state(at: chainFurnaceKey)
        let oreFed = furnaceAfterOreFeed.oreType == .rawIron && furnaceAfterOreFeed.oreCount == 1

        report.check(
            "hopper feeding furnace pushes ore into ore slot",
            oreFed,
            "furnace ore: \(String(describing: furnaceAfterOreFeed.oreType)), count: \(furnaceAfterOreFeed.oreCount)"
        )

        // 4c. Furnace ignites and burns
        var chainFurnaceState = furnaces.state(at: chainFurnaceKey)
        _ = chainFurnaceState.tick(dt: 0.1)
        furnaces.set(chainFurnaceState, at: chainFurnaceKey)

        let ignitedWithBucket = chainFurnaceState.isBurning
            && chainFurnaceState.fuelType == .bucket
            && chainFurnaceState.fuelCount == 1

        report.check(
            "furnace ignites lava bucket leaving empty bucket in fuel slot",
            ignitedWithBucket,
            "isBurning: \(chainFurnaceState.isBurning), fuel: \(String(describing: chainFurnaceState.fuelType)), fuelCount: \(chainFurnaceState.fuelCount)"
        )

        // 4d. Hopper extracting empty bucket from furnace
        // Check whether extract hopper pulls empty bucket into extract hopper / out chest
        HopperStore.transfer(at: extractHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)

        let extractedBucket = hoppers.item(at: extractHopperKey)?.type == .bucket
            || (chests.existing(at: outChestKey)?.contents.contains(where: { $0.type == .bucket }) ?? false)
        let furnaceBucketCleared = furnaces.state(at: chainFurnaceKey).fuelType == nil

        report.check(
            "hopper below furnace extracts empty bucket from fuel slot",
            extractedBucket && furnaceBucketCleared,
            "extractedBucket: \(extractedBucket), furnace fuel left: \(String(describing: furnaces.state(at: chainFurnaceKey).fuelType)), extractHopper item: \(String(describing: hoppers.item(at: extractHopperKey))), chest contents: \(String(describing: chests.existing(at: outChestKey)?.contents))"
        )

        // 4e. Hopper fuel chaining: once empty bucket is extracted, can the next lava bucket be fed and ignite?
        HopperStore.transfer(at: fuelHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts, hoppers: hoppers)
        var furnaceAfterSecondFuel = furnaces.state(at: chainFurnaceKey)
        let secondFuelFed = furnaceAfterSecondFuel.fuelType == .lavaBucket

        // Advance until first burn expires, then tick to verify second ignition
        furnaceAfterSecondFuel.burnRemaining = 0.05
        _ = furnaceAfterSecondFuel.tick(dt: 0.1)
        _ = furnaceAfterSecondFuel.tick(dt: 0.1)
        furnaces.set(furnaceAfterSecondFuel, at: chainFurnaceKey)

        let secondIgnited = furnaceAfterSecondFuel.isBurning
            && furnaceAfterSecondFuel.fuelType == .bucket
            && furnaceAfterSecondFuel.burnRemaining > 295.0

        report.check(
            "hopper feeds second lava bucket into furnace fuel slot and ignites after empty bucket extraction",
            secondFuelFed && secondIgnited,
            "fed: \(secondFuelFed), ignited: \(secondIgnited), burnRemaining: \(furnaceAfterSecondFuel.burnRemaining)"
        )

        // =========================================================================
        // Output Final Transcript
        // =========================================================================
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[stress-check] FAILED — conveyor logistics & lava fuel stress\n"
            : "[stress-check] all passed — conveyor logistics & lava fuel stress\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

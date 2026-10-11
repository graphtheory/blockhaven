import Foundation

/// Headless proof of the first thing in this world that moves an item
/// without a hand on it: a hopper pulls one item a tick from a container
/// above it into whatever sits below — chest to chest, furnace output down
/// into a chest, a chest feeding a furnace's ore or fuel slot exactly the
/// way a player's own hand already can, or a minecart's cargo riding a
/// rail through either side of it — and never destroys one when the far
/// end has nowhere to put it.
///
/// `BLOCKHAVEN_CHECK_HOPPER=1`. Exits nonzero if any line fails.
enum HopperCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_HOPPER"] != nil
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
        let world = World()
        let spawn = world.spawnPosition()
        // A margin east, not just the one chunk spawn sits in: the cart
        // tests further down sit past x+16, which can be one chunk over or
        // two depending on where in its own chunk spawn happens to fall.
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dx in 0...2 { world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z)) }
        let origin = (x: Int(spawn.x), y: 60, z: Int(spawn.z))

        // MARK: chest above, chest below — a plain relay

        let chests = ChestStore()
        let furnaces = FurnaceStore()
        var minecarts = MinecartManager()
        let relayX = origin.x
        world.setBlock(worldX: relayX, y: origin.y + 1, worldZ: origin.z, to: .chest)
        world.setBlock(worldX: relayX, y: origin.y, worldZ: origin.z, to: .hopper)
        world.setBlock(worldX: relayX, y: origin.y - 1, worldZ: origin.z, to: .chest)
        let topKey = ChestStore.Key(relayX, origin.y + 1, origin.z)
        let bottomKey = ChestStore.Key(relayX, origin.y - 1, origin.z)
        chests.chest(at: topKey)[0] = ItemStack(.wheat, count: 5)

        let hopperKey = HopperStore.Key(relayX, origin.y, origin.z)
        HopperStore.transfer(at: hopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts)
        report.check(
            "one item moves from the chest above to the chest below",
            chests.existing(at: topKey)?[0]?.count == 4
                && chests.existing(at: bottomKey)?.contents.first?.type == .wheat
                && chests.existing(at: bottomKey)?.contents.first?.count == 1,
            "top: \(String(describing: chests.existing(at: topKey)?[0])), "
                + "bottom: \(String(describing: chests.existing(at: bottomKey)?.contents.first))"
        )

        for _ in 0..<4 {
            HopperStore.transfer(at: hopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts)
        }
        report.check(
            "five ticks empty a five-item stack exactly, not more",
            chests.existing(at: topKey)?.isEmpty == true && chests.existing(at: bottomKey)?.contents.first?.count == 5,
            "top empty: \(chests.existing(at: topKey)?.isEmpty == true), "
                + "bottom count: \(chests.existing(at: bottomKey)?.contents.first?.count ?? -1)"
        )

        HopperStore.transfer(at: hopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts)
        report.check(
            "and nothing moves once the source is empty",
            chests.existing(at: bottomKey)?.contents.first?.count == 5,
            "bottom count after an extra tick: \(chests.existing(at: bottomKey)?.contents.first?.count ?? -1)"
        )

        // MARK: chest above, furnace below — feeds ore and fuel by itself

        let feedX = origin.x + 4
        world.setBlock(worldX: feedX, y: origin.y + 1, worldZ: origin.z, to: .chest)
        world.setBlock(worldX: feedX, y: origin.y, worldZ: origin.z, to: .hopper)
        world.setBlock(worldX: feedX, y: origin.y - 1, worldZ: origin.z, to: .furnace)
        let feedChestKey = ChestStore.Key(feedX, origin.y + 1, origin.z)
        let feedFurnaceKey = FurnaceStore.Key(feedX, origin.y - 1, origin.z)
        let feedHopperKey = HopperStore.Key(feedX, origin.y, origin.z)
        chests.chest(at: feedChestKey)[0] = ItemStack(.rawIron, count: 2)
        chests.chest(at: feedChestKey)[1] = ItemStack(.coal, count: 2)

        // The hopper always pulls the first stocked slot, so the two ticks
        // that empty slot 0's raw iron land in the ore slot before slot 1's
        // coal is even reached — four ticks, not two, drains both.
        for _ in 0..<4 {
            HopperStore.transfer(at: feedHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts)
        }
        let fed = furnaces.state(at: feedFurnaceKey)
        report.check(
            "a hopper feeds a chest's ore and fuel into a furnace below it",
            fed.oreType == .rawIron && fed.oreCount == 2 && fed.fuelType == .coal && fed.fuelCount == 2,
            "ore \(String(describing: fed.oreType))×\(fed.oreCount), fuel \(String(describing: fed.fuelType))×\(fed.fuelCount)"
        )

        // MARK: furnace above, chest below — collects finished output

        let collectX = origin.x + 8
        world.setBlock(worldX: collectX, y: origin.y + 1, worldZ: origin.z, to: .furnace)
        world.setBlock(worldX: collectX, y: origin.y, worldZ: origin.z, to: .hopper)
        world.setBlock(worldX: collectX, y: origin.y - 1, worldZ: origin.z, to: .chest)
        let collectFurnaceKey = FurnaceStore.Key(collectX, origin.y + 1, origin.z)
        let collectChestKey = ChestStore.Key(collectX, origin.y - 1, origin.z)
        let collectHopperKey = HopperStore.Key(collectX, origin.y, origin.z)
        var finished = FurnaceState()
        finished.outputType = .ironIngot
        finished.outputCount = 3
        furnaces.set(finished, at: collectFurnaceKey)

        HopperStore.transfer(at: collectHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts)
        report.check(
            "a hopper collects a furnace's output into the chest below it",
            furnaces.state(at: collectFurnaceKey).outputCount == 2
                && chests.existing(at: collectChestKey)?.contents.first?.type == .ironIngot,
            "furnace output left: \(furnaces.state(at: collectFurnaceKey).outputCount), "
                + "chest: \(String(describing: chests.existing(at: collectChestKey)?.contents.first))"
        )

        // MARK: nowhere to put it — nothing is lost

        let stuckX = origin.x + 12
        world.setBlock(worldX: stuckX, y: origin.y + 1, worldZ: origin.z, to: .chest)
        world.setBlock(worldX: stuckX, y: origin.y, worldZ: origin.z, to: .hopper)
        // Nothing below at all — nowhere for the pulled item to land.
        let stuckChestKey = ChestStore.Key(stuckX, origin.y + 1, origin.z)
        let stuckHopperKey = HopperStore.Key(stuckX, origin.y, origin.z)
        chests.chest(at: stuckChestKey)[0] = ItemStack(.diamond, count: 1)

        HopperStore.transfer(at: stuckHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts)
        report.check(
            "an item with nowhere to go is handed straight back, not lost",
            chests.existing(at: stuckChestKey)?.contents.first?.type == .diamond
                && chests.existing(at: stuckChestKey)?.contents.first?.count == 1,
            "source chest: \(String(describing: chests.existing(at: stuckChestKey)?.contents.first))"
        )

        // MARK: a cart is not a block, but a hopper reads it anyway

        // A hopper under a rail: a cart parked overhead is the "above"
        // side exactly the way a chest would be, and drains into the
        // chest below the hopper — the automatic unloading end of a line.
        let unloadX = origin.x + 16
        world.setBlock(worldX: unloadX, y: origin.y + 1, worldZ: origin.z, to: .railEastWest)
        world.setBlock(worldX: unloadX, y: origin.y, worldZ: origin.z, to: .hopper)
        world.setBlock(worldX: unloadX, y: origin.y - 1, worldZ: origin.z, to: .chest)
        let unloadChestKey = ChestStore.Key(unloadX, origin.y - 1, origin.z)
        let unloadHopperKey = HopperStore.Key(unloadX, origin.y, origin.z)
        guard let parkedID = minecarts.place(at: (unloadX, origin.y + 1, origin.z), in: world) else {
            report.check("a cart can be parked over the unloading hopper", false, "placement failed")
            for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
            exit(1)
        }
        minecarts.setCargo(ItemStack(.rawGold, count: 3), for: parkedID)

        for _ in 0..<3 {
            HopperStore.transfer(at: unloadHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts)
        }
        report.check(
            "a hopper under a parked cart drains its cargo into the chest below",
            minecarts.cart(parkedID)?.cargo == nil
                && chests.existing(at: unloadChestKey)?.contents.first?.type == .rawGold
                && chests.existing(at: unloadChestKey)?.contents.first?.count == 3,
            "cart cargo left: \(String(describing: minecarts.cart(parkedID)?.cargo)), "
                + "chest: \(String(describing: chests.existing(at: unloadChestKey)?.contents.first))"
        )

        // A hopper over a rail: a chest feeding it loads a passing empty
        // cart below — the automatic loading end of the same line.
        let loadX = origin.x + 20
        world.setBlock(worldX: loadX, y: origin.y + 1, worldZ: origin.z, to: .chest)
        world.setBlock(worldX: loadX, y: origin.y, worldZ: origin.z, to: .hopper)
        world.setBlock(worldX: loadX, y: origin.y - 1, worldZ: origin.z, to: .railEastWest)
        let loadChestKey = ChestStore.Key(loadX, origin.y + 1, origin.z)
        let loadHopperKey = HopperStore.Key(loadX, origin.y, origin.z)
        chests.chest(at: loadChestKey)[0] = ItemStack(.coal, count: 2)
        guard let emptyID = minecarts.place(at: (loadX, origin.y - 1, origin.z), in: world) else {
            report.check("a cart can be parked under the loading hopper", false, "placement failed")
            for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
            exit(1)
        }

        for _ in 0..<2 {
            HopperStore.transfer(at: loadHopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts)
        }
        report.check(
            "a hopper over an empty cart loads it from the chest above",
            chests.existing(at: loadChestKey)?.isEmpty == true
                && minecarts.cart(emptyID)?.cargo?.type == .coal
                && minecarts.cart(emptyID)?.cargo?.count == 2,
            "chest empty: \(chests.existing(at: loadChestKey)?.isEmpty == true), "
                + "cart cargo: \(String(describing: minecarts.cart(emptyID)?.cargo))"
        )

        // MARK: the store itself — registered, ticks, pruned when gone

        let store = HopperStore()
        let key = HopperStore.Key(0, 0, 0)
        store.hopperPlaced(at: key)
        report.check(
            "a placed hopper starts at zero cooldown",
            store.cooldown[key] == 0,
            "cooldown: \(String(describing: store.cooldown[key]))"
        )
        store.setCooldown(HopperStore.transferInterval, at: key)
        report.check(
            "and its cooldown can be advanced",
            store.cooldown[key] == HopperStore.transferInterval,
            "cooldown: \(String(describing: store.cooldown[key]))"
        )
        store.hopperRemoved(at: key)
        report.check(
            "removing a hopper drops it from the store",
            store.cooldown[key] == nil,
            "still tracked: \(store.cooldown[key] != nil)"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the hopper\n"
            : "[check] all passed — the hopper\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

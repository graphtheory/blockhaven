import Foundation

/// Headless proof of the one stake every other system in this game already
/// had and death alone did not: `Grave.drop` empties a dying player's
/// inventory into a chest at the spot they fell, the same "a chest exists
/// here" seam every landmark's own loot already goes through. This checks
/// that the chest is really placed and really holds what was carried, that
/// an empty inventory leaves no chest behind, that nothing is silently
/// lost when a haul overflows twenty-seven slots, and that dying twice on
/// the same spot adds to a grave rather than erasing it.
///
/// `BLOCKHAVEN_CHECK_GRAVE=1`. Exits nonzero if any line fails.
enum GraveCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_GRAVE"] != nil
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
        let spot = Vector3(8.4, 70, 8.4)
        world.forceGenerate(World.chunkCoord(forWorldX: 8, worldZ: 8))

        // MARK: a real chest, really holding what was carried

        let inventory = Inventory()
        inventory[0] = ItemStack(.log, count: 12)
        inventory[1] = ItemStack(.ironPickaxe, count: 1, wear: 40)
        inventory[2] = ItemStack(.torch, count: 6)
        let chests = ChestStore()
        let droppedKey = Grave.drop(inventory: inventory, chests: chests, world: world, at: spot)
        report.check(
            "drop hands back the key it actually used",
            droppedKey == ChestStore.Key(8, 70, 8),
            "returned: \(String(describing: droppedKey))"
        )

        let placed = world.block(worldX: 8, y: 70, worldZ: 8)
        report.check("a chest is really placed where the player fell", placed == .chest, "block there: \(placed)")

        let grave = chests.existing(at: ChestStore.Key(8, 70, 8))
        let carried = [
            ItemStack(.log, count: 12), ItemStack(.ironPickaxe, count: 1, wear: 40),
            ItemStack(.torch, count: 6),
        ]
        let graveContents = grave?.contents ?? []
        report.check(
            "it holds exactly what the player was carrying",
            graveContents.count == carried.count && carried.allSatisfy(graveContents.contains),
            "grave contents: \(graveContents)"
        )
        report.check(
            "the inventory it came from is now empty",
            (0..<Inventory.totalSize).allSatisfy { inventory[$0] == nil },
            "slots still occupied: \((0..<Inventory.totalSize).count { inventory[$0] != nil })"
        )

        // MARK: nothing carried, nothing left behind

        let emptyWorld = World()
        emptyWorld.forceGenerate(World.chunkCoord(forWorldX: 8, worldZ: 8))
        let emptyChests = ChestStore()
        Grave.drop(inventory: Inventory(), chests: emptyChests, world: emptyWorld, at: spot)
        let untouched = emptyWorld.block(worldX: 8, y: 70, worldZ: 8)
        report.check(
            "dying with nothing carried leaves no chest behind",
            untouched != .chest && emptyChests.isEmpty,
            "block: \(untouched), chest count: \(emptyChests.chests.count)"
        )

        // MARK: a haul too big for one chest loses nothing

        let fullInventory = Inventory()
        let hauledTypes = Array(ItemType.allCases.prefix(Inventory.totalSize))
        for (index, type) in hauledTypes.enumerated() { fullInventory[index] = ItemStack(type, count: 1) }
        let overflowWorld = World()
        let overflowSpot = Vector3(20.1, 70, 20.1)
        overflowWorld.forceGenerate(World.chunkCoord(forWorldX: 20, worldZ: 20))
        let overflowChests = ChestStore()
        Grave.drop(inventory: fullInventory, chests: overflowChests, world: overflowWorld, at: overflowSpot)
        let inGrave = overflowChests.existing(at: ChestStore.Key(20, 70, 20))?.contents.count ?? 0
        let stillCarried = (0..<Inventory.totalSize).count { fullInventory[$0] != nil }
        report.check(
            "a chest that fills up stops rather than losing the rest",
            inGrave == Chest.size && stillCarried == hauledTypes.count - Chest.size,
            "hauled \(hauledTypes.count) kinds, \(inGrave) made it into the chest, \(stillCarried) stayed with the player"
        )

        // MARK: dying in lava doesn't bury the grave inside it

        let lavaWorld = World()
        let lavaSpot = Vector3(40.4, 70, 40.4)
        lavaWorld.forceGenerate(World.chunkCoord(forWorldX: 40, worldZ: 40))
        lavaWorld.setBlock(worldX: 40, y: 70, worldZ: 40, to: .lava)
        lavaWorld.setBlock(worldX: 40, y: 71, worldZ: 40, to: .lava)
        lavaWorld.setBlock(worldX: 40, y: 72, worldZ: 40, to: .air)
        let lavaChests = ChestStore()
        let lavaInventory = Inventory()
        lavaInventory[0] = ItemStack(.diamond, count: 2)
        let lavaKey = Grave.drop(
            inventory: lavaInventory, chests: lavaChests, world: lavaWorld, at: lavaSpot
        )
        report.check(
            "dying in lava rises the grave above it instead of sealing it inside",
            lavaKey == ChestStore.Key(40, 72, 40),
            "grave landed at: \(String(describing: lavaKey))"
        )
        let lavaGraveBlock = lavaWorld.block(worldX: 40, y: 72, worldZ: 40)
        report.check(
            "the cell it lands in is a real chest, not still lava",
            lavaGraveBlock == .chest,
            "block there: \(lavaGraveBlock)"
        )

        // MARK: dying twice on the same spot adds to the grave, not over it

        let secondDeath = Inventory()
        secondDeath[0] = ItemStack(.stone, count: 3)
        Grave.drop(inventory: secondDeath, chests: chests, world: world, at: spot)
        let afterSecondDeath = chests.existing(at: ChestStore.Key(8, 70, 8))?.contents ?? []
        report.check(
            "a second death on the same spot adds to the grave rather than erasing it",
            afterSecondDeath.contains(ItemStack(.log, count: 12)) && afterSecondDeath.contains(ItemStack(.stone, count: 3)),
            "grave now holds: \(afterSecondDeath)"
        )

        // MARK: the compass points at what dying cost, only for as long as it's owed

        let home = Vector3(0, 70, 0)
        let compassWorld = World()
        let compassSpot = Vector3(30.4, 70, 30.4)
        compassWorld.forceGenerate(World.chunkCoord(forWorldX: 30, worldZ: 30))
        let compassChests = ChestStore()
        let compassInventory = Inventory()
        compassInventory[0] = ItemStack(.diamond, count: 4)
        let compassKey = Grave.drop(
            inventory: compassInventory, chests: compassChests, world: compassWorld, at: compassSpot
        )

        let noGrave = Grave.compassTarget(pendingGraves: [], chests: compassChests, home: home, playerPosition: home)
        report.check(
            "with no grave at all, the compass points home",
            noGrave.position == home && !noGrave.isGrave,
            "target: \(noGrave)"
        )

        let onePending = [compassKey].compactMap { $0 }
        let towardGrave = Grave.compassTarget(
            pendingGraves: onePending, chests: compassChests, home: home, playerPosition: home
        )
        report.check(
            "with an unclaimed grave, the compass points there instead of home",
            towardGrave.isGrave && towardGrave.position != home,
            "target: \(towardGrave)"
        )

        if let key = compassKey, let emptied = compassChests.existing(at: key) {
            for index in 0..<Chest.size { emptied[index] = nil }
        }
        let afterEmptied = Grave.compassTarget(
            pendingGraves: onePending, chests: compassChests, home: home, playerPosition: home
        )
        report.check(
            "once the grave is emptied by hand, home takes back over on its own",
            afterEmptied.position == home && !afterEmptied.isGrave && afterEmptied.stillPending.isEmpty,
            "target: \(afterEmptied)"
        )

        compassChests.remove(at: compassKey ?? ChestStore.Key(0, 0, 0))
        let afterGone = Grave.compassTarget(
            pendingGraves: onePending, chests: compassChests, home: home, playerPosition: home
        )
        report.check(
            "and once the grave chest is gone entirely, home takes back over the same way",
            afterGone.position == home && !afterGone.isGrave,
            "target: \(afterGone)"
        )

        // MARK: a second death before the first grave is walked back to
        // doesn't quietly drop the first grave from the list

        let twinWorld = World()
        twinWorld.forceGenerate(World.chunkCoord(forWorldX: 30, worldZ: 30))
        let twinChests = ChestStore()
        let nearInventory = Inventory()
        nearInventory[0] = ItemStack(.diamond, count: 1)
        let nearGrave = Grave.drop(
            inventory: nearInventory, chests: twinChests, world: twinWorld, at: Vector3(2, 70, 0)
        )
        let farInventory = Inventory()
        farInventory[0] = ItemStack(.diamond, count: 2)
        let farGrave = Grave.drop(
            inventory: farInventory, chests: twinChests, world: twinWorld, at: Vector3(40, 70, 0)
        )
        let bothPending = [nearGrave, farGrave].compactMap { $0 }
        let towardNearer = Grave.compassTarget(
            pendingGraves: bothPending, chests: twinChests, home: home, playerPosition: Vector3(0, 70, 0)
        )
        report.check(
            "with two graves out, the compass points at the nearer one, not just the newer one",
            towardNearer.position == Vector3(2.5, 70.5, 0.5) && towardNearer.stillPending.count == 2,
            "target: \(towardNearer)"
        )

        if let key = nearGrave, let emptied = twinChests.existing(at: key) {
            for index in 0..<Chest.size { emptied[index] = nil }
        }
        let towardRemaining = Grave.compassTarget(
            pendingGraves: towardNearer.stillPending, chests: twinChests, home: home,
            playerPosition: Vector3(0, 70, 0)
        )
        report.check(
            "and once the nearer grave is claimed, the farther one is still tracked rather than lost",
            towardRemaining.isGrave && towardRemaining.stillPending == [farGrave],
            "target: \(towardRemaining)"
        )

        // MARK: an unclaimed grave survives a save the same way pets and beds do

        let saved = WorldSave(
            seed: 1, mode: .survival, name: "t", lastPlayed: 0,
            edits: [:], position: home, yaw: 0, pitch: 0,
            inventory: Inventory(), stats: PlayerStats(), timeOfDay: 0,
            pendingGraves: [ChestStore.Key(30, 70, 30), ChestStore.Key(40, 70, 40)]
        )
        report.check(
            "every pending grave is written as its own set of coordinates",
            saved.pendingGraves?.count == 2,
            "pendingGraves=\(String(describing: saved.pendingGraves))"
        )
        report.check(
            "and reads back as the same keys, in order",
            saved.pendingGraveKeys == [ChestStore.Key(30, 70, 30), ChestStore.Key(40, 70, 40)],
            "restored: \(saved.pendingGraveKeys)"
        )

        let cleared = WorldSave(
            seed: 1, mode: .survival, name: "t", lastPlayed: 0,
            edits: [:], position: home, yaw: 0, pitch: 0,
            inventory: Inventory(), stats: PlayerStats(), timeOfDay: 0
        )
        report.check(
            "a file with nothing owed reads back as no graves at all, not a zeroed one",
            cleared.pendingGraveKeys.isEmpty,
            "restored: \(cleared.pendingGraveKeys)"
        )

        // A file written before a second grave could ever be owed at once
        // still remembers the one grave it always knew about.
        var legacy = WorldSave(
            seed: 1, mode: .survival, name: "t", lastPlayed: 0,
            edits: [:], position: home, yaw: 0, pitch: 0,
            inventory: Inventory(), stats: PlayerStats(), timeOfDay: 0
        )
        legacy.lastGraveX = 30
        legacy.lastGraveY = 70
        legacy.lastGraveZ = 30
        report.check(
            "a legacy single-grave file still reads back as that one grave",
            legacy.pendingGraveKeys == [ChestStore.Key(30, 70, 30)],
            "restored: \(legacy.pendingGraveKeys)"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed ? "[check] FAILED — the grave\n" : "[check] all passed — the grave\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

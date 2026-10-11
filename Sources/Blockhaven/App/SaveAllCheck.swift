import Foundation

/// Headless proof that a save is one round trip, not eight of them.
///
/// Every one of `WorldSave`'s optional fields — chests, a furnace, a
/// minecart, a tamed animal, a chestplate, a bed, a grave, plus everything
/// that rides for free inside the edit journal (a wired lever, wire, a
/// signal torch, a crop, a sapling) — already has its own check proving it
/// survives a reload *by itself*. Nothing had ever written all of them into
/// the same file and read them all back together, the same gap
/// `HomesteadCheck` closed for one live session rather than a save/load
/// boundary: every system composing on its own is not proof they still
/// compose once they have all been through the same encoder at once.
///
/// `BLOCKHAVEN_CHECK_SAVEALL=1`. Exits nonzero if any line fails.
enum SaveAllCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_SAVEALL"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    /// The same lever/plate/detector/torch reconstruction
    /// `GameViewController`'s own restoring initialiser runs over a loaded
    /// journal — mirrored here rather than reused, the same way every
    /// other check in this file rebuilds a small slice of production logic
    /// to prove it from the outside rather than trusting it from within.
    private static func registerSignalSources(from journal: [ChunkCoord: [Int: BlockType]], into signals: SignalNetwork) {
        for (coord, entries) in journal {
            for (index, block) in entries where block == .leverOff || block == .leverOn
                || block == .pressurePlateOff || block == .pressurePlateOn
                || block.isDetectorRail || block.isSignalTorch {
                let plane = Chunk.width * Chunk.depth
                let y = index / plane
                let remainder = index % plane
                let z = remainder / Chunk.width
                let x = remainder % Chunk.width
                let worldX = coord.x * Chunk.width + x, worldZ = coord.z * Chunk.depth + z
                let key = SignalNetwork.Key(worldX, y, worldZ)
                if block.isDetectorRail {
                    signals.detectorPlaced(at: key)
                } else if block.isSignalTorch {
                    signals.torchPlaced(at: key)
                } else if block == .pressurePlateOff || block == .pressurePlateOn {
                    signals.platePlaced(at: key)
                } else {
                    signals.leverPlaced(at: key)
                }
            }
        }
    }

    static func run() -> Never {
        var report = Report()
        let world = World()
        let spawn = world.spawnPosition()
        let originX = Int(spawn.x), originZ = Int(spawn.z)
        let centre = World.chunkCoord(forWorldX: originX, worldZ: originZ)
        for dz in -2...2 {
            for dx in -2...2 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }
        let deckY = 40
        for dz in -8...8 {
            for dx in -8...8 {
                world.setBlock(worldX: originX + dx, y: deckY - 1, worldZ: originZ + dz, to: .stone, remesh: false)
                for y in deckY...(deckY + 4) {
                    world.setBlock(worldX: originX + dx, y: y, worldZ: originZ + dz, to: .air, remesh: false)
                }
            }
        }

        // MARK: everything that rides for free inside the edit journal

        let leverCell = (originX, deckY, originZ)
        world.setBlock(worldX: leverCell.0, y: leverCell.1, worldZ: leverCell.2, to: .leverOn)
        let wireCell = (originX + 1, deckY, originZ)
        world.setBlock(worldX: wireCell.0, y: wireCell.1, worldZ: wireCell.2, to: .wireOff)
        let torchCell = (originX + 2, deckY, originZ)
        world.setBlock(worldX: torchCell.0, y: torchCell.1, worldZ: torchCell.2, to: .signalTorchOn)
        let cropCell = (originX, deckY, originZ + 2)
        world.setBlock(worldX: cropCell.0, y: cropCell.1, worldZ: cropCell.2, to: .wheatStage2)
        let saplingCell = (originX + 1, deckY, originZ + 2)
        world.setBlock(worldX: saplingCell.0, y: saplingCell.1, worldZ: saplingCell.2, to: .sapling)
        let railCell = (originX + 3, deckY, originZ)
        world.setBlock(worldX: railCell.0, y: railCell.1, worldZ: railCell.2, to: .railEastWest)

        // MARK: everything that needs a store of its own

        let chests = ChestStore()
        let stockedKey = ChestStore.Key(originX - 3, deckY, originZ)
        chests.chest(at: stockedKey).add(ItemStack(.diamond, count: 5))

        let furnaces = FurnaceStore()
        let furnaceKey = FurnaceStore.Key(originX - 3, deckY, originZ + 1)
        var cooking = FurnaceState()
        cooking.oreType = .rawIron
        cooking.oreCount = 3
        cooking.fuelType = .coal
        cooking.fuelCount = 2
        cooking.burnRemaining = 12
        cooking.progress = 1.5
        cooking.outputType = .ironIngot
        cooking.outputCount = 1
        furnaces.set(cooking, at: furnaceKey)

        var minecarts = MinecartManager()
        guard let cartID = minecarts.place(at: railCell, in: world) else {
            report.check("a cart parks on the rail", false, "Minecart.placed refused \(railCell)")
            for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
            exit(1)
        }
        minecarts.setCargo(ItemStack(.rawGold, count: 4), for: cartID)

        var animals = AnimalManager(mode: .survival, seed: 0x5AFE)
        animals.adopt([
            Animal(
                kind: .wolf,
                position: Vector3(CGFloat(originX), CGFloat(deckY), CGFloat(originZ - 3)),
                seed: 0x5EED, morph: .rare
            ),
        ])
        let wolfID = animals.animals.keys.first!
        animals.feed(wolfID)
        animals.toggleSit(wolfID)

        let deathInventory = Inventory()
        deathInventory.add(ItemStack(.diamondSword, wear: 40))
        let gravePosition = Vector3(CGFloat(originX + 4), CGFloat(deckY), CGFloat(originZ + 3))
        guard let graveKey = Grave.drop(inventory: deathInventory, chests: chests, world: world, at: gravePosition) else {
            report.check("a grave gets dropped", false, "Grave.drop returned nil")
            for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
            exit(1)
        }

        var stats = PlayerStats()
        stats.takeDamage(6, mitigable: false)
        stats.equip(.diamondChestplate)

        let bedSpawn = BedSpawn(x: originX - 1, y: deckY, z: originZ - 1)
        let carriedInventory = Inventory()
        carriedInventory.add(ItemStack(.woodenPickaxe, wear: 3))

        // A conveyor hopper aimed west with an item caught mid-transfer.
        // Neither fact is in the block journal — a hopper is one byte like
        // any other block — so both have to ride in the file or come back
        // wrong: a nil facing sends the hopper auto-discovering whatever
        // container it finds first, which is how a belt aimed one way comes
        // back feeding the other.
        let hoppers = HopperStore()
        let hopperCell = (originX + 3, deckY, originZ + 3)
        world.setBlock(worldX: hopperCell.0, y: hopperCell.1, worldZ: hopperCell.2, to: .hopper, remesh: false)
        let hopperKey = HopperStore.Key(hopperCell.0, hopperCell.1, hopperCell.2)
        hoppers.hopperPlaced(at: hopperKey, facing: .west)
        hoppers.setItem(ItemStack(.coal, count: 1), at: hopperKey)

        // MARK: one file, everything in it, one reload

        let snapshot = WorldSave(
            seed: world.seed, mode: .survival, name: "save-all check",
            lastPlayed: Date().timeIntervalSince1970, edits: world.editJournal,
            position: spawn, yaw: 0.4, pitch: -0.1,
            inventory: carriedInventory, stats: stats, timeOfDay: 0.3,
            weatherDayIndex: 2, bedSpawn: bedSpawn, pendingGraves: [graveKey],
            chests: chests, furnaces: furnaces, hoppers: hoppers,
            minecarts: minecarts, animals: animals
        )
        let fileURL = WorldSave.directoryURL.appendingPathComponent("save-all-check.json")
        do {
            try snapshot.save(to: fileURL)
        } catch {
            report.check("the combined save writes", false, "\(error)")
        }
        guard let reloaded = WorldSave.load(from: fileURL) else {
            report.check("the combined save reloads", false, "WorldSave.load returned nil for \(fileURL.path)")
            for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
            exit(1)
        }

        // MARK: every field, read back from the one reload

        let reloadedWorld = World(seed: reloaded.seed, edits: reloaded.editJournal)
        for dz in -2...2 {
            for dx in -2...2 {
                reloadedWorld.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }
        report.check(
            "the crop and the sapling are still the blocks they were",
            reloadedWorld.block(worldX: cropCell.0, y: cropCell.1, worldZ: cropCell.2) == .wheatStage2
                && reloadedWorld.block(worldX: saplingCell.0, y: saplingCell.1, worldZ: saplingCell.2) == .sapling,
            "crop \(reloadedWorld.block(worldX: cropCell.0, y: cropCell.1, worldZ: cropCell.2)), "
                + "sapling \(reloadedWorld.block(worldX: saplingCell.0, y: saplingCell.1, worldZ: saplingCell.2))"
        )

        let restoredHoppers = reloaded.hopperStore
        let restoredFacing = restoredHoppers.facing(at: hopperKey)
        let restoredHeld = restoredHoppers.item(at: hopperKey)
        report.check(
            "a hopper comes back pointing where it was aimed, still holding what it caught",
            restoredFacing == .west && restoredHeld?.type == .coal && restoredHeld?.count == 1,
            "facing \(String(describing: restoredFacing)), holding \(String(describing: restoredHeld))"
        )

        let signals = SignalNetwork()
        registerSignalSources(from: reloaded.editJournal, into: signals)
        let fuses = FuseManager()
        signals.recompute(world: reloadedWorld, fuses: fuses)
        let wireLit = reloadedWorld.block(worldX: wireCell.0, y: wireCell.1, worldZ: wireCell.2) == .wireOn
        report.check(
            "the lever still lights the wire once the world comes back",
            wireLit,
            "wire reads \(reloadedWorld.block(worldX: wireCell.0, y: wireCell.1, worldZ: wireCell.2))"
        )
        _ = signals.updateTorches(world: reloadedWorld, fuses: fuses, dt: SignalNetwork.torchDelay)
        let torchDark = reloadedWorld.block(worldX: torchCell.0, y: torchCell.1, worldZ: torchCell.2) == .signalTorchOff
        report.check(
            "and the torch still inverts once it feels that power",
            torchDark,
            "torch reads \(reloadedWorld.block(worldX: torchCell.0, y: torchCell.1, worldZ: torchCell.2))"
        )

        let reloadedChest = reloaded.chestStore.existing(at: stockedKey)
        report.check(
            "the stocked chest kept what it was given",
            reloadedChest?.contents.first?.type == .diamond && reloadedChest?.contents.first?.count == 5,
            "\(reloadedChest?.contents.first.map { "\($0.count)×\($0.type)" } ?? "empty")"
        )

        let reloadedGrave = reloaded.chestStore.existing(at: graveKey)
        report.check(
            "and the grave, a second chest in the same store, kept its own contents",
            reloadedGrave?.contents.first?.type == .diamondSword && reloadedGrave?.contents.first?.wear == 40,
            "\(reloadedGrave?.contents.first.map { "\($0.type) wear \($0.wear)" } ?? "empty")"
        )

        let reloadedFurnace = reloaded.furnaceStore.state(at: furnaceKey)
        report.check(
            "the furnace is still mid-cook",
            reloadedFurnace.oreType == .rawIron && reloadedFurnace.fuelType == .coal
                && reloadedFurnace.burnRemaining == 12 && reloadedFurnace.progress == 1.5,
            "ore \(String(describing: reloadedFurnace.oreType)), burn \(reloadedFurnace.burnRemaining), progress \(reloadedFurnace.progress)"
        )

        let reloadedCart = reloaded.restoredMinecarts.first
        report.check(
            "the cart still has its cargo",
            reloadedCart?.cargo?.type == .rawGold && reloadedCart?.cargo?.count == 4,
            "\(reloadedCart?.cargo.map { "\($0.count)×\($0.type)" } ?? "no cart or no cargo")"
        )

        let reloadedAnimals = reloaded.restoredAnimals
        report.check(
            "the tamed, sitting, rare wolf is still tamed, sitting, and rare",
            reloadedAnimals.count == 1 && reloadedAnimals[0].kind == .wolf
                && reloadedAnimals[0].isTamed && reloadedAnimals[0].isSitting && reloadedAnimals[0].morph == .rare,
            "\(reloadedAnimals.first.map { "tamed \($0.isTamed), sitting \($0.isSitting), \($0.morph)" } ?? "missing")"
        )

        report.check(
            "health, chestplate, bed and weather all came back with everything else",
            reloaded.health == 14 && reloaded.equippedChestplate == .diamondChestplate
                && reloaded.bedSpawn == bedSpawn && reloaded.weatherDayIndex == 2,
            "health \(reloaded.health), chestplate \(String(describing: reloaded.equippedChestplate)), "
                + "bed \(String(describing: reloaded.bedSpawn)), weather day \(String(describing: reloaded.weatherDayIndex))"
        )

        let target = Grave.compassTarget(
            pendingGraves: reloaded.pendingGraveKeys, chests: reloaded.chestStore, home: spawn, playerPosition: spawn
        )
        report.check(
            "and the compass still owes the player their grave, not just home",
            target.isGrave && (target.position - Vector3(CGFloat(graveKey.x) + 0.5, CGFloat(graveKey.y) + 0.5, CGFloat(graveKey.z) + 0.5)).length() < 0.01,
            "isGrave \(target.isGrave), position \(target.position)"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the combined save\n"
            : "[check] all passed — the combined save\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

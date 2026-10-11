import Foundation

/// Headless proof that a furnace is a process rather than a menu: it does
/// nothing until it is lit, it costs the fuel it burns, it takes real time
/// per item, and the block in the world says which of those is true without
/// anyone opening a screen.
///
/// `BLOCKHAVEN_CHECK_FURNACE=1`. Exits nonzero if any line fails.
enum FurnaceCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_FURNACE"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    /// A frame, at the rate the game runs its simulation.
    private static let dt = 1.0 / 60

    static func run() -> Never {
        var report = Report()

        // MARK: cold, and unlit costs nothing

        var idle = FurnaceState()
        let idleChanged = idle.tick(dt: 1.0)
        report.check(
            "an empty furnace stays cold",
            !idleChanged && !idle.isBurning && idle.isEmpty,
            "burning \(idle.isBurning), empty \(idle.isEmpty)"
        )

        // MARK: lighting up

        var state = FurnaceState()
        state.oreType = .rawIron
        state.oreCount = 3
        state.fuelType = .coal
        state.fuelCount = 1
        let lit = state.tick(dt: dt)
        report.check(
            "ore and fuel together light the fire",
            lit && state.isBurning && state.fuelType == nil && state.fuelCount == 0,
            "burning \(state.isBurning), fuel left \(state.fuelCount), "
                + "coal consumed as one lump: \(state.fuelType == nil)"
        )

        // MARK: smelting takes real time, not a frame

        var afterOneFrame = state
        _ = afterOneFrame.tick(dt: dt)
        report.check(
            "one frame does not finish a smelt",
            afterOneFrame.outputType == nil,
            "output after \(dt * 1000)ms: \(String(describing: afterOneFrame.outputType))"
        )

        var elapsed = 0.0
        var litChanges = 0
        while elapsed < FurnaceRecipe.smeltSeconds + 0.5 {
            if state.tick(dt: dt) { litChanges += 1 }
            elapsed += dt
        }
        report.check(
            "and finishes once it has run that long",
            state.outputType == .ironIngot && state.outputCount == 1 && state.oreCount == 2,
            "output \(String(describing: state.outputType))×\(state.outputCount), "
                + "\(state.oreCount) raw iron left"
        )
        report.check(
            "the fire does not flicker mid-burn",
            litChanges == 0,
            "\(litChanges) lit/unlit transitions during one uninterrupted burn"
        )

        // MARK: one lump of coal is five smelts, then the fire goes out

        var five = FurnaceState()
        five.oreType = .rawIron
        five.oreCount = 5
        five.fuelType = .coal
        five.fuelCount = 1
        var wentOutAt = -1.0
        elapsed = 0
        var sawFiveOutputs = false
        while elapsed < FurnaceRecipe.burnSeconds(for: .coal)! + 1 {
            let changed = five.tick(dt: dt)
            if changed, !five.isBurning, wentOutAt < 0 { wentOutAt = elapsed }
            if five.outputCount == 5 { sawFiveOutputs = true }
            elapsed += dt
        }
        report.check(
            "one lump of coal smelts exactly five items",
            sawFiveOutputs && five.outputCount == 5 && five.oreCount == 0,
            "\(five.outputCount) ingots out of 5 ore, coal's worth of burn used"
        )
        let expectedBurn = FurnaceRecipe.burnSeconds(for: .coal)!
        report.check(
            "and the fire goes out when the coal runs out, not before or long after",
            wentOutAt > expectedBurn - 0.1 && wentOutAt < expectedBurn + 0.1,
            String(format: "went dark at %.2fs against a %.2fs lump", wentOutAt, expectedBurn)
        )

        // MARK: fuel with nothing to cook does not burn itself for nothing

        var noOre = FurnaceState()
        noOre.fuelType = .coal
        noOre.fuelCount = 1
        _ = noOre.tick(dt: 2.0)
        report.check(
            "fuel alone does not light without ore to cook",
            !noOre.isBurning && noOre.fuelCount == 1,
            "burning \(noOre.isBurning), coal still in the slot: \(noOre.fuelCount)"
        )

        // MARK: the block in the world is the only signal — no screen needed

        let world = World()
        let spawn = world.spawnPosition()
        let cell = (x: Int(spawn.x), y: 40, z: Int(spawn.z))
        world.forceGenerate(World.chunkCoord(forWorldX: cell.x, worldZ: cell.z))
        world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .furnace)
        var live = FurnaceState()
        live.oreType = .rawGold
        live.oreCount = 1
        live.fuelType = .planks
        live.fuelCount = 1
        if live.tick(dt: dt) {
            world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .furnaceLit)
        }
        let litBlock = world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)
        report.check(
            "a burning furnace is a different block, not a hidden flag",
            litBlock == .furnaceLit && litBlock.lightEmission > 0 && BlockType.furnace.lightEmission == 0,
            "block is \(String(describing: litBlock)), lit emission \(litBlock.lightEmission), "
                + "cold emission \(BlockType.furnace.lightEmission)"
        )

        elapsed = 0
        while elapsed < FurnaceRecipe.smeltSeconds + 0.5 {
            if live.tick(dt: dt) {
                world.setBlock(
                    worldX: cell.x, y: cell.y, worldZ: cell.z,
                    to: live.isBurning ? .furnaceLit : .furnace
                )
            }
            elapsed += dt
        }
        let outBlock = world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)
        report.check(
            "and goes dark in the world when the fire does",
            outBlock == .furnace && live.outputType == .goldIngot,
            "block is \(String(describing: outBlock)) with \(String(describing: live.outputType)) smelted"
        )

        // MARK: raw meat cooks too, not just ore

        var meat = FurnaceState()
        meat.oreType = .porkchop
        meat.oreCount = 1
        meat.fuelType = .planks
        meat.fuelCount = 1
        elapsed = 0
        while elapsed < FurnaceRecipe.smeltSeconds + 0.5 {
            _ = meat.tick(dt: dt)
            elapsed += dt
        }
        report.check(
            "a furnace cooks raw meat into something worth more to eat",
            meat.outputType == .cookedPorkchop
                && (ItemType.cookedPorkchop.foodValue ?? 0) > (ItemType.porkchop.foodValue ?? 0),
            "output \(String(describing: meat.outputType)), raw \(ItemType.porkchop.foodValue ?? -1) "
                + "vs cooked \(ItemType.cookedPorkchop.foodValue ?? -1)"
        )

        // MARK: the store: keyed by cell, pruned when the block is gone

        let store = FurnaceStore()
        let key = FurnaceStore.Key(cell.x, cell.y, cell.z)
        store.set(live, at: key)
        report.check(
            "a non-empty furnace is kept by the store",
            !store.isEmpty && store.state(at: key) == live,
            "stored: \(!store.isEmpty), round-trips: \(store.state(at: key) == live)"
        )
        store.prune { $0 == key }
        report.check(
            "pruning drops a furnace whose block is gone",
            store.isEmpty,
            "\(store.furnaces.count) furnaces left after pruning the one cell"
        )

        var emptied = live
        let collected = ItemStack(emptied.outputType!, count: emptied.outputCount)
        emptied.outputType = nil
        emptied.outputCount = 0
        store.set(emptied, at: key)
        report.check(
            "collecting the output empties the furnace back out of the store",
            store.isEmpty,
            "collected \(collected.type)×\(collected.count), store empty: \(store.isEmpty)"
        )

        // MARK: round-trips a save

        let saved = WorldSave(
            seed: 1, mode: .survival, name: "furnace check", lastPlayed: 0,
            edits: [:], position: .zero, yaw: 0, pitch: 0,
            inventory: Inventory(), stats: PlayerStats(), timeOfDay: 0,
            furnaces: { let s = FurnaceStore(); s.set(state, at: key); return s }()
        )
        let restored = saved.furnaceStore.state(at: key)
        report.check(
            "a furnace mid-burn survives a save round-trip",
            restored.oreType == state.oreType && restored.oreCount == state.oreCount
                && restored.outputType == state.outputType && restored.outputCount == state.outputCount,
            "before ore \(String(describing: state.oreType))×\(state.oreCount) output "
                + "\(String(describing: state.outputType))×\(state.outputCount); "
                + "after ore \(String(describing: restored.oreType))×\(restored.oreCount) output "
                + "\(String(describing: restored.outputType))×\(restored.outputCount)"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the furnace\n"
            : "[check] all passed — the furnace\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

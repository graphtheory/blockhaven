import Foundation

/// Headless proof of the tool that turns "place a wall" into "mark a wall":
/// a mason's line remembers two corners, and the next ordinary material
/// placed fills the whole box between them instead of the one cell it
/// would otherwise take — or the next ordinary block broken clears it back
/// to air instead of just the one it hit — the same reuse of an existing
/// gesture a relay made of plain wire.
///
/// `BLOCKHAVEN_CHECK_MASON=1`. Exits nonzero if any line fails.
enum MasonCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_MASON"] != nil
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
        let origin = (x: Int(spawn.x), y: 60, z: Int(spawn.z))
        for dx in stride(from: -16, through: 64, by: 8) {
            world.forceGenerate(World.chunkCoord(forWorldX: origin.x + dx, worldZ: origin.z))
        }
        for dz in -6...6 {
            for dx in -16...64 {
                for y in origin.y...(origin.y + 6) {
                    world.setBlock(worldX: origin.x + dx, y: y, worldZ: origin.z + dz, to: .air, remesh: false)
                }
            }
        }

        // MARK: the box itself

        let a = (x: origin.x, y: origin.y, z: origin.z)
        let b = (x: origin.x + 3, y: origin.y + 1, z: origin.z + 2)
        let box = RegionFill.region(from: a, to: b)
        report.check(
            "the box spans both corners inclusive, whichever order they were marked in",
            RegionFill.volume(of: box) == 4 * 2 * 3,
            "volume: \(RegionFill.volume(of: box)) (want 4×2×3 = 24)"
        )
        let reversedBox = RegionFill.region(from: b, to: a)
        report.check(
            "and marking the far corner first gives the identical box",
            reversedBox.minX == box.minX && reversedBox.maxX == box.maxX
                && reversedBox.minY == box.minY && reversedBox.maxY == box.maxY
                && reversedBox.minZ == box.minZ && reversedBox.maxZ == box.maxZ,
            "forward: \(box), reversed: \(reversedBox)"
        )

        // MARK: filling — every replaceable cell in the box, and nothing outside it

        let filled = RegionFill.fill(
            box, with: .stone, world: world, playerOverlaps: { _, _, _ in false }, available: 999
        )
        report.check(
            "a fill with enough material fills the whole box",
            filled == 24,
            "cells placed: \(filled)"
        )
        var allStone = true
        for y in box.minY...box.maxY {
            for z in box.minZ...box.maxZ {
                for x in box.minX...box.maxX where world.block(worldX: x, y: y, worldZ: z) != .stone {
                    allStone = false
                }
            }
        }
        report.check("and every cell inside the box actually took the block", allStone, "all stone: \(allStone)")
        let justOutside = world.block(worldX: box.maxX + 1, y: box.minY, worldZ: box.minZ)
        report.check(
            "but nothing one cell past the box was touched",
            justOutside != .stone,
            "cell just past the box: \(String(describing: justOutside))"
        )

        // MARK: running out of material stops the fill, not the whole game

        let shortBox = RegionFill.region(
            from: (x: origin.x + 10, y: origin.y, z: origin.z),
            to: (x: origin.x + 13, y: origin.y, z: origin.z)
        )
        let shortFill = RegionFill.fill(
            shortBox, with: .planks, world: world, playerOverlaps: { _, _, _ in false }, available: 2
        )
        report.check(
            "a fill that outruns the stack places only what the stack could pay for",
            shortFill == 2,
            "cells placed with 2 available out of a 4-cell box: \(shortFill)"
        )

        // MARK: the player's own cell, and anything already occupied, are skipped rather than refusing the whole box

        let occupied = (x: origin.x + 20, y: origin.y, z: origin.z)
        world.setBlock(worldX: occupied.x, y: occupied.y, worldZ: occupied.z, to: .obsidian, remesh: false)
        let standing = (x: origin.x + 21, y: origin.y, z: origin.z)
        let partialBox = RegionFill.region(from: occupied, to: standing)
        let partialFill = RegionFill.fill(
            partialBox, with: .stone, world: world,
            playerOverlaps: { x, y, z in x == standing.x && y == standing.y && z == standing.z },
            available: 999
        )
        report.check(
            "an occupied cell and the player's own cell are skipped, not a reason to fill nothing",
            partialFill == 0
                && world.block(worldX: occupied.x, y: occupied.y, worldZ: occupied.z) == .obsidian
                && world.block(worldX: standing.x, y: standing.y, worldZ: standing.z) != .stone,
            "placed: \(partialFill), occupied cell still: "
                + "\(String(describing: world.block(worldX: occupied.x, y: occupied.y, worldZ: occupied.z)))"
        )

        // MARK: plain material, wire, a relay and a torch fill in bulk — a
        // lever, a plate, a detector, rails, crops, saplings and per-block
        // stores still take one placement at a time

        report.check(
            "ordinary terrain and building blocks are bulk-fillable",
            BlockType.stone.isBulkFillable && BlockType.planks.isBulkFillable && BlockType.glass.isBulkFillable,
            "stone: \(BlockType.stone.isBulkFillable), planks: \(BlockType.planks.isBulkFillable), "
                + "glass: \(BlockType.glass.isBulkFillable)"
        )
        report.check(
            "so is wire, a relay and a torch — none of the three is meant to be thrown one at a time",
            BlockType.wireOff.isBulkFillable && BlockType.signalRelayOff.isBulkFillable
                && BlockType.signalTorchOff.isBulkFillable,
            "wire: \(BlockType.wireOff.isBulkFillable), relay: \(BlockType.signalRelayOff.isBulkFillable), "
                + "torch: \(BlockType.signalTorchOff.isBulkFillable)"
        )
        report.check(
            "but a lever, a plate and a detector are switches meant to be thrown one at a time",
            !BlockType.leverOff.isBulkFillable && !BlockType.pressurePlateOff.isBulkFillable
                && !BlockType.detectorNorthSouth.isBulkFillable,
            "lever: \(BlockType.leverOff.isBulkFillable), plate: \(BlockType.pressurePlateOff.isBulkFillable), "
                + "detector: \(BlockType.detectorNorthSouth.isBulkFillable)"
        )
        report.check(
            "and rails, crops, saplings and per-block stores stay one-at-a-time too",
            !BlockType.railNorthSouth.isBulkFillable && !BlockType.wheatStage0.isBulkFillable
                && !BlockType.sapling.isBulkFillable && !BlockType.chest.isBulkFillable
                && !BlockType.hopper.isBulkFillable && !BlockType.furnace.isBulkFillable,
            "rail: \(BlockType.railNorthSouth.isBulkFillable), wheat: \(BlockType.wheatStage0.isBulkFillable), "
                + "sapling: \(BlockType.sapling.isBulkFillable), chest: \(BlockType.chest.isBulkFillable), "
                + "hopper: \(BlockType.hopper.isBulkFillable), furnace: \(BlockType.furnace.isBulkFillable)"
        )

        // MARK: a bulk-filled wire run is not just present, it actually
        // carries a signal — the whole point of allowing it at all

        let wireBox = RegionFill.region(
            from: (x: origin.x + 30, y: origin.y, z: origin.z),
            to: (x: origin.x + 34, y: origin.y, z: origin.z)
        )
        let wireFill = RegionFill.fill(
            wireBox, with: .wireOff, world: world, playerOverlaps: { _, _, _ in false }, available: 999
        )
        report.check(
            "a mason's line fill of wire places the whole run",
            wireFill == 5,
            "cells placed: \(wireFill)"
        )
        world.setBlock(worldX: origin.x + 29, y: origin.y, worldZ: origin.z, to: .leverOn)
        let wireSignals = SignalNetwork()
        let wireFuses = FuseManager()
        wireSignals.leverPlaced(at: SignalNetwork.Key(origin.x + 29, origin.y, origin.z))
        wireSignals.recompute(world: world, fuses: wireFuses)
        let farWireCell = world.block(worldX: origin.x + 34, y: origin.y, worldZ: origin.z)
        report.check(
            "and every cell of it conducts exactly like hand-placed wire would",
            farWireCell == .wireOn,
            "far end of a 5-cell bulk-filled run, one cell from a thrown lever: \(String(describing: farWireCell))"
        )

        // MARK: a bulk-filled relay resets reach exactly like a hand-placed one

        let relayBox = RegionFill.region(
            from: (x: origin.x + 40, y: origin.y, z: origin.z),
            to: (x: origin.x + 40, y: origin.y, z: origin.z)
        )
        let relayFilled = RegionFill.fill(
            relayBox, with: .signalRelayOff, world: world, playerOverlaps: { _, _, _ in false }, available: 999
        )
        for step in 1...(SignalNetwork.maxReach + 5) {
            world.setBlock(worldX: origin.x + 40 + step, y: origin.y, worldZ: origin.z, to: .wireOff)
        }
        for step in 1..<SignalNetwork.maxReach {
            world.setBlock(worldX: origin.x + 40 - step, y: origin.y, worldZ: origin.z, to: .wireOff)
        }
        world.setBlock(worldX: origin.x + 40 - SignalNetwork.maxReach, y: origin.y, worldZ: origin.z, to: .leverOn)
        let relaySignals = SignalNetwork()
        let relayFuses = FuseManager()
        relaySignals.leverPlaced(at: SignalNetwork.Key(origin.x + 40 - SignalNetwork.maxReach, origin.y, origin.z))
        relaySignals.recompute(world: world, fuses: relayFuses)
        let pastBulkFilledRelay = world.block(
            worldX: origin.x + 40 + SignalNetwork.maxReach - 2, y: origin.y, worldZ: origin.z
        )
        report.check(
            "a bulk-filled relay resets reach the same as one placed by hand",
            relayFilled == 1 && pastBulkFilledRelay == .wireOn,
            "relay placed: \(relayFilled), a cell only reachable through it reads \(String(describing: pastBulkFilledRelay))"
        )

        // MARK: a bulk-filled torch joins the network exactly like a
        // hand-placed one — `fill` itself makes no `*Placed` call, so this
        // mirrors the same registration loop `GameViewController` runs
        // after a torch fill, the same way the wire/relay checks above
        // stand in for what the view controller does with those.

        let torchBox = RegionFill.region(
            from: (x: origin.x + 10, y: origin.y, z: origin.z + 4),
            to: (x: origin.x + 13, y: origin.y, z: origin.z + 4)
        )
        let torchFilled = RegionFill.fill(
            torchBox, with: .signalTorchOff, world: world, playerOverlaps: { _, _, _ in false }, available: 999
        )
        report.check(
            "a mason's line fill of torches places the whole run",
            torchFilled == 4,
            "cells placed: \(torchFilled)"
        )
        let torchSignals = SignalNetwork()
        let torchFuses = FuseManager()
        for y in torchBox.minY...torchBox.maxY {
            for z in torchBox.minZ...torchBox.maxZ {
                for x in torchBox.minX...torchBox.maxX
                where world.block(worldX: x, y: y, worldZ: z).isSignalTorch {
                    torchSignals.torchPlaced(at: SignalNetwork.Key(x, y, z))
                }
            }
        }
        torchSignals.recompute(world: world, fuses: torchFuses)
        torchSignals.updateTorches(world: world, fuses: torchFuses, dt: SignalNetwork.torchDelay)
        let litAfterFill = (torchBox.minX...torchBox.maxX).allSatisfy {
            world.block(worldX: $0, y: torchBox.minY, worldZ: torchBox.minZ) == .signalTorchOn
        }
        report.check(
            "and every cell of it actually joins the network and lights unpowered, same as a hand-placed torch",
            litAfterFill && torchSignals.torchCells.count == 4,
            "all four lit: \(litAfterFill), registered: \(torchSignals.torchCells.count)"
        )

        // MARK: a bulk-cleared torch leaves the network the same way a
        // hand-broken one does

        let torchCleared = RegionFill.clear(
            torchBox, world: world,
            playerOverlaps: { _, _, _ in false },
            availableUses: 999
        ) { cleared, x, y, z in
            if cleared.isSignalTorch { torchSignals.torchRemoved(at: SignalNetwork.Key(x, y, z)) }
        }
        report.check(
            "clearing that same box unregisters every torch it took with it",
            torchCleared == 4 && torchSignals.torchCells.isEmpty,
            "cells cleared: \(torchCleared), still registered: \(torchSignals.torchCells.count)"
        )

        // MARK: a box too large to place by hand is too large for one fill

        let hugeBox = RegionFill.region(
            from: (x: 0, y: 0, z: 0),
            to: (x: RegionFill.maxVolume, y: 0, z: 0)
        )
        report.check(
            "a fill request past the cap places nothing rather than stalling on a huge box",
            RegionFill.fill(hugeBox, with: .stone, world: world, playerOverlaps: { _, _, _ in false }, available: 999_999) == 0,
            "volume requested: \(RegionFill.volume(of: hugeBox)), cap: \(RegionFill.maxVolume)"
        )

        // MARK: clearing — the reverse of filling, and just as bounded

        let clearBox = RegionFill.region(
            from: (x: origin.x + 50, y: origin.y, z: origin.z),
            to: (x: origin.x + 53, y: origin.y + 1, z: origin.z + 1)
        )
        for y in clearBox.minY...clearBox.maxY {
            for z in clearBox.minZ...clearBox.maxZ {
                for x in clearBox.minX...clearBox.maxX {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .stone, remesh: false)
                }
            }
        }
        var clearedCells: [(BlockType, Int, Int, Int)] = []
        let cleared = RegionFill.clear(
            clearBox, world: world, playerOverlaps: { _, _, _ in false }, availableUses: 999
        ) { block, x, y, z in clearedCells.append((block, x, y, z)) }
        report.check(
            "a clear with enough tool uses empties the whole box back to air",
            cleared == RegionFill.volume(of: clearBox) && clearedCells.count == cleared,
            "cells cleared: \(cleared) of \(RegionFill.volume(of: clearBox)), callback fired \(clearedCells.count) times"
        )
        var allAir = true
        for y in clearBox.minY...clearBox.maxY {
            for z in clearBox.minZ...clearBox.maxZ {
                for x in clearBox.minX...clearBox.maxX where world.block(worldX: x, y: y, worldZ: z) != .air {
                    allAir = false
                }
            }
        }
        report.check("and every cell inside the box actually went back to air", allAir, "all air: \(allAir)")

        // MARK: running out of tool uses stops the clear, not the whole game

        let shortClearBox = RegionFill.region(
            from: (x: origin.x + 60, y: origin.y, z: origin.z),
            to: (x: origin.x + 63, y: origin.y, z: origin.z)
        )
        for x in shortClearBox.minX...shortClearBox.maxX {
            world.setBlock(worldX: x, y: shortClearBox.minY, worldZ: shortClearBox.minZ, to: .dirt, remesh: false)
        }
        let shortCleared = RegionFill.clear(
            shortClearBox, world: world, playerOverlaps: { _, _, _ in false }, availableUses: 2
        ) { _, _, _, _ in }
        report.check(
            "a clear that outruns the tool's uses removes only what it could pay for",
            shortCleared == 2,
            "cells cleared with 2 uses available out of a 4-cell box: \(shortCleared)"
        )

        // MARK: a chest keeps what's in it even when the box around it clears

        let chestBox = RegionFill.region(
            from: (x: origin.x + 70, y: origin.y, z: origin.z),
            to: (x: origin.x + 71, y: origin.y, z: origin.z)
        )
        world.setBlock(worldX: origin.x + 70, y: origin.y, worldZ: origin.z, to: .stone, remesh: false)
        world.setBlock(worldX: origin.x + 71, y: origin.y, worldZ: origin.z, to: .chest, remesh: false)
        let chestCleared = RegionFill.clear(
            chestBox, world: world, playerOverlaps: { _, _, _ in false }, availableUses: 999
        ) { _, _, _, _ in }
        report.check(
            "isBulkFillable keeps a clear off a chest the same way it keeps a fill off one",
            chestCleared == 1 && world.block(worldX: origin.x + 71, y: origin.y, worldZ: origin.z) == .chest,
            "cells cleared: \(chestCleared) (want 1, the stone only), chest still standing: "
                + "\(String(describing: world.block(worldX: origin.x + 71, y: origin.y, worldZ: origin.z)))"
        )

        // MARK: the recipe

        let grid = CraftingGrid(size: 2)
        var withParts = grid
        withParts[0] = ItemStack(.ironIngot)
        withParts[1] = ItemStack(.stick)
        withParts[2] = ItemStack(.stick)
        let crafted = RecipeBook.match(withParts)
        report.check(
            "an iron ingot and two sticks craft a mason's line on the everyday grid",
            crafted?.type == .masonLine && crafted?.count == 1,
            "result: \(String(describing: crafted))"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the mason's line\n"
            : "[check] all passed — the mason's line\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

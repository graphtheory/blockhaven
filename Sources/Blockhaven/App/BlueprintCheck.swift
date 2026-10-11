import Foundation

/// Headless proof of the mason's line's own late-game step: a blueprint
/// captures whatever a marked box actually contains, in whatever materials
/// it actually used, and every later stamp reproduces that same shape
/// somewhere else — billed per block against real inventory, the same as
/// building it by hand would have cost, and good for as many stamps as the
/// player wants rather than being spent by the first one.
///
/// `BLOCKHAVEN_CHECK_BLUEPRINT=1`. Exits nonzero if any line fails.
enum BlueprintCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_BLUEPRINT"] != nil
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

        // MARK: capturing skips air and reproduces exactly what was there,
        // in whatever materials it actually used

        let sourceOrigin = (x: origin.x, y: origin.y, z: origin.z)
        world.setBlock(worldX: sourceOrigin.x, y: sourceOrigin.y, worldZ: sourceOrigin.z, to: .stone, remesh: false)
        world.setBlock(
            worldX: sourceOrigin.x + 1, y: sourceOrigin.y, worldZ: sourceOrigin.z, to: .planks, remesh: false
        )
        // Cell +2 is left air on purpose — a capture should come back with
        // three cells at offsets 0, 1 and 3, not four in a row.
        world.setBlock(
            worldX: sourceOrigin.x + 3, y: sourceOrigin.y, worldZ: sourceOrigin.z, to: .wireOff, remesh: false
        )
        let sourceBox = RegionFill.region(
            from: sourceOrigin, to: (x: sourceOrigin.x + 3, y: sourceOrigin.y, z: sourceOrigin.z)
        )
        let captured = RegionFill.capture(sourceBox, world: world)
        report.check(
            "a capture records every non-air cell and skips the air between them",
            captured.cells.count == 3,
            "cells captured: \(captured.cells.count) (want 3 — stone, planks, wire, not the air gap at +2)"
        )

        var placedCells: [(BlockType, Int, Int, Int)] = []
        let stampAnchor = (x: origin.x + 10, y: origin.y, z: origin.z)
        let stamped = RegionFill.stamp(
            captured, at: stampAnchor, world: world,
            playerOverlaps: { _, _, _ in false },
            available: { _ in 999 }
        ) { block, x, y, z in placedCells.append((block, x, y, z)) }
        report.check(
            "and a stamp reproduces every captured cell at the new anchor",
            stamped == 3 && placedCells.count == 3,
            "cells stamped: \(stamped), callback fired \(placedCells.count) times"
        )
        let stone = world.block(worldX: stampAnchor.x, y: stampAnchor.y, worldZ: stampAnchor.z)
        let planks = world.block(worldX: stampAnchor.x + 1, y: stampAnchor.y, worldZ: stampAnchor.z)
        let gap = world.block(worldX: stampAnchor.x + 2, y: stampAnchor.y, worldZ: stampAnchor.z)
        let wire = world.block(worldX: stampAnchor.x + 3, y: stampAnchor.y, worldZ: stampAnchor.z)
        report.check(
            "each material lands in the same relative cell it was captured from, and the gap stays a gap",
            stone == .stone && planks == .planks && gap == .air && wire == .wireOff,
            "stamped row: \(String(describing: stone)), \(String(describing: planks)), "
                + "\(String(describing: gap)), \(String(describing: wire))"
        )

        // MARK: the same capture stamps again, unspent by the first stamp

        var secondPlacedCells: [(BlockType, Int, Int, Int)] = []
        let secondAnchor = (x: origin.x + 20, y: origin.y, z: origin.z)
        let secondStamp = RegionFill.stamp(
            captured, at: secondAnchor, world: world,
            playerOverlaps: { _, _, _ in false },
            available: { _ in 999 }
        ) { block, x, y, z in secondPlacedCells.append((block, x, y, z)) }
        report.check(
            "the very same capture stamps again at a second anchor — it is not spent by the first stamp",
            secondStamp == 3
                && world.block(worldX: secondAnchor.x, y: secondAnchor.y, worldZ: secondAnchor.z) == .stone
                && world.block(worldX: secondAnchor.x + 3, y: secondAnchor.y, worldZ: secondAnchor.z) == .wireOff,
            "second stamp placed: \(secondStamp) cells"
        )

        // MARK: a bulk-stamped wire cell is not just present, it actually
        // conducts — the same claim mason's-line-lays-wire made for a fill

        world.setBlock(worldX: secondAnchor.x + 4, y: secondAnchor.y, worldZ: secondAnchor.z, to: .leverOn)
        let wireSignals = SignalNetwork()
        let wireFuses = FuseManager()
        wireSignals.leverPlaced(at: SignalNetwork.Key(secondAnchor.x + 4, secondAnchor.y, secondAnchor.z))
        wireSignals.recompute(world: world, fuses: wireFuses)
        let stampedWireState = world.block(worldX: secondAnchor.x + 3, y: secondAnchor.y, worldZ: secondAnchor.z)
        report.check(
            "and a stamped wire cell conducts exactly like hand-placed wire would",
            stampedWireState == .wireOn,
            "wire cell beside a thrown lever reads: \(String(describing: stampedWireState))"
        )

        // MARK: a stamped torch joins the network too — `stamp` hands back
        // every placed cell's coordinates, which is what lets the
        // registration `GameViewController` runs after a torch stamp
        // happen per cell instead of needing a second scan the way a
        // fill's own fix needed one

        let torchSourceOrigin = (x: origin.x + 60, y: origin.y + 1, z: origin.z + 4)
        world.setBlock(worldX: torchSourceOrigin.x, y: torchSourceOrigin.y, worldZ: torchSourceOrigin.z, to: .signalTorchOff)
        let torchCapture = RegionFill.capture(
            RegionFill.region(from: torchSourceOrigin, to: torchSourceOrigin), world: world
        )
        let torchAnchor = (x: origin.x + 62, y: origin.y + 1, z: origin.z + 4)
        let torchSignals = SignalNetwork()
        let torchFuses = FuseManager()
        let torchStamped = RegionFill.stamp(
            torchCapture, at: torchAnchor, world: world,
            playerOverlaps: { _, _, _ in false },
            available: { _ in 999 }
        ) { block, x, y, z in
            if block.isSignalTorch { torchSignals.torchPlaced(at: SignalNetwork.Key(x, y, z)) }
        }
        torchSignals.recompute(world: world, fuses: torchFuses)
        torchSignals.updateTorches(world: world, fuses: torchFuses, dt: SignalNetwork.torchDelay)
        let stampedTorchState = world.block(worldX: torchAnchor.x, y: torchAnchor.y, worldZ: torchAnchor.z)
        report.check(
            "and a stamped torch actually joins the network and lights unpowered, same as a hand-placed one",
            torchStamped == 1 && stampedTorchState == .signalTorchOn && torchSignals.torchCells.count == 1,
            "stamped: \(torchStamped), state: \(String(describing: stampedTorchState)), "
                + "registered: \(torchSignals.torchCells.count)"
        )

        // MARK: material runs out per block type, not as one shared pool —
        // a farmhouse missing planks still gets its stone walls

        let mixedOrigin = (x: origin.x, y: origin.y + 1, z: origin.z + 10)
        for step in 0..<3 {
            world.setBlock(
                worldX: mixedOrigin.x + step, y: mixedOrigin.y, worldZ: mixedOrigin.z, to: .stone, remesh: false
            )
        }
        for step in 3..<6 {
            world.setBlock(
                worldX: mixedOrigin.x + step, y: mixedOrigin.y, worldZ: mixedOrigin.z, to: .planks, remesh: false
            )
        }
        let mixedBox = RegionFill.region(
            from: mixedOrigin, to: (x: mixedOrigin.x + 5, y: mixedOrigin.y, z: mixedOrigin.z)
        )
        let mixedCapture = RegionFill.capture(mixedBox, world: world)
        let mixedAnchor = (x: origin.x + 30, y: origin.y, z: origin.z)
        var perMaterialCounts: [BlockType: Int] = [:]
        let mixedStamped = RegionFill.stamp(
            mixedCapture, at: mixedAnchor, world: world,
            playerOverlaps: { _, _, _ in false },
            available: { block in block == .stone ? 1 : 999 }
        ) { block, _, _, _ in perMaterialCounts[block, default: 0] += 1 }
        report.check(
            "running out of one material stops only that material's cells, not the whole stamp",
            mixedStamped == 4 && perMaterialCounts[.stone] == 1 && perMaterialCounts[.planks] == 3,
            "placed: \(mixedStamped) (want 4 = 1 stone + 3 planks), stone: \(perMaterialCounts[.stone] ?? 0), "
                + "planks: \(perMaterialCounts[.planks] ?? 0)"
        )

        // MARK: the player's own cell and anything already occupied are
        // skipped rather than refusing the whole stamp

        let blockedAnchor = (x: origin.x + 40, y: origin.y, z: origin.z)
        // The wire cell's target is already occupied by something a stamp
        // can't replace — the same guard `fill` leans on.
        world.setBlock(
            worldX: blockedAnchor.x + 3, y: blockedAnchor.y, worldZ: blockedAnchor.z, to: .obsidian, remesh: false
        )
        let overlapStamped = RegionFill.stamp(
            captured, at: blockedAnchor, world: world,
            playerOverlaps: { x, y, z in x == blockedAnchor.x + 1 && y == blockedAnchor.y && z == blockedAnchor.z },
            available: { _ in 999 }
        ) { _, _, _, _ in }
        report.check(
            "the player's own cell and an already-occupied one are skipped, not a reason to stamp nothing",
            overlapStamped == 1
                && world.block(worldX: blockedAnchor.x, y: blockedAnchor.y, worldZ: blockedAnchor.z) == .stone
                && world.block(worldX: blockedAnchor.x + 1, y: blockedAnchor.y, worldZ: blockedAnchor.z) != .planks
                && world.block(worldX: blockedAnchor.x + 3, y: blockedAnchor.y, worldZ: blockedAnchor.z) == .obsidian,
            "placed: \(overlapStamped) of 3 (the player's own cell and the occupied one both held back)"
        )

        // MARK: a chest is never part of a capture, so a stamp can never
        // duplicate one, let alone one with something in it

        let chestOrigin = (x: origin.x + 50, y: origin.y, z: origin.z)
        world.setBlock(worldX: chestOrigin.x, y: chestOrigin.y, worldZ: chestOrigin.z, to: .stone, remesh: false)
        world.setBlock(worldX: chestOrigin.x + 1, y: chestOrigin.y, worldZ: chestOrigin.z, to: .chest, remesh: false)
        let chestBox = RegionFill.region(from: chestOrigin, to: (x: chestOrigin.x + 1, y: chestOrigin.y, z: chestOrigin.z))
        let chestCapture = RegionFill.capture(chestBox, world: world)
        report.check(
            "isBulkFillable keeps a chest out of a capture the same way it keeps it out of a fill",
            chestCapture.cells.count == 1 && chestCapture.cells[0].block == .stone,
            "cells captured: \(chestCapture.cells.count) (want 1, the stone only)"
        )
        let chestStamped = RegionFill.stamp(
            chestCapture, at: (x: origin.x + 55, y: origin.y, z: origin.z), world: world,
            playerOverlaps: { _, _, _ in false }, available: { _ in 999 }
        ) { _, _, _, _ in }
        report.check(
            "so stamping that capture never places a second chest",
            chestStamped == 1,
            "cells stamped: \(chestStamped) (want 1, the stone only, no chest anywhere)"
        )

        // MARK: a capture past the cap stamps nothing rather than stalling

        let hugeBlueprint = RegionFill.Blueprint(
            cells: (0..<(RegionFill.maxVolume + 1)).map { (dx: $0, dy: 0, dz: 0, block: BlockType.stone) }
        )
        let hugeStamped = RegionFill.stamp(
            hugeBlueprint, at: (x: 0, y: 0, z: 0), world: world,
            playerOverlaps: { _, _, _ in false }, available: { _ in 999_999 }
        ) { _, _, _, _ in }
        report.check(
            "a capture past the cap stamps nothing rather than placing an unbounded structure",
            hugeStamped == 0,
            "cells in the oversized blueprint: \(hugeBlueprint.cells.count), cap: \(RegionFill.maxVolume)"
        )

        // MARK: the recipe — a mason's line bound in diamond and iron,
        // needing the table a mason's line itself never did

        var grid = CraftingGrid(size: 3)
        grid[0] = ItemStack(.diamond)
        grid[1] = ItemStack(.masonLine)
        grid[2] = ItemStack(.diamond)
        grid[4] = ItemStack(.ironIngot)
        let crafted = RecipeBook.match(grid)
        report.check(
            "a mason's line, two diamonds and an iron ingot craft a blueprint at a table",
            crafted?.type == .blueprint && crafted?.count == 1,
            "result: \(String(describing: crafted))"
        )
        let twoByTwo = CraftingGrid(size: 2)
        report.check(
            "and it needs the 3×3 table — it will not fit the everyday grid at all",
            RecipeBook.all.first { $0.output.type == .blueprint }?.fits(gridSize: twoByTwo.size) == false,
            "blueprint recipe fits a 2×2 grid: "
                + "\(String(describing: RecipeBook.all.first { $0.output.type == .blueprint }?.fits(gridSize: 2)))"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the blueprint\n"
            : "[check] all passed — the blueprint\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

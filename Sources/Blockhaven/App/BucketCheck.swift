import Foundation

/// Headless proof of the first item that lets a player carry a piece of
/// the world somewhere else rather than mining, placing or eating it: a
/// bucket against standing water becomes a water bucket, and a water
/// bucket empties into wherever it's aimed, each turning into the other
/// rather than being consumed or minted.
///
/// `BLOCKHAVEN_CHECK_BUCKET=1`. Exits nonzero if any line fails.
enum BucketCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_BUCKET"] != nil
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
        world.forceGenerate(World.chunkCoord(forWorldX: origin.x, worldZ: origin.z))

        // MARK: filling — only standing water gives up a bucketful

        world.setBlock(worldX: origin.x, y: origin.y, worldZ: origin.z, to: .water, remesh: false)
        let filled = BucketInteraction.fill(at: (origin.x, origin.y, origin.z), world: world)
        report.check(
            "an empty bucket against standing water fills, and the water goes with it",
            filled && world.block(worldX: origin.x, y: origin.y, worldZ: origin.z) == .air,
            "filled: \(filled), cell now: \(String(describing: world.block(worldX: origin.x, y: origin.y, worldZ: origin.z)))"
        )
        world.setBlock(worldX: origin.x + 1, y: origin.y, worldZ: origin.z, to: .stone, remesh: false)
        let refusedOnStone = BucketInteraction.fill(at: (origin.x + 1, origin.y, origin.z), world: world)
        report.check(
            "and nothing else in the world gives one up",
            !refusedOnStone && world.block(worldX: origin.x + 1, y: origin.y, worldZ: origin.z) == .stone,
            "filled against stone: \(refusedOnStone)"
        )

        // MARK: fluid picking — bucket raycast stops at water and lava while ordinary picking aims through

        world.setBlock(worldX: origin.x, y: origin.y - 1, worldZ: origin.z, to: .stone, remesh: false)
        world.setBlock(worldX: origin.x, y: origin.y, worldZ: origin.z, to: .water, remesh: false)
        for dy in 1...3 {
            world.setBlock(worldX: origin.x, y: origin.y + dy, worldZ: origin.z, to: .air, remesh: false)
        }
        let aimOrigin = Vector3(CGFloat(origin.x) + 0.5, CGFloat(origin.y) + 2.5, CGFloat(origin.z) + 0.5)
        let aimDir = Vector3(0, -1, 0)
        let standardHit = VoxelRaycast.cast(from: aimOrigin, direction: aimDir, maxDistance: 5, world: world)
        let fluidHit = VoxelRaycast.cast(from: aimOrigin, direction: aimDir, maxDistance: 5, world: world) {
            $0.occupiesCell || $0.isFluid
        }
        report.check(
            "ordinary picking sails through water",
            standardHit == nil || standardHit?.block != .water,
            "standard hit: \(String(describing: standardHit?.block))"
        )
        report.check(
            "the bucket raycast stops at water to scoop it",
            fluidHit?.block == .water && fluidHit?.blockX == origin.x && fluidHit?.blockY == origin.y && fluidHit?.blockZ == origin.z,
            "fluid hit: \(String(describing: fluidHit?.block)) at \(String(describing: fluidHit.map { ($0.blockX, $0.blockY, $0.blockZ) }))"
        )
        if let fluidHit {
            let scooped = BucketInteraction.fillFluid(at: (fluidHit.blockX, fluidHit.blockY, fluidHit.blockZ), world: world)
            report.check(
                "scooping the raycast hit produces a water bucket and clears the cell",
                scooped == .waterBucket && world.block(worldX: origin.x, y: origin.y, worldZ: origin.z) == .air,
                "scooped: \(String(describing: scooped)), cell now: \(String(describing: world.block(worldX: origin.x, y: origin.y, worldZ: origin.z)))"
            )
        }
        world.setBlock(worldX: origin.x, y: origin.y, worldZ: origin.z, to: .lava, remesh: false)
        let lavaFluidHit = VoxelRaycast.cast(from: aimOrigin, direction: aimDir, maxDistance: 5, world: world) {
            $0.occupiesCell || $0.isFluid
        }
        if let lavaFluidHit {
            let scoopedLava = BucketInteraction.fillFluid(at: (lavaFluidHit.blockX, lavaFluidHit.blockY, lavaFluidHit.blockZ), world: world)
            report.check(
                "and scooping lava produces a lava bucket and clears the cell",
                scoopedLava == .lavaBucket && world.block(worldX: origin.x, y: origin.y, worldZ: origin.z) == .air,
                "scooped lava: \(String(describing: scoopedLava)), cell now: \(String(describing: world.block(worldX: origin.x, y: origin.y, worldZ: origin.z)))"
            )
        }

        // MARK: emptying — the same replaceability every other placement uses

        let emptyCell = (x: origin.x + 2, y: origin.y, z: origin.z)
        world.setBlock(worldX: emptyCell.x, y: emptyCell.y, worldZ: emptyCell.z, to: .air, remesh: false)
        let placed = BucketInteraction.empty(at: emptyCell, world: world, playerOverlaps: false)
        report.check(
            "a full bucket empties into open air",
            placed && world.block(worldX: emptyCell.x, y: emptyCell.y, worldZ: emptyCell.z) == .water,
            "placed: \(placed), cell now: \(String(describing: world.block(worldX: emptyCell.x, y: emptyCell.y, worldZ: emptyCell.z)))"
        )
        let blockedByPlayer = BucketInteraction.empty(at: emptyCell, world: world, playerOverlaps: true)
        report.check(
            "but never into the cell the player is standing in",
            !blockedByPlayer,
            "placed while overlapping: \(blockedByPlayer)"
        )
        let solidCell = (x: origin.x + 1, y: origin.y, z: origin.z)
        let blockedBySolid = BucketInteraction.empty(at: solidCell, world: world, playerOverlaps: false)
        report.check(
            "or into a cell something solid already occupies",
            !blockedBySolid && world.block(worldX: solidCell.x, y: solidCell.y, worldZ: solidCell.z) == .stone,
            "placed against stone: \(blockedBySolid)"
        )

        // MARK: the item pair itself

        report.check(
            "an empty and a full bucket are two different items, neither stacking",
            ItemType.bucket.maxStack == 1 && ItemType.waterBucket.maxStack == 1 && ItemType.bucket != .waterBucket,
            "bucket stack: \(ItemType.bucket.maxStack), water bucket stack: \(ItemType.waterBucket.maxStack)"
        )

        // MARK: the recipe

        let grid = CraftingGrid(size: 3)
        var withIron = grid
        withIron[0] = ItemStack(.ironIngot)
        withIron[2] = ItemStack(.ironIngot)
        withIron[4] = ItemStack(.ironIngot)
        let crafted = RecipeBook.match(withIron)
        report.check(
            "three iron ingots in a V craft a bucket",
            crafted?.type == .bucket && crafted?.count == 1,
            "result: \(String(describing: crafted))"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the bucket\n"
            : "[check] all passed — the bucket\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

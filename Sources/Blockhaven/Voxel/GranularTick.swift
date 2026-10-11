import Foundation

/// Core granular physics engine for Milestone 3 (sand and gravel falling gravity).
enum GranularTick {

    /// Represents a single granular block movement.
    struct Move: Equatable {
        let block: BlockType
        let x: Int
        let fromY: Int
        let toY: Int
        let z: Int
        var fallDistance: Int { fromY - toY }

        init(block: BlockType, x: Int, fromY: Int, toY: Int, z: Int) {
            self.block = block
            self.x = x
            self.fromY = fromY
            self.toY = toY
            self.z = z
        }
    }

    /// Result summary of a settling operation.
    /// One piece of scenery a falling block took out on its way past.
    struct Wreckage {
        var block: BlockType
        var x: Int
        var y: Int
        var z: Int
    }

    struct SettleResult {
        var blocksMoved: Int = 0
        var columnsAffected: Int = 0
        var maxFallDistance: Int = 0
        var moves: [Move] = []
        /// Rails, wire, levers, plates and flowers a fall passed through
        /// and destroyed. Reported rather than acted on, the same way
        /// `moves` is: whether the player gets these back is a question
        /// about who was standing there, which this has no way to answer.
        var destroyed: [Wreckage] = []

        init() {}
    }

    /// Determines whether a falling granular block can pass through / displace the block.
    @inline(__always)
    static func canFallThrough(_ block: BlockType) -> Bool {
        switch block {
        case .air, .water, .lava:
            return true
        default:
            // A door reads as "not solid" the moment it is open, and a bed
            // always does. That is a fact about *walking* through them, not
            // about falling through them, and both are two cells that only
            // mean anything together. The pass-through cleanup below works
            // one cell at a time and never goes near
            // `ShapedPlacement.removalCells`, so treating them as holes let
            // a single block of sand dropped on an open doorway delete the
            // top half of the door and leave the bottom half standing —
            // exactly the orphan `removalCells` exists to prevent.
            if block.isDoor || block.isBed { return false }
            return !block.isSolid || block.isDelicateScenery
        }
    }

    /// Settles a single vertical column at (worldX, worldZ) from bottom to top.
    ///
    /// `scanTop` is the highest cell an edit is known to have disturbed. The
    /// sweep does not stop there — a stack of sand standing on the
    /// disturbance still has to come down with it — but once it is above
    /// `scanTop` the first non-granular cell ends the column, because
    /// nothing higher could have been destabilised by something that never
    /// reached it. Left at the top of the world it scans everything, which
    /// is what a hand-placed block wants and what every caller but a blast
    /// still asks for.
    @discardableResult
    static func settleColumn(
        in world: World,
        worldX x: Int,
        worldZ z: Int,
        startY: Int = 1,
        scanTop: Int = Chunk.height - 1,
        maxFall: Int = .max,
        remesh: Bool = true
    ) -> SettleResult {
        var result = SettleResult()
        guard startY < Chunk.height else { return result }

        var columnModified = false

        // Bottom-up pass guarantees all lower cavities are filled first
        var y = max(1, startY) - 1
        while true {
            y += 1
            guard y < Chunk.height else { break }
            let currentBlock = world.block(worldX: x, y: y, worldZ: z)
            guard currentBlock.hasGravity else {
                if y > scanTop { break }
                continue
            }

            // Check if cell directly below can be fallen through
            let belowBlock = world.block(worldX: x, y: y - 1, worldZ: z)
            guard canFallThrough(belowBlock) else { continue }

            // Scan downward to find lowest resting cell
            var targetY = y - 1
            while targetY > 0 && canFallThrough(world.block(worldX: x, y: targetY - 1, worldZ: z)) {
                if (y - targetY) >= maxFall { break }
                targetY -= 1
            }

            guard targetY < y else { continue }

            // Clean up any non-fluid scenery passed through on the fall,
            // reporting each one so a caller that has a player to hand can
            // give it back rather than simply vanishing a run of rail.
            for passY in (targetY + 1)..<y {
                let intermediate = world.block(worldX: x, y: passY, worldZ: z)
                if intermediate != .air && intermediate != .water && intermediate != .lava && canFallThrough(intermediate) {
                    result.destroyed.append(
                        Wreckage(block: intermediate, x: x, y: passY, z: z)
                    )
                    world.setBlock(worldX: x, y: passY, worldZ: z, to: .air, remesh: false)
                }
            }

            // Whatever was sitting in the resting cell goes under the
            // block that landed on it. That is the *other* way a fall takes
            // out scenery — the cleanup above only covers what it passed
            // through on the way, and a rail at the bottom of the drop is
            // destroyed by the landing rather than by the passage.
            let landedOn = world.block(worldX: x, y: targetY, worldZ: z)
            if landedOn != .air && landedOn != .water && landedOn != .lava {
                result.destroyed.append(Wreckage(block: landedOn, x: x, y: targetY, z: z))
            }

            // Move the block down
            world.setBlock(worldX: x, y: targetY, worldZ: z, to: currentBlock, remesh: false)
            world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)

            let move = Move(block: currentBlock, x: x, fromY: y, toY: targetY, z: z)
            result.moves.append(move)
            result.blocksMoved += 1
            result.maxFallDistance = max(result.maxFallDistance, move.fallDistance)
            columnModified = true
        }

        if columnModified {
            result.columnsAffected = 1
            if remesh {
                let coord = World.chunkCoord(forWorldX: x, worldZ: z)
                world.markNeedsRemesh(coord, urgent: true)
            }
        }

        return result
    }

    /// Settles all columns in an area around a center point (e.g. post-explosion crater).
    @discardableResult
    static func settleArea(
        in world: World,
        centerX: Int,
        centerY: Int,
        centerZ: Int,
        radius: Int,
        remesh: Bool = true
    ) -> SettleResult {
        var aggregate = SettleResult()
        var touchedChunks: Set<ChunkCoord> = []

        let minX = centerX - radius, maxX = centerX + radius
        let minZ = centerZ - radius, maxZ = centerZ + radius
        let startY = max(1, centerY - radius)
        // An explosion reaches `radius`; nothing above that was touched, so
        // the sweep stops at the first settled cell above it rather than
        // reading every column to the roof of the world. A crater at y 70
        // was scanning 120 cells of empty sky per column, on every one of
        // the several hundred blasts a frame can carry.
        let scanTop = min(Chunk.height - 1, centerY + radius)

        for z in minZ...maxZ {
            for x in minX...maxX {
                let dx = x - centerX, dz = z - centerZ
                guard dx * dx + dz * dz <= radius * radius + 1 else { continue }

                let colResult = settleColumn(
                    in: world, worldX: x, worldZ: z,
                    startY: startY, scanTop: scanTop, maxFall: .max, remesh: false
                )
                if colResult.blocksMoved > 0 {
                    aggregate.blocksMoved += colResult.blocksMoved
                    aggregate.columnsAffected += 1
                    aggregate.maxFallDistance = max(aggregate.maxFallDistance, colResult.maxFallDistance)
                    aggregate.moves.append(contentsOf: colResult.moves)
                    aggregate.destroyed.append(contentsOf: colResult.destroyed)
                    touchedChunks.insert(World.chunkCoord(forWorldX: x, worldZ: z))
                }
            }
        }

        if remesh {
            for coord in touchedChunks {
                world.markNeedsRemesh(coord, urgent: true)
            }
        }

        return aggregate
    }

    /// Settles all 256 columns in a given chunk.
    @discardableResult
    static func settleChunk(in world: World, coord: ChunkCoord, remesh: Bool = true) -> SettleResult {
        guard let chunk = world.chunk(at: coord) else { return SettleResult() }
        var aggregate = SettleResult()

        for lz in 0..<Chunk.depth {
            for lx in 0..<Chunk.width {
                let wx = chunk.originX + lx
                let wz = chunk.originZ + lz
                let colResult = settleColumn(in: world, worldX: wx, worldZ: wz, startY: 1, maxFall: .max, remesh: false)
                if colResult.blocksMoved > 0 {
                    aggregate.blocksMoved += colResult.blocksMoved
                    aggregate.columnsAffected += 1
                    aggregate.maxFallDistance = max(aggregate.maxFallDistance, colResult.maxFallDistance)
                    aggregate.moves.append(contentsOf: colResult.moves)
                    aggregate.destroyed.append(contentsOf: colResult.destroyed)
                }
            }
        }

        if remesh && aggregate.blocksMoved > 0 {
            world.markNeedsRemesh(coord, urgent: true)
        }

        return aggregate
    }

    /// The shortest fall that hurts.
    ///
    /// Damage used to start at a fall of one, which is the distance a block
    /// settles when you simply *place* it on uneven ground — so putting a
    /// single block of sand down next to a pig, or under your own feet,
    /// took two half-hearts off for nothing anybody would call an accident.
    /// A fall has to be a fall before it is a crushing.
    static let crushingFallThreshold = 2

    /// Evaluates crushing damage on entities caught under falling granular blocks.
    static func applyCrushingDamage(
        moves: [Move],
        player: PlayerController?,
        playerStats: inout PlayerStats?,
        fizzlers: inout FizzlerManager?,
        skeletons: inout SkeletonManager?,
        animals: inout AnimalManager?
    ) -> Int {
        var entitiesDamaged = 0

        for move in moves where move.fallDistance >= crushingFallThreshold {
            let damage = max(1, min(12, move.fallDistance * 2))

            // Player check
            if let player, player.overlaps(blockX: move.x, y: move.toY, z: move.z) {
                playerStats?.takeDamage(damage, mitigable: true)
                entitiesDamaged += 1
            }

            // Fizzler check
            if var cm = fizzlers {
                for (id, fizzler) in cm.fizzlers where !fizzler.isDead && !fizzler.hasExploded {
                    if fizzler.overlaps(blockX: move.x, y: move.toY, z: move.z) {
                        _ = cm.damage(id: id, amount: damage, knockback: .zero)
                        entitiesDamaged += 1
                    }
                }
                fizzlers = cm
            }

            // Skeleton check
            if var sm = skeletons {
                for (id, skeleton) in sm.skeletons where !skeleton.isDead {
                    if skeleton.overlaps(blockX: move.x, y: move.toY, z: move.z) {
                        _ = sm.damage(id: id, amount: damage, knockback: .zero)
                        entitiesDamaged += 1
                    }
                }
                skeletons = sm
            }

            // Animal check
            if var am = animals {
                for (id, animal) in am.animals where !animal.isDead {
                    if animal.overlaps(blockX: move.x, y: move.toY, z: move.z) {
                        _ = am.damage(id: id, amount: damage, knockback: .zero)
                        entitiesDamaged += 1
                    }
                }
                animals = am
            }
        }

        return entitiesDamaged
    }
}

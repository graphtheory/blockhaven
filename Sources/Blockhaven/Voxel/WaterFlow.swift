import Foundation

/// What a freshly placed water source does next: finds its own way
/// downhill and pools at the bottom, the same as a bucket poured out
/// anywhere real does.
///
/// Not a live simulation — there is no per-frame water tick anywhere in
/// the game, and one is not needed for this: a stream is carved once,
/// when it is poured, the same way `BlockLight` computes a lamp's reach
/// once when it goes up rather than re-walking it every frame the lamp
/// stays lit. A block is still just a block; nothing here remembers that
/// a given cell of water arrived by flowing rather than by hand.
enum WaterFlow {
    /// How far water may spread sideways from the last cell it had to stop
    /// falling at, before it stops rather than crossing an entire flat
    /// world from one bucket. Falling resets this to zero: the fall itself
    /// costs nothing, only the pool at the bottom of it does — the same
    /// shape the original's own decreasing fluid levels give, without needing
    /// a block variant for every level.
    static let maxHorizontalReach = 5

    /// A hard ceiling on how many cells one placement may flood, so a
    /// bucket poured into an open cave mouth cascades rather than fills
    /// the whole system it happened to find.
    static let maxCells = 200

    private struct Node {
        var x: Int
        var y: Int
        var z: Int
        var horizontalReach: Int
    }

    private static let sideSteps: [(x: Int, z: Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]

    /// Spreads outward and downward from a source that was just placed at
    /// `origin`. Every cell water actually reaches is written through
    /// `World.setBlock` like any other placement, so it lights, remeshes
    /// and journals exactly the way a player's own hand would have done it
    /// one block at a time.
    static func spread(from origin: (x: Int, y: Int, z: Int), world: World) {
        var queue = [Node(x: origin.x, y: origin.y, z: origin.z, horizontalReach: 0)]
        var head = 0
        var placed = 0

        while head < queue.count, placed < maxCells {
            let node = queue[head]
            head += 1

            // Gravity first, and it never runs out: only the pool a fall
            // ends in counts against the spread cap, not the fall itself.
            let below = node.y - 1
            if below >= 0 {
                let belowBlock = world.block(worldX: node.x, y: below, worldZ: node.z)
                if belowBlock == .air {
                    if world.setBlock(worldX: node.x, y: below, worldZ: node.z, to: .water) {
                        placed += 1
                        queue.append(Node(x: node.x, y: below, z: node.z, horizontalReach: 0))
                    }
                    continue
                }
                // Water meeting lava is the one interaction nobody has to
                // be told about: the melt seizes solid the instant it's
                // touched, so the cell that killed the flow becomes a wall
                // rather than a puddle. Counted against the same cap
                // everything else here is, but never enqueued — the
                // obsidian it becomes is exactly as solid as the stone the
                // stream was already stopping at.
                if belowBlock == .lava, placed < maxCells {
                    if world.setBlock(worldX: node.x, y: below, worldZ: node.z, to: .obsidian) {
                        placed += 1
                    }
                    continue
                }
            }

            // Nothing to fall into, so it spreads across whatever it is
            // resting on — until it has gone as far as this stretch is
            // allowed to.
            guard node.horizontalReach < maxHorizontalReach else { continue }
            for step in sideSteps {
                guard placed < maxCells else { break }
                let nx = node.x + step.x, nz = node.z + step.z
                let sideBlock = world.block(worldX: nx, y: node.y, worldZ: nz)
                if sideBlock == .lava {
                    if world.setBlock(worldX: nx, y: node.y, worldZ: nz, to: .obsidian) { placed += 1 }
                    continue
                }
                guard sideBlock == .air else { continue }
                if world.setBlock(worldX: nx, y: node.y, worldZ: nz, to: .water) {
                    placed += 1
                    queue.append(Node(x: nx, y: node.y, z: nz, horizontalReach: node.horizontalReach + 1))
                }
            }
        }
    }
}

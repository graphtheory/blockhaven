import Foundation

/// Every sapling planted in the world, ticking toward the tree it grows
/// into — the same arrangement `CropStore` uses for wheat, and for the
/// same reason: a block is a byte and cannot count seconds.
///
/// Where a crop swaps itself for the next stage of itself, a sapling swaps
/// itself for dozens of blocks it did not place, all at once — see
/// `GameViewController.growTree`, which reads a matured cell here and hands
/// off to `WorldGenerator.treeBlocks`, the exact builder that plants a wild
/// wood in the first place. Nothing about the shape of the resulting tree
/// is invented twice.
final class SaplingStore {
    struct Key: Hashable {
        var x: Int
        var y: Int
        var z: Int

        init(_ x: Int, _ y: Int, _ z: Int) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    /// Seconds a sapling stands before it grows. Longer than a wheat
    /// stage — a tree is the bigger promise, wood enough all at once
    /// rather than a harvest that regrows in place — but still well inside
    /// a single sitting, the same reason `CropStore.stageSeconds` is what
    /// it is: this is a game played in bursts.
    static let growSeconds: Double = 50.0

    private(set) var elapsed: [Key: Double] = [:]

    func planted(at key: Key) { elapsed[key] = 0 }
    func remove(at key: Key) { elapsed.removeValue(forKey: key) }
    var isEmpty: Bool { elapsed.isEmpty }

    /// Drops every planting no longer standing where it says it is — the
    /// same sweep `CropStore.prune` runs, and needed for the same reason:
    /// an explosion takes a cell out without asking this store first.
    func prune(where blockIsGone: (Key) -> Bool) {
        for key in elapsed.keys where blockIsGone(key) {
            elapsed.removeValue(forKey: key)
        }
    }

    /// One frame for every tracked sapling: banks daylight toward growth
    /// and hands back the cells that matured, for the caller to grow a
    /// tree over — the same split `CropStore.tick` uses, where this store
    /// answers the clock and `GameViewController` is the only thing that
    /// ever touches the world.
    ///
    /// Gated on open sky for the same reason a crop is: a sapling potted
    /// in a basement should wait exactly as long as a seed would, not grow
    /// a tree through somebody's roof.
    ///
    /// `isRaining` reuses `CropStore.rainGrowthMultiplier` rather than a
    /// second constant of its own: a felled forest regrows on the same
    /// weather clock a field ripens on, not a rule a storm happens to skip
    /// because nobody carried it over to the other grower.
    func tick(dt: Double, world: World, isRaining: Bool = false) -> [Key] {
        var matured: [Key] = []
        for (key, time) in elapsed {
            guard world.block(worldX: key.x, y: key.y, worldZ: key.z).isSapling else {
                elapsed.removeValue(forKey: key)
                continue
            }
            let hasLight = world.isSkyOpen(worldX: key.x, y: key.y, worldZ: key.z)
                || world.lightLevel(worldX: key.x, y: key.y, worldZ: key.z) >= 9
            guard hasLight else { continue }
            let multiplier = isRaining ? CropStore.rainGrowthMultiplier : 1.0
            let next = time + dt * multiplier
            // Epsilon for the same reason `CropStore.tick` needs one: the
            // last frame of the wait could miss its own threshold by a
            // float's width of drift.
            if next >= SaplingStore.growSeconds - 1e-9 {
                elapsed.removeValue(forKey: key)
                matured.append(key)
            } else {
                elapsed[key] = next
            }
        }
        return matured
    }
}

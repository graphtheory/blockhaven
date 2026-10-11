import Foundation

/// Every crop planted in the world, ticking toward its next growth stage.
///
/// A block is a byte and remembers nothing between frames, so — the same
/// reason a furnace's fire lives in `FurnaceStore` beside the world rather
/// than in it — how long a planting has stood in daylight lives here, keyed
/// by cell. This is the first thing in the game that changes because time
/// passed rather than because a player or an explosion touched it.
final class CropStore {
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

    /// Seconds one stage takes to ripen into the next, in daylight. Three
    /// stages between a planted seed and a harvest, so a crop planted at
    /// the start of a session is ready well before the end of one — this
    /// is a game a child plays in bursts, not one that rewards leaving it
    /// running overnight.
    static let stageSeconds: Double = 20.0

    private(set) var elapsed: [Key: Double] = [:]

    func planted(at key: Key) { elapsed[key] = 0 }
    func remove(at key: Key) { elapsed.removeValue(forKey: key) }
    var isEmpty: Bool { elapsed.isEmpty }

    /// Drops every planting no longer standing where it says it is — the
    /// same sweep `FurnaceStore.prune` runs, and needed for the same
    /// reason: an explosion takes a cell out without asking this store
    /// first.
    func prune(where blockIsGone: (Key) -> Bool) {
        for key in elapsed.keys where blockIsGone(key) {
            elapsed.removeValue(forKey: key)
        }
    }

    /// How much faster a planting banks its stage while it rains — the
    /// same field, wet rather than merely lit, grows a third again as
    /// fast. Not a second gate beside `isSkyOpen`: rain speeds a field
    /// already growing rather than starting one that wasn't, so a planting
    /// shut away from the sky stays shut away from the sky, storm or not.
    static let rainGrowthMultiplier: Double = 1.35

    /// How much faster a planting banks its stage with standing water
    /// somewhere near the farmland it's rooted in — half again as fast,
    /// stacking with rain rather than replacing it, so a canal dug to a
    /// field in a storm is the fastest ground in the game to farm on. No
    /// block anywhere says this; a field someone bothered to irrigate
    /// simply outgrows one that wasn't, which is the whole reward for
    /// noticing and the whole reason to dig the canal in the first place.
    static let hydratedGrowthMultiplier: Double = 1.5
    /// The classic farmland hydration reach — far enough that one canal
    /// waters a real field rather than one furrow, close enough that
    /// irrigating still means routing water *to* the field, not just
    /// living near an ocean.
    private static let hydrationReach = 4

    /// Whether standing water sits anywhere within reach of the farmland a
    /// planting is rooted in — one y below the crop itself, the level the
    /// tilled soil and any canal both sit at.
    private static func isHydrated(at key: Key, world: World) -> Bool {
        world.isFarmlandHydrated(worldX: key.x, y: key.y - 1, worldZ: key.z, reach: hydrationReach)
    }

    /// One frame for every tracked planting: banks daylight toward the next
    /// stage and hands back the cells that ripened enough to advance, for
    /// the caller to swap the block itself — the same arrangement a
    /// furnace's fire uses, where this store answers the clock and
    /// `GameViewController` is the only thing that ever touches the world.
    ///
    /// A planting under a roof simply waits: `isSkyOpen` gates every
    /// second banked, so the one system already deciding whether a cell
    /// sees the sky is the same one deciding whether anything grows in
    /// it — a field still has to be a field, open to the sky, not just a
    /// patch of tilled dirt in a basement.
    func tick(dt: Double, world: World, isRaining: Bool = false) -> [Key] {
        var advanced: [Key] = []
        for (key, time) in elapsed {
            let block = world.block(worldX: key.x, y: key.y, worldZ: key.z)
            guard block.isCrop, block != .wheatStage3 else {
                elapsed.removeValue(forKey: key)
                continue
            }
            let hasLight = world.isSkyOpen(worldX: key.x, y: key.y, worldZ: key.z)
                || world.lightLevel(worldX: key.x, y: key.y, worldZ: key.z) >= 9
            guard hasLight else { continue }
            var multiplier = 1.0
            if isRaining { multiplier *= CropStore.rainGrowthMultiplier }
            if CropStore.isHydrated(at: key, world: world) { multiplier *= CropStore.hydratedGrowthMultiplier }
            let bankedSeconds = dt * multiplier
            let next = time + bankedSeconds
            // Epsilon for the same reason `FurnaceState.tick` needs one:
            // repeated float addition of the same per-frame `dt` drifts by
            // a few `1e-14` from the exact sum, and without slack the last
            // frame of a stage could miss its own threshold by that much.
            if next >= CropStore.stageSeconds - 1e-9 {
                elapsed[key] = 0
                advanced.append(key)
            } else {
                elapsed[key] = next
            }
        }
        return advanced
    }
}

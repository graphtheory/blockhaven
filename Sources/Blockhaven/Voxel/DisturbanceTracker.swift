import Foundation

/// Tracks industrial noise, seismic vibrations, and machinery activity across
/// world chunks, scaling hostile mob awareness, attack speed, and spawn density.
///
/// In quiet wilderness, hostile mobs adhere to their baseline sight radius (16–18 blocks).
/// When factories burn fuel in furnaces, miners excavate stone, or TNT blasts fracture rock,
/// local chunk disturbance accumulates up to 100.0, expanding hostile mob detection range
/// up to 32 blocks and intensifying nocturnal danger.
final class DisturbanceTracker {
    static let maxDisturbance: Double = 100.0
    static let decayRate: Double = 1.0 // Units dissipated per second of quiet

    // Activity cost weights
    static let furnaceBurnRate: Double = 2.0 // Per second of burning (or ~0.033 per tick)
    static let explosionPulse: Double = 30.0  // Per TNT / fizzler detonation
    static let blockBreakCost: Double = 1.5   // Per block mined
    static let hopperTransferCost: Double = 0.5 // Per item moved through conveyor

    /// How high one piece of *sustained* machinery — a furnace burning, a
    /// conveyor running — may raise a chunk by itself. Callers that know
    /// they are speaking for several multiply it.
    ///
    /// Decay here is linear, so a source stronger than `decayRate` has no
    /// equilibrium to settle at: it simply climbs until something stops it.
    /// Nothing did. One lit furnace puts out 2.0/s against 1.0/s of decay,
    /// so it reached 100 in a hundred seconds and held the chunk there for
    /// as long as it burned — doubling every hostile's sight range and both
    /// spawners' rates around a base, for the crime of smelting a stack of
    /// iron, with nothing on screen to explain it.
    ///
    /// A ceiling rather than a slower rate, because the rate is what makes
    /// a working factory *feel* loud and that part was right. Scaling it by
    /// how many machines are actually running keeps the gradient that made
    /// the idea worth having: one furnace is a nuisance, a smelting hall is
    /// still genuinely dangerous. Pulses — an explosion, a pickaxe — are
    /// deliberately exempt and still reach the top on their own: a blast
    /// should be able to wake the whole neighbourhood.
    static let machineryCeiling: Double = 30.0

    private(set) var chunkLevels: [ChunkCoord: Double] = [:]

    init() {}

    /// Records disturbance at the specified world coordinate, diffusing 20% to cardinal neighbors.
    func record(atWorldX x: Int, worldZ z: Int, amount: Double, ceiling: Double = maxDisturbance) {
        guard amount > 0 else { return }
        let center = World.chunkCoord(forWorldX: x, worldZ: z)
        record(inChunk: center, amount: amount, ceiling: ceiling)

        let spill = amount * 0.2
        if spill > 0.05 {
            record(inChunk: ChunkCoord(x: center.x - 1, z: center.z), amount: spill, ceiling: ceiling)
            record(inChunk: ChunkCoord(x: center.x + 1, z: center.z), amount: spill, ceiling: ceiling)
            record(inChunk: ChunkCoord(x: center.x, z: center.z - 1), amount: spill, ceiling: ceiling)
            record(inChunk: ChunkCoord(x: center.x, z: center.z + 1), amount: spill, ceiling: ceiling)
        }
    }

    /// Records disturbance directly in a chunk coordinate.
    ///
    /// `ceiling` caps what *this* source may raise the chunk to. It never
    /// lowers a chunk something louder already raised — a furnace ticking
    /// beside a fresh crater leaves the crater's reading alone rather than
    /// dragging it back down to the machinery cap.
    func record(inChunk coord: ChunkCoord, amount: Double, ceiling: Double = maxDisturbance) {
        guard amount > 0 else { return }
        let current = chunkLevels[coord] ?? 0.0
        let cap = min(Self.maxDisturbance, max(ceiling, current))
        let next = min(cap, current + amount)
        guard next > current else { return }
        chunkLevels[coord] = next
    }

    /// Records industrial smelting disturbance from a furnace.
    ///
    /// `ceiling` is `machineryCeiling` times however many furnaces the
    /// caller is speaking for — see `GameViewController.updateFurnaces`,
    /// which batches a chunk's burning furnaces into one call.
    func recordSmelting(
        at key: FurnaceStore.Key,
        amount: Double = furnaceBurnRate,
        ceiling: Double = machineryCeiling
    ) {
        record(atWorldX: key.x, worldZ: key.z, amount: amount, ceiling: ceiling)
    }

    /// Records excavation disturbance from breaking a block.
    func recordBreak(atWorldX x: Int, worldZ z: Int, amount: Double = blockBreakCost) {
        record(atWorldX: x, worldZ: z, amount: amount)
    }

    /// Records seismic shockwave from an explosion.
    func recordExplosion(at center: Vector3, amount: Double = explosionPulse) {
        record(atWorldX: Int(center.x), worldZ: Int(center.z), amount: amount)
    }

    /// Explicitly sets the disturbance level for a chunk (used in deterministic tests).
    func setLevel(_ level: Double, inChunk coord: ChunkCoord) {
        let clamped = min(max(level, 0.0), Self.maxDisturbance)
        if clamped <= 0.001 {
            chunkLevels.removeValue(forKey: coord)
        } else {
            chunkLevels[coord] = clamped
        }
    }

    /// Returns disturbance level for the chunk containing (worldX, worldZ).
    func level(atWorldX x: Int, worldZ z: Int) -> Double {
        let coord = World.chunkCoord(forWorldX: x, worldZ: z)
        return chunkLevels[coord] ?? 0.0
    }

    /// Returns disturbance level for a specific chunk coordinate.
    func level(inChunk coord: ChunkCoord) -> Double {
        chunkLevels[coord] ?? 0.0
    }

    /// Alias for `level(inChunk:)`.
    func disturbance(inChunk coord: ChunkCoord) -> Double {
        level(inChunk: coord)
    }

    /// Alias for `level(atWorldX:worldZ:)`.
    func disturbance(atWorldX x: Int, worldZ z: Int) -> Double {
        level(atWorldX: x, worldZ: z)
    }

    /// Calculates mob sight range scaled by local chunk disturbance (from baseRange up to 32 blocks).
    func effectiveSightRange(baseRange: CGFloat, inChunk coord: ChunkCoord) -> CGFloat {
        let dist = level(inChunk: coord)
        let factor = 1.0 + min(max(dist, 0.0), Self.maxDisturbance) / Self.maxDisturbance
        return min(32.0, baseRange * CGFloat(factor))
    }

    /// Calculates mob sight range scaled by local chunk disturbance at world coordinates.
    func effectiveSightRange(baseRange: CGFloat, atWorldX x: Int, worldZ z: Int) -> CGFloat {
        let coord = World.chunkCoord(forWorldX: x, worldZ: z)
        return effectiveSightRange(baseRange: baseRange, inChunk: coord)
    }

    /// Decays active disturbance across all chunks and prunes silent chunks.
    func tick(dt: Double) {
        guard dt > 0, !chunkLevels.isEmpty else { return }
        let decay = Self.decayRate * dt
        for (coord, val) in chunkLevels {
            let next = val - decay
            if next <= 0.001 {
                chunkLevels.removeValue(forKey: coord)
            } else {
                chunkLevels[coord] = next
            }
        }
    }

    /// Resets all disturbance to pristine zero.
    func reset() {
        chunkLevels.removeAll()
    }
}

import Foundation

/// Spawns, updates and fires the skeleton population.
///
/// Deliberately built on top of `FizzlerManager`'s own darkness gate and
/// distance ramp — `FizzlerManager.canSpawn` and `.dangerScale` — rather
/// than a second copy of either. Both mobs answer to the same night, the
/// same torch, the same distance from home and the same storm; a skeleton
/// is a different *shape* of threat, not a different *rule* for when a
/// threat exists at all.
struct SkeletonManager {
    /// Half the fizzler's cap — the two populations share the night, and
    /// doubling the total hostile count on top of what already existed
    /// would be pressure added by counting rather than by design.
    static let populationCap = 4
    static let minimumSpawnDistance: CGFloat = 20
    static let maximumSpawnDistance: CGFloat = 44
    static let despawnDistance: CGFloat = 96
    static let spawnInterval: Double = 6.0

    /// One shot loosed this frame, for the caller to turn into player
    /// damage and a camera cue — same shape as `FizzlerManager.Explosion`.
    struct Shot {
        let origin: Vector3
        let damage: Int
    }

    /// What one arrow costs at this distance from spawn — the same ramp
    /// `trySpawn` reads to decide how many skeletons and how often, reused
    /// so a shot hurts more the farther out it's loosed, not just more
    /// often. See `FizzlerManager.blastDamageMaximum` for the twin change
    /// on the blast side; a named function here for the same reason it's
    /// named there, so a test can point at the arithmetic directly.
    static func shotDamage(distanceFromSpawn: CGFloat) -> Int {
        Int((Double(Skeleton.shotDamage) * FizzlerManager.dangerScale(distanceFromSpawn: distanceFromSpawn)).rounded())
    }

    private(set) var skeletons: [Int: Skeleton] = [:]
    private var nextID = 0
    private var spawnTimer: Double = 0
    private var rng: SeededGenerator

    var enabled: Bool

    /// The Moon's version of the population: the garden's old maintenance
    /// sentries. They do not burn in the sun and do not wait for night —
    /// they come where there is live wire, mistaking it for a fault, and
    /// power down and leave when the wire goes dead.
    var sentryMode = false
    /// Live wire cells a sentry may come to inspect, refreshed by the
    /// session about once a second.
    var sentryAnchors: [Vector3] = []
    static let sentryCap = 1

    init(mode: GameMode, seed: UInt64) {
        self.enabled = mode.spawnsHostileMobs
        self.rng = SeededGenerator(seed: seed &* 0x9E3779B9 &+ 0x50EE7075)
    }

    mutating func update(
        dt: Double,
        playerEye: Vector3,
        playerIsTargetable: Bool,
        isNight: Bool,
        isRaining: Bool,
        world: World
    ) -> [Shot] {
        guard enabled else { return [] }
        // A sentry acts as though it is always night — it never burns —
        // and the whole population powers down when no wire is live.
        let isNight = sentryMode ? true : isNight
        if sentryMode, sentryAnchors.isEmpty, !skeletons.isEmpty { skeletons.removeAll() }

        if sentryMode {
            trySpawnSentry(dt: dt, playerEye: playerEye, world: world)
        } else {
            trySpawn(dt: dt, playerEye: playerEye, isNight: isNight, isRaining: isRaining, world: world)
        }

        let distanceFromSpawn = (playerEye - world.spawnPosition()).length()

        var shots: [Shot] = []
        for id in skeletons.keys {
            let target = playerIsTargetable ? playerEye : nil
            var canSee = false
            let skeletonPos = skeletons[id]?.position ?? .zero
            let localDist = world.disturbance(atWorldX: Int(skeletonPos.x), worldZ: Int(skeletonPos.z))
            let effectiveSight = Skeleton.effectiveSightRange(disturbance: localDist)
            if let target, let skeleton = skeletons[id],
               (skeleton.position - target).length() <= effectiveSight {
                canSee = MobSight.canSee(from: skeleton.eyePosition, to: target, world: world)
            }
            skeletons[id]?.step(
                dt: dt,
                playerEye: target,
                canSeePlayer: canSee,
                isNight: isNight,
                isRaining: isRaining,
                sightRange: effectiveSight,
                disturbance: localDist,
                world: world
            )

            guard let skeleton = skeletons[id] else { continue }
            if skeleton.isFinished {
                skeletons[id] = nil
            } else if skeleton.firedThisFrame {
                let damage = SkeletonManager.shotDamage(distanceFromSpawn: distanceFromSpawn)
                shots.append(Shot(origin: skeleton.eyePosition, damage: damage))
            } else if (skeleton.position - playerEye).length() > SkeletonManager.despawnDistance {
                skeletons[id] = nil
            }
        }
        return shots
    }

    /// Lands a hit; returns true when it killed the skeleton, same contract
    /// as `FizzlerManager.damage`.
    mutating func damage(id: Int, amount: Int, knockback: Vector3) -> Bool {
        guard let skeleton = skeletons[id], !skeleton.isDead else { return false }
        skeletons[id]?.damage(amount, knockback: knockback)
        return skeletons[id]?.isDead ?? false
    }

    mutating func removeAll() {
        skeletons.removeAll()
    }

    /// True when any living skeleton overlaps the given block cell.
    func occupies(blockX x: Int, y: Int, z: Int) -> Bool {
        for skeleton in skeletons.values {
            if skeleton.overlaps(blockX: x, y: y, z: z) { return true }
        }
        return false
    }

    /// Replaces the active skeleton population with the given array.
    /// Used by headless checks to establish deterministic test populations.
    mutating func adopt(_ population: [Skeleton]) {
        skeletons.removeAll()
        for skeleton in population {
            nextID += 1
            skeletons[nextID] = skeleton
        }
    }

    private mutating func trySpawn(dt: Double, playerEye: Vector3, isNight: Bool, isRaining: Bool, world: World) {
        spawnTimer -= dt
        guard spawnTimer <= 0 else { return }
        var scale = FizzlerManager.dangerScale(
            distanceFromSpawn: (playerEye - world.spawnPosition()).length()
        )
        if isRaining { scale *= 1.4 }
        let localDist = world.disturbance(atWorldX: Int(playerEye.x), worldZ: Int(playerEye.z))
        let distMultiplier = 1.0 + (min(localDist, 100.0) / 100.0) * 1.0
        scale *= distMultiplier
        spawnTimer = SkeletonManager.spawnInterval / scale
        let cap = Int((Double(SkeletonManager.populationCap) * scale).rounded())
        guard isNight, skeletons.count < cap else { return }

        for _ in 0..<6 where spawnOne(playerEye: playerEye, world: world) { return }
    }

    /// A sentry turns up on open ground near live wire — never closer to
    /// the player than a dozen blocks, so its scanning light is seen
    /// before its shot is, and never under a roof, so it never appears
    /// inside a room someone sealed.
    private mutating func trySpawnSentry(dt: Double, playerEye: Vector3, world: World) {
        spawnTimer -= dt
        guard spawnTimer <= 0 else { return }
        spawnTimer = SkeletonManager.spawnInterval * 3
        guard skeletons.count < SkeletonManager.sentryCap, !sentryAnchors.isEmpty else { return }
        for _ in 0..<6 {
            let anchor = sentryAnchors[Int(Double.random(in: 0..<1, using: &rng) * Double(sentryAnchors.count))]
            let angle = Double.random(in: 0..<1, using: &rng) * 2 * .pi
            let distance = 4 + Double.random(in: 0..<1, using: &rng) * 6
            let x = Int((anchor.x + CGFloat(cos(angle) * distance)).rounded(.down))
            let z = Int((anchor.z + CGFloat(sin(angle) * distance)).rounded(.down))
            guard let y = groundHeight(worldX: x, worldZ: z, world: world),
                  world.isSkyOpen(worldX: x, y: y, worldZ: z) else { continue }
            let position = Vector3(CGFloat(x) + 0.5, CGFloat(y), CGFloat(z) + 0.5)
            guard (position - playerEye).length() > 12 else { continue }
            nextID += 1
            skeletons[nextID] = Skeleton(position: position, seed: UInt64(nextID) &* 0xA24BAED4963EE407)
            return
        }
    }

    private mutating func spawnOne(playerEye: Vector3, world: World) -> Bool {
        let angle = Double.random(in: 0..<1, using: &rng) * 2 * .pi
        let span = SkeletonManager.maximumSpawnDistance - SkeletonManager.minimumSpawnDistance
        let distance = SkeletonManager.minimumSpawnDistance
            + CGFloat(Double.random(in: 0..<1, using: &rng)) * span
        let x = Int((playerEye.x + CGFloat(cos(angle)) * distance).rounded())
        let z = Int((playerEye.z + CGFloat(sin(angle)) * distance).rounded())

        guard let y = groundHeight(worldX: x, worldZ: z, world: world) else { return false }
        guard FizzlerManager.canSpawn(atX: x, y: y, z: z, in: world) else { return false }

        let position = Vector3(CGFloat(x) + 0.5, CGFloat(y), CGFloat(z) + 0.5)
        nextID += 1
        skeletons[nextID] = Skeleton(position: position, seed: UInt64(nextID) &* 0xA24BAED4963EE407)
        return true
    }

    /// Land or lake bed, never a puddle: a fizzler is excluded from water
    /// outright because it has to close distance to hurt you and has no
    /// way to swim after you, but a skeleton's whole threat is sight, not
    /// approach — `MobSight.canSee` already doesn't stop at a water
    /// surface, so nothing about the mechanic changes underwater. What
    /// used to make the entire ocean, every lake, and every flooded cave
    /// the one place in the game with no night at all was this single
    /// exclusion, not any real limit of the AI. The two cells above the
    /// stand must agree — both water or both air — so it never spawns
    /// waist-deep with its head sticking out of a puddle.
    private func groundHeight(worldX x: Int, worldZ z: Int, world: World) -> Int? {
        let coord = World.chunkCoord(forWorldX: x, worldZ: z)
        guard world.chunk(at: coord) != nil else { return nil }

        for y in stride(from: Chunk.height - 3, through: 1, by: -1) {
            guard world.isSolid(worldX: x, y: y, worldZ: z) else { continue }
            let headWater = world.isWater(worldX: x, y: y + 1, worldZ: z)
            guard headWater == world.isWater(worldX: x, y: y + 2, worldZ: z) else { return nil }
            let clear = !world.isSolid(worldX: x, y: y + 1, worldZ: z)
                && !world.isSolid(worldX: x, y: y + 2, worldZ: z)
            return clear ? y + 1 : nil
        }
        return nil
    }
}

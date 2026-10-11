import Foundation

/// Spawns, updates and detonates the fizzler population.
///
/// Renderer-agnostic: it owns the simulation and reports what happened, and
/// `GameViewController` is responsible for turning that into entities,
/// screen shake and damage.
struct FizzlerManager {
    /// How many may be alive around the player at once.
    static let populationCap = 8
    /// Spawn attempts are made no closer and no further than this, so a
    /// fizzler never materialises in the player's face.
    static let minimumSpawnDistance: CGFloat = 20
    static let maximumSpawnDistance: CGFloat = 44
    /// Beyond this a fizzler is culled — it has wandered out of the
    /// streamed world and its chunks may not even be loaded.
    static let despawnDistance: CGFloat = 88

    /// Seconds between spawn attempts. Attempts can fail (no dark, valid
    /// ground found), so this is a ceiling on the spawn rate, not a rate.
    static let spawnInterval: Double = 4.0

    /// Straight-line distance from the world's own spawn point at which
    /// danger finishes ramping up to its worst.
    ///
    /// Distance from spawn rather than from the player's own base on
    /// purpose: a base built far out does not buy back the safety of the
    /// doorstep, and the number is one the player can always answer for
    /// themselves without a compass — "how far have I come from where I
    /// started" is the whole question the ramp is measuring. Measured in
    /// three dimensions rather than two, so descending a mineshaft counts
    /// exactly as much as walking the same distance overland — going deep
    /// is going far, not a shortcut around the ramp.
    static let dangerRampDistance: CGFloat = 500

    /// How far past flat, doorstep-safe spawning has ramped at this
    /// distance — 1 at the doorstep, up to 3 once `dangerRampDistance` is
    /// behind you: three times the population, a third of the wait between
    /// attempts. Everywhere in between it up scales smoothly, not in steps,
    /// so there is no single line on the map where the game visibly flips
    /// a switch.
    static func dangerScale(distanceFromSpawn: CGFloat) -> Double {
        1.0 + 2.0 * Double(min(max(distanceFromSpawn, 0), dangerRampDistance) / dangerRampDistance)
    }

    /// The ground-zero maximum for one blast at this distance from spawn —
    /// the same ramp that already spawns more of these farther from home,
    /// applied to how much the one going off in front of you costs.
    /// Otherwise "danger" only ever meant "more often," never "worse," and
    /// a player who understood the ramp still took identical damage on day
    /// one and five hundred blocks out. Scales the maximum fed into
    /// `Blast.damage`'s own falloff, not the falloff shape itself, so a
    /// near miss is still a near miss — it is just a bigger number behind
    /// it. A named function rather than inline arithmetic in `detonate` so
    /// a test can point straight at it instead of driving a whole fizzler
    /// through `update` to prove the scaling. TNT is untouched — a
    /// player's own fuse is a tool, not this ramp; see `FuseManager`'s own
    /// unscaled call to `Blast.damage`.
    static func blastDamageMaximum(distanceFromSpawn: CGFloat) -> Int {
        Int((Double(Fizzler.maxBlastDamage) * dangerScale(distanceFromSpawn: distanceFromSpawn)).rounded())
    }

    /// What one detonation did, for the caller to react to.
    struct Explosion {
        let centre: Vector3
        /// Half-hearts to apply to the player; zero when out of range or
        /// when the mode is invulnerable.
        let playerDamage: Int
        /// How many blocks it took out.
        let blocksDestroyed: Int
        /// TNT the blast reached, for the caller to light. A fizzler going
        /// off beside a stack of dynamite setting it off is both correct
        /// and much funnier than the alternative.
        var ignited: [(x: Int, y: Int, z: Int)] = []
    }

    private(set) var fizzlers: [Int: Fizzler] = [:]
    /// Stable ids so the renderer can keep one entity per fizzler across
    /// frames rather than rebuilding the set every tick.
    private var nextID = 0
    private var spawnTimer: Double = 0
    private var rng: SeededGenerator

    /// Fizzlers only exist in survival — creative is for building.
    private let enabled: Bool

    init(mode: GameMode, seed: UInt64) {
        self.enabled = mode.spawnsHostileMobs
        self.rng = SeededGenerator(seed: seed &* 0x9E3779B9 &+ 0xC0FFEE)
    }

    /// Advances every fizzler and returns any explosions from this frame.
    /// `isNight` gates spawning the way light level does in the original;
    /// `isRaining` does not — rain does not make a lit yard spawnable —
    /// it only sharpens the pressure distance already puts on a night
    /// that was going to spawn something anyway.
    mutating func update(
        dt: Double,
        playerEye: Vector3,
        playerIsTargetable: Bool,
        isNight: Bool,
        isRaining: Bool,
        world: World
    ) -> [Explosion] {
        guard enabled else { return [] }

        trySpawn(dt: dt, playerEye: playerEye, isNight: isNight, isRaining: isRaining, world: world)

        var explosions: [Explosion] = []
        for id in fizzlers.keys {
            let target = playerIsTargetable ? playerEye : nil
            var canSee = false
            let fizzlerPos = fizzlers[id]?.position ?? .zero
            let localDist = world.disturbance(atWorldX: Int(fizzlerPos.x), worldZ: Int(fizzlerPos.z))
            let effectiveSight = Fizzler.effectiveSightRange(disturbance: localDist)
            if let target, let fizzler = fizzlers[id],
               (fizzler.position - target).length() <= effectiveSight {
                canSee = MobSight.canSee(from: fizzler.eyePosition, to: target, world: world)
            }
            fizzlers[id]?.step(
                dt: dt,
                playerEye: target,
                canSeePlayer: canSee,
                sightRange: effectiveSight,
                disturbance: localDist,
                world: world
            )

            guard let fizzler = fizzlers[id] else { continue }
            // Death is tested first so a fizzler killed with the fuse lit
            // takes its explosion with it — and only once the dying window
            // has run down, so the kill is visible before the body goes.
            if fizzler.isFinished {
                fizzlers[id] = nil
            } else if fizzler.hasExploded {
                explosions.append(detonate(fizzler, playerEye: playerEye, world: world))
                fizzlers[id] = nil
            } else if (fizzler.position - playerEye).length() > FizzlerManager.despawnDistance {
                fizzlers[id] = nil
            }
        }
        return explosions
    }

    /// Lands a hit on one fizzler. Returns true when that hit killed it, so
    /// the caller can grant the drop; the corpse itself is cleared by the
    /// next `update`, alongside detonations and despawns.
    mutating func damage(id: Int, amount: Int, knockback: Vector3) -> Bool {
        guard let fizzler = fizzlers[id], !fizzler.isDead else { return false }
        fizzlers[id]?.damage(amount, knockback: knockback)
        return fizzlers[id]?.isDead ?? false
    }

    /// Removes everything — used when the player respawns, so they don't
    /// come back to the same fizzler standing over them.
    mutating func removeAll() {
        fizzlers.removeAll()
    }

    /// True when any living fizzler overlaps the given block cell.
    func occupies(blockX x: Int, y: Int, z: Int) -> Bool {
        for fizzler in fizzlers.values {
            if fizzler.overlaps(blockX: x, y: y, z: z) { return true }
        }
        return false
    }

    /// Replaces the active fizzler population with the given array.
    /// Used by headless checks to establish deterministic test populations.
    mutating func adopt(_ population: [Fizzler]) {
        fizzlers.removeAll()
        for fizzler in population {
            nextID += 1
            fizzlers[nextID] = fizzler
        }
    }

    // MARK: - Spawning

    /// Multiplies the distance ramp a further notch while it rains —
    /// stacked with it rather than a separate gate, so a storm at the
    /// doorstep is still safer than a clear night a long way out, and a
    /// storm a long way out is the worst combination the game has.
    private static let rainDangerMultiplier: Double = 1.4

    private mutating func trySpawn(dt: Double, playerEye: Vector3, isNight: Bool, isRaining: Bool, world: World) {
        spawnTimer -= dt
        guard spawnTimer <= 0 else { return }
        var scale = FizzlerManager.dangerScale(
            distanceFromSpawn: (playerEye - world.spawnPosition()).length()
        )
        if isRaining { scale *= FizzlerManager.rainDangerMultiplier }
        let localDist = world.disturbance(atWorldX: Int(playerEye.x), worldZ: Int(playerEye.z))
        let distMultiplier = 1.0 + (min(localDist, 100.0) / 100.0) * 1.0
        scale *= distMultiplier
        spawnTimer = FizzlerManager.spawnInterval / scale
        let cap = Int((Double(FizzlerManager.populationCap) * scale).rounded())
        guard isNight, fizzlers.count < cap else { return }

        // A handful of attempts per interval; most fail on unloaded chunks
        // or no headroom, and that's fine.
        for _ in 0..<6 where spawnOne(playerEye: playerEye, world: world) { return }
    }

    /// Picks a random ring position around the player and drops a fizzler
    /// on the surface there, if there's room. Returns true on success.
    private mutating func spawnOne(playerEye: Vector3, world: World) -> Bool {
        let angle = Double.random(in: 0..<1, using: &rng) * 2 * .pi
        let span = FizzlerManager.maximumSpawnDistance - FizzlerManager.minimumSpawnDistance
        let distance = FizzlerManager.minimumSpawnDistance
            + CGFloat(Double.random(in: 0..<1, using: &rng)) * span
        let x = Int((playerEye.x + CGFloat(cos(angle)) * distance).rounded())
        let z = Int((playerEye.z + CGFloat(sin(angle)) * distance).rounded())

        guard let y = groundHeight(worldX: x, worldZ: z, world: world) else { return false }
        guard FizzlerManager.canSpawn(atX: x, y: y, z: z, in: world) else { return false }

        let position = Vector3(CGFloat(x) + 0.5, CGFloat(y), CGFloat(z) + 0.5)
        nextID += 1
        fizzlers[nextID] = Fizzler(position: position, seed: UInt64(nextID) &* 0x9E3779B97F4A7C15)
        return true
    }

    /// Whether a fizzler may appear in this cell.
    ///
    /// Darkness, and darkness means *no lamp reaches here* — `lightLevel`
    /// is block light only, so at night an unlit field is 0 and a torch-lit
    /// yard is not. That makes a torch the thing it is in the original: the
    /// wall you build against the night. Before this, lighting a house
    /// changed nothing at all, and a player being blown up had nothing
    /// they could have done differently.
    static func canSpawn(atX x: Int, y: Int, z: Int, in world: World) -> Bool {
        // The cell it stands in and the one its head is in: a torch on the
        // floor of a shelter must not leave its ceiling spawnable.
        world.lightLevel(worldX: x, y: y, worldZ: z) == 0
            && world.lightLevel(worldX: x, y: y + 1, worldZ: z) == 0
    }

    /// The y a mob would stand on at this column: the first solid block
    /// from the top with two blocks of air above it. Nil when the column
    /// isn't loaded or has no room.
    private func groundHeight(worldX x: Int, worldZ z: Int, world: World) -> Int? {
        // An unloaded column reads as all air, which would otherwise look
        // like a valid bottomless spawn.
        let coord = World.chunkCoord(forWorldX: x, worldZ: z)
        guard world.chunk(at: coord) != nil else { return nil }

        for y in stride(from: Chunk.height - 3, through: 1, by: -1) {
            guard world.isSolid(worldX: x, y: y, worldZ: z) else { continue }
            // Don't spawn them standing in a lake.
            guard !world.isWater(worldX: x, y: y + 1, worldZ: z) else { return nil }
            let clear = !world.isSolid(worldX: x, y: y + 1, worldZ: z)
                && !world.isSolid(worldX: x, y: y + 2, worldZ: z)
            return clear ? y + 1 : nil
        }
        return nil
    }

    // MARK: - Explosion

    /// Carves a rough sphere out of the world and works out the damage.
    private func detonate(_ fizzler: Fizzler, playerEye: Vector3, world: World) -> Explosion {
        let centre = fizzler.position + Vector3(0, Fizzler.height / 2, 0)
        let radius = Fizzler.blastRadius

        // The crater, and any TNT it reached. A fizzler going off next to a
        // stack of dynamite setting the stack off is the correct and much
        // funnier answer, and it costs nothing here — `Blast` already found
        // them and the fuse manager already knows what to do with them.
        let result = Blast.carve(at: centre, radius: radius, in: world)
        let destroyed = result.destroyed

        let damage = Blast.damage(
            maximum: FizzlerManager.blastDamageMaximum(
                distanceFromSpawn: (playerEye - world.spawnPosition()).length()
            ),
            at: playerEye, from: centre, radius: radius
        )

        return Explosion(centre: centre, playerDamage: damage, blocksDestroyed: destroyed,
                         ignited: result.ignited)
    }
}

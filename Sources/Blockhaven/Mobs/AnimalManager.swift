import Foundation

/// Spawns and updates the passive animal population.
///
/// Renderer-agnostic, the same split as `FizzlerManager`: it owns the
/// simulation and `GameViewController` turns that into entities and drops.
struct AnimalManager {
    /// How many land animals may be alive around the player at once. Higher
    /// than the fizzler cap — a world with a few herds in it feels inhabited.
    static let populationCap = 16
    /// How many swimmers may be alive *on top of* that, not a slice of it.
    /// A shared cap sounds fairer and is not: land is everywhere and water
    /// is not, so the fields spend every slot going long before the lake is
    /// looked at, and the kid who walked to the lake finds it empty. Their
    /// own budget is what makes a lake reliably worth walking to.
    ///
    /// Raised with the shoal: six cod is one shoal, and a lake that can
    /// hold one shoal and nothing else is a lake with no axolotl in it.
    static let waterPopulationCap = 14
    /// How often a spawn attempt looks for water rather than for ground.
    /// Higher than the share of the world that is lake, because most water
    /// attempts fail: the ring lands on dry land far more often than not.
    static let waterSpawnChance = 0.4

    /// How far a fish looks for shoalmates, and how close it will let one
    /// get before it starts pushing off.
    ///
    /// The radius is deliberately larger than a shoal is: a flee burst
    /// throws a fish 2.2× its swim speed for a second and a half, which is
    /// about seven blocks, so a radius of seven meant one swing at a shoal
    /// scattered it permanently — every fish that bolted was outside the
    /// only rule that would have brought it back. Twelve is far enough that
    /// being frightened is a thing a shoal recovers from.
    static let shoalRadius: CGFloat = 12.0
    static let shoalSpacing: CGFloat = 1.1

    /// How far apart the members of one spawned group are scattered, so a
    /// herd arrives as a herd rather than as a stack of animals in one
    /// cell. Each is placed independently, so a group that only half fits
    /// spawns half as many rather than failing.
    static let groupScatter: CGFloat = 2.5
    /// Spawn attempts are made no closer and no further than this, so an
    /// animal never materialises in the player's face.
    static let minimumSpawnDistance: CGFloat = 16
    static let maximumSpawnDistance: CGFloat = 40
    /// Beyond this an animal is culled — it has wandered out of the
    /// streamed world and its chunks may not even be loaded.
    static let despawnDistance: CGFloat = 88

    /// Seconds between spawn attempts. Attempts can fail (no valid ground
    /// found), so this is a ceiling on the spawn rate, not a rate. Quicker
    /// than the fizzler's: at most one animal arrives per interval, and a
    /// world that takes a minute to grow a herd reads as an empty one.
    static let spawnInterval: Double = 3.0

    /// How close two animals fed into love have to stand for it to take —
    /// close enough that it reads as "these two", not "this field".
    static let breedRadius: CGFloat = 3.0

    /// How close a hostile mob has to be before a herd notices it and
    /// bolts. Well past `Fizzler.blastRadius` (3.0) on purpose — the whole
    /// point of a prey response is that it fires before the predator is
    /// close enough to matter, not at the moment it would anyway.
    static let threatRadius: CGFloat = 8.0
    /// How close a hostile mob has to be before a tamed wolf turns to fight
    /// it instead of standing at its owner's side. Tighter than
    /// `threatRadius`: a herd bolts the moment danger is merely nearby, but
    /// a dog that charged off after everything within eight blocks would
    /// never actually be at your side when you needed it.
    static let defendRadius: CGFloat = 6.0

    /// One live hostile mob, as `AnimalManager` sees it: just enough to
    /// notice it (`position`), flee it (shared by every animal), or — a
    /// tamed wolf only — find and bite it (`id`, `isFizzler`, to route a
    /// landed hit to the right manager).
    struct Threat {
        let id: Int
        let isFizzler: Bool
        let position: Vector3
    }

    /// One bite landed this frame: which wolf threw it and what it hit —
    /// the wolf's own id travels with the threat so a skeleton can bite
    /// back at the right dog instead of the nearest one.
    struct Bite {
        let wolfID: Int
        let threat: Threat
    }

    private(set) var animals: [Int: Animal] = [:]
    /// Stable ids so the renderer can keep one entity per animal across
    /// frames rather than rebuilding the set every tick.
    private var nextID = 0
    private var spawnTimer: Double = 0
    private var rng: SeededGenerator
    /// Seconds left before each wolf, by id, can land another bite —
    /// tracked here rather than on `Animal` because it's the one piece of
    /// combat state that belongs to the fight, not to the animal.
    private var biteTimers: [Int: Double] = [:]

    /// Animals exist in both modes, so this is only ever false if a future
    /// mode turns them off.
    private let enabled: Bool

    init(mode: GameMode, seed: UInt64) {
        self.enabled = mode.spawnsPassiveMobs
        self.rng = SeededGenerator(seed: seed &* 0x85EBCA6B &+ 0xA11A1)
    }

    /// Advances every animal. Unlike fizzlers there is no time-of-day gate:
    /// animals keep to the surface around the clock, which is also what
    /// stops a herd evaporating at dusk.
    ///
    /// `threats` is every live hostile mob — fizzler and skeleton alike,
    /// the manager doesn't care which for fleeing, only for routing a
    /// tamed wolf's bite back to the right one. Passed in rather than
    /// reached for, the same split as `world`: this struct has no way to
    /// see `FizzlerManager` or `SkeletonManager` on its own, and shouldn't
    /// need one just to ask "is anything dangerous nearby." Returns
    /// whichever threats got bitten this frame, for the caller to apply
    /// the damage — the same shape `swingAt` already uses for the player's
    /// own sword.
    @discardableResult
    mutating func update(dt: Double, playerEye: Vector3, world: World, threats: [Threat]) -> [Bite] {
        guard enabled else { return [] }

        trySpawn(dt: dt, playerEye: playerEye, world: world)
        breed()

        // Worked out once for the whole population, before anything moves,
        // so every fish in a shoal steers off the same snapshot of it
        // rather than off half-updated neighbours — which would make the
        // shoal's behaviour depend on dictionary ordering.
        let shoals = shoalContexts()
        var bitten: [Bite] = []

        for id in animals.keys {
            // A tamed animal is told where the player is; nothing else here
            // knows or cares. Set before the step so the follow branch has
            // this frame's position rather than last frame's.
            if animals[id]?.isTamed == true {
                animals[id]?.followTarget = playerEye
                recallIfLost(id, playerEye: playerEye, world: world)
            }

            if let animal = animals[id], !animal.isDead {
                if !animal.isTamed {
                    // A pet stands its ground: it already has a job in this
                    // loop — following or sitting — and a tamed animal that
                    // bolted the moment a fizzler wandered near would undo
                    // the entire promise taming makes, the same promise
                    // `recallIfLost` above exists to keep.
                    if let threat = threats.first(
                        where: { ($0.position - animal.position).length() < AnimalManager.threatRadius }
                    ) {
                        animals[id]?.spook(awayFrom: threat.position)
                    }
                } else if animal.kind == .wolf, !animal.isSitting,
                          let threat = threats.first(
                              where: { ($0.position - animal.position).length() < AnimalManager.defendRadius }
                          ) {
                    // The one tamed kind that doesn't just stand its
                    // ground: a dog fights for the pack it's part of
                    // instead of merely being immune to what scatters one.
                    animals[id]?.defend(against: threat.position)
                    biteTimers[id, default: 0] -= dt
                    if (threat.position - animal.position).length() < Animal.biteRange,
                       biteTimers[id, default: 0] <= 0 {
                        biteTimers[id] = Animal.biteCooldown
                        bitten.append(Bite(wolfID: id, threat: threat))
                    }
                }
            }

            animals[id]?.step(dt: dt, world: world, shoal: shoals[id])

            guard let animal = animals[id] else { continue }
            if animal.isFinished {
                animals[id] = nil
                biteTimers[id] = nil
            } else if animal.isTamed {
                // A pet is never despawned. The whole promise of taming one
                // is that it is still there later, and the despawn radius
                // below would quietly break exactly that promise the first
                // time the player outran it.
                continue
            } else if (animal.position - playerEye).length() > AnimalManager.despawnDistance {
                animals[id] = nil
            }
        }
        return bitten
    }

    /// Lands a hit on one animal. Returns its kind when that hit killed it,
    /// so the caller can grant the right drop; the body itself is cleared
    /// by a later `update`, once the dying window has played out.
    mutating func damage(id: Int, amount: Int, knockback: Vector3) -> AnimalKind? {
        guard let animal = animals[id], !animal.isDead else { return nil }
        animals[id]?.damage(amount, knockback: knockback)
        guard animals[id]?.isDead == true else { return nil }
        return animal.kind
    }

    /// Removes everything — the checks' way of clearing a population
    /// before `adopt` puts down a chosen one.
    mutating func removeAll() {
        animals.removeAll()
    }

    /// Removes only the untamed — used when the player respawns, so the
    /// wildlife around the new spawn point is populated fresh without
    /// deleting a tamed pet along with it. A tamed animal is a save-worthy
    /// promise (`restore`, `WorldSave.animals`); dying is far more common
    /// than closing the app; a pet that survives a reload but not a
    /// fizzler's fuse would be a promise kept in one place and broken in
    /// the other.
    mutating func removeAllWild() {
        animals = animals.filter { $0.value.isTamed }
    }

    /// Feeds an animal, and tames it if it is the sort that can be.
    ///
    /// Returns whether the food was taken, so the caller knows whether to
    /// consume it. Deliberately always succeeds rather than rolling a
    /// chance like the original's: a kid who feeds a wolf eight steaks and
    /// still has a wild wolf has learned that the game is unfair, not that
    /// taming is a gamble.
    @discardableResult
    mutating func feed(_ id: Int) -> Bool {
        guard let animal = animals[id], animal.kind.isTameable, !animal.isDead else { return false }
        guard !animal.isTamed else { return false }
        animals[id]?.isTamed = true
        animals[id]?.isSitting = false
        return true
    }

    /// Feeds a non-tameable animal into love mode — the other half of the
    /// gesture `feed` already is for a wolf, aimed at the herd kinds a
    /// leash was never going to keep. Returns whether the food was taken,
    /// so the caller knows whether to consume it.
    @discardableResult
    mutating func feedForBreeding(_ id: Int) -> Bool {
        guard let animal = animals[id], !animal.kind.isTameable, !animal.isDead else { return false }
        guard !animal.isInLove, animal.canBeFedForBreeding else { return false }
        animals[id]?.enterLove()
        return true
    }

    /// Toggles a tamed animal between following and staying put. Returns
    /// the new state, or nil if this was not a pet.
    @discardableResult
    mutating func toggleSit(_ id: Int) -> Bool? {
        guard let animal = animals[id], animal.isTamed, !animal.isDead else { return nil }
        animals[id]?.isSitting = !animal.isSitting
        return animals[id]?.isSitting
    }

    /// Puts a pet that has fallen too far behind back beside the player.
    ///
    /// The original's rule, and it is here for the same reason: a dog that
    /// loses a race with a closing door, a ravine or a chunk boundary is
    /// gone, and a pet you can lose by walking is not a pet. A sitting one
    /// stays where it was told — that is what being told means.
    private mutating func recallIfLost(_ id: Int, playerEye: Vector3, world: World) {
        guard let animal = animals[id], !animal.isSitting, !animal.isDead else { return }
        guard (animal.position - playerEye).length() > AnimalKind.recallDistance else { return }

        // Somewhere solid to stand, close by but not underfoot. Tried on a
        // ring around the player so the dog does not reappear inside them.
        for angleStep in 0..<8 {
            let angle = Double(angleStep) / 8 * 2 * .pi
            let x = Int(playerEye.x + CGFloat(cos(angle)) * 2.5)
            let z = Int(playerEye.z + CGFloat(sin(angle)) * 2.5)
            guard let ground = groundHeight(worldX: x, worldZ: z, world: world) else { continue }
            animals[id]?.recall(to: Vector3(CGFloat(x) + 0.5, CGFloat(ground), CGFloat(z) + 0.5))
            return
        }

        // No loaded ground anywhere on the ring — the player is somewhere
        // the world has not streamed in yet. Put it on them rather than
        // leaving it four hundred blocks away: it will fall the moment
        // there is something to fall onto, and a pet standing in the player
        // is a worse picture than a pet that no longer exists only for the
        // fraction of a second before the chunk arrives.
        animals[id]?.recall(to: playerEye)
    }

    /// Puts a chosen population in place of whatever is there.
    ///
    /// The headless checks' way in. Everything else about a shoal can be
    /// asked of animals the spawner placed, but not the one claim that
    /// matters most — that scattered fish come together — because the
    /// spawner puts a group down together in the first place. Proving that
    /// needs the fish to start somewhere chosen rather than somewhere
    /// rolled.
    mutating func adopt(_ population: [Animal]) {
        animals.removeAll()
        for animal in population {
            nextID += 1
            animals[nextID] = animal
        }
    }

    /// True when any living animal overlaps the given block cell.
    func occupies(blockX x: Int, y: Int, z: Int) -> Bool {
        for animal in animals.values {
            if animal.overlaps(blockX: x, y: y, z: z) { return true }
        }
        return false
    }

    /// Puts saved animals back without touching whatever's already here —
    /// unlike `adopt`, which replaces the whole population for a check's
    /// sake. Called once at load, before the spawner has placed anything,
    /// so a tamed pet is there from the first frame instead of taming
    /// being a promise a reload quietly breaks.
    mutating func restore(_ recovered: [Animal]) {
        for animal in recovered {
            nextID += 1
            animals[nextID] = animal
        }
    }

    // MARK: - Shoaling

    /// What each shoaling fish should be told about its neighbours.
    ///
    /// The whole of the multi-animal awareness in the game lives in this
    /// one function: `Animal` simulates exactly one animal and cannot see
    /// another, so the three classic urges are worked out here and handed
    /// down as plain vectors. It is O(n²) over the shoaling fish alone —
    /// half a dozen of them — which is cheaper than the grid that would
    /// avoid it, and stays cheaper until there are far more fish than a
    /// lake this size should hold.
    ///
    /// Nothing is normalised on the way out. Cohesion is scaled by the
    /// search radius and alignment by cruising pace, which gives both a
    /// natural falloff — a distant shoal pulls harder than a near one, and
    /// a shoal that has stopped moving exerts no pull to keep going — and
    /// avoids `Vector3.normalized`, which answers +z for a zero vector.
    private func shoalContexts() -> [Int: Animal.Shoal] {
        let members = animals.filter { $0.value.kind.shoals && !$0.value.isDead }
        guard members.count > 1 else { return [:] }

        var contexts: [Int: Animal.Shoal] = [:]
        for (id, fish) in members {
            var toward = Vector3.zero
            var heading = Vector3.zero
            var away = Vector3.zero
            var count = 0

            for (otherID, other) in members
            where otherID != id && other.kind == fish.kind {
                let offset = other.position - fish.position
                let gap = offset.length()
                guard gap < AnimalManager.shoalRadius else { continue }
                count += 1
                toward = toward + offset
                heading = heading + other.velocity
                // Crowding pushes back harder the closer it gets, and not
                // at all past `shoalSpacing`. The sign is negative because
                // `offset` points at the neighbour and this wants away.
                if gap < AnimalManager.shoalSpacing, gap > 0.0001 {
                    let crowding = (AnimalManager.shoalSpacing - gap) / AnimalManager.shoalSpacing
                    away = away + offset * (-crowding / gap)
                }
            }

            guard count > 0 else { continue }
            let share = 1 / CGFloat(count)
            contexts[id] = Animal.Shoal(
                cohesion: toward * (share / AnimalManager.shoalRadius),
                alignment: heading * (share / max(0.01, fish.kind.swimSpeed)),
                separation: away,
                count: count
            )
        }
        return contexts
    }

    // MARK: - Spawning

    private mutating func trySpawn(dt: Double, playerEye: Vector3, world: World) {
        spawnTimer -= dt
        guard spawnTimer <= 0 else { return }
        spawnTimer = AnimalManager.spawnInterval
        // Mirrors the exemption in `hasRoom`: both budgets full is not
        // "nothing to do" while some kind still has zero members — that
        // kind's one guaranteed shot lives inside the attempt loop below,
        // and this early exit must not cut it off before it is taken.
        let anyKindUnseen = AnimalKind.allCases.contains { count(of: $0) == 0 }
        guard landCount < AnimalManager.populationCap
            || swimmerCount < AnimalManager.waterPopulationCap
            || anyKindUnseen else { return }

        // A handful of attempts per interval; most fail on unloaded chunks
        // or no headroom, and that's fine.
        for _ in 0..<6 where spawnOne(playerEye: playerEye, world: world) { return }
    }

    /// Picks a random ring position around the player and puts a *group* of
    /// one kind there, if there's room: on the surface for the land kinds,
    /// or under the surface of a lake for the swimmers. Returns true if at
    /// least one animal landed.
    ///
    /// A group rather than an animal, since the spawn interval is what sets
    /// how long a new field stays empty and one arrival every three seconds
    /// reads as animals trickling in. What a herd looks like is several
    /// together, so several together is what a spawn places.
    private mutating func spawnOne(playerEye: Vector3, world: World) -> Bool {
        let angle = Double.random(in: 0..<1, using: &rng) * 2 * .pi
        let span = AnimalManager.maximumSpawnDistance - AnimalManager.minimumSpawnDistance
        let distance = AnimalManager.minimumSpawnDistance
            + CGFloat(Double.random(in: 0..<1, using: &rng)) * span
        let x = Int((playerEye.x + CGFloat(cos(angle)) * distance).rounded())
        let z = Int((playerEye.z + CGFloat(sin(angle)) * distance).rounded())

        // Water is asked for on the roll, and asked for outright once the
        // land budget is spent: the fields being full is exactly the state
        // in which a lake would otherwise never be looked at again. Either
        // budget also counts as having room while one of its own kinds has
        // never appeared at all — see `hasRoom(for:)` — so a full habitat
        // doesn't shut out the one kind that hasn't had its guaranteed shot
        // yet.
        let landUnseen = AnimalKind.allCases.contains { !$0.isAquatic && count(of: $0) == 0 }
        let waterUnseen = AnimalKind.allCases.contains { $0.isAquatic && count(of: $0) == 0 }
        let waterHasRoom = swimmerCount < AnimalManager.waterPopulationCap || waterUnseen
        let landHasRoom = landCount < AnimalManager.populationCap || landUnseen
        let wantsWater = waterHasRoom
            && (!landHasRoom
                || Double.random(in: 0..<1, using: &rng) < AnimalManager.waterSpawnChance)

        guard wantsWater ? waterHasRoom : landHasRoom else { return false }
        let biome = world.generator.biome(x: x, z: z)
        guard let kind = pick(aquatic: wantsWater, biome: biome) else { return false }

        let group = kind.groupSize
        let wanted = group.lowerBound
            + Int(Double.random(in: 0..<1, using: &rng)
                  * Double(group.upperBound - group.lowerBound + 1))

        // The first goes on the column the ring picked; the rest are
        // scattered around it and each checked on its own, so a group that
        // straddles a bank or a drop-off places the ones that fit rather
        // than failing whole.
        var placed = 0
        for member in 0..<wanted {
            guard hasRoom(for: kind) else { break }
            let dx = member == 0 ? 0 : scatterOffset()
            let dz = member == 0 ? 0 : scatterOffset()
            guard let spot = place(kind: kind, worldX: x + dx, worldZ: z + dz, world: world) else {
                // The centre column failing means the ring landed somewhere
                // this kind can't be at all — dry land for a shoal, a
                // treetop for a herd — and the scattered tries would only
                // be more of the same guess.
                if member == 0 { return false }
                continue
            }
            if spawn(kind: kind, at: spot) { placed += 1 }
        }
        return placed > 0
    }

    /// One axis of a group member's scatter, in whole cells.
    private mutating func scatterOffset() -> Int {
        let spread = Double(AnimalManager.groupScatter)
        return Int(((Double.random(in: 0..<1, using: &rng) - 0.5) * 2 * spread).rounded())
    }

    /// Which animal a spawn attempt is for: an even roll over the kinds of
    /// that habitat which still have room *and* actually belong at this
    /// column's biome. Nil when none qualify, which is the caller's cue to
    /// give the attempt up rather than spend it on a kind that cannot
    /// spawn.
    ///
    /// Filtering by room and biome before rolling, rather than rolling and
    /// then failing in `place`, is what stops one full or out-of-habitat
    /// kind eating attempts another could have used — with three water
    /// kinds and six tries an interval, a cod-heavy lake would otherwise
    /// starve the axolotl of chances long before it starved it of slots,
    /// and a plain would burn a fifth of every attempt rolling a wolf that
    /// was never going to be allowed to land there.
    private mutating func pick(aquatic: Bool, biome: WorldGenerator.Biome) -> AnimalKind? {
        let kinds = AnimalKind.allCases.filter {
            $0.isAquatic == aquatic && hasRoom(for: $0)
                && (aquatic || $0.habitatBiomes.contains(biome))
        }
        guard !kinds.isEmpty else { return nil }
        let roll = Int(Double.random(in: 0..<1, using: &rng) * Double(kinds.count))
        return kinds[min(kinds.count - 1, roll)]
    }

    /// How many of one kind are alive, which is what its own ceiling is
    /// measured against.
    private func count(of kind: AnimalKind) -> Int {
        animals.values.filter { $0.kind == kind }.count
    }

    /// Where this kind's feet would go in this column, or nil if it can't
    /// stand or swim there.
    private func place(kind: AnimalKind, worldX x: Int, worldZ z: Int, world: World) -> Vector3? {
        if kind.isAquatic {
            guard let y = swimDepth(kind: kind, worldX: x, worldZ: z, world: world) else {
                return nil
            }
            return Vector3(CGFloat(x) + 0.5, y, CGFloat(z) + 0.5)
        }
        guard kind.habitatBiomes.contains(world.generator.biome(x: x, z: z)) else { return nil }
        guard let y = groundHeight(worldX: x, worldZ: z, world: world) else { return nil }
        return Vector3(CGFloat(x) + 0.5, CGFloat(y), CGFloat(z) + 0.5)
    }

    /// Whether this kind's half of the budget, *and* this kind's own share
    /// of that half, have a slot left.
    ///
    /// A kind nobody has seen yet is let through even past a full budget.
    /// Land is gated by habitat now (`AnimalKind.habitatBiomes`), and
    /// nothing here ever frees a slot on its own — a stationary player
    /// grows no despawns — so a home surrounded mostly by plains could
    /// otherwise fill all sixteen land slots on pigs and cows before a
    /// forest kind three attempts away ever got rolled, and lock the door
    /// on it for good. This costs at most one slot per kind that would
    /// otherwise never get one, and stops mattering the moment that kind
    /// has a single member — this is a foot in the door, not a standing
    /// exemption.
    private func hasRoom(for kind: AnimalKind) -> Bool {
        guard count(of: kind) < kind.maximumAlive else { return false }
        if count(of: kind) == 0 { return true }
        return kind.isAquatic
            ? swimmerCount < AnimalManager.waterPopulationCap
            : landCount < AnimalManager.populationCap
    }

    /// How many of the live animals are swimmers, which is what the water
    /// cap is measured against.
    private var swimmerCount: Int {
        animals.values.filter { $0.kind.isAquatic }.count
    }

    /// The rest of them, which is what `populationCap` is measured against.
    private var landCount: Int {
        animals.count - swimmerCount
    }

    /// Pairs off whatever is currently in love mode: same kind, within
    /// `breedRadius` of each other, neither already spent on another pair
    /// this frame. A baby lands at the midpoint and both parents spend
    /// their love and start the cooldown — the wheat-breeds-a-herd loop,
    /// entirely downstream of `feedForBreeding` and `Animal`'s own timers,
    /// with no new spawn logic beyond calling `spawn` one extra time.
    ///
    /// Internal rather than private so `BreedCheck` can call this alone —
    /// `update` also runs `trySpawn` and every animal's own `step`, and a
    /// check trying to isolate one pairing from a whole frame of those
    /// would be at the mercy of whatever else that frame happened to spawn.
    mutating func breed() {
        let lovers = animals.filter { $0.value.isInLove && !$0.value.isDead }
        guard !lovers.isEmpty else { return }
        let byKind = Dictionary(grouping: lovers.keys) { lovers[$0]!.kind }

        var paired: Set<Int> = []
        for (kind, ids) in byKind {
            for i in ids.indices {
                let idA = ids[i]
                guard !paired.contains(idA), let a = animals[idA] else { continue }
                for j in (i + 1)..<ids.count {
                    let idB = ids[j]
                    guard !paired.contains(idB), let b = animals[idB] else { continue }
                    guard (a.position - b.position).length() <= AnimalManager.breedRadius else { continue }
                    guard hasRoom(for: kind) else { break }
                    guard spawn(kind: kind, at: (a.position + b.position) * 0.5) else { continue }
                    animals[idA]?.consumeLove()
                    animals[idB]?.consumeLove()
                    paired.insert(idA)
                    paired.insert(idB)
                    break
                }
            }
        }
    }

    /// Internal rather than private — `BreedCheck` needs to put two
    /// animals at an exact, known distance apart rather than waiting on
    /// `trySpawn`'s own random ring to happen to land a pair close
    /// together, the same reason `World.setBlock` is the mutator every
    /// check drives directly instead of playing through world generation
    /// to get there.
    @discardableResult
    mutating func spawn(kind: AnimalKind, at position: Vector3) -> Bool {
        nextID += 1
        animals[nextID] = Animal(
            kind: kind,
            position: position,
            seed: UInt64(nextID) &* 0xD1342543DE82EF95 &+ 0x2545F491
        )
        return true
    }

    /// Where a swimmer's feet go in this column: inside a run of water at
    /// least `kind.minimumWaterDepth` cells deep, one cell up from the
    /// bottom, so the whole body starts under the surface and the
    /// water-only movement rule can hold from frame one. Nil when the
    /// column isn't loaded, holds no water, or is too shallow for this kind.
    ///
    /// The depth is per kind, and that is what keeps the squid out in the
    /// sea: a pond four cells deep will take a shoal and an axolotl and
    /// refuse a squid, so swimming out over the deep is worth doing.
    private func swimDepth(
        kind: AnimalKind, worldX x: Int, worldZ z: Int, world: World
    ) -> CGFloat? {
        let coord = World.chunkCoord(forWorldX: x, worldZ: z)
        guard world.chunk(at: coord) != nil else { return nil }

        for y in stride(from: Chunk.height - 2, through: 2, by: -1) {
            guard world.isWater(worldX: x, y: y, worldZ: z) else { continue }
            // The whole run has to be water, counted down from the surface
            // cell just found. A fizzler blast leaves air pockets in a sea
            // — there is no fluid simulation to fill them — so this counts
            // rather than assuming the column is solid water to the floor.
            var depth = 1
            while depth < kind.minimumWaterDepth,
                  world.isWater(worldX: x, y: y - depth, worldZ: z) {
                depth += 1
            }
            guard depth >= kind.minimumWaterDepth else { return nil }
            // Sits one cell up from the deepest it checked, clear of both
            // cell boundaries.
            return CGFloat(y - depth + 1) + 0.25
        }
        return nil
    }

    /// The y an animal would stand on at this column: the first solid block
    /// from the top with two blocks of air above it. Nil when the column
    /// isn't loaded or has no room.
    private func groundHeight(worldX x: Int, worldZ z: Int, world: World) -> Int? {
        // An unloaded column reads as all air, which would otherwise look
        // like a valid bottomless spawn.
        let coord = World.chunkCoord(forWorldX: x, worldZ: z)
        guard world.chunk(at: coord) != nil else { return nil }

        for y in stride(from: Chunk.height - 3, through: 1, by: -1) {
            let block = world.block(worldX: x, y: y, worldZ: z)
            guard block.isSolid else { continue }
            // A tree is not ground. Leaves and trunks are solid, so the
            // plain "first solid thing from the top" walk stops on the
            // canopy — and a forest is exactly where a herd wants to be,
            // so this was putting cows in the treetops. Keep walking down
            // through a tree rather than standing on it.
            if block == .leaves || block == .log { continue }
            // Don't spawn them standing in a lake, or in the one hazard
            // that shares water's non-solid clearance check.
            guard !world.isWater(worldX: x, y: y + 1, worldZ: z),
                  !world.isLava(worldX: x, y: y + 1, worldZ: z) else { return nil }
            let clear = !world.isSolid(worldX: x, y: y + 1, worldZ: z)
                && !world.isSolid(worldX: x, y: y + 2, worldZ: z)
            return clear ? y + 1 : nil
        }
        return nil
    }
}

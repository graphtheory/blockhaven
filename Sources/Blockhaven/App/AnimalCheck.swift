import Foundation

/// Headless proof of the four things the animals gained that a picture
/// cannot settle.
///
/// A still cannot tell a shoal from six fish that happen to be near each
/// other, cannot tell a chicken beating its wings from one falling with
/// the animation playing, and cannot tell an animal standing on a treetop
/// from one standing on a hill behind a tree. So they are checked the way
/// the axolotl's water rule is — a real `World`, the real `Animal`, the
/// real `AnimalManager`, and time simulated a hundred frames a second.
///
/// `BLOCKHAVEN_CHECK_ANIMALS=1`. Nothing here touches the save file; it never
/// opens a window and exits nonzero if any line fails.
enum AnimalCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_ANIMALS"] != nil
    }

    /// One simulated frame at 100 Hz, matching the display the physics is
    /// tuned for.
    private static let frameInterval: Double = 0.01

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    /// The test tank: a stone table with a wide deep basin sunk into it,
    /// laid clear of the terrain. Deeper and wider than the axolotl check's
    /// pond, because a shoal needs room to be scattered in before it can be
    /// shown to gather.
    private static let tableHalf = 30
    private static let pondHalf = 24
    private static let pondDepth = 8

    static func run() -> Never {
        var report = Report()
        let world = World()
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dz in -4...4 {
            for dx in -4...4 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        // MARK: nothing stands in a tree
        //
        // Run first, on the *untouched* terrain, before the table below
        // flattens it — the claim is about the forest the generator makes,
        // and a stone slab has no canopy to stand on.
        checkCanopy(world: world, spawn: spawn, report: &report)

        checkNoSpawnInLava(world: world, spawn: spawn, report: &report)

        let originX = Int(spawn.x), originZ = Int(spawn.z)
        var highest = 0
        for z in (originZ - tableHalf)...(originZ + tableHalf) {
            for x in (originX - tableHalf)...(originX + tableHalf) {
                var top = Chunk.height - 1
                while top > 0, !world.block(worldX: x, y: top, worldZ: z).isSolid { top -= 1 }
                highest = max(highest, top)
            }
        }
        let deck = highest + 2
        guard deck + 8 < Chunk.height, deck - pondDepth - 1 > 0 else {
            StandardError.write(Data("[check] no headroom over the terrain\n".utf8))
            exit(2)
        }

        for z in (originZ - tableHalf)...(originZ + tableHalf) {
            for x in (originX - tableHalf)...(originX + tableHalf) {
                for y in (deck - pondDepth - 1)...deck {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .stone, remesh: false)
                }
                for y in (deck + 1)...(deck + 8) {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }
        for z in (originZ - pondHalf)...(originZ + pondHalf) {
            for x in (originX - pondHalf)...(originX + pondHalf) {
                for y in (deck - pondDepth + 1)...deck {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .water, remesh: false)
                }
            }
        }

        checkShoal(world: world, originX: originX, originZ: originZ, deck: deck, report: &report)
        checkGlide(world: world, originX: originX, originZ: originZ, deck: deck, report: &report)
        checkGroupSpawn(world: world, originX: originX, originZ: originZ, deck: deck, report: &report)
        checkThreatResponse(world: world, originX: originX, originZ: originZ, deck: deck, report: &report)
        checkWolfDefends(world: world, originX: originX, originZ: originZ, deck: deck, report: &report)
        checkRespawnSparesPets(report: &report)

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the animals\n"
            : "[check] all passed — the animals\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }

    // MARK: - The shoal

    /// Six cod dropped in a ring twelve blocks across, then a minute of
    /// simulation. Three things have to be true at the end and each of them
    /// fails differently, which is why they are three lines and not one.
    private static func checkShoal(
        world: World, originX: Int, originZ: Int, deck: Int, report: inout Report
    ) {
        let swimY = CGFloat(deck - 3) + 0.25
        let ringRadius: CGFloat = 10
        var manager = AnimalManager(mode: .survival, seed: 0xC0D5)
        var scattered: [Animal] = []
        for index in 0..<6 {
            let angle = Double(index) / 6 * 2 * .pi
            scattered.append(Animal(
                kind: .cod,
                position: Vector3(
                    CGFloat(originX) + 0.5 + CGFloat(cos(angle)) * ringRadius,
                    swimY,
                    CGFloat(originZ) + 0.5 + CGFloat(sin(angle)) * ringRadius
                ),
                seed: UInt64(0xC0D0 + index)
            ))
        }
        manager.adopt(scattered)

        let startSpread = meanPairwiseDistance(manager.animals.values.map(\.position))
        let eye = Vector3(CGFloat(originX) + 0.5, CGFloat(deck) + 3, CGFloat(originZ) + 0.5)
        var driedFrames = 0
        var tightest = CGFloat.greatestFiniteMagnitude
        // Distance covered is measured on the shoal's centre of mass, not
        // on one fish: `Dictionary.values` comes out in whatever order it
        // likes from frame to frame, so "the first fish" is a different
        // animal each time and its apparent travel is noise.
        var travelled: CGFloat = 0
        var previousCentre = centroid(manager.animals.values.map(\.position))

        for _ in 0..<6000 {
            manager.update(dt: frameInterval, playerEye: eye, world: world, threats: [])
            let fish = manager.animals.values.filter { $0.kind == .cod }
            driedFrames += fish.filter { !$0.isSwimming }.count
            tightest = min(tightest, minimumPairwiseDistance(fish.map(\.position)))
            let centre = centroid(fish.map(\.position))
            travelled += (centre - previousCentre).length()
            previousCentre = centre
        }

        let endSpread = meanPairwiseDistance(
            manager.animals.values.filter { $0.kind == .cod }.map(\.position)
        )
        // Cohesion: they have to end up nearer each other than they began.
        report.check(
            "a scattered shoal gathers",
            endSpread < startSpread * 0.7,
            String(format: "mean gap %.2f → %.2f blocks over 60 s", startSpread, endSpread)
        )
        // Separation: and not by piling into one point, which is the
        // failure that looks identical to success in every summary but this
        // one. A shoal collapsed to a knot of fish is worse than no shoal.
        report.check(
            "and does not collapse into a knot",
            tightest > 0.25,
            String(format: "closest two fish ever came was %.2f blocks", tightest)
        )
        // And the bank still wins. Cohesion is the one urge that will
        // happily aim a whole shoal at the shore.
        report.check(
            "and stays in the water while it does it",
            driedFrames == 0,
            driedFrames == 0
                ? String(format: "6000 frames, 6 fish, all wet; the shoal itself covered %.1f blocks", travelled)
                : "\(driedFrames) fish-frames out of the water"
        )
    }

    // MARK: - The chicken

    /// A chicken and a pig pushed off the same ledge on the same frame.
    ///
    /// The pig is the control and it is the whole point of the line: "the
    /// chicken fell slowly" is unfalsifiable without something falling
    /// beside it that did not.
    private static func checkGlide(
        world: World, originX: Int, originZ: Int, deck: Int, report: inout Report
    ) {
        let dropHeight = CGFloat(deck) + 7
        let dry = CGFloat(originX + pondHalf + 4) + 0.5
        var chicken = Animal(
            kind: .chicken, position: Vector3(dry, dropHeight, CGFloat(originZ) + 0.5), seed: 0xC41C
        )
        var pig = Animal(
            kind: .pig, position: Vector3(dry + 2, dropHeight, CGFloat(originZ) + 0.5), seed: 0x9163
        )

        var chickenFrames = 0
        var pigFrames = 0
        var chickenFastest: CGFloat = 0
        var flappedFrames = 0
        for frame in 0..<1200 {
            if !chicken.isGrounded {
                chicken.step(dt: frameInterval, world: world)
                chickenFastest = min(chickenFastest, chicken.velocity.y)
                if chicken.isGliding { flappedFrames += 1 }
                chickenFrames = frame
            }
            if !pig.isGrounded {
                pig.step(dt: frameInterval, world: world)
                pigFrames = frame
            }
        }

        report.check(
            "a chicken beats its wings on the way down",
            chicken.isGrounded && chickenFrames > pigFrames,
            String(format: "chicken took %.2f s to fall, pig took %.2f s",
                   Double(chickenFrames) * frameInterval, Double(pigFrames) * frameInterval)
        )
        report.check(
            "and never falls faster than a beat can hold it",
            chickenFastest >= (AnimalKind.chicken.glideFallSpeed ?? 0) - 0.01 && flappedFrames > 0,
            String(format: "fastest descent %.2f blocks/s against a cap of %.2f, over %d flapping frames",
                   chickenFastest, AnimalKind.chicken.glideFallSpeed ?? 0, flappedFrames)
        )
    }

    // MARK: - Herds

    /// One spawn attempt has to put down more than one animal.
    ///
    /// The claim is about arrival, not about the population: twelve animals
    /// that trickled in one at a time and twelve that arrived as four herds
    /// are the same number and a completely different field.
    private static func checkGroupSpawn(
        world: World, originX: Int, originZ: Int, deck: Int, report: inout Report
    ) {
        var manager = AnimalManager(mode: .survival, seed: 0x11E4D)
        let eye = Vector3(CGFloat(originX) + 0.5, CGFloat(deck) + 3, CGFloat(originZ) + 0.5)
        // One interval's worth of time, and no more: the point is that a
        // single attempt lands a group, so this must not run long enough
        // for a second attempt to be what produced the company.
        var arrivals = 0
        while arrivals == 0 {
            manager.update(dt: AnimalManager.spawnInterval + 0.01, playerEye: eye, world: world, threats: [])
            arrivals = manager.animals.count
            guard arrivals > 0 || manager.animals.isEmpty else { break }
            if arrivals > 0 { break }
        }

        let byKind = Dictionary(grouping: manager.animals.values, by: \.kind)
        let largest = byKind.max { $0.value.count < $1.value.count }
        let together = largest?.value.count ?? 0
        report.check(
            "animals arrive in company",
            together >= 2,
            "one spawn put down \(together) × \(largest?.key.identifier ?? "nothing")"
        )

        // Together, but not stacked: they do not collide with one another,
        // so a group placed on one column is a single animal-shaped blob.
        let spread = largest.map { meanPairwiseDistance($0.value.map(\.position)) } ?? 0
        report.check(
            "and not all in the same cell",
            together < 2 || spread > 0.6,
            String(format: "mean gap within the group %.2f blocks", spread)
        )
    }

    // MARK: - Threat response

    /// A cow within `AnimalManager.threatRadius` of a fizzler or skeleton
    /// bolts away from it without being touched; one twice the radius away
    /// never notices; a tamed wolf standing exactly where the cow was
    /// never flees at all — it defends instead, which is `checkWolfDefends`
    /// below's claim, not this one. Three lines because "a herd scatters
    /// when danger gets close" is three separate claims — proximity gates
    /// it, distance runs out the clock on it, and taming overrides it
    /// outright — and each fails in a different way if the wiring is wrong.
    private static func checkThreatResponse(
        world: World, originX: Int, originZ: Int, deck: Int, report: inout Report
    ) {
        let standY = CGFloat(deck) + 1
        let eye = Vector3(CGFloat(originX) + 0.5, CGFloat(deck) + 3, CGFloat(originZ) + 0.5)
        let threat = AnimalManager.Threat(
            id: 1, isFizzler: true, position: Vector3(CGFloat(originX) + 0.5, standY, CGFloat(originZ) + 0.5)
        )

        var near = AnimalManager(mode: .survival, seed: 0x7EA7)
        let cowStart = Vector3(CGFloat(originX) + 4.5, standY, CGFloat(originZ) + 0.5)
        near.adopt([Animal(kind: .cow, position: cowStart, seed: 0xC0)])
        // Captured now, before the first `update` below has any chance to
        // spawn a second animal in: with only a cow in the population every
        // other kind reads as "never seen", which is `trySpawn`'s own cue to
        // place one regardless of the cap (see `hasRoom`'s doc comment) — so
        // `animals.keys.first!` read *after* a spawn is not reliably this
        // cow. Dictionary order is unspecified and did in fact differ enough
        // between a debug and a release build to pick up the newcomer
        // instead, which is what a first version of this check found the
        // hard way.
        let cowID = near.animals.keys.first!
        near.update(dt: 0.05, playerEye: eye, world: world, threats: [threat])
        report.check(
            "a cow within range bolts from a threat that never touched it",
            { if case .fleeing = near.animals[cowID]!.activity { return true }; return false }(),
            "activity after one frame beside a threat: \(near.animals[cowID]!.activity)"
        )
        var fled: CGFloat = 0
        for _ in 0..<60 {
            near.update(dt: 0.05, playerEye: eye, world: world, threats: [threat])
            fled = (near.animals[cowID]!.position - threat.position).length()
        }
        report.check(
            "and actually puts distance between itself and it",
            fled > (cowStart - threat.position).length(),
            String(format: "gap %.1f → %.1f blocks over 3 s", (cowStart - threat.position).length(), fled)
        )

        var far = AnimalManager(mode: .survival, seed: 0x7EA8)
        let farStart = Vector3(CGFloat(originX) + 4.5 + AnimalManager.threatRadius * 2, standY, CGFloat(originZ) + 0.5)
        far.adopt([Animal(kind: .cow, position: farStart, seed: 0xC1)])
        let farID = far.animals.keys.first!
        far.update(dt: 0.05, playerEye: eye, world: world, threats: [threat])
        report.check(
            "a cow well outside that range never notices",
            { if case .idle = far.animals[farID]!.activity { return true }; return false }(),
            "activity for a cow \(String(format: "%.0f", AnimalManager.threatRadius * 2)) blocks off: \(far.animals[farID]!.activity)"
        )

        // Just past `defendRadius` (6.0) but still inside `threatRadius`
        // (8.0): a wolf that neither flees nor closes in, the one band
        // where "tamed" alone is doing all the work and defending hasn't
        // kicked in yet.
        var pet = AnimalManager(mode: .survival, seed: 0x7EA9)
        let dogStart = Vector3(CGFloat(originX) + 6.5, standY, CGFloat(originZ) + 0.5)
        var dog = Animal(kind: .wolf, position: dogStart, seed: 0xD06)
        dog.isTamed = true
        pet.adopt([dog])
        let dogID = pet.animals.keys.first!
        pet.update(dt: 0.05, playerEye: eye, world: world, threats: [threat])
        report.check(
            "a tamed wolf just outside defendRadius holds its ground",
            { if case .idle = pet.animals[dogID]!.activity { return true }; return false }(),
            "activity for a leashed wolf beside a threat: \(pet.animals[dogID]!.activity)"
        )
    }

    /// A tamed wolf within `AnimalManager.defendRadius` closes on a threat
    /// instead of following its owner, and actually lands a bite once it's
    /// close enough — the tamed answer to `checkThreatResponse`'s cow, and
    /// the whole reason a wolf is worth taming beyond company.
    private static func checkWolfDefends(
        world: World, originX: Int, originZ: Int, deck: Int, report: inout Report
    ) {
        let standY = CGFloat(deck) + 1
        // Out past `pondHalf` (24) but still on the dry ring of the table
        // (`tableHalf`, 30): `checkThreatResponse`'s cow can fall into the
        // pond mid-flight and still pass its check, since it only has to
        // put distance behind it — but a wolf closing to a precise bite
        // range has to actually keep its footing to get there, so this
        // check needs the one patch of deck that's solid stone rather than
        // eight blocks of water over it.
        let threatZ = CGFloat(originZ) + 26
        let dogZ = CGFloat(originZ) + 29.5
        let eye = Vector3(CGFloat(originX) + 0.5, CGFloat(deck) + 3, threatZ)
        let threat = AnimalManager.Threat(
            id: 7, isFizzler: false, position: Vector3(CGFloat(originX) + 0.5, standY, threatZ)
        )

        var pack = AnimalManager(mode: .survival, seed: 0x7EAA)
        var dog = Animal(kind: .wolf, position: Vector3(CGFloat(originX) + 0.5, standY, dogZ), seed: 0xD07)
        dog.isTamed = true
        pack.adopt([dog])
        let dogID = pack.animals.keys.first!

        var closed: CGFloat = .greatestFiniteMagnitude
        var bitten = false
        for _ in 0..<300 {
            let landed = pack.update(dt: 0.05, playerEye: eye, world: world, threats: [threat])
            closed = min(closed, (pack.animals[dogID]!.position - threat.position).length())
            if landed.contains(where: { $0.threat.id == threat.id }) { bitten = true }
        }
        report.check(
            "a tamed wolf within defendRadius closes to bite range on a threat",
            closed <= Animal.biteRange + 0.05,
            String(format: "closest approach over 15 s: %.2f blocks (bite range %.2f)", closed, Animal.biteRange)
        )
        report.check(
            "and actually lands a bite once it gets there",
            bitten,
            bitten ? "a bite landed within 15 s of closing in" : "no bite landed in 15 s of standing beside the threat"
        )

        var sitting = AnimalManager(mode: .survival, seed: 0x7EAB)
        var seated = Animal(kind: .wolf, position: Vector3(CGFloat(originX) + 0.5, standY, dogZ), seed: 0xD08)
        seated.isTamed = true
        seated.isSitting = true
        sitting.adopt([seated])
        let seatedID = sitting.animals.keys.first!
        sitting.update(dt: 0.05, playerEye: eye, world: world, threats: [threat])
        report.check(
            "a wolf told to sit stays out of the fight",
            { if case .defending = sitting.animals[seatedID]!.activity { return false }; return true }(),
            "activity for a seated wolf beside a threat: \(sitting.animals[seatedID]!.activity)"
        )

        // A skeleton bites back; a fizzler never does. Sending a wolf after
        // a skeleton is a real wager now, not a free kill. Retaliation is
        // costed through `SkeletonManager.shotDamage(distanceFromSpawn:)`,
        // the same distance-scaled arithmetic an arrow costs the player —
        // not the flat `Skeleton.shotDamage` constant underneath it — so
        // this whole scenario is run twice below, at the doorstep and past
        // the ramp, to prove the wiring actually reaches the scale rather
        // than just re-checking the pure function `SkeletonCheck` already
        // covers.
        func fightSkeleton(at eye: Vector3, threat: AnimalManager.Threat, seed: UInt64) -> Int? {
            var pack = AnimalManager(mode: .survival, seed: seed)
            var fighter = Animal(kind: .wolf, position: Vector3(CGFloat(originX) + 0.5, standY, dogZ), seed: 0xD09)
            fighter.isTamed = true
            pack.adopt([fighter])
            let fighterID = pack.animals.keys.first!
            let distanceFromSpawn = (eye - world.spawnPosition()).length()
            // Four seconds, not fifteen: long enough to guarantee a bite
            // lands and the skeleton answers it, short of the ~8 s of
            // continuous doorstep retaliation a 16-health wolf could
            // actually die to at the unscaled rate — the far scenario
            // below is exactly the case where dying inside 4 s is the
            // point, not an accident of the loop running too long.
            for _ in 0..<80 {
                // Mirrors `GameViewController.updateAnimals`'s own wiring —
                // the manager only reports a landed bite, applying it back
                // onto the wolf is the caller's job, same as it is for the
                // fizzler and skeleton it bites.
                let landed = pack.update(dt: 0.05, playerEye: eye, world: world, threats: [threat])
                for bite in landed {
                    let retaliation = SkeletonManager.shotDamage(distanceFromSpawn: distanceFromSpawn)
                    _ = pack.damage(id: bite.wolfID, amount: retaliation, knockback: .zero)
                }
            }
            return pack.animals[fighterID]?.health
        }

        let skeletonFighterHealth = fightSkeleton(at: eye, threat: threat, seed: 0x7EAC)
        report.check(
            "a skeleton bites back at the wolf that's biting it",
            (skeletonFighterHealth ?? 0) < AnimalKind.wolf.maxHealth,
            "wolf health after 4 s fighting a skeleton at the doorstep: "
                + "\(skeletonFighterHealth.map(String.init) ?? "dead") (started at \(AnimalKind.wolf.maxHealth))"
        )

        let farOffset = FizzlerManager.dangerRampDistance + 100
        let farEye = Vector3(eye.x + farOffset, eye.y, eye.z)
        let farThreat = AnimalManager.Threat(
            id: threat.id, isFizzler: false, position: Vector3(threat.position.x + farOffset, standY, threat.position.z)
        )
        let farFighterHealth = fightSkeleton(at: farEye, threat: farThreat, seed: 0x7EAC)
        report.check(
            "and the same four seconds is fatal once distance from spawn triples the bite",
            farFighterHealth == nil,
            "wolf health after 4 s fighting a skeleton \(Int(farOffset)) blocks out: "
                + "\(farFighterHealth.map(String.init) ?? "dead") — the doorstep fight over the same window left it at "
                + "\(skeletonFighterHealth.map(String.init) ?? "dead")"
        )

        let fizzlerThreat = AnimalManager.Threat(
            id: 8, isFizzler: true, position: Vector3(CGFloat(originX) + 0.5, standY, threatZ)
        )
        var vsFizzler = AnimalManager(mode: .survival, seed: 0x7EAD)
        var fizzlerFighter = Animal(kind: .wolf, position: Vector3(CGFloat(originX) + 0.5, standY, dogZ), seed: 0xD0A)
        fizzlerFighter.isTamed = true
        vsFizzler.adopt([fizzlerFighter])
        let fizzlerFighterID = vsFizzler.animals.keys.first!
        for _ in 0..<300 { vsFizzler.update(dt: 0.05, playerEye: eye, world: world, threats: [fizzlerThreat]) }
        report.check(
            "a fizzler never bites back — its only weapon is a fuse aimed at the player",
            vsFizzler.animals[fizzlerFighterID]!.health == AnimalKind.wolf.maxHealth,
            "wolf health after 15 s fighting a fizzler: \(vsFizzler.animals[fizzlerFighterID]!.health) "
                + "(started at \(AnimalKind.wolf.maxHealth))"
        )
    }

    /// Dying clears the wildlife gathered around the old spawn so the new
    /// one gets its own herd — but a tamed pet is not wildlife, and a
    /// reload already promises it survives (`PetCheck`). This is the other
    /// half of that promise: a fizzler's fuse shouldn't delete what a
    /// closed app wouldn't.
    private static func checkRespawnSparesPets(report: inout Report) {
        var manager = AnimalManager(mode: .survival, seed: 0x7EAF)
        var wild = Animal(kind: .cow, position: Vector3(0, 64, 0), seed: 0xD0B)
        wild.isTamed = false
        var tame = Animal(kind: .wolf, position: Vector3(2, 64, 0), seed: 0xD0C)
        tame.isTamed = true
        manager.adopt([wild, tame])
        let tameID = manager.animals.first { $0.value.isTamed }!.key

        manager.removeAllWild()

        report.check(
            "respawn's cleanup spares a tamed pet",
            manager.animals[tameID] != nil,
            "tamed wolf present after removeAllWild: \(manager.animals[tameID] != nil)"
        )
        report.check(
            "and still clears the wild animals around the old spawn",
            manager.animals.values.allSatisfy { $0.isTamed },
            "animals remaining after removeAllWild: \(manager.animals.count), all tamed: "
                + "\(manager.animals.values.allSatisfy { $0.isTamed })"
        )
    }

    // MARK: - Canopies

    /// No land animal may be standing on leaves or a trunk.
    ///
    /// `isSolid` is true for both, so the plain "first solid thing from the
    /// top" walk every spawner shares used to stop on the canopy — and a
    /// forest is exactly where a herd wants to be, so this was quietly
    /// putting cows in the treetops.
    private static func checkCanopy(
        world: World, spawn: Vector3, report: inout Report
    ) {
        var manager = AnimalManager(mode: .survival, seed: 0x7BEE)
        var treetopFrames = 0
        var checked = 0
        var worst = ""
        for _ in 0..<900 {
            manager.update(dt: 0.05, playerEye: spawn, world: world, threats: [])
            for animal in manager.animals.values where !animal.kind.isAquatic {
                checked += 1
                let below = world.block(
                    worldX: Int(floor(animal.position.x)),
                    y: Int(floor(animal.position.y - 0.1)),
                    worldZ: Int(floor(animal.position.z))
                )
                if below == .leaves || below == .log {
                    treetopFrames += 1
                    if worst.isEmpty {
                        worst = String(
                            format: "%@ on %@ at (%.1f, %.1f, %.1f)",
                            animal.kind.identifier, below == .leaves ? "leaves" : "a trunk",
                            animal.position.x, animal.position.y, animal.position.z
                        )
                    }
                }
            }
        }
        report.check(
            "nothing stands in a tree",
            treetopFrames == 0 && checked > 0,
            treetopFrames == 0
                ? "\(checked) animal-frames over real forest, none on a canopy"
                : "\(treetopFrames) of \(checked) animal-frames in a tree — \(worst)"
        )
    }

    /// Nothing stands in lava either — the same `isWater`-only clearance
    /// check `groundHeight` shares with the fizzler and skeleton spawners,
    /// but with no darkness gate to fall back on. Standing over lava kills
    /// a player on contact (`LavaCheck`); a fizzler or skeleton can never
    /// actually spawn there since lava's own light emission fails their
    /// `canSpawn` darkness requirement, but an animal spawns around the
    /// clock with no light check at all, so a cow left floating over a
    /// mineshaft's own exposed lake was a real, reachable bug, not a
    /// theoretical one — the one place a player could genuinely dig a hole
    /// through, in a real habitat biome, and have an animal spawn into it.
    private static func checkNoSpawnInLava(
        world: World, spawn: Vector3, report: inout Report
    ) {
        // Half the spawn ring floored in lava, centred on spawn itself —
        // biome is a noise function of x/z, and only spawn's own column is
        // *guaranteed* tree-bearing land since iteration 58, but biome
        // regions run for many tens of blocks, so the ring around it reads
        // the same. Covering half the ring rather than one small patch is
        // what makes a random spawn attempt actually land on it often
        // enough to prove the point, while leaving the other half as
        // ordinary ground — proving the exclusion turns away a bad site
        // rather than just breaking spawning near it altogether.
        let originX = Int(spawn.x), originZ = Int(spawn.z)
        let outer = Int(AnimalManager.maximumSpawnDistance) + 1
        let inner = Int(AnimalManager.minimumSpawnDistance) - 1
        let floorY = Int(spawn.y)
        for dz in -outer...outer {
            for dx in 0...outer {
                let distanceSquared = dx * dx + dz * dz
                guard distanceSquared >= inner * inner, distanceSquared <= outer * outer else { continue }
                // Open all the way up: a roof here would be the first
                // solid thing `groundHeight` finds walking down from the
                // sky, and the lava underneath would never be reached.
                for y in (floorY + 1)...(floorY + 30) {
                    world.setBlock(worldX: originX + dx, y: y, worldZ: originZ + dz, to: .air, remesh: false)
                }
                world.setBlock(worldX: originX + dx, y: floorY, worldZ: originZ + dz, to: .lava, remesh: false)
                world.setBlock(worldX: originX + dx, y: floorY - 1, worldZ: originZ + dz, to: .stone, remesh: false)
            }
        }

        let eye = spawn
        var manager = AnimalManager(mode: .survival, seed: 0x1A4A)
        var worstFound: Animal?
        var seen: Set<Int> = []
        var spawnCount = 0
        for _ in 0..<3000 {
            manager.update(dt: frameInterval, playerEye: eye, world: world, threats: [])
            // Checked the instant each animal is first seen, not over its
            // whole life — ordinary wandering has no lava avoidance at all
            // (`collides` only tests `isSolid`), so a long-running sweep
            // would conflate that separate, much larger gap with the one
            // actually being fixed here: where a spawn attempt lands.
            for (id, animal) in manager.animals where !seen.contains(id) {
                seen.insert(id)
                guard !animal.kind.isAquatic else { continue }
                spawnCount += 1
                if world.isLava(
                    worldX: Int(floor(animal.position.x)), y: Int(floor(animal.position.y)),
                    worldZ: Int(floor(animal.position.z))
                ) {
                    worstFound = animal
                }
            }
            if worstFound != nil || spawnCount >= 6 { break }
        }
        report.check(
            "spawning still succeeds on the untouched half of the ring",
            spawnCount > 0,
            "\(spawnCount) land animal(s) spawned near a half-lava ring"
        )
        report.check(
            "and nothing spawns standing in the lava half",
            worstFound == nil,
            worstFound == nil
                ? "\(spawnCount) land animal(s) spawned near a real lava field, none in it"
                : "\(worstFound!.kind.identifier) found in lava at "
                    + "(\(worstFound!.position.x), \(worstFound!.position.y), \(worstFound!.position.z))"
        )
    }

    // MARK: - Measures

    private static func centroid(_ points: [Vector3]) -> Vector3 {
        guard !points.isEmpty else { return .zero }
        var total = Vector3.zero
        for point in points { total = total + point }
        return total * (1 / CGFloat(points.count))
    }

    private static func meanPairwiseDistance(_ points: [Vector3]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var total: CGFloat = 0
        var pairs = 0
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                total += (points[i] - points[j]).length()
                pairs += 1
            }
        }
        return pairs == 0 ? 0 : total / CGFloat(pairs)
    }

    private static func minimumPairwiseDistance(_ points: [Vector3]) -> CGFloat {
        guard points.count > 1 else { return .greatestFiniteMagnitude }
        var closest = CGFloat.greatestFiniteMagnitude
        for i in 0..<points.count {
            for j in (i + 1)..<points.count {
                closest = min(closest, (points[i] - points[j]).length())
            }
        }
        return closest
    }
}

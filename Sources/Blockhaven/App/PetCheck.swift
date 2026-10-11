import Foundation

/// Headless proof that a tamed animal is actually kept.
///
/// A pet is a promise — feed this and it will be there later — and every
/// way of breaking that promise is invisible in a screenshot. A dog that
/// follows beautifully for ten seconds and then despawns because the player
/// walked past the despawn radius looks identical, right up until it is
/// gone. So does one that follows but never catches up, or one that heels
/// so tightly it stands inside you, or one told to sit that wanders off
/// anyway.
///
/// `BLOCKHAVEN_CHECK_PET=1`. Exits nonzero if any line fails.
enum PetCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_PET"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    private static let dt = 1.0 / 60

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

        // A wolf a few blocks away, and a player who does not move.
        func freshPack(at offset: CGFloat) -> AnimalManager {
            var manager = AnimalManager(mode: .survival, seed: 0xD065)
            let ground = world.generator.surfaceHeight(
                x: Int(spawn.x + offset), z: Int(spawn.z)
            )
            manager.adopt([Animal(
                kind: .wolf,
                position: Vector3(spawn.x + offset, CGFloat(ground + 1), spawn.z),
                seed: 0x5EED
            )])
            return manager
        }

        // MARK: taming

        var pack = freshPack(at: 4)
        var id = pack.animals.keys.first ?? 0
        report.check(
            "a wild wolf is not yours",
            pack.animals[id]?.isTamed == false,
            "tamed \(pack.animals[id]?.isTamed.description ?? "gone")"
        )
        let fed = pack.feed(id)
        report.check(
            "feeding one tames it, first time",
            fed && pack.animals[id]?.isTamed == true,
            "fed \(fed), tamed \(pack.animals[id]?.isTamed.description ?? "gone")"
        )
        report.check(
            "and feeding it again does nothing",
            !pack.feed(id),
            "second helping refused"
        )

        // A pig cannot be kept, however much you feed it.
        var farm = AnimalManager(mode: .survival, seed: 0xF00D)
        let ground = world.generator.surfaceHeight(x: Int(spawn.x), z: Int(spawn.z))
        farm.adopt([Animal(kind: .pig, position: Vector3(spawn.x, CGFloat(ground + 1), spawn.z), seed: 0x5EED)])
        let pigID = farm.animals.keys.first ?? 0
        report.check(
            "a pig is not a pet",
            !farm.feed(pigID) && farm.animals[pigID]?.isTamed == false,
            "pig refused the offer"
        )

        // MARK: following

        // First the simplest claim there is: a pet left behind closes the
        // gap to a player who is standing still. If this fails, follow is
        // broken; if it passes and the walking test below fails, the dog is
        // losing to the terrain rather than to the arithmetic.
        pack = freshPack(at: 14)
        id = pack.animals.keys.first ?? 0
        pack.feed(id)
        var standing = spawn
        standing.y = CGFloat(world.generator.surfaceHeight(x: Int(spawn.x), z: Int(spawn.z)) + 1)
        let startGap = pack.animals[id].map { ($0.position - standing).length() } ?? 0
        for _ in 0..<600 { pack.update(dt: dt, playerEye: standing, world: world, threats: []) }
        let closedGap = pack.animals[id].map { ($0.position - standing).length() } ?? 999
        report.check(
            "a pet comes to a player standing still",
            closedGap <= AnimalKind.followDistance + 1.5,
            String(format: "%.1f blocks away, closed from %.1f over 10 s", closedGap, startGap)
        )

        // The player walks away in a straight line; the dog has to close.
        pack = freshPack(at: 4)
        id = pack.animals.keys.first ?? 0
        pack.feed(id)
        var walker = spawn
        var gapWhileWalking: [CGFloat] = []
        for frame in 0..<900 {
            // Two blocks a second, well under the wolf's 2.2 walk times its
            // follow sprint, so it can in fact keep up.
            walker.x += CGFloat(dt) * 2.0
            walker.y = CGFloat(world.generator.surfaceHeight(x: Int(walker.x), z: Int(walker.z)) + 1)
            pack.update(dt: dt, playerEye: walker, world: world, threats: [])
            if frame % 60 == 0, let animal = pack.animals[id] {
                gapWhileWalking.append((animal.position - walker).length())
            }
        }
        let stillThere = pack.animals[id] != nil
        report.check(
            "a pet is still there after a long walk",
            stillThere,
            stillThere ? "the wolf is still in the population" : "it despawned"
        )
        let worstGap = gapWhileWalking.max() ?? 999
        report.check(
            "and it keeps up",
            worstGap <= AnimalKind.recallDistance + 1,
            String(format: "worst gap over 15 s of walking %.1f blocks, recall at %.0f", worstGap, Double(AnimalKind.recallDistance))
        )
        // And it does not walk into you.
        let finalGap = pack.animals[id].map { ($0.position - walker).length() } ?? 0
        report.check(
            "and it does not stand on top of you",
            finalGap > 0.5,
            String(format: "%.1f blocks away when the walking stopped", finalGap)
        )

        // MARK: not despawning

        // The despawn radius is what would quietly break the promise, so it
        // is tested directly: the player goes far enough that any untamed
        // animal would be gone.
        pack = freshPack(at: 4)
        id = pack.animals.keys.first ?? 0
        var wild = AnimalManager(mode: .survival, seed: 0xD065)
        wild.adopt([Animal(
            kind: .wolf,
            position: Vector3(spawn.x + 4, CGFloat(world.generator.surfaceHeight(
                x: Int(spawn.x + 4), z: Int(spawn.z)) + 1), spawn.z),
            seed: 0x5EED
        )])
        let wildID = wild.animals.keys.first ?? 0
        pack.feed(id)

        // Teleport the player far off, in one step, and tick both.
        let far = Vector3(spawn.x + 400, spawn.y, spawn.z)
        pack.update(dt: dt, playerEye: far, world: world, threats: [])
        wild.update(dt: dt, playerEye: far, world: world, threats: [])
        report.check(
            "a wild animal left far behind is dropped",
            wild.animals[wildID] == nil,
            "the untamed wolf despawned, as it should"
        )
        report.check(
            "and a pet left far behind is not",
            pack.animals[id] != nil,
            pack.animals[id] != nil ? "the pet survived" : "the pet was despawned too"
        )
        // It should also have been put back beside the player rather than
        // left four hundred blocks away trying to walk it.
        let recalled = pack.animals[id].map { ($0.position - far).length() } ?? 999
        report.check(
            "and it is put back beside you rather than left to walk",
            recalled < AnimalKind.recallDistance,
            String(format: "%.1f blocks away after the recall", recalled)
        )

        // MARK: sitting

        pack = freshPack(at: 2)
        id = pack.animals.keys.first ?? 0
        pack.feed(id)
        pack.toggleSit(id)
        report.check(
            "right-clicking a pet sits it down",
            pack.animals[id]?.isSitting == true,
            "sitting \(pack.animals[id]?.isSitting.description ?? "gone")"
        )
        let satAt = pack.animals[id]?.position ?? .zero
        var runner = spawn
        for _ in 0..<600 {
            runner.x += CGFloat(dt) * 3.0
            runner.y = CGFloat(world.generator.surfaceHeight(x: Int(runner.x), z: Int(runner.z)) + 1)
            pack.update(dt: dt, playerEye: runner, world: world, threats: [])
        }
        let drift = pack.animals[id].map { ($0.position - satAt).length() } ?? 999
        report.check(
            "and a sitting pet stays where it was told",
            drift < 2.0 && pack.animals[id] != nil,
            String(format: "drifted %.2f blocks while the player walked 30", drift)
        )

        // MARK: surviving a save

        // A tamed, sitting, rare-morph wolf and an untamed pig in the same
        // population. Only the promise taming makes is worth a save slot —
        // the pig is here to prove it's the one left out, not forgotten.
        var kept = AnimalManager(mode: .survival, seed: 0xD065)
        kept.adopt([
            Animal(
                kind: .wolf, position: Vector3(spawn.x + 6, spawn.y + 1, spawn.z - 3),
                seed: 0x5EED, morph: .rare
            ),
            Animal(kind: .pig, position: Vector3(spawn.x, spawn.y + 1, spawn.z), seed: 0x5EED),
        ])
        let keptIDs = Array(kept.animals.keys)
        for keptID in keptIDs where kept.animals[keptID]?.kind == .wolf {
            kept.feed(keptID)
            kept.toggleSit(keptID)
        }

        let saved = WorldSave(
            seed: 1, mode: .survival, name: "t", lastPlayed: 0,
            edits: [:], position: spawn, yaw: 0, pitch: 0,
            inventory: Inventory(), stats: PlayerStats(), timeOfDay: 0,
            animals: kept
        )
        report.check(
            "only the tamed one makes it into the file",
            saved.animals?.count == 1,
            "\(saved.animals?.count ?? -1) animal(s) written"
        )

        let restored = saved.restoredAnimals
        report.check(
            "and comes back tamed, sitting, and the same rare colour",
            restored.count == 1 && restored[0].kind == .wolf
                && restored[0].isTamed && restored[0].isSitting && restored[0].morph == .rare,
            "\(restored.count) animal(s), first is \(restored.first.map { "\($0.kind), tamed \($0.isTamed), sitting \($0.isSitting), \($0.morph)" } ?? "missing")"
        )
        let restoredPosition = restored.first?.position ?? .zero
        let savedWolfPosition = Vector3(spawn.x + 6, spawn.y + 1, spawn.z - 3)
        report.check(
            "at the position it was saved at",
            (restoredPosition - savedWolfPosition).length() < 0.01,
            "restored at \(restoredPosition), saved at \(savedWolfPosition)"
        )

        // A kind this build no longer has a case for — a future rename, or
        // a hand-edited file — drops that one pet instead of the whole list
        // failing to decode, the same forgiveness every other saved list in
        // the file shows an item it doesn't recognise.
        var withUnknownKind = saved
        withUnknownKind.animals?.append(
            WorldSave.SavedAnimal(
                kind: "dragon", x: 0, y: 0, z: 0, isSitting: false, isRareMorph: false
            )
        )
        report.check(
            "an unreadable kind drops just that one pet, not the rest",
            withUnknownKind.restoredAnimals.count == 1,
            "\(withUnknownKind.restoredAnimals.count) animal(s) survived decoding"
        )

        // A restore has to add to an existing population rather than wipe
        // it — the spawner may already have put wild animals down by the
        // time a save finishes loading.
        var arriving = AnimalManager(mode: .survival, seed: 0xF00D)
        arriving.adopt([Animal(kind: .cow, position: spawn, seed: 0x5EED)])
        arriving.restore(restored)
        report.check(
            "restoring a pet adds to the population instead of replacing it",
            arriving.animals.count == 2,
            "\(arriving.animals.count) animal(s) after restoring one pet into an existing herd"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the pet\n"
            : "[check] all passed — the pet\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

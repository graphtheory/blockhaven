import Foundation

/// Headless proof of the wheat-breeds-a-herd loop: two fed animals close
/// together turn into three, the two spent parents cannot be fed straight
/// back into it, distance and the population cap both still hold, and a
/// wolf — already tameable a different way — never enters love mode at all.
///
/// `BLOCKHAVEN_CHECK_BREED=1`. Exits nonzero if any line fails.
enum BreedCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_BREED"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    static func run() -> Never {
        var report = Report()
        let world = World()
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dz in -3...3 {
            for dx in -3...3 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }
        // MARK: two pigs, close together, both fed — one becomes three

        var manager = AnimalManager(mode: .survival, seed: 0xB4EED)
        manager.spawn(kind: .pig, at: spawn)
        manager.spawn(kind: .pig, at: Vector3(spawn.x + 1, spawn.y, spawn.z))
        let ids = manager.animals.keys.sorted()
        report.check("two pigs actually landed", ids.count == 2, "\(ids.count) animals after spawning two")

        report.check(
            "wheat puts a pig in love",
            manager.feedForBreeding(ids[0]) && manager.animals[ids[0]]!.isInLove,
            "fed: \(manager.animals[ids[0]]?.isInLove ?? false)"
        )
        report.check(
            "and the second one too",
            manager.feedForBreeding(ids[1]) && manager.animals[ids[1]]!.isInLove,
            "fed: \(manager.animals[ids[1]]?.isInLove ?? false)"
        )

        manager.breed()
        let pigsAfterOne = manager.animals.values.filter { $0.kind == .pig }.count
        report.check(
            "two pigs in love, close together, become three",
            pigsAfterOne == 3,
            "\(pigsAfterOne) pigs after one update"
        )
        report.check(
            "and both parents spend their love on it",
            manager.animals[ids[0]]?.isInLove == false && manager.animals[ids[1]]?.isInLove == false,
            "parent 0 in love: \(manager.animals[ids[0]]?.isInLove ?? false), "
                + "parent 1: \(manager.animals[ids[1]]?.isInLove ?? false)"
        )
        report.check(
            "and cannot be fed straight back into it",
            !manager.feedForBreeding(ids[0]),
            "fed again: \(manager.feedForBreeding(ids[0]))"
        )

        // MARK: too far apart never pairs at all

        var apart = AnimalManager(mode: .survival, seed: 0x9A9A)
        apart.spawn(kind: .sheep, at: spawn)
        apart.spawn(kind: .sheep, at: Vector3(spawn.x + AnimalManager.breedRadius + 6, spawn.y, spawn.z))
        let apartIDs = apart.animals.keys.sorted()
        apart.feedForBreeding(apartIDs[0])
        apart.feedForBreeding(apartIDs[1])
        apart.breed()
        report.check(
            "too far apart, love mode alone does not breed",
            apart.animals.count == 2,
            "\(apart.animals.count) sheep after one update, \(AnimalManager.breedRadius) block radius"
        )

        // MARK: a wolf — tameable a different way — never enters love mode

        var wolfManager = AnimalManager(mode: .survival, seed: 0x0)
        wolfManager.spawn(kind: .wolf, at: spawn)
        let wolfID = wolfManager.animals.keys.first!
        report.check(
            "a tameable animal does not breed on wheat",
            !wolfManager.feedForBreeding(wolfID),
            "fed: \(wolfManager.feedForBreeding(wolfID))"
        )

        // MARK: the population cap still holds even with two willing parents

        var atCap = AnimalManager(mode: .survival, seed: 0x5EED)
        for i in 0..<AnimalKind.chicken.maximumAlive {
            atCap.spawn(kind: .chicken, at: Vector3(spawn.x + CGFloat(i) * 2, spawn.y, spawn.z))
        }
        let capIDs = atCap.animals.keys.sorted()
        atCap.feedForBreeding(capIDs[0])
        atCap.feedForBreeding(capIDs[1])
        atCap.breed()
        report.check(
            "a kind already at its own cap does not breed past it",
            atCap.animals.values.filter { $0.kind == .chicken }.count == AnimalKind.chicken.maximumAlive,
            "\(atCap.animals.values.filter { $0.kind == .chicken }.count) chickens against a cap of "
                + "\(AnimalKind.chicken.maximumAlive)"
        )

        // MARK: love fades on its own if nothing answers it

        var alone = Animal(kind: .cow, position: .zero, seed: 1)
        alone.enterLove()
        var elapsed = 0.0
        while elapsed < Animal.loveDuration + 1 {
            alone.step(dt: 0.1, world: world)
            elapsed += 0.1
        }
        report.check(
            "love fades on its own if no mate ever answers it",
            !alone.isInLove,
            "still in love after \(String(format: "%.0f", elapsed))s: \(alone.isInLove)"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the breeding\n"
            : "[check] all passed — the breeding\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

import Foundation

/// Headless proof that the axolotl stays where an axolotl belongs.
///
/// It is the first mob whose rule is about a block type rather than about
/// solidity, and none of that shows in a picture: a snapshot of one in a
/// pond looks exactly like a snapshot of one that is about to swim up
/// through the surface and hang in the air. So it is checked the way the
/// shaped blocks are — a real `World`, the real `Animal`, and a minute
/// simulated a hundred frames a second.
///
/// `BLOCKHAVEN_CHECK_AXOLOTL=1`. Nothing here touches the save file; it never
/// opens a window and exits nonzero if any line fails.
enum AxolotlCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_AXOLOTL"] != nil
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

    /// The test pond: a stone table with a basin sunk into it, laid clear
    /// of the terrain so nothing measured below is really a hill.
    ///
    /// The table reaches past the far edge of the spawn ring — 16 to 40
    /// blocks out — while the basin only just reaches its near edge, so all
    /// but a sliver of the ring is dry ground. Those proportions are the
    /// point. A world that is mostly pond hands the swimmers the population
    /// for nothing; the failure worth catching is the opposite one, where
    /// the fields fill up first and the lake never gets a look in.
    /// Deep enough for the squid, which asks for five cells before it will
    /// take a column at all. A pond that only suits the small swimmers
    /// would pass the caps line below by never testing the kind whose whole
    /// point is that it needs depth.
    private static let tableHalf = 44
    private static let pondHalf = 18
    private static let pondDepth = 6

    static func run() -> Never {
        let world = World()
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dz in -4...4 {
            for dx in -4...4 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

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
        guard deck + 6 < Chunk.height, deck - pondDepth - 1 > 0 else {
            StandardError.write(Data("[check] no headroom over the terrain\n".utf8))
            exit(2)
        }

        for z in (originZ - tableHalf)...(originZ + tableHalf) {
            for x in (originX - tableHalf)...(originX + tableHalf) {
                for y in (deck - pondDepth - 1)...deck {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .stone, remesh: false)
                }
                for y in (deck + 1)...(deck + 6) {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }
        // The basin, cut back out of the table it was just filled with, so
        // its floor and its banks are solid stone all the way round.
        for z in (originZ - pondHalf)...(originZ + pondHalf) {
            for x in (originX - pondHalf)...(originX + pondHalf) {
                for y in (deck - pondDepth + 1)...deck {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .water, remesh: false)
                }
            }
        }

        var report = Report()
        let surface = deck                       // the top water cell
        let floor = deck - pondDepth + 1         // the bottom water cell

        // MARK: a minute in the pond
        //
        // Every frame, the whole body box has to be in water: water is
        // neither solid nor air, so one test rules out both burying it in
        // the bank and letting it surface into the sky.
        var swimmer = Animal(
            kind: .axolotl,
            position: Vector3(CGFloat(originX) + 0.5, CGFloat(floor) + 0.25, CGFloat(originZ) + 0.5),
            seed: 0x0A0
        )
        let startPosition = swimmer.position
        var strandedFrames = 0
        var lowest = swimmer.position.y
        var peak = swimmer.position.y
        var firstFailure = ""
        for _ in 0..<6000 {
            swimmer.step(dt: frameInterval, world: world)
            lowest = min(lowest, swimmer.position.y)
            peak = max(peak, swimmer.position.y)
            if !swimmer.submerged(at: swimmer.position, world: world) {
                strandedFrames += 1
                if firstFailure.isEmpty {
                    firstFailure = String(
                        format: "left the water at (%.2f, %.2f, %.2f)",
                        swimmer.position.x, swimmer.position.y, swimmer.position.z
                    )
                }
            }
        }
        report.check(
            "stays in the water for a minute",
            strandedFrames == 0,
            strandedFrames == 0
                ? String(format: "6000 frames submerged, y ranged %.2f…%.2f (water cells %d…%d)",
                         lowest, peak, floor, surface)
                : "\(strandedFrames) frames out of the water — \(firstFailure)"
        )
        // A frozen axolotl would pass the line above for the wrong reason.
        let travelled = (swimmer.position - startPosition).length()
        report.check(
            "actually swims about",
            travelled > 1.0 && peak - lowest > 0.05,
            String(format: "moved %.2f blocks from the drop point, y spread %.2f",
                   travelled, peak - lowest)
        )

        // MARK: beached, three cells from the bank
        //
        // Dropped on the stone table just past the edge of the pond. It
        // should flop toward the water rather than away from it.
        let bankX = originX + pondHalf + 3
        var beached = Animal(
            kind: .axolotl,
            position: Vector3(CGFloat(bankX) + 0.5, CGFloat(deck) + 1, CGFloat(originZ) + 0.5),
            seed: 0x1A0
        )
        let startGap = gapToWater(beached.position, pondEdge: originX + pondHalf)
        var reachedWater = false
        for _ in 0..<3000 {
            beached.step(dt: frameInterval, world: world)
            if beached.isSwimming { reachedWater = true; break }
        }
        let endGap = gapToWater(beached.position, pondEdge: originX + pondHalf)
        report.check(
            "heads for water when stranded",
            reachedWater || endGap < startGap - 1,
            String(format: "started %.2f blocks from the bank, ", startGap)
                + (reachedWater ? "reached the water" : "closed the gap")
                + String(format: " (now %.2f)", endGap)
        )

        // MARK: beached with water in its own column
        //
        // A sealed cell of water buried in the stone two blocks under its
        // feet — a shore ledge, or shallows with the middle of the cell
        // dry. Water straight down is the one candidate that offers no
        // heading at all, and the search has to step over it and keep
        // looking rather than let it settle the answer.
        //
        // Only the *first* heading can see this, and only from the exact
        // centre of the cell — which is where a spawn puts an animal, and
        // is the only place the horizontal distance to its own column is
        // zero. One frame each, then, and the bank is 4 cells away in -x,
        // so a heading that found it reads -π/2. Four seeds: what this
        // guards against is falling back to a *random* angle, and one
        // lucky roll is not a pass.
        let pocketX = originX + pondHalf + 4
        world.setBlock(worldX: pocketX, y: deck - 1, worldZ: originZ, to: .water, remesh: false)
        let towardBank = -CGFloat.pi / 2
        var headings: [CGFloat] = []
        for seed in [UInt64(0x2A0), 0x3A0, 0x4A0, 0x5A0] {
            var ledged = Animal(
                kind: .axolotl,
                position: Vector3(CGFloat(pocketX) + 0.5, CGFloat(deck) + 1, CGFloat(originZ) + 0.5),
                seed: seed
            )
            ledged.step(dt: frameInterval, world: world)
            headings.append(ledged.facing)
        }
        let onTarget = headings.filter { abs($0 - towardBank) < 0.2 }.count
        report.check(
            "looks past the water under its own feet",
            onTarget == headings.count,
            "\(onTarget) of \(headings.count) first headings made for the bank — "
                + headings.map { String(format: "%.2f", $0) }.joined(separator: ", ")
                + String(format: " (the bank is %.2f)", towardBank)
        )

        // MARK: the caps
        //
        // The manager run against the same pond, with the player standing
        // in the middle of it — a lake with fields all round it, which is
        // the shape the caps have to survive. Land is always spawnable here
        // and water only sometimes, so if the two share one budget the
        // pigs win every slot and the pond stays empty however long this
        // runs.
        var manager = AnimalManager(mode: .survival, seed: 0xA0A0)
        let eye = Vector3(CGFloat(originX) + 0.5, CGFloat(deck) + 2, CGFloat(originZ) + 0.5)
        // `hasRoom(for:)` lets a kind with zero members through even past a
        // full budget, so a kind nobody had seen yet does not lose forever
        // to a habitat that filled first — see its own doc comment. That
        // is a bounded overrun, at most one extra per kind that habitat has
        // never seen, so the cap the population can actually land on is the
        // stated one plus how many kinds share that habitat, not the stated
        // one exactly.
        let landSlack = AnimalKind.allCases.filter { !$0.isAquatic }.count
        let waterSlack = AnimalKind.allCases.filter { $0.isAquatic }.count
        var mostLand = 0
        var mostSwimmers = 0
        var brokeCap = false
        for _ in 0..<4000 {
            manager.update(dt: 0.05, playerEye: eye, world: world, threats: [])
            let swimmers = manager.animals.values.filter { $0.kind.isAquatic }.count
            let land = manager.animals.count - swimmers
            mostLand = max(mostLand, land)
            mostSwimmers = max(mostSwimmers, swimmers)
            if land > AnimalManager.populationCap + landSlack
                || swimmers > AnimalManager.waterPopulationCap + waterSlack {
                brokeCap = true
            }
        }
        // Both halves have to fill. Swimmers alone would pass on a world
        // that is all water; land alone is the bug this line was written
        // for, where the fields crowd the axolotls out entirely.
        report.check(
            "fills the lake as well as the fields",
            mostSwimmers >= AnimalManager.waterPopulationCap
                && mostLand >= AnimalManager.populationCap,
            "peaked at \(mostSwimmers) of \(AnimalManager.waterPopulationCap) swimmers "
                + "alongside \(mostLand) of \(AnimalManager.populationCap) land animals"
        )
        // And every kind whose habitat actually reaches this ring has to be
        // in there. Not every kind, now that land spawns are gated by
        // biome (`AnimalKind.habitatBiomes`): a doorstep can be surrounded
        // by plains for as far as the spawn ring reaches, and a wolf, whose
        // habitat is forest, mountains and snow, has nothing here to be
        // wrong about missing — that absence is the feature working, not a
        // crowd-out. So "expected" is sampled the same way `AnimalManager`
        // itself would place a land kind: every biome the ring can actually
        // land a member on, ored across every angle around the eye at the
        // ring's own radii.
        var reachableBiomes: Set<WorldGenerator.Biome> = []
        for angle in stride(from: 0.0, to: 2 * Double.pi, by: .pi / 32) {
            var distance = AnimalManager.minimumSpawnDistance
            while distance <= AnimalManager.maximumSpawnDistance {
                let x = Int((eye.x + CGFloat(cos(angle)) * distance).rounded())
                let z = Int((eye.z + CGFloat(sin(angle)) * distance).rounded())
                reachableBiomes.insert(world.generator.biome(x: x, z: z))
                distance += 2
            }
        }
        let expected = AnimalKind.allCases.filter { kind in
            kind.isAquatic || !kind.habitatBiomes.isDisjoint(with: reachableBiomes)
        }
        let missing = expected.filter { kind in
            !manager.animals.values.contains { $0.kind == kind }
        }
        report.check(
            "every kind this ring's habitat can reach is represented",
            missing.isEmpty,
            missing.isEmpty
                ? expected.map {
                    kind in "\(kind.identifier) \(manager.animals.values.filter { $0.kind == kind }.count)"
                  }.joined(separator: ", ")
                : "never saw " + missing.map(\.identifier).joined(separator: ", ")
                    + " (ring biomes: \(reachableBiomes))"
        )
        report.check(
            "respects the caps",
            !brokeCap,
            "never past \(mostLand)/\(AnimalManager.populationCap) land, "
                + "\(mostSwimmers)/\(AnimalManager.waterPopulationCap) swimmers"
        )
        // Every spawned swimmer has to have landed in water too — a water
        // spawn that starts half in the bank would swim out of the check
        // above by never having been submerged in the first place.
        let dryAtSpawn = manager.animals.values.filter {
            $0.kind.isAquatic && !$0.isSwimming
        }.count
        report.check(
            "every live axolotl is in water",
            dryAtSpawn == 0,
            "\(dryAtSpawn) of \(manager.animals.values.filter { $0.kind.isAquatic }.count) out of it"
        )

        for line in report.lines { print(line) }
        exit(report.failed ? 1 : 0)
    }

    /// Horizontal distance from a point to the near bank of the test pond,
    /// which runs to `pondEdge` in +x.
    private static func gapToWater(_ position: Vector3, pondEdge: Int) -> CGFloat {
        max(0, position.x - CGFloat(pondEdge + 1))
    }
}

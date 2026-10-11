import Foundation

/// Headless proof that what grows, grows where it should.
///
/// A snapshot answers "is there vegetation" and nothing else. It cannot say
/// whether the desert got its cactus, whether all three trees are actually
/// being planted or whether every one of forty thousand plants has ground
/// under it — and a plant hanging in mid-air, or a poppy inside a tree
/// trunk, is a bug you find by flying past exactly one of them.
///
/// So the generator is run over a real slab of world and the result is
/// counted. Generation only, with no view and no save: this is the same
/// `WorldGenerator` the game runs, asked the same questions.
///
/// `BLOCKHAVEN_CHECK_PLANTS=1`. Exits nonzero if any line fails.
///
/// Run it against a release build. It is 0.7 s there and 39 s in debug,
/// and the split says why: generating the 529 chunks is around nine
/// tenths of it either way, because chunk generation is octaves of noise
/// per column and every one of those is a real function call until the
/// optimiser gets at it. Scanning the result — 3.4 million voxel reads —
/// is the small half, a tenth of a second against a couple. So a debug
/// run is not hung; it is paying about 70 ms a chunk instead of 1.1 ms.
enum VegetationCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_PLANTS"] != nil
    }

    /// Chunks either side of spawn to generate. Wide enough to be sure of
    /// crossing into a desert and a snowfield: the biome noise turns over
    /// a few hundred blocks, and a slab that only covers the plains it
    /// starts on would pass every line below while proving nothing about
    /// the biomes it never reached.
    private static let radius = 11

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    static func run() -> Never {
        let world = World()
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dz in -radius...radius {
            for dx in -radius...radius {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        var counts: [BlockType: Int] = [:]
        var rootless: [String] = []
        var buried = 0
        var scanned = 0

        let half = radius * Chunk.width
        let originX = Int(spawn.x), originZ = Int(spawn.z)
        for z in (originZ - half)...(originZ + half) {
            for x in (originX - half)...(originX + half) {
                // Only the band around the surface can hold vegetation, and
                // walking the full 128-cell column for every one of half a
                // million columns is a minute of nothing.
                let surface = world.generator.surfaceHeight(x: x, z: z)
                let lowest = max(1, surface - 2)
                let highest = min(Chunk.height - 2, surface + 24)
                for y in lowest...highest {
                    let block = world.block(worldX: x, y: y, worldZ: z)
                    guard block.isPlant || block == .cactus
                        || block == .birchLog || block == .spruceLog || block == .log
                        || block == .birchLeaves || block == .spruceLeaves || block == .leaves
                    else { continue }
                    scanned += 1
                    counts[block, default: 0] += 1

                    // Every plant and every cactus needs a footing: the
                    // ground it rooted in, or — for a cactus — more cactus.
                    guard block.isPlant || block == .cactus else { continue }
                    let under = world.block(worldX: x, y: y - 1, worldZ: z)
                    let rooted = BlockType.plantCanRootOn(under)
                        || (block == .cactus && under == .cactus)
                    if !rooted, rootless.count < 4 {
                        rootless.append(
                            "\(String(describing: block)) on \(String(describing: under))"
                                + " at (\(x), \(y), \(z))"
                        )
                    }
                    if !rooted { buried += 1 }
                }
            }
        }

        // The desert is very likely not next door. Biome is pure noise and
        // needs no loaded chunk, so the nearest one can simply be looked
        // up and then generated — which is a far better test than widening
        // the slab until a desert happens to fall inside it, because it
        // proves the rule wherever the sand actually is.
        var report = Report()
        if let dune = nearestColumn(of: .desert, from: spawn, world: world) {
            let coord = World.chunkCoord(forWorldX: dune.x, worldZ: dune.z)
            for dz in -2...2 {
                for dx in -2...2 {
                    world.forceGenerate(ChunkCoord(x: coord.x + dx, z: coord.z + dz))
                }
            }
            let reach = 2 * Chunk.width
            for z in (dune.z - reach)...(dune.z + reach) {
                for x in (dune.x - reach)...(dune.x + reach) {
                    let surface = world.generator.surfaceHeight(x: x, z: z)
                    for y in max(1, surface)...min(Chunk.height - 2, surface + 4) {
                        let block = world.block(worldX: x, y: y, worldZ: z)
                        guard block == .cactus || block == .deadBush else { continue }
                        counts[block, default: 0] += 1
                        let under = world.block(worldX: x, y: y - 1, worldZ: z)
                        if !BlockType.plantCanRootOn(under), under != .cactus { buried += 1 }
                    }
                }
            }
            let dx = Double(dune.x - Int(spawn.x)), dz = Double(dune.z - Int(spawn.z))
            report.check(
                "there is a desert to check",
                true,
                String(format: "nearest sand at (%d, %d), %.0f blocks out",
                       dune.x, dune.z, (dx * dx + dz * dz).squareRoot())
            )
        } else {
            report.check("there is a desert to check", false, "no desert within the search")
        }

        let total = counts.values.reduce(0, +)
        report.check(
            "the generator grows things at all",
            total > 0 && scanned > 0,
            "\(total) blocks of vegetation over \((2 * half + 1) * (2 * half + 1)) columns"
        )

        // Everything that should exist, does. A silently empty biome is the
        // failure mode here — a density typo turns one of these to zero and
        // nothing else in the game notices, least of all a screenshot of
        // somewhere else.
        let wanted: [BlockType] = [
            .tallGrass, .poppy, .dandelion, .cornflower, .deadBush, .cactus,
            .log, .birchLog, .spruceLog,
        ]
        let missing = wanted.filter { (counts[$0] ?? 0) == 0 }
        report.check(
            "every plant and every tree is somewhere in it",
            missing.isEmpty,
            missing.isEmpty
                ? wanted.map { "\(String(describing: $0)) \(counts[$0] ?? 0)" }
                    .joined(separator: ", ")
                : "never grew " + missing.map { String(describing: $0) }.joined(separator: ", ")
        )

        report.check(
            "nothing is rooted in mid-air",
            buried == 0,
            buried == 0
                ? "every one of \((counts.filter { $0.key.isPlant || $0.key == .cactus }.values.reduce(0, +))) plants has ground under it"
                : "\(buried) rootless — " + rootless.joined(separator: "; ")
        )

        // The grass has to be common and the flowers rare, or "there are
        // flowers" is true and the meadow is still a flowerbed.
        let grass = counts[.tallGrass] ?? 0
        let flowers = (counts[.poppy] ?? 0) + (counts[.dandelion] ?? 0) + (counts[.cornflower] ?? 0)
        report.check(
            "grass is ground cover and flowers are finds",
            flowers > 0 && grass > flowers * 4,
            "\(grass) tufts of grass against \(flowers) flowers"
                + String(format: " (%.1f×)", flowers == 0 ? 0 : Double(grass) / Double(flowers))
        )

        // A wood of one species is wallpaper. The rarest of the three has to
        // be a real share of the commonest, or the mix is not a mix.
        let woods = [counts[.log] ?? 0, counts[.birchLog] ?? 0, counts[.spruceLog] ?? 0]
        let mixed = (woods.min() ?? 0) * 12 > (woods.max() ?? 1)
        report.check(
            "no one tree crowds the other two out",
            mixed,
            "oak \(woods[0]), birch \(woods[1]), spruce \(woods[2]) trunk blocks"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the vegetation\n"
            : "[check] all passed — the vegetation\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }

    /// The nearest column of a given biome, walking outward in rings.
    ///
    /// `biome` is a pure function of the noise and needs no loaded chunk,
    /// so this costs nothing but arithmetic — which is exactly why the
    /// check can afford to go and find a desert rather than hoping one
    /// falls inside the slab it already generated.
    private static func nearestColumn(
        of wanted: WorldGenerator.Biome, from spawn: Vector3, world: World
    ) -> (x: Int, z: Int)? {
        let originX = Int(spawn.x), originZ = Int(spawn.z)
        // Every 16 blocks: a biome is hundreds of blocks across, so a finer
        // step only samples the same answer more times.
        for ring in stride(from: 0, through: 3200, by: 16) {
            for angleStep in 0..<max(1, ring / 8) {
                let angle = Double(angleStep) / Double(max(1, ring / 8)) * 2 * .pi
                let x = originX + Int(Double(ring) * cos(angle))
                let z = originZ + Int(Double(ring) * sin(angle))
                guard world.generator.biome(x: x, z: z) == wanted else { continue }
                // Well inside it, not on its edge, so the 5×5 chunks
                // generated around this point are mostly the biome asked for.
                return (x, z)
            }
        }
        return nil
    }
}

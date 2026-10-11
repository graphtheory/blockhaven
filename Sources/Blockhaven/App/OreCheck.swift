import Foundation

/// Headless proof that ore comes in pockets rather than as single blocks
/// scattered independently: mining a real vein has to feel different from
/// mining stone that occasionally isn't stone.
///
/// `BLOCKHAVEN_CHECK_ORE=1`. Exits nonzero if any line fails.
enum OreCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_ORE"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    private struct Census {
        var count = 0
        var clustered = 0
        var deepestMiss = 0
    }

    static func run() -> Never {
        var report = Report()
        let world = World(seed: 20260823)

        var census: [BlockType: Census] = [
            .coalOre: Census(), .ironOre: Census(), .goldOre: Census(), .diamondOre: Census(),
        ]
        var total = 0
        // Every third column over a 120-block square: enough columns for
        // the rarer veins to show up a meaningful number of times without
        // this check taking as long as generating the square outright
        // would.
        for x in stride(from: -60, through: 60, by: 1) {
            for z in stride(from: -60, through: 60, by: 1) where (x + z) % 3 == 0 {
                world.forceGenerate(World.chunkCoord(forWorldX: x, worldZ: z))
                for y in 1...87 {
                    total += 1
                    let block = world.block(worldX: x, y: y, worldZ: z)
                    guard census[block] != nil else { continue }
                    census[block]!.count += 1
                    let neighbors = [
                        world.block(worldX: x + 1, y: y, worldZ: z),
                        world.block(worldX: x - 1, y: y, worldZ: z),
                        world.block(worldX: x, y: y + 1, worldZ: z),
                        world.block(worldX: x, y: y - 1, worldZ: z),
                        world.block(worldX: x, y: y, worldZ: z + 1),
                        world.block(worldX: x, y: y, worldZ: z - 1),
                    ]
                    if neighbors.contains(block) { census[block]!.clustered += 1 }
                }
            }
        }

        report.check(
            "every ore type actually generates",
            census.values.allSatisfy { $0.count > 0 },
            census.map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
        )

        // Independent placement at these densities would put a same-type
        // neighbour on well under a fifth of the ore blocks found — six
        // face-adjacent cells at a per-cell chance under 2% each gives
        // under 12% even for the commonest type, and the rarer types round
        // to nothing. A vein clears that by a wide margin however loosely
        // the threshold is set, which is what makes this a real
        // distinction and not a coin flip.
        for (kind, data) in census {
            let clusterFraction = data.count > 0 ? Double(data.clustered) / Double(data.count) : 0
            report.check(
                "\(kind) clusters instead of scattering",
                clusterFraction > 0.5,
                "\(data.clustered) of \(data.count) had a same-type neighbour "
                    + "(\(String(format: "%.0f", clusterFraction * 100))%)"
            )
        }

        // Depth bands are still absolute: a vein test only ever runs
        // inside its own `if y < …` guard, so nothing here should be able
        // to put diamond above y 16 or gold above y 32, same as the flat
        // roll this replaced.
        var diamondAboveBand = 0
        var goldAboveBand = 0
        for x in stride(from: -60, through: 60, by: 4) {
            for z in stride(from: -60, through: 60, by: 4) {
                for y in stride(from: 88, through: 16, by: -1) {
                    if world.block(worldX: x, y: y, worldZ: z) == .diamondOre { diamondAboveBand += 1 }
                }
                for y in stride(from: 88, through: 32, by: -1) {
                    if world.block(worldX: x, y: y, worldZ: z) == .goldOre { goldAboveBand += 1 }
                }
            }
        }
        report.check(
            "diamond never rises above its band",
            diamondAboveBand == 0,
            "\(diamondAboveBand) diamondOre blocks found at y >= 16"
        )
        report.check(
            "gold never rises above its band",
            goldAboveBand == 0,
            "\(goldAboveBand) goldOre blocks found at y >= 32"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the ore\n"
            : "[check] all passed — the ore\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

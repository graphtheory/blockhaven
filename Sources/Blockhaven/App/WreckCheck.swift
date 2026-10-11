import Foundation

/// Headless proof of the first landmark that costs a clock instead of a
/// tool or a walk: a wreck sits on a genuinely deep ocean floor, reachable
/// only by spending down `PlayerStats.maxAir` and getting back before it
/// runs out (or draining a path first with buckets, the patient answer).
/// This checks that a fresh world actually grows wrecks, that every one
/// found sits where the depth rule promises, that its loot is real and
/// never hands over a shortcut, and that armor's own damage-mitigation
/// table still excludes drowning — the one thing that would let gear buy
/// past the clock this landmark is built entirely out of.
///
/// `BLOCKHAVEN_CHECK_WRECK=1`. Exits nonzero if any line fails.
enum WreckCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_WRECK"] != nil
    }

    /// Wrecks sit in regions coarser than a ruin's and are filtered again
    /// by depth after that, so this radius runs wider than `RuinCheck`'s
    /// own — the smallest slab that reliably turns up more than one or two.
    private static let radius = 80

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

        var report = Report()
        let half = radius * Chunk.width
        let originX = Int(spawn.x), originZ = Int(spawn.z)

        // A wreck's chest sits on the seabed — well above a vault's own
        // band (6...15) and never mistaken for a ruin's, which is never
        // over ocean at all. Scanning by block alone, the same way
        // `SpireCheck`/`VaultCheck` do, rather than asking the generator
        // which is which.
        var chestSites: [(x: Int, y: Int, z: Int)] = []
        for z in (originZ - half)...(originZ + half) {
            for x in (originX - half)...(originX + half) {
                for y in 20...58 where world.block(worldX: x, y: y, worldZ: z) == .chest {
                    chestSites.append((x, y, z))
                }
            }
        }

        report.check(
            "a fresh world actually has wrecks in it",
            !chestSites.isEmpty,
            "\(chestSites.count) wreck chests found over this slab"
        )

        // MARK: every one found actually sits where the rule promises

        var offBiome = 0
        var tooShallow = 0
        for site in chestSites {
            let siteBiome = world.generator.biome(x: site.x, z: site.z)
            if siteBiome != .ocean { offBiome += 1 }
            let height = world.generator.surfaceHeight(x: site.x, z: site.z)
            if WorldGenerator.seaLevel - height < 12 { tooShallow += 1 }
        }
        report.check(
            "every wreck sits on the ocean floor, never dry land",
            offBiome == 0,
            "\(offBiome) of \(chestSites.count) had the wrong biome"
        )
        report.check(
            "and every one is genuinely deep, not a puddle",
            tooShallow == 0,
            "\(tooShallow) of \(chestSites.count) sat less than 12 blocks under sea level"
        )

        // MARK: the loot is real and doesn't hand over a shortcut

        var unlooted = 0
        var emptyRolls = 0
        var overflowedRolls = 0
        var inconsistentRolls = 0
        var shortcutItems: [String] = []
        for site in chestSites {
            guard let loot = world.generator.wreckLoot(atX: site.x, y: site.y, z: site.z) else {
                unlooted += 1
                continue
            }
            if loot.isEmpty { emptyRolls += 1 }
            for entry in loot where entry.item.toolClass != nil || entry.item.isArmor {
                shortcutItems.append("\(entry.item) at (\(site.x), \(site.y), \(site.z))")
            }
            let chest = Chest()
            for entry in loot {
                if chest.add(ItemStack(entry.item, count: entry.count)) != nil { overflowedRolls += 1 }
            }
            if chest.isEmpty { emptyRolls += 1 }
            let secondRoll = world.generator.wreckLoot(atX: site.x, y: site.y, z: site.z)
            if secondRoll?.map(\.item) != loot.map(\.item) || secondRoll?.map(\.count) != loot.map(\.count) {
                inconsistentRolls += 1
            }
        }
        report.check(
            "every wreck's chest can actually be traced back to it",
            unlooted == 0,
            "\(unlooted) of \(chestSites.count) chest positions came back nil"
        )
        report.check(
            "every roll actually puts something in the chest",
            emptyRolls == 0,
            "\(emptyRolls) of \(chestSites.count) rolled zero items or overflowed a fresh chest entirely"
        )
        report.check(
            "a roll always fits a fresh chest",
            overflowedRolls == 0,
            "\(overflowedRolls) of \(chestSites.count) rolls didn't fully fit"
        )
        report.check(
            "the same chest rolls the same loot every time it's asked",
            inconsistentRolls == 0,
            "\(inconsistentRolls) of \(chestSites.count) rolled differently on a second call"
        )
        report.check(
            "no roll hands over a finished tool or armor — the depth costs air, not a skipped tier",
            shortcutItems.isEmpty,
            shortcutItems.isEmpty ? "clear" : shortcutItems.joined(separator: "; ")
        )

        let strayX = originX + half + 5000, strayZ = originZ + half + 5000
        report.check(
            "a chest nobody's wreck placed rolls no loot at all",
            world.generator.wreckLoot(atX: strayX, y: 40, z: strayZ) == nil,
            "checked (\(strayX), 40, \(strayZ)), far outside every wreck this slab generated"
        )

        // MARK: no gear shortcut past the clock this landmark is built on

        var armored = PlayerStats()
        armored.equip(.diamondChestplate)
        for _ in 0..<PlayerStats.maxAir {
            armored.update(dt: 1.0, distanceMoved: 0, isSprinting: false, isSubmerged: true, isInLava: false)
        }
        let beforeDrowning = armored.health
        armored.update(dt: 1.0, distanceMoved: 0, isSprinting: false, isSubmerged: true, isInLava: false)
        report.check(
            "a diamond chestplate still leaves drowning at its full cost — depth is the whole wall here",
            beforeDrowning - armored.health == 2,
            "health \(beforeDrowning) -> \(armored.health), expected a full 2 rather than 40% off"
        )

        // MARK: the haul still answers the same ramp the danger of reaching it does
        //
        // Unlike a ruin, vault or spire — all found well inside
        // `FizzlerManager.dangerRampDistance` — a wreck's own siting
        // (ocean, twelve-plus blocks deep) means every instance this scan
        // finds already sits past the ramp's five-hundred-block cap, so
        // comparing the nearest found wreck against the farthest only ever
        // compares two already-saturated rolls against each other, which
        // is pure per-slot noise, not a gradient. What's actually provable
        // here is that the ramp is saturated at all: the average haul
        // across every wreck this slab found should sit well above what
        // an unscaled roll from the same pool and slot range could
        // produce, since `lootScale` (the same helper `rollRuinLoot`,
        // `rollVaultLoot` and `rollSpireLoot` all share) always reads 3x
        // this far out.
        if !chestSites.isEmpty {
            let totals = chestSites.map { site in
                (world.generator.wreckLoot(atX: site.x, y: site.y, z: site.z) ?? []).reduce(0) { $0 + $1.count }
            }
            let average = Double(totals.reduce(0, +)) / Double(totals.count)
            // Unscaled, this pool's slots (2-4) and per-item counts (1-4
            // each) average around 7 — nowhere near the 21 a genuine 3x
            // scale on top of that produces. 14 sits well clear of both,
            // close to the unscaled hard ceiling of 16 so this can only
            // read true when the ramp actually fired.
            report.check(
                "every wreck this far out is already past the ramp's cap, and the haul shows it",
                average > 14,
                "average haul across \(chestSites.count) wrecks: \(String(format: "%.1f", average)) items"
            )
        }

        if let first = chestSites.first {
            let dx = Double(first.x - originX), dz = Double(first.z - originZ)
            report.lines.append(
                "[check] first wreck: chest at (\(first.x), \(first.y), \(first.z)), "
                    + String(format: "%.0f blocks from spawn", (dx * dx + dz * dz).squareRoot())
            )
        }

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the wreck\n"
            : "[check] all passed — the wreck\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

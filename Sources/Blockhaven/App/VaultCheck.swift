import Foundation

/// Headless proof that a vault is the one place in the world a player
/// without the right tool genuinely pays for it, rather than another
/// landmark luck hands over regardless of what showed up to find it.
///
/// A screenshot can show an obsidian room if the camera happens to be
/// standing in front of one; it cannot say whether the shell is actually
/// unbroken on every face, whether the loot behind it stays matched to
/// what the wall costs rather than skipping the tier that wall stands for,
/// or whether a chest a player placed themselves ever gets mistaken for
/// one. So the generator runs over a real slab of world, the same way
/// `RuinCheck` proves ruins out, and every vault found in it is checked
/// structurally and by its loot.
///
/// `BLOCKHAVEN_CHECK_VAULT=1`. Exits nonzero if any line fails.
enum VaultCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_VAULT"] != nil
    }

    /// Chunks either side of spawn to generate. Vaults sit in regions far
    /// coarser than a ruin's and roll against a lower chance besides, so
    /// this radius runs noticeably wider than `RuinCheck`'s own — the
    /// smallest slab that reliably turns up more than one or two.
    private static let radius = 24

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

        // A vault's chest sits deep — the same band ore and lava share —
        // while a ruin's never does; the two can never be confused by
        // depth alone, which is what lets this scan tell them apart
        // without asking the generator which is which.
        var chestSites: [(x: Int, y: Int, z: Int)] = []
        for z in (originZ - half)...(originZ + half) {
            for x in (originX - half)...(originX + half) {
                for y in 5...20 where world.block(worldX: x, y: y, worldZ: z) == .chest {
                    chestSites.append((x, y, z))
                }
            }
        }

        report.check(
            "a fresh world actually has vaults in it",
            !chestSites.isEmpty,
            "\(chestSites.count) deep chests found over this slab"
        )
        report.check(
            "far rarer than a ruin",
            chestSites.count < 60,
            "\(chestSites.count) — expected a handful, not the dozens a ruin scan turns up"
        )

        var openShell = 0
        var breachedShell: [String] = []
        var headroomBlocked = 0
        for site in chestSites {
            for dy in -1...2 {
                for dz in -1...1 {
                    for dx in -1...1 {
                        let isChest = dx == 0 && dy == 0 && dz == 0
                        let isHeadroom = dx == 0 && dy == 1 && dz == 0
                        let cell = world.block(
                            worldX: site.x + dx, y: site.y + dy, worldZ: site.z + dz
                        )
                        if isChest {
                            if cell != .chest { openShell += 1 }
                        } else if isHeadroom {
                            if cell != .air { headroomBlocked += 1 }
                        } else if cell != .obsidian {
                            openShell += 1
                            if breachedShell.count < 4 {
                                breachedShell.append(
                                    "\(String(describing: cell)) at "
                                        + "(\(site.x + dx), \(site.y + dy), \(site.z + dz))"
                                )
                            }
                        }
                    }
                }
            }
        }
        report.check(
            "every vault's shell is unbroken obsidian on every face",
            openShell == 0,
            openShell == 0
                ? "34 obsidian cells confirmed per vault, \(chestSites.count) vaults checked"
                : "\(openShell) cells weren't obsidian or chest — " + breachedShell.joined(separator: "; ")
        )
        report.check(
            "the one cell of headroom over the chest is actually open",
            headroomBlocked == 0,
            "\(headroomBlocked) vaults had something other than air where the headroom should be"
        )

        // MARK: obsidian is what makes any of this mean something

        report.check(
            "obsidian is still the one block only a diamond pickaxe drops",
            BlockType.obsidian.minimumTier == .diamond && BlockType.obsidian.requiresTool,
            "minimumTier \(BlockType.obsidian.minimumTier), requiresTool \(BlockType.obsidian.requiresTool)"
        )
        report.check(
            "and the hardest one in the game by a wide margin, not just a labelled one",
            BlockType.obsidian.hardness >= BlockType.stone.hardness * 5,
            "obsidian \(BlockType.obsidian.hardness) vs stone \(BlockType.stone.hardness)"
        )

        // MARK: the loot matches what the wall costs, not what it skips

        var unlooted = 0
        var emptyRolls = 0
        var overflowedRolls = 0
        var inconsistentRolls = 0
        var shortcutItems: [String] = []
        for site in chestSites {
            guard let loot = world.generator.vaultLoot(atX: site.x, y: site.y, z: site.z) else {
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
            let secondRoll = world.generator.vaultLoot(atX: site.x, y: site.y, z: site.z)
            if secondRoll?.map(\.item) != loot.map(\.item) || secondRoll?.map(\.count) != loot.map(\.count) {
                inconsistentRolls += 1
            }
        }
        report.check(
            "every chest a vault placed can actually be traced back to it",
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
            "no roll hands over a finished tool — that would let a wooden pickaxe skip the tier obsidian costs",
            shortcutItems.isEmpty,
            shortcutItems.isEmpty ? "clear" : shortcutItems.joined(separator: "; ")
        )

        let strayX = originX + half + 5000, strayZ = originZ + half + 5000
        report.check(
            "a chest nobody's vault placed rolls no loot at all",
            world.generator.vaultLoot(atX: strayX, y: 10, z: strayZ) == nil,
            "checked (\(strayX), 10, \(strayZ)), far outside every vault this slab generated"
        )

        // MARK: the haul answers the same ramp the danger of reaching it does

        if chestSites.count >= 2 {
            let byDistance = chestSites.sorted {
                let da = pow(Double($0.x - originX), 2) + pow(Double($0.z - originZ), 2)
                let db = pow(Double($1.x - originX), 2) + pow(Double($1.z - originZ), 2)
                return da < db
            }
            let nearest = byDistance.first!, farthest = byDistance.last!
            let nearTotal = (world.generator.vaultLoot(atX: nearest.x, y: nearest.y, z: nearest.z) ?? [])
                .reduce(0) { $0 + $1.count }
            let farTotal = (world.generator.vaultLoot(atX: farthest.x, y: farthest.y, z: farthest.z) ?? [])
                .reduce(0) { $0 + $1.count }
            report.check(
                "a haul far from spawn outweighs one at the doorstep, the same ramp that makes it riskier",
                farTotal > nearTotal,
                "nearest vault \(nearTotal) items, farthest \(farTotal) items"
            )
        }

        // MARK: depth alone is distance, the same way descending a mineshaft
        // already costs a player as much as walking the same span overland
        // — a vault almost directly under spawn horizontally still sits
        // fifty-odd blocks of stone below it, and that far down is answered
        // by the same ramp a long walk is. Proved directly against the ramp
        // itself rather than by comparing two random real vaults: a vault's
        // whole depth band (y 6...20) spans barely a tenth of the ramp's
        // own five-hundred-block reach, which is real but far too small a
        // signal to reliably outrank ordinary horizontal variation between
        // whatever handful of vaults one slab happens to generate — as
        // found the hard way with this exact scan's own four sites, whose
        // depths (y 10-15) never once flipped their horizontal ranking.
        let atSpawnColumn = world.generator.lootScale(anchorX: 0, anchorY: 15, anchorZ: 0)
        let atSpawnSurface = world.generator.lootScale(anchorX: 0, anchorY: WorldGenerator.seaLevel, anchorZ: 0)
        report.check(
            "even the shallowest possible vault, sitting right under spawn, still outscales a landmark at spawn itself",
            atSpawnColumn > atSpawnSurface,
            "shallowest vault scale \(atSpawnColumn), spawn-column scale \(atSpawnSurface)"
        )
        report.check(
            "the deepest possible vault depth scales higher again than the shallowest",
            world.generator.lootScale(anchorX: 0, anchorY: 6, anchorZ: 0) > atSpawnColumn,
            "deepest vault scale \(world.generator.lootScale(anchorX: 0, anchorY: 6, anchorZ: 0)), shallowest \(atSpawnColumn)"
        )
        report.check(
            "a ruin, spire or wreck's own scale is unaffected — they still read as a surface column",
            world.generator.lootScale(anchorX: 300, anchorZ: 0)
                == world.generator.lootScale(anchorX: 300, anchorY: WorldGenerator.seaLevel, anchorZ: 0),
            "default anchorY must still resolve to seaLevel"
        )

        if let first = chestSites.first {
            let dx = Double(first.x - originX), dz = Double(first.z - originZ)
            report.lines.append(
                "[check] first vault: chest at (\(first.x), \(first.y), \(first.z)), "
                    + String(format: "%.0f blocks from spawn", (dx * dx + dz * dz).squareRoot())
            )
        }

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the vault\n"
            : "[check] all passed — the vault\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

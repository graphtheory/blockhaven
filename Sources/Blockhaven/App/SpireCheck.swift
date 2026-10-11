import Foundation

/// Headless proof of the first landmark meant to be seen from far away
/// rather than stumbled into up close: a spire is a plain stone shaft that
/// rises well clear of the mountain it stands on, capped in a light a
/// `seaLantern` already knows how to cast — height and an existing emitter
/// are the whole trick, so this checks that the shaft is actually solid and
/// actually tall, that the beacon is actually lit, that the loot atop
/// it is real and stays matched to what a ruin/vault already promise, and
/// that it never roots inside a ruin's own footprint — the one other
/// landmark that shares its dry ground.
///
/// `BLOCKHAVEN_CHECK_SPIRE=1`. Exits nonzero if any line fails.
enum SpireCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_SPIRE"] != nil
    }

    /// Spires sit in regions coarser than a vault's and roll against a
    /// lower chance besides, so this radius runs wider still — the
    /// smallest slab that reliably turns up more than one or two.
    private static let radius = 100

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

        // A beacon sits well above any ordinary terrain or tree, and
        // nothing else in the game ever places a lit block that high — the
        // same clean-signal reasoning `VaultCheck` uses for depth.
        var beacons: [(x: Int, y: Int, z: Int)] = []
        for z in (originZ - half)...(originZ + half) {
            for x in (originX - half)...(originX + half) {
                for y in 130..<Chunk.height where world.block(worldX: x, y: y, worldZ: z) == .seaLantern {
                    beacons.append((x, y, z))
                }
            }
        }

        report.check(
            "a fresh world actually has spires in it",
            !beacons.isEmpty,
            "\(beacons.count) beacons found over this slab"
        )
        report.check(
            "rarer than a vault, not just further up",
            beacons.count < 30,
            "\(beacons.count) — expected a handful over a \(half * 2)-block slab"
        )

        var brokenShaft = 0
        var shortShaft = 0
        var missingChest = 0
        for beacon in beacons {
            // Natural mountain stone continues below a spire's own base, so
            // block type alone can't tell the two apart — the generator's
            // own `surfaceHeight` is the one source of truth for where the
            // shaft the builder actually wrote begins.
            let base = world.generator.surfaceHeight(x: beacon.x, z: beacon.z)
            let top = beacon.y - 1
            var solid = true
            for y in base...top where world.block(worldX: beacon.x, y: y, worldZ: beacon.z) != .stone {
                solid = false
                break
            }
            if !solid { brokenShaft += 1 }
            if top - base < 45 { shortShaft += 1 }
            let chestX = beacon.x + 1
            if world.block(worldX: chestX, y: beacon.y, worldZ: beacon.z) != .chest { missingChest += 1 }
        }
        report.check(
            "every spire's shaft is unbroken stone from base to beacon",
            brokenShaft == 0,
            "\(brokenShaft) of \(beacons.count) had a gap in the column"
        )
        report.check(
            "and actually rises the 45+ blocks it's supposed to",
            shortShaft == 0,
            "\(shortShaft) of \(beacons.count) rose less than 45 blocks"
        )
        report.check(
            "a chest sits right beside every beacon",
            missingChest == 0,
            "\(missingChest) of \(beacons.count) had no chest where one belongs"
        )

        // MARK: the beacon is actually lit, not just placed

        report.check(
            "seaLantern still lights up as bright as a torch",
            BlockType.seaLantern.lightEmission >= 14,
            "lightEmission \(BlockType.seaLantern.lightEmission)"
        )
        if let first = beacons.first {
            let nearby = world.lightLevel(worldX: first.x + 2, y: first.y, worldZ: first.z)
            report.check(
                "and a real beacon actually lights the air beside it",
                nearby >= 10,
                "light level two cells off a beacon: \(nearby)"
            )
        }

        // MARK: the loot is real and doesn't hand over a shortcut

        var unlooted = 0
        var emptyRolls = 0
        var overflowedRolls = 0
        var inconsistentRolls = 0
        var shortcutItems: [String] = []
        for beacon in beacons {
            let site = (x: beacon.x + 1, y: beacon.y, z: beacon.z)
            guard let loot = world.generator.spireLoot(atX: site.x, y: site.y, z: site.z) else {
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
            let secondRoll = world.generator.spireLoot(atX: site.x, y: site.y, z: site.z)
            if secondRoll?.map(\.item) != loot.map(\.item) || secondRoll?.map(\.count) != loot.map(\.count) {
                inconsistentRolls += 1
            }
        }
        report.check(
            "every spire's chest can actually be traced back to it",
            unlooted == 0,
            "\(unlooted) of \(beacons.count) chest positions came back nil"
        )
        report.check(
            "every roll actually puts something in the chest",
            emptyRolls == 0,
            "\(emptyRolls) of \(beacons.count) rolled zero items or overflowed a fresh chest entirely"
        )
        report.check(
            "a roll always fits a fresh chest",
            overflowedRolls == 0,
            "\(overflowedRolls) of \(beacons.count) rolls didn't fully fit"
        )
        report.check(
            "the same chest rolls the same loot every time it's asked",
            inconsistentRolls == 0,
            "\(inconsistentRolls) of \(beacons.count) rolled differently on a second call"
        )
        report.check(
            "no roll hands over a finished tool or armor — the climb costs nerve, not a skipped tier",
            shortcutItems.isEmpty,
            shortcutItems.isEmpty ? "clear" : shortcutItems.joined(separator: "; ")
        )

        let strayX = originX + half + 5000, strayZ = originZ + half + 5000
        report.check(
            "a chest nobody's spire placed rolls no loot at all",
            world.generator.spireLoot(atX: strayX, y: 150, z: strayZ) == nil,
            "checked (\(strayX), 150, \(strayZ)), far outside every spire this slab generated"
        )

        // MARK: it only ever stands on a real peak

        var offBiome = 0
        for beacon in beacons {
            let siteBiome = world.generator.biome(x: beacon.x, z: beacon.z)
            if siteBiome == .ocean || siteBiome == .beach { offBiome += 1 }
        }
        report.check(
            "every spire stands on dry land, never the sea or its shore",
            offBiome == 0,
            "\(offBiome) of \(beacons.count) sat on the wrong biome"
        )

        // MARK: a spire never roots inside a ruin's own footprint

        // Independent rolls on independent lattices: nothing but this guard
        // stops a spire's shaft from rising through a ruin's own rubble.
        // Found by scanning ruin anchors directly rather than waiting for
        // one to turn up in the beacon slab above — a collision with a
        // spire specifically is too rare a coincidence to trust one
        // generated slab to contain, but a ruin anchor tall enough to also
        // clear a spire's own height bound is common, and that is the only
        // thing the guard actually needs to be tested at.
        var claimedRuin: (x: Int, z: Int)?
        searchRuins: for regionZ in -120...120 {
            for regionX in -120...120 {
                guard let anchor = world.generator.ruinAnchor(regionX: regionX, regionZ: regionZ) else { continue }
                guard world.generator.ruinSiteIsValid(atX: anchor.x, z: anchor.z) else { continue }
                guard world.generator.surfaceHeight(x: anchor.x, z: anchor.z) > WorldGenerator.seaLevel + 4
                else { continue }
                claimedRuin = anchor
                break searchRuins
            }
        }
        if let ruin = claimedRuin {
            report.check(
                "a spire refuses to root at a real ruin's own anchor",
                !world.generator.spireSiteIsValid(atX: ruin.x, z: ruin.z),
                "spire site check at ruin anchor (\(ruin.x), \(ruin.z)): expected rejected"
            )
            let clear = (x: ruin.x + 40, z: ruin.z)
            report.lines.append(
                "[check] control, 40 blocks clear of that same ruin: spireSiteIsValid = "
                    + "\(world.generator.spireSiteIsValid(atX: clear.x, z: clear.z))"
            )
        } else {
            report.check(
                "found a ruin site tall enough to test the overlap guard against",
                false,
                "no ruin anchor in the scanned regions cleared a spire's own height bound"
            )
        }

        // The margin itself, in isolation: a ruin's own footprint is 2
        // blocks past its anchor, widened by 1 more for a spire's own
        // half-width — 3 blocks off is still claimed, 4 is clear.
        report.check(
            "the overlap guard widens a ruin's footprint by a spire's own half-width",
            world.generator.columnIsClaimedByRuin(3, 0, anchors: [(x: 0, z: 0)], margin: 3)
                && !world.generator.columnIsClaimedByRuin(4, 0, anchors: [(x: 0, z: 0)], margin: 3),
            "margin 3: 3 blocks off a claimed anchor stays claimed, 4 blocks off is clear"
        )

        // MARK: the haul answers the same ramp the danger of reaching it does

        if beacons.count >= 2 {
            let byDistance = beacons.sorted {
                let da = pow(Double($0.x - originX), 2) + pow(Double($0.z - originZ), 2)
                let db = pow(Double($1.x - originX), 2) + pow(Double($1.z - originZ), 2)
                return da < db
            }
            let nearest = byDistance.first!, farthest = byDistance.last!
            let nearSite = (x: nearest.x + 1, y: nearest.y, z: nearest.z)
            let farSite = (x: farthest.x + 1, y: farthest.y, z: farthest.z)
            let nearTotal = (world.generator.spireLoot(atX: nearSite.x, y: nearSite.y, z: nearSite.z) ?? [])
                .reduce(0) { $0 + $1.count }
            let farTotal = (world.generator.spireLoot(atX: farSite.x, y: farSite.y, z: farSite.z) ?? [])
                .reduce(0) { $0 + $1.count }
            report.check(
                "a haul far from spawn outweighs one at the doorstep, the same ramp that makes it riskier",
                farTotal > nearTotal,
                "nearest spire \(nearTotal) items, farthest \(farTotal) items"
            )
        }

        if let first = beacons.first {
            let dx = Double(first.x - originX), dz = Double(first.z - originZ)
            report.lines.append(
                "[check] first spire: beacon at (\(first.x), \(first.y), \(first.z)), "
                    + String(format: "%.0f blocks from spawn", (dx * dx + dz * dz).squareRoot())
            )
        }

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the spire\n"
            : "[check] all passed — the spire\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

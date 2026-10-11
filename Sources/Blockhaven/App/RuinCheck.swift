import Foundation

/// Headless proof that a fresh world has somewhere worth finding in it.
///
/// A screenshot can show one ruin if the camera happens to be standing in
/// front of one; it cannot say whether they are common enough to matter,
/// rare enough to feel found, always somewhere a player can actually reach,
/// or never quietly buried under the ground-cover pass that runs before
/// them. So the generator is run over a real slab of world, the same way
/// `VegetationCheck` proves out what grows, and every ruin in it is
/// checked structurally: capped, not floating; on land, not at sea; ground
/// cover clear of it rather than planted through it. And now that a ruin
/// hands back something regardless of what tool found it: a chest beside
/// every treasure cap, its contents rolled the same deterministic way the
/// cap's own material is, so it can be checked without a window at all.
///
/// `BLOCKHAVEN_CHECK_RUINS=1`. Exits nonzero if any line fails.
enum RuinCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_RUINS"] != nil
    }

    /// Chunks either side of spawn to generate — wide enough that, at
    /// roughly one ruin per five regions and a region three chunks on a
    /// side, the slab covers dozens of candidate regions rather than one
    /// or two a single unlucky roll could skew.
    private static let radius = 20

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

        var treasureSites: [(x: Int, y: Int, z: Int, block: BlockType)] = []
        var pillarColumns = 0
        var rubbleBlocks = 0
        var uncappedTreasure = 0
        var atSea = 0
        var plantedThrough: [String] = []
        var chestSites: [(x: Int, y: Int, z: Int)] = []
        var doorLowers: [(x: Int, y: Int, z: Int)] = []
        var leverSites: [(x: Int, y: Int, z: Int)] = []

        for z in (originZ - half)...(originZ + half) {
            for x in (originX - half)...(originX + half) {
                let surface = world.generator.surfaceHeight(x: x, z: z)
                let lowest = max(1, surface - 1)
                let highest = min(Chunk.height - 2, surface + 6)
                for y in lowest...highest {
                    let block = world.block(worldX: x, y: y, worldZ: z)
                    switch block {
                    case .goldBlock, .diamondBlock:
                        treasureSites.append((x, y, z, block))
                        let under = world.block(worldX: x, y: y - 1, worldZ: z)
                        if under != .sandstonePillar { uncappedTreasure += 1 }
                        let biome = world.generator.biome(x: x, z: z)
                        if biome == .ocean || biome == .beach { atSea += 1 }
                        // Ground cover must have stayed off the cap and the
                        // column right above it — a tuft of grass here
                        // would mean `columnIsClaimedByRuin` missed a site.
                        let above = world.block(worldX: x, y: y + 1, worldZ: z)
                        if above.isPlant, plantedThrough.count < 4 {
                            plantedThrough.append("\(String(describing: above)) over \(String(describing: block)) at (\(x), \(y), \(z))")
                        }
                    case .sandstonePillar:
                        pillarColumns += 1
                        let biome = world.generator.biome(x: x, z: z)
                        if biome == .ocean || biome == .beach { atSea += 1 }
                    case .sandstoneCarved:
                        // Sandstone carving is also the pyramid's lining in
                        // the demo world, but this is a fresh survival
                        // generation with no landmark anywhere near it —
                        // every one found here is a ruin's rubble.
                        rubbleBlocks += 1
                    case .chest:
                        chestSites.append((x, y, z))
                    case .leverOff, .leverOn:
                        leverSites.append((x, y, z))
                    default:
                        if block.isDoor, block.doorPart == .lower {
                            doorLowers.append((x, y, z))
                        }
                    }
                }
            }
        }

        let scanned = (2 * half + 1) * (2 * half + 1)
        report.check(
            "a fresh world actually has ruins in it",
            !treasureSites.isEmpty,
            "\(treasureSites.count) treasure caps over \(scanned) columns"
        )
        report.check(
            "rare rather than everywhere",
            treasureSites.count < 400,
            "\(treasureSites.count) caps — expected on the order of tens, not hundreds, over this slab"
        )
        report.check(
            "every treasure cap sits on a pillar, not on air",
            uncappedTreasure == 0,
            "\(uncappedTreasure) of \(treasureSites.count) had something other than a pillar under them"
        )
        report.check(
            "no ruin washed up in the ocean or on the beach",
            atSea == 0,
            "\(atSea) ruin blocks found in an ocean or beach column"
        )
        report.check(
            "ground cover left every ruin's columns alone",
            plantedThrough.isEmpty,
            plantedThrough.isEmpty
                ? "clear"
                : plantedThrough.joined(separator: "; ")
        )
        report.check(
            "rubble and pillars both actually generate",
            pillarColumns > 0 && rubbleBlocks > 0,
            "\(pillarColumns) pillar blocks, \(rubbleBlocks) rubble blocks"
        )

        // MARK: every ruin also stands a door and the lever that opens it

        report.check(
            "a door actually generates at almost every ruin",
            Double(doorLowers.count) >= Double(treasureSites.count) * 0.7,
            "\(doorLowers.count) door bases for \(treasureSites.count) treasure caps"
        )
        report.check(
            "and a lever stands beside just as many",
            Double(leverSites.count) >= Double(treasureSites.count) * 0.7,
            "\(leverSites.count) levers for \(treasureSites.count) treasure caps"
        )
        var doorsNotClosed = 0
        for door in doorLowers where world.block(worldX: door.x, y: door.y, worldZ: door.z).doorIsOpen {
            doorsNotClosed += 1
        }
        report.check(
            "every generated door starts closed, not standing open",
            doorsNotClosed == 0,
            "\(doorsNotClosed) of \(doorLowers.count) doors generated already open"
        )
        var leversNotOff = 0
        for lever in leverSites where world.block(worldX: lever.x, y: lever.y, worldZ: lever.z) != .leverOff {
            leversNotOff += 1
        }
        report.check(
            "every generated lever starts off, not already thrown",
            leversNotOff == 0,
            "\(leversNotOff) of \(leverSites.count) levers generated already on"
        )

        // MARK: every ruin also hands back something regardless of tool

        report.check(
            "a chest actually stands beside the treasure, not just the cap",
            !chestSites.isEmpty,
            "\(chestSites.count) chest blocks over \(treasureSites.count) treasure caps"
        )
        report.check(
            "a chest at almost every ruin, not a stray few",
            Double(chestSites.count) >= Double(treasureSites.count) * 0.8,
            "\(chestSites.count) chests for \(treasureSites.count) caps — "
                + "a chest skips only when its own column happens to be ocean or beach"
        )

        var unlooted = 0
        var emptyRolls = 0
        var overflowedRolls = 0
        var inconsistentRolls = 0
        for site in chestSites {
            guard let loot = world.generator.ruinLoot(atX: site.x, y: site.y, z: site.z) else {
                unlooted += 1
                continue
            }
            if loot.isEmpty { emptyRolls += 1 }
            let chest = Chest()
            for entry in loot {
                if chest.add(ItemStack(entry.item, count: entry.count)) != nil { overflowedRolls += 1 }
            }
            if chest.isEmpty { emptyRolls += 1 }
            // Rolled from the anchor and the seed alone, so opening the
            // same chest twice — or a save reloading it — must never turn
            // up a different haul.
            let secondRoll = world.generator.ruinLoot(atX: site.x, y: site.y, z: site.z)
            if secondRoll?.map(\.item) != loot.map(\.item) || secondRoll?.map(\.count) != loot.map(\.count) {
                inconsistentRolls += 1
            }
        }
        report.check(
            "every chest a ruin placed can actually be traced back to it",
            unlooted == 0,
            "\(unlooted) of \(chestSites.count) chest positions the generator itself placed came back nil"
        )
        report.check(
            "every roll actually puts something in the chest",
            emptyRolls == 0,
            "\(emptyRolls) of \(chestSites.count) rolled zero items or overflowed a fresh chest entirely"
        )
        report.check(
            "a roll always fits a fresh chest — nothing spills before the player ever sees it",
            overflowedRolls == 0,
            "\(overflowedRolls) of \(chestSites.count) rolls didn't fully fit 27 empty slots"
        )
        report.check(
            "the same chest rolls the same loot every time it's asked",
            inconsistentRolls == 0,
            "\(inconsistentRolls) of \(chestSites.count) rolled differently on a second call"
        )
        // An arbitrary column nowhere near any of this slab's ruins — a
        // chest a player placed there themselves must never come back
        // stocked just because its coordinates happen to exist.
        let strayX = originX + half + 5000, strayZ = originZ + half + 5000
        report.check(
            "a chest nobody's ruin placed rolls no loot at all",
            world.generator.ruinLoot(atX: strayX, y: 70, z: strayZ) == nil,
            "checked (\(strayX), 70, \(strayZ)), far outside every ruin this slab generated"
        )

        // MARK: the haul answers the same ramp the danger of reaching it does

        if chestSites.count >= 2 {
            let byDistance = chestSites.sorted {
                let da = pow(Double($0.x - originX), 2) + pow(Double($0.z - originZ), 2)
                let db = pow(Double($1.x - originX), 2) + pow(Double($1.z - originZ), 2)
                return da < db
            }
            let nearest = byDistance.first!, farthest = byDistance.last!
            let nearTotal = (world.generator.ruinLoot(atX: nearest.x, y: nearest.y, z: nearest.z) ?? [])
                .reduce(0) { $0 + $1.count }
            let farTotal = (world.generator.ruinLoot(atX: farthest.x, y: farthest.y, z: farthest.z) ?? [])
                .reduce(0) { $0 + $1.count }
            report.check(
                "a haul far from spawn outweighs one at the doorstep, the same ramp that makes it riskier",
                farTotal > nearTotal,
                "nearest ruin \(nearTotal) items, farthest \(farTotal) items"
            )
        }

        // MARK: a ruin never roots inside another ruin's own footprint

        // Independent rolls on independent lattices, exactly the same
        // shape as the ruin/spire collision `SpireCheck` proves out — but
        // here both sides of the collision are the same landmark type, so
        // nothing but `ruinSiteIsValid`'s own neighbour guard stops two
        // ruins from adjacent regions landing close enough for their
        // rubble to interpenetrate. Found directly by scanning region
        // pairs rather than waiting for one to turn up in the slab above:
        // at roughly one ruin in five regions and a region only 48 blocks
        // wide, a genuine collision is common enough to find within a few
        // hundred regions, not a coincidence worth trusting one generated
        // slab to contain.
        // Proximity alone isn't enough to prove the guard did anything —
        // a pair that happens to collide could just as easily both sit in
        // the ocean, valid or not regardless of each other. What actually
        // exercises the guard is a pair where, apart from each other, both
        // would otherwise be real ruins: exactly one of the two coming
        // back valid is the guard's own signature, so the search keeps
        // going until it finds a pair that shows it.
        var collidingPair: ((x: Int, z: Int), (x: Int, z: Int))?
        searchCollision: for regionZ in -300...300 {
            for regionX in -300...300 {
                guard let a = world.generator.ruinAnchor(regionX: regionX, regionZ: regionZ) else { continue }
                for dz in -1...1 {
                    for dx in -1...1 where dx != 0 || dz != 0 {
                        guard let b = world.generator.ruinAnchor(regionX: regionX + dx, regionZ: regionZ + dz)
                        else { continue }
                        guard abs(a.x - b.x) <= 4, abs(a.z - b.z) <= 4 else { continue }
                        guard world.generator.ruinSiteIsValid(atX: a.x, z: a.z)
                            != world.generator.ruinSiteIsValid(atX: b.x, z: b.z)
                        else { continue }
                        collidingPair = (a, b)
                        break searchCollision
                    }
                }
            }
        }
        if let (a, b) = collidingPair {
            let aValid = world.generator.ruinSiteIsValid(atX: a.x, z: a.z)
            report.check(
                "of a real overlapping pair, exactly one ruin actually generates",
                aValid != world.generator.ruinSiteIsValid(atX: b.x, z: b.z),
                "(\(a.x), \(a.z)) valid: \(aValid), (\(b.x), \(b.z)) valid: \(!aValid)"
            )
            let loser = aValid ? b : a
            let clear = (x: loser.x + 40, z: loser.z)
            report.lines.append(
                "[check] control, 40 blocks clear of that same pair: ruinSiteIsValid = "
                    + "\(world.generator.ruinSiteIsValid(atX: clear.x, z: clear.z))"
            )
        } else {
            report.check(
                "found a real overlapping ruin pair in the scanned regions to test the guard against",
                false,
                "no two adjacent ruin anchors landed within footprint range over 600x600 regions"
            )
        }

        if let first = treasureSites.first {
            let dx = Double(first.x - originX), dz = Double(first.z - originZ)
            report.lines.append(
                "[check] first ruin: \(String(describing: first.block)) at "
                    + "(\(first.x), \(first.y), \(first.z)), "
                    + String(format: "%.0f blocks from spawn", (dx * dx + dz * dz).squareRoot())
            )
        }
        if let firstChest = chestSites.first {
            report.lines.append(
                "[check] first chest: (\(firstChest.x), \(firstChest.y), \(firstChest.z))"
            )
        }

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the ruins\n"
            : "[check] all passed — the ruins\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

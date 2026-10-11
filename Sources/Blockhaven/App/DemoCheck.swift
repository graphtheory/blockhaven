import Foundation

/// Headless proof that the demo world is worth opening.
///
/// It exists because the demo is the one world nobody builds by hand and
/// everybody sees first. A landmark that came out as a solid lump, a spire
/// quietly sawn off by the world's ceiling, or a loop with a
/// building sitting in it are all things you only find by walking the whole
/// site — and all things that are one arithmetic slip away at any time.
///
/// The half that cannot be checked here is the reset, because it is not a
/// behaviour: `GameViewController(demoWorld:)` passes `fileURL: nil`, so
/// there is no code path that could write one. What *is* checkable is the
/// other half of the same promise — that building it twice from the seed
/// gives the same site — and that is the last claim below.
///
/// `BLOCKHAVEN_CHECK_DEMO=1`. Exits nonzero if any line fails.
enum DemoCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_DEMO"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }

        mutating func note(_ detail: String) {
            lines.append("[check]   \(detail)")
        }
    }

    private static let dt = 1.0 / 60

    /// Generates chunks as they are asked for.
    ///
    /// The site spans nearly two hundred blocks, which is more chunks than
    /// there is any reason to generate up front — and generation is most of
    /// the cost of every check in this repo. Landmarks and track only touch
    /// a fraction of them.
    private struct Site {
        /// The world itself, for the things that take one directly — the
        /// cart managers. Anything reading through it has to have had
        /// `ensure` called for the cells it will touch, since generation is
        /// this type's job rather than the world's.
        let world: World
        private var generated: Set<ChunkCoord> = []

        init(seed: UInt64) {
            world = World(seed: seed)
            DemoWorld.build(in: world)
        }

        mutating func block(_ x: Int, _ y: Int, _ z: Int) -> BlockType {
            ensure(x, z)
            return world.block(worldX: x, y: y, worldZ: z)
        }

        mutating func ensure(_ x: Int, _ z: Int) {
            let coord = World.chunkCoord(forWorldX: x, worldZ: z)
            if generated.insert(coord).inserted { world.forceGenerate(coord) }
        }
    }

    static func run() -> Never {
        var report = Report()
        var site = Site(seed: DemoWorld.seed)
        let deck = DemoWorld.deck

        // MARK: the ground you land on

        // Spawning inside a wall or twenty blocks over a hole is the one
        // failure that makes the world unopenable rather than merely ugly.
        let spawnX = Int(DemoWorld.spawn.x), spawnZ = Int(DemoWorld.spawn.z)
        let underfoot = site.block(spawnX, deck, spawnZ)
        let headroom = (1...3).allSatisfy { site.block(spawnX, deck + $0, spawnZ) == .air }
        report.check(
            "the player lands on the plaza with room to stand",
            underfoot.isSolid && headroom,
            "\(underfoot) underfoot at y \(deck), three clear blocks above"
        )

        let torches = (-10...10).flatMap { dz in (-10...10).map { (x: $0, z: dz) } }
            .filter { site.block($0.x, deck + 1, $0.z) == .torch }
        report.check(
            "and the plaza is lit",
            torches.count == 8,
            "\(torches.count) torches in the ring"
        )

        // The four radiant lamps inlaid at the compass points, each the
        // colour of what lies that way. They are full lamps as well as
        // markers, so presence is checked rather than light — the torches
        // above already own the light claim.
        let compass: [(x: Int, z: Int, lamp: BlockType)] = [
            (8, 0, .radiantYellow), (-8, 0, .radiantCyan),
            (0, -8, .radiantRed), (0, 8, .radiantGreen),
        ]
        let placed = compass.filter { site.block($0.x, deck, $0.z) == $0.lamp }
        report.check(
            "and the plaza's compass points glow their colours",
            placed.count == 4,
            "\(placed.count) of 4 radiant lamps inlaid in the floor"
        )

        // The glimmer patch: every pearl lamp the builder published is
        // standing where it was written — raised ones on the lawn, sunk
        // ones flush in it — and one of them actually floods light, so
        // the constellation shines rather than merely exists.
        let glimmer = DemoWorld.glimmerCells
        for cell in glimmer { site.ensure(cell.x, cell.z) }
        let shining = glimmer.filter {
            site.block($0.x, $0.raised ? deck + 1 : deck, $0.z) == .pearlLight
        }
        let sample = glimmer[0]
        let sampleLight = site.world.lightLevel(
            worldX: sample.x + 1, y: deck + 1, worldZ: sample.z
        )
        report.check(
            "and the pearl-lamp constellation shines on the lawn",
            shining.count == glimmer.count && sampleLight >= 12,
            "\(shining.count) of \(glimmer.count) lamps placed, "
                + "light \(sampleLight) beside the first"
        )

        // The torches being *present* is not the same as their light being
        // in the world. A structure builder places a lamp with
        // `remesh: false`, into a chunk that may or may not have been
        // generated yet, and the flood that lights the room has to happen
        // either way. This is the claim that a torch in a built structure
        // lights anything at all.
        if let lamp = torches.first {
            site.ensure(lamp.x, lamp.z)
            site.ensure(lamp.x - 2, lamp.z)
            let atLamp = site.world.lightLevel(worldX: lamp.x, y: deck + 1, worldZ: lamp.z)
            let twoAway = site.world.lightLevel(worldX: lamp.x - 2, y: deck + 1, worldZ: lamp.z)
            report.check(
                "and the torches' light is in the world, not just the torches",
                atLamp >= 13 && twoAway >= 10,
                "level \(atLamp) at the torch, \(twoAway) two blocks off it"
            )
        }

        // The deck against the ground it replaced. A site that stands well
        // above its surroundings reads as a plinth someone built rather
        // than as a clearing, and every block it stands proud by is a block
        // off the top of what the landmarks can be — the world stops
        // wherever it stops, whatever the deck does.
        var surfaces: [Int] = []
        for step in 0..<64 {
            let angle = Double(step) / 64 * 2 * .pi
            let radius = 60.0 + Double(step % 4) * 8
            surfaces.append(site.world.generator.surfaceHeight(
                x: Int(radius * cos(angle)), z: Int(radius * sin(angle))
            ))
        }
        surfaces.sort()
        let median = surfaces[surfaces.count / 2]
        report.check(
            "the deck sits on the terrain rather than on a plinth",
            abs(deck - median) <= 6,
            "deck y \(deck) against a median ground of \(median) "
                + "(\(surfaces[0])–\(surfaces[surfaces.count - 1])), "
                + "leaving \(Landmarks.ceiling - deck) blocks of building height"
        )

        // MARK: the landmarks

        // Each is measured rather than described: the check knows where the
        // three were told to stand and nothing else about them, so a
        // builder that changes shape does not need this file changed too.
        //
        // `floor` is per landmark rather than one number for all three,
        // because these are different kinds of building. They are floors
        // that catch "this came out as a sketch", not targets.
        //
        // The tower's floor was 500 for exactly the wrong reason: a lattice
        // is see-through, so a low number looked like the tower being
        // correctly open. It is not — at 120 blocks tall a thousand-block
        // version is a wireframe of a tower rather than a tower, and
        // openness comes from many thin members rather than from few.
        //
        // The floor is not a target to grow toward, though, and it would be
        // read as one if it sat at the ten thousand a finished voxel Eiffel
        // Tower is usually quoted at. Built out to nine thousand this one
        // measures as ironwork and reads as solid brown timber with an arch
        // cut out of it; it stands a little over seven, and what the extra
        // openness costs is argued out at `Landmarks.eiffelTower` rather
        // than here. So: a floor under where it stands, to catch it
        // collapsing back into a sketch.
        //
        // `declared` is how tall the builder says it means to be, where it
        // says so at all. The castle and the basilica are shapes nobody
        // pinned a number to; the tower's spire is aimed at one block.
        //
        // `limit` is the roof each one has to stay under. It is
        // `Landmarks.ceiling` for everything built out of the `Landmarks`
        // helpers, because that is where those helpers stop writing — but
        // it is per site rather than one constant, because the Burj
        // Khalifa is written past them on purpose and measuring it against
        // a ceiling it was never aiming at would fail it for succeeding.
        let sites: [
            (name: String, x: Int, z: Int, floor: Int, declared: Int?, limit: Int)
        ] = [
            ("Neuschwanstein", DemoWorld.castleSite.x, DemoWorld.castleSite.z, 3000, nil,
             Landmarks.ceiling),
            ("the Hagia Sophia", DemoWorld.basilicaSite.x, DemoWorld.basilicaSite.z, 3000, nil,
             Landmarks.ceiling),
            (
                "the Eiffel Tower", DemoWorld.towerSite.x, DemoWorld.towerSite.z, 6500,
                Landmarks.eiffelHeight, Landmarks.ceiling
            ),
            // The floor is what this window can see of it: the scan reaches
            // 24 blocks from the centre of a base that reaches 42, so most
            // of the pyramid is outside the frame. The full hundred
            // thousand is claimed further down, over the whole footprint.
            (
                "the Great Pyramid", DemoWorld.pyramidSite.x, DemoWorld.pyramidSite.z, 50000,
                Landmarks.pyramidTop, Landmarks.ceiling
            ),
            // The window catches the main isle whole — its rock, the
            // cathedral, the houses — plus whatever valley hilltops poke
            // above the deck, which is why the floor is set well above
            // what hills alone could reach. The declared top is the
            // cathedral's spire torch.
            (
                "the city in the sky", DemoWorld.skySite.x, DemoWorld.skySite.z, 6000,
                Landmarks.skyCityTop, Landmarks.ceiling
            ),
            // The one building measured against the world's own roof
            // rather than the landmark ceiling. Its declared height is
            // the pinnacle less the deck, so the equality below is the
            // claim that the beacon is on the highest block there is.
            (
                "the Burj Khalifa", DemoWorld.burjSite.x, DemoWorld.burjSite.z, 12000,
                Landmarks.burjPinnacle - deck, Chunk.height
            ),
        ]

        for place in sites {
            var solids = 0
            var top = deck
            var reach = 0
            for dz in -24...24 {
                for dx in -24...24 {
                    let x = place.x + dx, z = place.z + dz
                    // Up to this site's own roof rather than the landmark
                    // ceiling: the Burj is built past that one, and a scan
                    // that stopped there would report its beacon missing.
                    for y in (deck + 1)...(place.limit - 1) {
                        let block = site.block(x, y, z)
                        guard block != .air, !block.isRail else { continue }
                        solids += 1
                        top = max(top, y)
                        reach = max(reach, max(abs(dx), abs(dz)))
                    }
                }
            }

            report.check(
                "\(place.name) is there and stands up",
                solids > place.floor && top - deck >= 20,
                "\(solids) blocks against a floor of \(place.floor), \(top - deck) tall, "
                    + "reaching \(reach) blocks from its centre"
            )
            // Below the ceiling is the weaker half of this. `setBlock`
            // drops anything above it without a word, so a spire sawn off
            // at the ceiling and a spire that was never that tall read
            // identically here — and the tower clears the ceiling by two
            // blocks, which is one edit to its height or to the deck under
            // it away from being sawn off. Where a builder declares the
            // height it is aiming at, the measured top has to hit it
            // exactly.
            let fullHeight = place.declared.map { top == deck + $0 } ?? true
            report.check(
                "and it is not cut off by the world's ceiling",
                top < place.limit && fullHeight,
                "highest block y \(top), its ceiling is \(place.limit)"
                    + (place.declared.map { ", built to reach \(deck + $0)" } ?? "")
            )

            // Hollow where a person would walk in: somewhere with a floor
            // under it, two clear blocks to stand in and something solid
            // overhead. A building with nowhere inside it is a lump, and a
            // lump is the likeliest way for one of these to come out wrong.
            //
            // Searched at every height rather than at the deck, because a
            // landmark is free to stand on a plinth — Neuschwanstein's
            // ground floor is five blocks up, and looking only at deck
            // level found the plinth and reported the castle solid.
            var standable = 0
            for dz in -20...20 {
                for dx in -20...20 {
                    let x = place.x + dx, z = place.z + dz
                    for y in (deck + 1)...(Landmarks.ceiling - 3) {
                        guard site.block(x, y - 1, z).isSolid,
                              site.block(x, y, z) == .air,
                              site.block(x, y + 1, z) == .air else { continue }
                        let roofed = ((y + 2)...Landmarks.ceiling).contains {
                            site.block(x, $0, z).isSolid
                        }
                        if roofed { standable += 1 }
                    }
                }
            }
            report.check(
                "and you can get inside it",
                standable >= 40,
                "\(standable) cells of covered head-height space"
            )
        }

        // MARK: the tower's arch and stairs

        // The arch. Raising the tower's block floor to catch a wireframe
        // creates the opposite temptation — reach the number by filling the
        // thing in — and the one feature that cannot survive that is the
        // open span underneath, which is what makes the Eiffel Tower a
        // thing you stand beneath and look up through. Straight up the
        // centreline from the deck there must be nothing at all.
        //
        // Counted to the world's ceiling rather than to a cap of its own.
        // A loop that stopped at sixty reported sixty-one for every tower
        // that was open at all, which is a constant wearing a
        // measurement's clothes: it could not tell the tower it has from
        // one twice as open, or notice the day the span started shrinking.
        //
        // And counted over every column of the square the builder says it
        // cleared, not up the axis. One column is one sample of a hole and
        // the one likeliest to be clear, since the axis is where nothing is
        // ever built; the worst column of the square is the span you can
        // actually walk under. The two differ by a factor of two here.
        let well = Landmarks.eiffelWell
        var openSpan = Int.max
        var worst = (dx: 0, dz: 0)
        for dz in -well...well {
            for dx in -well...well {
                let x = DemoWorld.towerSite.x + dx, z = DemoWorld.towerSite.z + dz
                var span = 0
                while deck + 1 + span <= Landmarks.ceiling,
                      site.block(x, deck + 1 + span, z) == .air {
                    span += 1
                }
                if span < openSpan {
                    openSpan = span
                    worst = (dx, dz)
                }
            }
        }
        report.check(
            "and you can still stand under the tower and see sky",
            openSpan >= 25,
            "\(openSpan) clear blocks up the worst column of the \(well * 2 + 1)-block "
                + "square on the axis, at \(worst)"
        )

        // The stairs. The Eiffel Tower is meant to be climbable: four
        // staircases from the ground to the first terrace and two on from
        // there to the second, as the real one has.
        //
        // Walked with the player's own body. Two weaker versions came
        // before it and both passed a tower nobody could climb, which is
        // the whole reason this one is expensive. The first counted whether
        // *a* step existed at every height anywhere in the footprint, so a
        // step at height 5 in one leg and a step at height 6 in another
        // satisfied it — it never once asked whether two consecutive steps
        // were next to each other. The second flooded standable cells and
        // did ask that, but moved a point between them a whole block at a
        // time, which is the one rise `stepHeight` exists to refuse, and
        // had no width to fit past a riser with. Counting is not walking,
        // and neither is flooding.
        let flights = Landmarks.eiffelFlights(
            originX: DemoWorld.towerSite.x, groundY: deck, originZ: DemoWorld.towerSite.z
        )
        for route in flights {
            for cell in route {
                for (dx, dz) in [(0, 0), (2, 0), (-2, 0), (0, 2), (0, -2)] {
                    site.ensure(cell.x + dx, cell.z + dz)
                }
            }
        }
        let walk = Walk(flights: flights, world: site.world)
        // Half the tower's own height, rather than a fixed number: the
        // claim is that both stages work, and the second terrace is above
        // the halfway mark on any sane set of proportions. Taken from the
        // builder rather than copied, so shortening the tower cannot leave
        // this quietly demanding a climb the tower no longer offers.
        let topCell = (flights.flatMap { $0 }.map { $0.y }.max() ?? deck) - deck
        report.check(
            "the tower can actually be walked up",
            walk.stuck == nil && topCell >= Landmarks.eiffelHeight / 2,
            walk.stuck.map { "\($0) — \(walk.stood) of \(walk.total) cells walked" }
                ?? "a body walked in off the plaza and up all \(walk.total) treads and "
                    + "landings of \(flights.count) staircases, finishing "
                    + String(format: "%.1f", Double(walk.highestFoot) - Double(deck))
                    + " blocks above the deck of a tower \(Landmarks.eiffelHeight) tall"
        )

        // MARK: the pyramid

        // The headline claim, counted over the whole footprint rather than
        // trusted from the builder's arithmetic: a hundred thousand blocks
        // standing in the world. This is the demo's largest structure by a
        // factor of ten, and "the sum of forty-three odd squares minus two
        // carved rooms" is exactly the kind of number that is one slipped
        // sign away from being half itself.
        let pyramid = DemoWorld.pyramidSite
        var pyramidBlocks = 0
        for dz in -44...44 {
            for dx in -44...44 {
                for y in (deck + 1)...Landmarks.ceiling {
                    let block = site.block(pyramid.x + dx, y, pyramid.z + dz)
                    guard block != .air, !block.isRail else { continue }
                    pyramidBlocks += 1
                }
            }
        }
        report.check(
            "the pyramid really is a hundred thousand blocks",
            pyramidBlocks >= 100_000,
            "\(pyramidBlocks) blocks over the full footprint"
        )
        report.check(
            "and it is capped in gold",
            site.block(pyramid.x, deck + Landmarks.pyramidTop - 1, pyramid.z) == .goldBlock
                && site.block(pyramid.x, deck + Landmarks.pyramidTop, pyramid.z) == .torch,
            "\(site.block(pyramid.x, deck + Landmarks.pyramidTop - 1, pyramid.z)) at the apex, "
                + "\(site.block(pyramid.x, deck + Landmarks.pyramidTop, pyramid.z)) above it"
        )

        // The way in, walked with the player's own body — the same argument
        // as the tower's stairs, one dimension easier. The route is the
        // builder's, so a pyramid that moves its door says so here.
        let corridor = Landmarks.pyramidRoute(
            originX: pyramid.x, groundY: deck, originZ: pyramid.z
        )
        for routeCells in corridor {
            for cell in routeCells {
                for (dx, dz) in [(0, 0), (2, 0), (-2, 0), (0, 2), (0, -2)] {
                    site.ensure(cell.x + dx, cell.z + dz)
                }
            }
        }
        let crawl = Walk(flights: corridor, world: site.world)
        report.check(
            "and a body can walk in off the sand to the treasure",
            crawl.stuck == nil,
            crawl.stuck.map { "\($0) — \(crawl.stood) of \(crawl.total) cells walked" }
                ?? "all \(crawl.total) cells of the corridor walked"
        )

        // The treasure itself, and the light to find it by. A chamber this
        // deep inside a solid structure sees no sky at all: if the torches'
        // flood failed here the room would be pitch black, and a treasure
        // nobody can see is a rumour.
        var gold = 0
        var diamonds = 0
        for dz in -2...2 {
            for dx in -2...2 {
                for dy in 1...4 {
                    switch site.block(pyramid.x + dx, deck + dy, pyramid.z + dz) {
                    case .goldBlock: gold += 1
                    case .diamondOre, .diamondBlock: diamonds += 1
                    default: break
                    }
                }
            }
        }
        let glow = site.world.lightLevel(worldX: pyramid.x, y: deck + 4, worldZ: pyramid.z)
        report.check(
            "and the treasure is worth the walk, and lit",
            gold >= 9 && diamonds == 1 && glow >= 10,
            "\(gold) gold and \(diamonds) diamond on the plinth, light level \(glow) over it"
        )

        // The approach: every painted capital the builder published stands
        // on a fluted shaft, from the causeway colonnade to the pool
        // court's ring. The list is the builder's own — a moved column
        // fails here rather than quietly standing somewhere else.
        let capitals = Landmarks.pyramidCapitals(
            originX: pyramid.x, groundY: deck, originZ: pyramid.z
        )
        let crowned = capitals.filter {
            site.block($0.x, $0.y, $0.z) == .pillarCapital
                && site.block($0.x, $0.y - 1, $0.z) == .sandstonePillar
        }
        report.check(
            "the causeway is a colonnade of painted capitals",
            !capitals.isEmpty && crowned.count == capitals.count,
            "\(crowned.count) of \(capitals.count) capitals on their shafts"
        )

        // The obelisks, checked at the one block that makes them obelisks:
        // gold at the top of a fluted shaft.
        let obeliskCaps = Landmarks.pyramidObeliskCaps(
            originX: pyramid.x, groundY: deck, originZ: pyramid.z
        )
        let gilded = obeliskCaps.filter {
            site.block($0.x, $0.y, $0.z) == .goldBlock
                && site.block($0.x, $0.y - 1, $0.z) == .sandstonePillar
        }
        report.check(
            "and two obelisks stand gold-capped beside the door",
            gilded.count == 2,
            "\(gilded.count) of 2 pyramidions in gold"
        )

        // The sphinx: a head at head height with its gold nemes flaps. The
        // body is a lot of sandstone that could be anything; the gold on
        // the head is the part that is a sphinx or is nothing.
        var nemes = 0
        for dy in 5...8 {
            for dz in -13...(-9) {
                for dx in -51...(-49)
                where site.block(pyramid.x + dx, deck + dy, pyramid.z + dz) == .goldBlock {
                    nemes += 1
                }
            }
        }
        report.check(
            "and the sphinx keeps watch in a gold headdress",
            site.block(pyramid.x - 50, deck + 6, pyramid.z - 11) == .sandstone && nemes >= 12,
            "\(nemes) gold blocks about the head"
        )

        // The pool court holds its water — all of it. A pool with one
        // missing cell is a pool draining into the crypt below.
        var wet = 0
        for dz in 10...14 {
            for dx in -53...(-47)
            where site.block(pyramid.x + dx, deck, pyramid.z + dz) == .water {
                wet += 1
            }
        }
        report.check(
            "and the pool court's water is standing",
            wet == 35,
            "\(wet) of 35 water cells in the basin"
        )

        // The secret rooms. Each is behind exactly one carved marker
        // block; each check confirms the marker is there to be noticed,
        // the room behind it is open and lit, and the treasure inside is
        // real. The serdab hides in the corridor's north wall, the crypt
        // under the chamber's own floor.
        let markers = Landmarks.pyramidSecretMarkers(
            originX: pyramid.x, groundY: deck, originZ: pyramid.z
        )
        let serdabDoor = markers[0]
        let serdabLight = site.world.lightLevel(
            worldX: pyramid.x - 25, y: deck + 3, worldZ: pyramid.z - 5
        )
        report.check(
            "one carved block in the corridor wall hides the serdab",
            site.block(serdabDoor.x, serdabDoor.y, serdabDoor.z) == .sandstoneCarved
                && site.block(serdabDoor.x, serdabDoor.y, serdabDoor.z - 1) == .air
                && site.block(pyramid.x - 26, deck + 1, pyramid.z - 5) == .goldBlock
                && site.block(pyramid.x - 25, deck + 2, pyramid.z - 5) == .diamondOre
                && serdabLight >= 8,
            "marker \(site.block(serdabDoor.x, serdabDoor.y, serdabDoor.z)), "
                + "light \(serdabLight) over the diamond"
        )
        let cryptDoor = markers[1]
        let cryptLid = site.block(pyramid.x + 1, deck - 2, pyramid.z + 3)
        let cryptLight = site.world.lightLevel(
            worldX: pyramid.x + 2, y: deck - 2, worldZ: pyramid.z + 2
        )
        report.check(
            "and one carved tile in the chamber floor hides the crypt",
            site.block(cryptDoor.x, cryptDoor.y, cryptDoor.z) == .sandstoneCarved
                && site.block(cryptDoor.x, cryptDoor.y - 1, cryptDoor.z) == .air
                && cryptLid == .goldBlock
                && site.block(pyramid.x, deck - 1, pyramid.z + 3) == .diamondBlock
                && cryptLight >= 8,
            "marker \(site.block(cryptDoor.x, cryptDoor.y, cryptDoor.z)), "
                + "\(cryptLid) on the sarcophagus, light \(cryptLight) beside it"
        )

        // MARK: the sunken city

        // What counts as the city when a block is being counted: the stuff
        // no seabed grows on its own.
        func isCityFabric(_ block: BlockType) -> Bool {
            switch block {
            case .seaStone, .glass, .seaLantern, .goldBlock, .obsidian,
                 .radiantRed, .radiantYellow, .radiantGreen, .radiantCyan:
                return true
            default: return block.isStairs
            }
        }

        let city = DemoWorld.atlantisSite
        let cityFloor = 42

        // The beacon first: the only part of Atlantis you can see from the
        // plaza, and the thing that tells anybody it exists. It has to be
        // there, and its light has to be in the world.
        let beacon = Landmarks.atlantisBeacon(originX: city.x, originZ: city.z)
        let beaconBlock = site.block(beacon.x, beacon.y, beacon.z)
        let beaconGlow = site.world.lightLevel(worldX: beacon.x + 1, y: beacon.y, worldZ: beacon.z)
        report.check(
            "the lighthouse is lit",
            beaconBlock == .seaLantern && beaconGlow >= 12,
            "\(beaconBlock) in the lantern room, light level \(beaconGlow) beside it"
        )

        // The dredge did its job: this seed's own sea is eight blocks deep,
        // and the city's claim to be sunken rests on the twenty the builder
        // dug. Measured over the crown of the grand dome and out on the
        // open basin floor.
        var overCrown = 0
        for y in 43...WorldGenerator.seaLevel where site.block(city.x, y, city.z + 20) == .water {
            overCrown += 1
        }
        report.check(
            "and the city is properly drowned",
            site.block(city.x, 61, city.z) == .water && overCrown >= 16,
            "water over the grand dome's crown, \(overCrown) blocks of sea on the basin floor"
        )

        // The fabric of the city, counted across its three volumes: the
        // domes' column, the tunnel's strip, the lighthouse's plot.
        var cityBlocks = 0
        for (xs, zs) in [
            (city.x - 20...city.x + 20, city.z - 50...city.z + 50),
            (city.x + 20...city.x + 110, city.z - 4...city.z + 4),
        ] as [(ClosedRange<Int>, ClosedRange<Int>)] {
            for z in zs {
                for x in xs {
                    for y in (cityFloor - 8)...90 where isCityFabric(site.block(x, y, z)) {
                        cityBlocks += 1
                    }
                }
            }
        }
        report.check(
            "the city is really built down there",
            cityBlocks >= 7000,
            "\(cityBlocks) blocks of glass, sea-stone, gold and obsidian under the sea"
        )

        // The domes hold their air. A hole in a shell, or a band the bore
        // missed, floods the room the moment the mesher looks at it — and a
        // drowned garden is the single likeliest way for this build to rot.
        for (name, cz, radius) in [
            ("the grand dome", city.z, 17), ("the garden", city.z - 35, 11),
            ("the maze", city.z + 35, 13),
        ] {
            var wet = 0
            var standable = 0
            for dz in -(radius - 3)...(radius - 3) {
                for dx in -(radius - 3)...(radius - 3) {
                    // Inside the dome's circle, not its bounding square: the
                    // square's corners are open sea, and open sea being wet
                    // is not a finding.
                    guard dx * dx + dz * dz <= (radius - 3) * (radius - 3) else { continue }
                    for dy in 1...3 {
                        let block = site.block(city.x + dx, cityFloor + dy, cz + dz)
                        if block == .water { wet += 1 }
                        if dy == 1, block == .air || block.isPlant,
                           site.block(city.x + dx, cityFloor, cz + dz).isSolid {
                            standable += 1
                        }
                    }
                }
            }
            report.check(
                "and \(name) holds its air",
                wet == 0 && standable >= 40,
                "\(wet) water cells inside, \(standable) cells of dry floor"
            )
        }

        // The walk: a body goes in off the lawn, through the lighthouse,
        // down twenty-two treads under the shore, along a hundred blocks of
        // sea tunnel, and stops at the foot of the trident. Same argument
        // as the tower and the pyramid: the route is the builder's, and
        // nothing but a body can certify a staircase.
        let dive = Landmarks.atlantisRoute(originX: city.x, groundY: deck, originZ: city.z)
        for routeCells in dive {
            for cell in routeCells {
                for (dx, dz) in [(0, 0), (2, 0), (-2, 0), (0, 2), (0, -2)] {
                    site.ensure(cell.x + dx, cell.z + dz)
                }
            }
        }
        let descent = Walk(flights: dive, world: site.world)
        report.check(
            "and a body can walk from the lawn to the trident",
            descent.stuck == nil,
            descent.stuck.map { "\($0) — \(descent.stood) of \(descent.total) cells walked" }
                ?? "all \(descent.total) cells walked, finishing "
                    + String(format: "%.0f", Double(deck + 1) - Double(descent.highestFoot))
                    + " blocks under the lawn at the door"
        )
        let trident = site.block(city.x, cityFloor + 11, city.z)
        report.check(
            "and the trident is tipped with diamond",
            trident == .diamondBlock && site.block(city.x, cityFloor + 8, city.z) == .goldBlock,
            "\(trident) at the tip on a gold haft"
        )

        // The garden grows: grass underfoot, leaves overhead, flowers —
        // alive under glass at the bottom of the sea.
        var gardenGrass = 0
        var gardenLeaves = 0
        var gardenPlants = 0
        for dz in -9...9 {
            for dx in -9...9 {
                if site.block(city.x + dx, cityFloor, city.z - 35 + dz) == .grass { gardenGrass += 1 }
                for dy in 1...8 {
                    let block = site.block(city.x + dx, cityFloor + dy, city.z - 35 + dz)
                    if block == .leaves { gardenLeaves += 1 }
                    if block.isPlant { gardenPlants += 1 }
                }
            }
        }
        report.check(
            "and the garden grows under glass",
            gardenGrass >= 150 && gardenLeaves >= 20 && gardenPlants >= 8,
            "\(gardenGrass) grass, \(gardenLeaves) leaves, \(gardenPlants) plants"
        )

        // The maze is a maze — walls standing, corridors carved — and the
        // hole at its centre has a staircase in it, and the crypt below has
        // its treasure, lit. The maze's own walkability is by construction
        // (a depth-first carve reaches every cell); what is checked is that
        // the carve happened and the prize is real.
        var mazeWalls = 0
        var mazePaths = 0
        for dz in -7...7 {
            for dx in -7...7 {
                let block = site.block(city.x + dx, cityFloor + 1, city.z + 35 + dz)
                if block == .seaStone { mazeWalls += 1 }
                if block == .air { mazePaths += 1 }
            }
        }
        let hatch = site.block(city.x, cityFloor - 1, city.z + 35)
        var cryptGold = 0
        var cryptDiamonds = 0
        for dz in -3...3 {
            for dx in -3...3 {
                for dy in -6...(-3) {
                    switch site.block(city.x + dx, cityFloor + dy, city.z + 35 + dz) {
                    case .goldBlock: cryptGold += 1
                    case .diamondOre, .diamondBlock: cryptDiamonds += 1
                    default: break
                    }
                }
            }
        }
        let cryptGlow = site.world.lightLevel(worldX: city.x, y: cityFloor - 5, worldZ: city.z + 35)
        report.check(
            "the maze stands and its crypt pays out",
            mazeWalls >= 80 && mazePaths >= 80 && hatch.isStairs
                && cryptGold >= 12 && cryptDiamonds == 3 && cryptGlow >= 5,
            "\(mazeWalls) wall cells, \(mazePaths) corridor cells, \(hatch) under the hatch, "
                + "\(cryptGold) gold and \(cryptDiamonds) diamond below, light \(cryptGlow)"
        )

        // MARK: the city in the sky

        // Floating is the entire premise, and the way a floating island
        // fails is by quietly not floating: a taper miscounted by a few
        // blocks grows a root into a hilltop and the city becomes a
        // funny-shaped mountain. So each isle's keel — published by the
        // builder — must be solid with clear air beneath it, under a
        // walkable grass top.
        let sky = DemoWorld.skySite
        let isles = Landmarks.skyIslands(originX: sky.x, groundY: deck, originZ: sky.z)
        for isle in isles { site.ensure(isle.x, isle.z) }
        // Solid at the walking surface and the keel, air below — the
        // surface is asked for `isSolid` rather than grass because each
        // isle's centre carries a floor: the cathedral's plinth, the
        // mill's boards, the watchtower's.
        let earthbound = isles.filter { isle in
            !(site.block(isle.x, isle.top, isle.z).isSolid
                && site.block(isle.x, isle.tip, isle.z).isSolid
                && site.block(isle.x, isle.tip - 2, isle.z) == .air
                && site.block(isle.x, isle.tip - 6, isle.z) == .air)
        }
        report.check(
            "the sky city's three isles truly float",
            earthbound.isEmpty,
            earthbound.isEmpty
                ? "floor over rock over open air at all \(isles.count) keels"
                : "\(earthbound.count) of \(isles.count) isles grounded, first at "
                    + "(\(earthbound[0].x), \(earthbound[0].z))"
        )

        // The climb, walked with the player's own body — the same
        // physics-not-arithmetic argument as the tower stairs, and the
        // stakes are higher here because the stair hangs over a
        // twenty-block drop: a tread pinched too narrow is not a detour,
        // it is the city being unreachable.
        let skyFlights = Landmarks.skyStairRoute(originX: sky.x, groundY: deck, originZ: sky.z)
        for route in skyFlights {
            for cell in route {
                for (dx, dz) in [(0, 0), (2, 0), (-2, 0), (0, 2), (0, -2)] {
                    site.ensure(cell.x + dx, cell.z + dz)
                }
            }
        }
        let climb = Walk(flights: skyFlights, world: site.world)
        report.check(
            "and the sky stair carries a body from the lawn to the gate",
            climb.stuck == nil && climb.highestFoot >= CGFloat(deck + 30),
            climb.stuck.map { "\($0) — \(climb.stood) of \(climb.total) cells walked" }
                ?? "a body stepped off the lawn and climbed all \(climb.total) treads, "
                    + "finishing \(String(format: "%.1f", Double(climb.highestFoot) - Double(deck)))"
                    + " blocks above the deck"
        )

        // The golden road: every cell gold, and glowing — gold emits
        // here, so the road lighting its own way at dusk is a property
        // of the blocks being right, not of a lamp nearby.
        let road = Landmarks.skyRoadCells(originX: sky.x, groundY: deck, originZ: sky.z)
        for cell in road { site.ensure(cell.x, cell.z) }
        let paved = road.filter { site.block($0.x, deck + 29, $0.z) == .goldBlock }
        let roadGlow = site.world.lightLevel(worldX: sky.x, y: deck + 30, worldZ: sky.z - 8)
        report.check(
            "and the golden road glows from the gate to the cathedral doors",
            paved.count == road.count && roadGlow >= 4,
            "\(paved.count) of \(road.count) cells gold, light \(roadGlow) over the lane"
        )

        // The dwellings: half-timbered — the new fabric actually used,
        // not just craftable — with doors to walk in through, and a lit
        // hearth cell in every one of them, mill cottage included.
        var timbered = 0
        var cityDoors = 0
        for z in (sky.z - 26)...(sky.z + 12) {
            for x in (sky.x - 42)...(sky.x + 42) {
                for y in (deck + 30)...(deck + 38) {
                    let block = site.block(x, y, z)
                    if block == .timberFrame { timbered += 1 }
                    if block.isDoor, block.doorPart == .lower { cityDoors += 1 }
                }
            }
        }
        let hearths = Landmarks.skyHearths(originX: sky.x, groundY: deck, originZ: sky.z)
        for cell in hearths { site.ensure(cell.x, cell.z) }
        let coldHearths = hearths.filter {
            site.world.lightLevel(worldX: $0.x, y: $0.y, worldZ: $0.z) < 8
        }
        report.check(
            "and the houses are half-timbered, doored and lit",
            timbered >= 30 && cityDoors >= 6 && coldHearths.isEmpty,
            "\(timbered) timber-frame blocks, \(cityDoors) doorways, "
                + "\(hearths.count - coldHearths.count) of \(hearths.count) hearths lit"
        )

        // The airships: canvas where the builder says each canopy is,
        // a solid deck below it, and open air under the keel — riding at
        // anchor, not resting on anything.
        let balloons = Landmarks.skyBalloons(originX: sky.x, groundY: deck, originZ: sky.z)
        var moored = 0
        for ship in balloons {
            site.ensure(ship.x, ship.z)
            var canvas = 0
            for dz in -3...3 {
                for dx in -8...8 {
                    for dy in -3...3 where site.block(ship.x + dx, ship.y + dy, ship.z + dz) == .balloonCanvas {
                        canvas += 1
                    }
                }
            }
            if canvas >= 25,
               site.block(ship.x, ship.baseY, ship.z).isSolid,
               site.block(ship.x, ship.baseY - 4, ship.z) == .air {
                moored += 1
            }
        }
        report.check(
            "and two airships ride at anchor off the rim",
            moored == balloons.count,
            "\(moored) of \(balloons.count) vessels with a full canopy over a deck over air"
        )

        // The waterfalls: from each rim pool the column must be water
        // the whole way down and actually land — a fall that stops
        // mid-air says the builder and the terrain disagree about where
        // the valley floor is.
        let falls = Landmarks.skyFalls(originX: sky.x, groundY: deck, originZ: sky.z)
        var pouring = 0
        var fallDetail: [String] = []
        for fall in falls {
            site.ensure(fall.x, fall.z)
            var y = fall.top
            while y > 0, site.block(fall.x, y, fall.z) == .water { y -= 1 }
            let ribbon = fall.top - y
            let landed = site.block(fall.x, y, fall.z).isSolid
            if ribbon >= 15, landed { pouring += 1 }
            fallDetail.append("\(ribbon) blocks\(landed ? "" : ", never landing")")
        }
        report.check(
            "and the waterfalls pour all the way to the valley floor",
            pouring == falls.count,
            fallDetail.joined(separator: ", ")
        )

        // The clouds: gathered under the keels and misting at the falls'
        // feet — and one of them bears weight, because the first thing
        // anyone asks of a cloud block is whether they can stand on it.
        var cloudCells = 0
        for z in (sky.z - 35)...(sky.z + 30) {
            for x in (sky.x - 70)...(sky.x + 70) {
                for y in (deck - 6)...(deck + 31) where site.block(x, y, z) == .cloud {
                    cloudCells += 1
                }
            }
        }
        let perch = (x: sky.x + 28, y: deck + 28, z: sky.z + 16)
        let standableCloud = site.block(perch.x, perch.y, perch.z) == .cloud
            && site.block(perch.x, perch.y + 1, perch.z) == .air
            && site.block(perch.x, perch.y + 2, perch.z) == .air
        report.check(
            "and you can walk off the rim onto a cloud",
            cloudCells >= 80 && standableCloud,
            "\(cloudCells) cloud blocks about the city, "
                + (standableCloud ? "clear standing on the rim cloud" : "the rim cloud is not standable")
        )

        // MARK: the Burj Khalifa

        // The one claim this building exists to make: an unbroken column
        // of tower from the top of its body to the last block the world
        // has room for.
        //
        // Measured as continuity rather than as a height, because height
        // alone cannot tell the two failures apart. `setBlock` drops
        // anything at or above `Chunk.height` without a word, so a spire
        // aimed too high comes back looking exactly like one aimed
        // correctly — and a taper that divides wrong somewhere in the
        // middle leaves a beacon floating over a gap, which reads from the
        // plaza as a tower and from here as a pass. Walking the centre
        // column block by block catches both.
        let burj = DemoWorld.burjSite
        site.ensure(burj.x, burj.z)
        let spireFoot = deck + Burj.bodyHeight
        var needle = 0
        var firstGap: Int?
        for y in spireFoot...Landmarks.burjPinnacle {
            if site.block(burj.x, y, burj.z).isSolid {
                needle += 1
            } else if firstGap == nil {
                firstGap = y
            }
        }
        report.check(
            "the Burj Khalifa's spire runs unbroken to the roof of the world",
            firstGap == nil && needle == Landmarks.burjPinnacle - spireFoot + 1,
            firstGap.map { "the needle breaks at y \($0)" }
                ?? "\(needle) solid blocks from y \(spireFoot) to y "
                    + "\(Landmarks.burjPinnacle), the highest block this world has"
        )

        // The setbacks spiral rather than ring. The wings step back one at
        // a time, so at almost any height the three of them reach three
        // different distances — and if they ever all matched all the way
        // up, the tower would be a cone with ledges on it and the
        // silhouette the building is famous for would be gone. Measured
        // by walking out along each wing's own axis until the blocks stop.
        var staggered = 0
        var heights = 0
        for step in 1...8 {
            let y = deck + step * Burj.shaftHeight / 9
            var reaches: [Int] = []
            for direction in Burj.wingDirections {
                var far = 0
                for radius in 1...Landmarks.burjSpan {
                    let x = burj.x + Int((direction.x * Double(radius)).rounded())
                    let z = burj.z + Int((direction.z * Double(radius)).rounded())
                    if site.block(x, y, z) != .air { far = radius }
                }
                reaches.append(far)
            }
            heights += 1
            if Set(reaches).count > 1 { staggered += 1 }
        }
        report.check(
            "and its wings step back one at a time, so the setbacks spiral",
            staggered >= heights - 1,
            "\(staggered) of \(heights) heights sampled have the three wings "
                + "reaching different distances"
        )

        // The climb, walked with the player's own body — in at the door,
        // down the hall and up every tread of the spiral to the
        // observation deck. Seventy-odd treads of stair blocks at a block
        // of rise each is a thing that works only if every tread faces the
        // way it should, and a spiral turns a corner every eight treads.
        // Arithmetic will not tell you whether a body fits round them.
        let burjFlights = Landmarks.burjStairRoute(
            originX: burj.x, groundY: deck, originZ: burj.z
        )
        for route in burjFlights {
            for cell in route {
                for (dx, dz) in [(0, 0), (2, 0), (-2, 0), (0, 2), (0, -2)] {
                    site.ensure(cell.x + dx, cell.z + dz)
                }
            }
        }
        let ascent = Walk(flights: burjFlights, world: site.world)
        report.check(
            "and a body climbs it from the lobby door to the observation deck",
            ascent.stuck == nil
                && ascent.highestFoot >= CGFloat(deck + Landmarks.burjDeckHeight),
            ascent.stuck.map { "\($0) — \(ascent.stood) of \(ascent.total) cells walked" }
                ?? "a body walked in at the door and climbed all \(ascent.total) cells, "
                    + "finishing \(String(format: "%.1f", Double(ascent.highestFoot) - Double(deck)))"
                    + " blocks above the podium"
        )

        // The pool it stands over, because a tower with nothing in front
        // of it is a tower in a field.
        let pool = Landmarks.burjFountain(originX: burj.x, groundY: deck, originZ: burj.z)
        site.ensure(pool.x, pool.z)
        var water = 0
        for dz in (-pool.radius)...pool.radius {
            for dx in (-pool.radius)...pool.radius
            where site.block(pool.x + dx, pool.y, pool.z + dz) == .water {
                water += 1
            }
        }
        let poolLight = site.world.lightLevel(worldX: pool.x, y: pool.y, worldZ: pool.z)
        report.check(
            "and the fountain in front of it holds water, and lights it",
            water >= 300 && poolLight >= 6,
            "\(water) cells of water at y \(pool.y), light \(poolLight) in the middle of it"
        )

        // MARK: the dynamite twin

        // The copy west of it: the same tower, made of nothing but TNT.
        //
        // Two claims, and they are separate. That it is *there* — a column
        // of solid blocks running to the same pinnacle as the original, so
        // it is a Burj Khalifa and not a pile — and that it is *pure*, no
        // block of it anything but dynamite. Purity is the whole request,
        // and it is the one a shared builder can quietly break: a single
        // block placed straight through `world.setBlock` instead of
        // through `Burj.paint` would leave one stone floor plate in a
        // tower of explosives, which nobody would ever see and which would
        // mean this was not the thing that was asked for.
        let twin = DemoWorld.dynamiteBurjSite
        site.ensure(twin.x, twin.z)
        var twinNeedle = 0
        var twinGap: Int?
        for y in (deck + Burj.bodyHeight)...Landmarks.burjPinnacle {
            if site.block(twin.x, y, twin.z).isSolid {
                twinNeedle += 1
            } else if twinGap == nil {
                twinGap = y
            }
        }
        report.check(
            "the dynamite Burj Khalifa stands 200 blocks west, to the same roof",
            twinGap == nil
                && twinNeedle == Landmarks.burjPinnacle - (deck + Burj.bodyHeight) + 1,
            twinGap.map { "the needle breaks at y \($0)" }
                ?? "\(twinNeedle) solid blocks to y \(Landmarks.burjPinnacle), "
                    + "\(DemoWorld.burjSite.x - twin.x) blocks west of the original"
        )

        // Purity, over the tower itself rather than its apron: the scan
        // starts a block above the podium and stays inside the wings, so
        // the ground the apron laid and the pool it sits by are out of
        // frame and only what the building is made of is counted.
        var dynamite = 0
        var impurities: [BlockType: Int] = [:]
        for dz in (-Landmarks.burjSpan)...Landmarks.burjSpan {
            for dx in (-Landmarks.burjSpan)...Landmarks.burjSpan {
                site.ensure(twin.x + dx, twin.z + dz)
                for y in (deck + 1)...Landmarks.burjPinnacle {
                    let block = site.block(twin.x + dx, y, twin.z + dz)
                    guard block != .air else { continue }
                    if block == .tnt {
                        dynamite += 1
                    } else {
                        impurities[block, default: 0] += 1
                    }
                }
            }
        }
        let commonest = impurities.max { $0.value < $1.value }
        report.check(
            "and every block of it is dynamite",
            impurities.isEmpty && dynamite > 15000,
            commonest.map {
                "\($0.value) blocks of \($0.key) in it, and \(impurities.count) kinds that are not TNT"
            }
                ?? "\(dynamite) blocks of TNT and nothing else above the podium"
        )

        // MARK: the track

        // Every cell the builder laid still holds a rail. This is the
        // claim that catches a landmark growing far enough to swallow the
        // line, which would leave the ride ending in a wall.
        let track = DemoWorld.trackCells
        for cell in track { site.ensure(cell.x, cell.z) }
        let missing = track.filter { !site.block($0.x, $0.y, $0.z).isRail }
        report.check(
            "every cell of the track still holds a rail",
            missing.isEmpty,
            missing.isEmpty
                ? "\(track.count) cells, nothing built over"
                : "\(missing.count) of \(track.count) cells lost, first at \(missing[0])"
        )

        let boosters = track.filter { site.block($0.x, $0.y, $0.z).isBooster }
        let slopes = track.filter { site.block($0.x, $0.y, $0.z).isRailSlope }
        let curves = track.filter {
            let rail = site.block($0.x, $0.y, $0.z)
            return rail.isRail && !rail.isRailSlope && !rail.isBooster
                && rail != .railNorthSouth && rail != .railEastWest
        }
        report.check(
            "and the loop turned its own corners",
            curves.count >= 4,
            "\(curves.count) curves, \(slopes.count) slopes, \(boosters.count) powered"
        )

        // Every booster runs over glowCrystal — the strips of light that
        // make the loop readable from the tower at night. Counted against
        // the boosters actually resolved, not the builder's intent, so a
        // booster that moved leaves this red.
        let unlit = boosters.filter { site.block($0.x, $0.y - 1, $0.z) != .glowCrystal }
        report.check(
            "and every booster strip glows underfoot",
            !boosters.isEmpty && unlit.isEmpty,
            unlit.isEmpty
                ? "\(boosters.count) boosters, all on glowCrystal"
                : "\(unlit.count) of \(boosters.count) dark, first at \(unlit[0])"
        )

        // MARK: the ride

        // A cart put down on the north side and given a shove has to get
        // right round. Nothing about that is guaranteed by the track being
        // continuous: a corner that resolved wrong sends it down a siding,
        // and too little powered rail leaves it stopped on a hill.
        var carts = MinecartManager()
        let start = (x: 30, y: deck + 1, z: -64)
        guard let id = carts.place(at: start, in: site.world) else {
            report.check("a cart can be put on the loop", false, "nothing was placed at \(start)")
            finish(report)
        }
        report.check("a cart can be put on the loop", true, "at \(start)")

        carts.shove(id, speed: 8, heading: .east)
        var visited = Set<String>()
        var highest = deck
        var fastest: CGFloat = 0
        var returned = false
        for frame in 0..<(60 * 240) {
            _ = carts.update(dt: dt, world: site.world)
            guard let cart = carts.cart(id) else { break }
            let cell = cart.cell
            site.ensure(cell.x, cell.z)
            visited.insert("\(cell.x),\(cell.z)")
            highest = max(highest, cell.y)
            fastest = max(fastest, abs(cart.speed))
            // Back where it started, having actually gone somewhere first.
            if frame > 600, abs(cart.position.x - 30.5) < 1.5, cell.z == -64 {
                returned = true
                break
            }
        }

        report.check(
            "and it gets all the way round the loop",
            returned,
            returned
                ? "back at the start having visited \(visited.count) cells"
                : "stopped after \(visited.count) cells at \(String(describing: carts.cart(id)?.cell))"
        )
        report.check(
            "and the hill is a hill",
            highest >= deck + 4,
            "climbed to y \(highest) from a deck at \(deck), fastest \(String(format: "%.1f", Double(fastest))) blocks/s"
        )

        // MARK: getting going

        // The cart waiting in the plaza is on plain rail, so the only thing
        // that can start it is the rider leaning on the controls. If that
        // does not work the demo opens with a cart nobody can move.
        var parked = MinecartManager()
        guard let waiting = parked.place(at: DemoWorld.cartCell, in: site.world) else {
            report.check("there is a cart waiting in the plaza", false, "no rail at \(DemoWorld.cartCell)")
            finish(report)
        }
        report.check("there is a cart waiting in the plaza", true, "at \(DemoWorld.cartCell)")

        parked.ride(waiting)
        let parkedStart = parked.cart(waiting)?.position.z ?? 0
        for _ in 0..<180 {
            // Looking south down the spur — yaw 0 is +z — and pressing
            // forward.
            parked.drive(throttle: 1, cameraYaw: 0, dt: dt)
            _ = parked.update(dt: dt, world: site.world)
        }
        let drove = abs((parked.cart(waiting)?.position.z ?? 0) - parkedStart)
        report.check(
            "and the rider can start it moving without a booster under it",
            drove > 4,
            String(format: "%.1f blocks in 3 s of leaning forward", Double(drove))
        )

        // MARK: the reset

        // The same seed builds the same site. Together with there being no
        // save file, that is what "it resets when you start it" means.
        var second = Site(seed: DemoWorld.seed)
        var sampled = 0
        var differing = 0
        for cell in stride(from: 0, to: track.count, by: 7).map({ track[$0] }) {
            for dy in 0...6 {
                sampled += 1
                if site.block(cell.x, cell.y + dy, cell.z)
                    != second.block(cell.x, cell.y + dy, cell.z) { differing += 1 }
            }
        }
        for place in sites {
            for dy in stride(from: 1, to: 44, by: 3) {
                sampled += 1
                if site.block(place.x, deck + dy, place.z)
                    != second.block(place.x, deck + dy, place.z) { differing += 1 }
            }
        }
        // The city too — and deliberately including things the seed placed
        // through its own generator: a maze carved differently on the
        // second build is exactly the drift this check exists to catch.
        for cell in stride(from: 0, to: dive[0].count, by: 9).map({ dive[0][$0] }) {
            for dy in 0...4 {
                sampled += 1
                if site.block(cell.x, cell.y + dy, cell.z)
                    != second.block(cell.x, cell.y + dy, cell.z) { differing += 1 }
            }
        }
        for dz in stride(from: -7, through: 7, by: 2) {
            sampled += 1
            if site.block(city.x + dz, cityFloor + 1, city.z + 35 + dz)
                != second.block(city.x + dz, cityFloor + 1, city.z + 35 + dz) { differing += 1 }
        }
        // The sky stair too — it is the one structure whose cells the
        // waterfalls' terrain arithmetic could plausibly perturb between
        // builds, and a stair that drifts is a city nobody reaches.
        for cell in stride(from: 0, to: skyFlights[0].count, by: 4).map({ skyFlights[0][$0] }) {
            for dy in 0...2 {
                sampled += 1
                if site.block(cell.x, cell.y + dy, cell.z)
                    != second.block(cell.x, cell.y + dy, cell.z) { differing += 1 }
            }
        }
        report.check(
            "building it a second time gives the same site",
            differing == 0,
            "\(differing) of \(sampled) sampled cells differ"
        )
        report.note("the world is never saved: GameViewController builds it with fileURL nil")

        finish(report)
    }

    /// Climbs the tower's staircases with the player's own body.
    ///
    /// Not a model of the player's movement — the player's movement.
    /// `PlayerController.step` is the method the game loop calls sixty times
    /// a second, driven here by a direction instead of a keyboard, and every
    /// rule that decides whether a staircase carries anybody lives inside
    /// it: `stepHeight` clearing a half-block tread and refusing a whole
    /// block, the 0.6-wide body that has to fit on a tread beside its own
    /// riser, the headroom, the settle back down onto whatever is up there.
    ///
    /// The version this replaced flooded standable cells instead, and it is
    /// worth saying why that failed, because it looked like the careful
    /// choice. It moved a point between cells one block up, level, or one
    /// down, which reads like walking and is not: a stair tread is climbed
    /// in two half-block steps — onto the tread's own upper step and then
    /// onto the next tread — and a whole block up is precisely the rise
    /// `stepHeight` refuses. Being a point, it also fitted anywhere, so a
    /// tread carved one column wide, which no body fits on once the riser
    /// has taken half of it, was reachable. It passed this very tower on a
    /// day a real body could not get up it. An approximation of the
    /// physics is a second implementation of the physics, free to drift
    /// from the first, and the drift is the bug.
    ///
    /// The standing objection to driving a body is that a body has to be
    /// steered, and a check that knows the route knows the builder's
    /// design — it would pass the tower it expected and fail an equally
    /// good one built differently. That is answered by the builder
    /// publishing the route rather than this file guessing it.
    /// `Landmarks.eiffelFlights` is the same list the treads are laid from,
    /// so what gets walked is whatever was built, and a tower that moves
    /// its stairs says so here without this file changing.
    private struct Walk {
        /// Route cells the body stood in.
        let stood: Int
        /// Route cells there were.
        let total: Int
        /// The highest the feet got, in world coordinates.
        let highestFoot: CGFloat
        /// Where the climb stopped, when it stopped short of the top.
        let stuck: String?

        /// Frames allowed for one cell-to-cell step. A tread is a block
        /// away and a walk covers about four a second, so this is some
        /// twenty times what the step needs — loose enough that a body
        /// shuffling around a riser still counts, tight enough that six
        /// flights of it stay cheap.
        private static let framesPerStep = 75

        /// Where to aim within the cell being walked to, tried in order.
        /// The centre is right almost always; the two nudges are for a
        /// tread whose riser stands in the middle of the straight line to
        /// it, where a body pressed dead at the centre can wedge against
        /// the riser and stop making progress while a body angled a
        /// quarter-block to either side walks on past it. Trying rather
        /// than computing which, because which side is open is the
        /// builder's business.
        private static let aims: [(across: CGFloat, along: CGFloat)] = [
            (0, 0), (0.3, 0), (-0.3, 0),
        ]

        init(flights: [[(x: Int, y: Int, z: Int)]], world: World) {
            var stood = 0
            var total = 0
            var highest = -CGFloat.greatestFiniteMagnitude
            var stuck: String?

            for (number, route) in flights.enumerated() {
                total += route.count
                guard route.count >= 2 else { continue }

                // On from outside the staircase: one cell back along the
                // first stride, standing on whatever the flight rises from
                // — the plaza for the four ground flights, the first
                // platform for the two above it. Starting the body on the
                // first tread would skip the question of whether anybody
                // can reach the staircase at all.
                let approach = (
                    x: route[0].x - (route[1].x - route[0].x),
                    y: route[0].y,
                    z: route[0].z - (route[1].z - route[0].z)
                )
                var body = PlayerController(spawn: Vector3(
                    CGFloat(approach.x) + 0.5, CGFloat(approach.y), CGFloat(approach.z) + 0.5
                ))
                // Settled onto the floor before it is asked to walk, so the
                // first stride is taken from the ground rather than out of
                // a fall.
                for _ in 0..<12 {
                    body.step(
                        dt: dt, moveDirection: .zero,
                        wantsUp: false, wantsDown: false, world: world
                    )
                }

                var previous = approach
                for cell in route {
                    let before = body
                    var arrived = false
                    for aim in Walk.aims {
                        body = before
                        if Walk.press(
                            &body, to: cell, from: previous, aim: aim,
                            world: world, highest: &highest
                        ) {
                            arrived = true
                            break
                        }
                    }
                    guard arrived else {
                        if stuck == nil {
                            stuck = "staircase \(number + 1) stops at \(previous): "
                                + "a body cannot get from there to \(cell)"
                        }
                        break
                    }
                    stood += 1
                    previous = cell
                }
            }

            self.stood = stood
            self.total = total
            self.highestFoot = highest
            self.stuck = stuck
        }

        /// Walks toward one cell until the body is standing in it, or until
        /// the frames run out. Returns whether it got there.
        private static func press(
            _ body: inout PlayerController,
            to cell: (x: Int, y: Int, z: Int),
            from previous: (x: Int, y: Int, z: Int),
            aim: (across: CGFloat, along: CGFloat),
            world: World,
            highest: inout CGFloat
        ) -> Bool {
            // The nudge is across the direction of travel, so it means the
            // same thing whichever way the spiral happens to be turning.
            let stride = Vector3(
                CGFloat(cell.x - previous.x), 0, CGFloat(cell.z - previous.z)
            )
            let across = Vector3(-stride.z, 0, stride.x)
            let target = Vector3(
                CGFloat(cell.x) + 0.5 + across.x * aim.across + stride.x * aim.along,
                0,
                CGFloat(cell.z) + 0.5 + across.z * aim.across + stride.z * aim.along
            )

            for _ in 0..<framesPerStep {
                let toward = Vector3(
                    target.x - body.position.x, 0, target.z - body.position.z
                )
                let distance = (toward.x * toward.x + toward.z * toward.z).squareRoot()
                let direction = distance < 1e-4 ? Vector3.zero : toward.normalized()
                body.step(
                    dt: dt, moveDirection: direction,
                    wantsUp: false, wantsDown: false, world: world
                )
                highest = max(highest, body.position.y)
                if standing(body, in: cell) { return true }
            }
            return false
        }

        /// Whether the body is standing in this cell: over its footprint,
        /// with its feet somewhere between the cell's floor and its ceiling.
        ///
        /// The band is a block rather than a point because the three things
        /// a route cell can be put the feet at three different heights —
        /// on a tread's lower half, on the upper step above it, or flat on
        /// the planking of a landing — and all three are standing in it.
        private static func standing(
            _ body: PlayerController, in cell: (x: Int, y: Int, z: Int)
        ) -> Bool {
            Int(floor(body.position.x)) == cell.x
                && Int(floor(body.position.z)) == cell.z
                && body.position.y >= CGFloat(cell.y) - 0.05
                && body.position.y <= CGFloat(cell.y) + 1.05
        }
    }


    private static func finish(_ report: Report) -> Never {
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the demo world\n"
            : "[check] all passed — the demo world\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

import Foundation

/// Headless proof that the survival storyline can be played from the first
/// radio to the last seed, through the session code the game itself runs:
/// the station and the three sites are built and reachable, the radios
/// record their pieces and unlock the expedition, the rocket checks its
/// list and flies, the Moon is built with its garden, a sealed room holds
/// air, the garden's three faults clear the way the plaque says they do,
/// the lever wakes it, the rocket flies home, a moon seed grown at home
/// ends it — and a save taken at the end carries both worlds and the
/// journal through the encoder and back.
///
/// `BLOCKHAVEN_CHECK_STORY=1`. Exits nonzero if any line fails.
enum StoryCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_STORY"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    private static func load(_ session: GameSession, around cell: StoryCell, radius: Int = 1) {
        let centre = World.chunkCoord(forWorldX: cell.x, worldZ: cell.z)
        for dz in -radius...radius {
            for dx in -radius...radius {
                session.world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }
    }

    private static func hit(_ session: GameSession, _ cell: StoryCell) -> VoxelRayHit {
        VoxelRayHit(
            blockX: cell.x, blockY: cell.y, blockZ: cell.z,
            placeX: cell.x, placeY: cell.y + 1, placeZ: cell.z,
            normal: (0, 1, 0),
            block: session.world.block(worldX: cell.x, y: cell.y, worldZ: cell.z),
            distance: 2
        )
    }

    /// Puts one stack in the selected hotbar slot.
    private static func hold(_ session: GameSession, _ item: ItemType, count: Int = 1) {
        session.inventory[session.inventory.selectedHotbarSlot] = ItemStack(item, count: count)
    }

    private static func block(_ session: GameSession, _ cell: StoryCell) -> BlockType {
        session.world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)
    }

    private static func set(_ session: GameSession, _ x: Int, _ y: Int, _ z: Int, _ block: BlockType) {
        session.world.setBlock(worldX: x, y: y, worldZ: z, to: block)
    }

    /// Steps the story until `until` holds or `seconds` run out.
    private static func run(_ session: GameSession, seconds: Double, until: () -> Bool = { false }) {
        var elapsed = 0.0
        while elapsed < seconds, !until() {
            session.updateStory(dt: 0.25)
            session.updateCrops(dt: 0.25)
            elapsed += 0.25
        }
    }

    static func run() -> Never {
        var report = Report()

        // MARK: Chapter 1 — the station
        let home = GameSession(newWorld: .survival, name: "Story Check", seed: 424242)
        home.start()
        guard let station = home.story.station else {
            print("[check] station: FAILED — no station was built"); exit(1)
        }
        load(home, around: station)
        let spawn = home.world.spawnPosition()
        let stationDistance = (station.centre - spawn).length()
        report.check("station is built near spawn", block(home, station) == .radio && stationDistance < 200,
                     "radio at \(station.x), \(station.y), \(station.z), \(Int(stationDistance)) blocks from spawn")
        report.check("expedition recipes start locked", !RecipeBook.expeditionUnlocked,
                     "unlocked: \(RecipeBook.expeditionUnlocked)")
        hold(home, .dirt)
        _ = home.storyUse(hit(home, station))
        report.check("a dead radio wants a crystal", !home.story.radioRepaired,
                     "repaired without one: \(home.story.radioRepaired)")
        hold(home, .glowCrystal)
        _ = home.storyUse(hit(home, station))
        report.check("a glow crystal mends the radio",
                     home.story.radioRepaired && block(home, station) == .radioLit && home.keeperLine != nil,
                     "repaired: \(home.story.radioRepaired), KEEPER: \(home.keeperLine ?? "silent")")
        var meteor = 0
        for dz in -12...12 { for dx in -12...12 { for dy in -6...4
            where home.world.block(worldX: station.x + dx, y: station.y + dy, worldZ: station.z + dz) == .meteorOre {
            meteor += 1
        } } }
        report.check("meteor ore lies near the station", meteor >= 6, "\(meteor) blocks")

        // MARK: Chapter 2 — the three pieces
        report.check("three sites are built", home.story.sites.count == 3,
                     home.story.sites.map { "\($0.piece.rawValue)@\($0.radio.x),\($0.radio.y),\($0.radio.z)" }
                        .joined(separator: " "))
        for site in home.story.sites {
            load(home, around: site.radio)
            let distance = Int((site.radio.centre - station.centre).length())
            let present = block(home, site.radio) == .radio
            home.player.recall(to: site.radio.centre)
            let objective = home.objective()?.text ?? ""
            _ = home.storyUse(hit(home, site.radio))
            report.check("\(site.piece.rawValue) radio gives its piece",
                         present && home.story.hasPiece(site.piece) && distance < 450,
                         "\(distance) blocks from the station; objective was \"\(objective)\"")
        }
        if let spire = home.story.sites.first(where: { $0.piece == .navigation }) {
            let below = home.world.block(worldX: spire.radio.x, y: spire.radio.y - 1, worldZ: spire.radio.z)
            report.check("the spire's radio stands on its platform", below == .stone, "below it: \(below)")
        }
        report.check("all three pieces unlock the expedition",
                     home.story.hasAllPieces && RecipeBook.expeditionUnlocked
                        && home.inventory.count(of: .signalCore) == 3,
                     "pieces \(home.story.pieces.map(\.rawValue)), cores \(home.inventory.count(of: .signalCore))")
        var grid = CraftingGrid(size: 3)
        let rocketShape: [ItemType?] = [.meteorIngot, .glass, .meteorIngot, .meteorIngot, .furnace, .meteorIngot,
                                        .ironIngot, nil, .ironIngot]
        for (index, item) in rocketShape.enumerated() { grid[index] = item.map { ItemStack($0) } }
        report.check("a rocket can be crafted", RecipeBook.match(grid)?.type == .rocket,
                     "matched \(String(describing: RecipeBook.match(grid)?.type))")
        report.check("ice cooks into a fuel cell", FurnaceRecipe.output(for: .ice) == .fuelCell
                        && BlockType.ice.drop == .ice, "furnace gives \(String(describing: FurnaceRecipe.output(for: .ice)))")

        // MARK: Chapter 3 — the rocket
        let padCell = StoryCell(Int(spawn.x) + 3, Int(spawn.y) + 10, Int(spawn.z) + 3)
        load(home, around: padCell)
        for y in padCell.y...(padCell.y + 4) {
            for dz in -2...2 { for dx in -2...2 { set(home, padCell.x + dx, y, padCell.z + dz, .air) } }
        }
        set(home, padCell.x, padCell.y, padCell.z, .padCore)
        hold(home, .rocket)
        _ = home.storyUse(hit(home, padCell))
        let cabin = StoryCell(padCell.x, padCell.y + 3, padCell.z)
        report.check("a rocket stands on the pad", block(home, cabin) == .rocketCabin && home.story.homePad == padCell,
                     "cabin cell holds \(block(home, cabin))")
        _ = home.storyUse(hit(home, cabin))
        let missing = home.launchChecklist()
        report.check("the checklist names what is missing", missing.count >= 5 && home.launchArmedTimer == 0,
                     missing.joined(separator: " · "))
        home.stats.equip(.spaceSuit)
        home.inventory.add(ItemStack(.fuelCell, count: 3))
        home.inventory.add(ItemStack(.dirt, count: 4))
        home.inventory.add(ItemStack(.wheatSeeds, count: 4))
        home.inventory.add(ItemStack(.airMaker, count: 2))
        home.inventory.add(ItemStack(.signalTorch, count: 2))
        home.inventory.add(ItemStack(.torch, count: 4))
        home.inventory.add(ItemStack(.ice, count: 4))
        _ = home.storyUse(hit(home, cabin))
        report.check("a full checklist arms the launch", home.launchChecklist().isEmpty && home.launchArmedTimer > 0,
                     "armed for \(home.launchArmedTimer) s")
        _ = home.storyUse(hit(home, cabin))
        run(home, seconds: 5) { home.travelRequest != nil }
        guard let moon = home.takeTravelRequest() else {
            print(report.lines.joined(separator: "\n"))
            print("[check] launch: FAILED — no travel happened"); exit(1)
        }
        report.check("the launch burns one cell and loads one for home",
                     home.inventory.count(of: .fuelCell) == 1 && home.story.returnCellLoaded,
                     "cells left \(home.inventory.count(of: .fuelCell)), return loaded \(home.story.returnCellLoaded)")

        // MARK: Chapter 4 — the Moon
        moon.start()
        let landedAt = moon.player.position
        report.check("the Moon is a new place",
                     moon.destination == .moon && moon.world.isLunar && moon.sky.isLunar
                        && moon.player.gravityScale < 1 && moon.elsewhere?.destination == .home,
                     "destination \(moon.destination), seed \(moon.world.seed)")
        report.check("the player steps out carrying what they packed",
                     moon.inventory.count(of: .airMaker) == 2 && moon.stats.equippedChestplate == .spaceSuit
                        && moon.story.launched,
                     "air makers \(moon.inventory.count(of: .airMaker)), suit \(String(describing: moon.stats.equippedChestplate))")
        if let pad = moon.story.moonPad {
            report.check("they land beside the rocket", (landedAt - pad.centre).length() < 4
                            && block(moon, StoryCell(pad.x, pad.y + 3, pad.z)) == .rocketCabin,
                         "\(Int((landedAt - pad.centre).length())) blocks from the pad")
        } else {
            report.check("they land beside the rocket", false, "no pad recorded")
        }
        guard let garden = moon.story.garden else {
            print(report.lines.joined(separator: "\n"))
            print("[check] garden: FAILED — no garden was built"); exit(1)
        }
        load(moon, around: garden.panel, radius: 2)
        report.check("the garden is built and sealed", garden.seal.allSatisfy { block(moon, $0) == .gardenSeal }
                        && garden.lamps.allSatisfy { block(moon, $0) == .signalLamp },
                     "panel at \(garden.panel.x), \(garden.panel.y), \(garden.panel.z)")
        moon.stats.restore(health: 20, hunger: 20, air: 120, equippedChestplate: .spaceSuit)
        moon.updateStory(dt: 0.1)
        report.check("the suit holds six breaths", moon.stats.airCapacity == PlayerStats.suitAirCapacity,
                     "capacity \(moon.stats.airCapacity)")
        let outside = StoryCell(-30, moon.world.generator.surfaceHeight(x: -30, z: -30) + 1, -30)
        load(moon, around: outside)
        moon.player.recall(to: outside.centre)
        report.check("open ground has no air", !moon.isBreathing, "breathing outside: \(moon.isBreathing)")
        moon.player.recall(to: landedAt)
        report.check("the rocket tops the suit up", moon.isBreathing, "breathing at the rocket: \(moon.isBreathing)")

        // A three-by-three room of brick with an air maker and a signal
        // torch to keep it running.
        let roomY = moon.world.generator.surfaceHeight(x: -30, z: -30) + 1
        for y in roomY...(roomY + 4) {
            for z in -32...(-28) {
                for x in -32...(-28) {
                    let shell = x == -32 || x == -28 || z == -32 || z == -28 || y == roomY || y == roomY + 4
                    set(moon, x, y, z, shell ? .moonBrick : .air)
                }
            }
        }
        set(moon, -30, roomY + 1, -30, .airMaker)
        set(moon, -29, roomY + 1, -30, .signalTorchOn)
        moon.signals.torchPlaced(at: SignalNetwork.Key(-29, roomY + 1, -30))
        moon.signals.recompute(world: moon.world, fuses: moon.fuses)
        moon.sweepAir()
        let status = moon.airMakerStatus[StoryCell(-30, roomY + 1, -30)]
        moon.player.recall(to: Vector3(-30.5 + 1, CGFloat(roomY + 1), -30.5 + 1))
        moon.player.recall(to: Vector3(-31 + 0.5, CGFloat(roomY + 1), -31 + 0.5))
        run(moon, seconds: 2) { moon.story.breathedOnMoon }
        report.check("a sealed, powered room holds air", moon.isBreathing && moon.story.breathedOnMoon,
                     "air maker says \(status.map { $0.text } ?? "nothing")")
        set(moon, -30, roomY + 4, -30, .air)
        moon.sweepAir()
        report.check("a hole in the roof lets it out", !moon.isBreathing,
                     "air maker says \(moon.airMakerStatus[StoryCell(-30, roomY + 1, -30)].map { $0.text } ?? "nothing")")

        // MARK: Chapter 5 — the garden
        let roof = garden.lamps[0].y
        let collector = garden.collector
        for dx in -1...1 {
            set(moon, collector.x + dx, roof + 2, collector.z, .air)
            set(moon, collector.x + dx, roof + 3, collector.z, .air)
        }
        // Mend the broken stretch, with a relay in it.
        for z in (collector.z + 1)...garden.lamps[1].z {
            let cell = StoryCell(collector.x, roof + 1, z)
            if block(moon, cell) == .air {
                set(moon, cell.x, cell.y, cell.z, z == collector.z + 5 ? .signalRelayOff : .wireOff)
            }
        }
        moon.sky.setTimeOfDay(0.25)
        moon.signals.updateDaylightSensors(world: moon.world, sky: moon.sky, fuses: moon.fuses)
        moon.signals.recompute(world: moon.world, fuses: moon.fuses)
        run(moon, seconds: 2) { moon.story.isFixed(.light) }
        report.check("mended wire lights the hall at noon", moon.story.isFixed(.light),
                     "lamps: \(garden.lamps.map { "\(block(moon, $0))" }.joined(separator: ", "))")

        // Live wire round the garden draws a sentry, on open ground; dead
        // wire sends it away.
        moon.player.recall(to: landedAt)
        moon.updateStory(dt: 1.01)
        var sentrySeconds = 0.0
        // Small steps, the way frames run: one half-second step would
        // carry a fresh spawn straight through a one-block roof.
        while moon.skeletons.skeletons.isEmpty, sentrySeconds < 60 {
            moon.updateSkeletons(dt: 0.05)
            sentrySeconds += 0.05
        }
        for _ in 0..<10 { moon.updateSkeletons(dt: 0.05) }
        let sentry = moon.skeletons.skeletons.values.first
        let sentryOutside = sentry.map {
            moon.world.isSkyOpen(worldX: Int(floor($0.position.x)), y: Int(floor($0.position.y)), worldZ: Int(floor($0.position.z)))
        } ?? false
        let sentryCell = sentry.map { "\(Int(floor($0.position.x))),\($0.position.y),\(Int(floor($0.position.z))) on \(block(moon, StoryCell(Int(floor($0.position.x)), Int(floor($0.position.y)) - 1, Int(floor($0.position.z)))))" } ?? "none"
        report.check("live wire draws a sentry onto open ground", sentry != nil && sentryOutside,
                     "\(moon.skeletons.sentryAnchors.count) live cells, sentry after \(sentrySeconds) s at \(sentryCell)")
        moon.sky.setTimeOfDay(0.75)
        moon.signals.updateDaylightSensors(world: moon.world, sky: moon.sky, fuses: moon.fuses)
        moon.signals.recompute(world: moon.world, fuses: moon.fuses)
        moon.updateStory(dt: 1.01)
        moon.updateSkeletons(dt: 0.5)
        report.check("dead wire powers the sentries down", moon.skeletons.skeletons.isEmpty,
                     "\(moon.skeletons.skeletons.count) left at midnight")
        moon.sky.setTimeOfDay(0.25)

        // Water: ice in the channel, a torch beside it, the thermal tick.
        for cell in garden.reservoir { set(moon, cell.x, cell.y, cell.z, .ice) }
        set(moon, garden.reservoir[2].x, garden.reservoir[2].y + 1, garden.reservoir[2].z + 2, .torch)
        moon.player.recall(to: garden.reservoir[2].centre)
        for _ in 0..<12 { moon.updateThermal(dt: 1.1) }
        run(moon, seconds: 2) { moon.story.isFixed(.water) }
        report.check("ice melted by a torch fills the reservoir", moon.story.isFixed(.water),
                     "channel: \(garden.reservoir.map { "\(block(moon, $0))" }.joined(separator: ", "))")

        // Growth: seal the nursery, give it air and light, grow wheat.
        let doorX = garden.nurseryMin.x + 4, doorZ = garden.nurseryMax.z + 1
        set(moon, doorX, garden.nurseryMin.y, doorZ, .moonBrick)
        set(moon, doorX, garden.nurseryMin.y + 1, doorZ, .moonBrick)
        set(moon, doorX, roof, garden.nurseryMin.z + 3, .moonBrick)
        let maker = StoryCell(garden.nurseryMin.x, garden.nurseryMin.y, garden.nurseryMin.z)
        set(moon, maker.x, maker.y, maker.z, .airMaker)
        set(moon, maker.x + 1, maker.y, maker.z, .signalTorchOn)
        moon.signals.torchPlaced(at: SignalNetwork.Key(maker.x + 1, maker.y, maker.z))
        let bed = StoryCell(garden.nurseryMin.x + 3, garden.nurseryMin.y, garden.nurseryMin.z + 3)
        set(moon, bed.x, bed.y - 1, bed.z, .farmland)
        set(moon, bed.x, bed.y, bed.z, .wheatStage0)
        set(moon, bed.x + 1, bed.y, bed.z, .torch)
        moon.crops.planted(at: CropStore.Key(bed.x, bed.y, bed.z))
        moon.signals.recompute(world: moon.world, fuses: moon.fuses)
        run(moon, seconds: 120) { moon.story.isFixed(.growth) }
        report.check("wheat grown in the sealed nursery counts", moon.story.isFixed(.growth),
                     "crop is \(block(moon, bed)), nursery air: \(moon.airMakerStatus[maker].map { $0.text } ?? "none")")
        report.check("the garden opens its door", moon.story.gardenOpened
                        && garden.seal.allSatisfy { block(moon, $0) == .air },
                     "seal: \(garden.seal.map { "\(block(moon, $0))" }.joined(separator: ", "))")

        // MARK: Chapter 6 — the lever, home, a seed
        _ = moon.storyUse(hit(moon, garden.lever))
        run(moon, seconds: 20) { moon.story.gardenWoken }
        report.check("the lever wakes the garden",
                     moon.story.gardenWoken && moon.inventory.count(of: .lampBloomSeeds) >= 4
                        && garden.shutters.contains { block(moon, $0) == .prismGlass },
                     "seeds \(moon.inventory.count(of: .lampBloomSeeds)) + \(moon.inventory.count(of: .silverReedSeeds))")
        moon.player.recall(to: landedAt)
        let moonCabin = StoryCell(moon.story.moonPad!.x, moon.story.moonPad!.y + 3, moon.story.moonPad!.z)
        _ = moon.storyBreak(hit(moon, moonCabin))
        report.check("the Moon's rocket cannot be broken", block(moon, moonCabin) == .rocketCabin,
                     "cabin cell holds \(block(moon, moonCabin))")
        _ = moon.storyUse(hit(moon, moonCabin))
        _ = moon.storyUse(hit(moon, moonCabin))
        run(moon, seconds: 5) { moon.travelRequest != nil }
        guard let back = moon.takeTravelRequest() else {
            print(report.lines.joined(separator: "\n"))
            print("[check] return: FAILED — the rocket did not fly home"); exit(1)
        }
        back.start()
        report.check("the rocket flies home on the loaded cell",
                     back.destination == .home && !back.story.returnCellLoaded && back.elsewhere?.destination == .moon
                        && back.world.seed == home.world.seed,
                     "home seed \(back.world.seed)")
        load(back, around: station)
        report.check("home is as it was left", block(back, station) == .radioLit,
                     "station radio is \(block(back, station))")
        let homePad = back.story.homePad!
        report.check("they land beside the home rocket", (back.player.position - homePad.centre).length() < 4,
                     "\(Int((back.player.position - homePad.centre).length())) blocks from the pad")
        let plot = StoryCell(homePad.x - 3, homePad.y, homePad.z)
        set(back, plot.x, plot.y, plot.z, .farmland)
        set(back, plot.x, plot.y + 1, plot.z, .lampBloomStage0)
        set(back, plot.x, plot.y + 3, plot.z, .air)
        back.crops.planted(at: CropStore.Key(plot.x, plot.y + 1, plot.z))
        back.sky.setTimeOfDay(0.25)
        run(back, seconds: 120) { back.story.complete }
        report.check("a moon seed grown at home ends the story",
                     back.story.complete && back.sky.beaconSteady && back.sky.beacon == 1,
                     "bloom is \(block(back, StoryCell(plot.x, plot.y + 1, plot.z)))")

        // MARK: The save holds both places
        let save = back.captureSave()
        let data = (try? JSONEncoder().encode(save)) ?? Data()
        let decoded = try? JSONDecoder().decode(WorldSave.self, from: data)
        let dormant = decoded?.elsewhere?.first
        report.check("one save carries both worlds and the journal",
                     decoded?.story == back.story && decoded?.destination == .home
                        && dormant?.destination == .moon && dormant?.story == nil
                        && (dormant?.chunks.count ?? 0) > 10,
                     "\(data.count) bytes, moon journal \(dormant?.chunks.count ?? 0) chunks")
        if let decoded {
            let reopened = GameSession(mode: .survival, name: "Story Check", fileURL: nil, seed: nil, restoring: decoded)
            reopened.start()
            report.check("a reopened save is home with the Moon asleep",
                         reopened.destination == .home && reopened.elsewhere?.destination == .moon
                            && reopened.story.complete && RecipeBook.expeditionUnlocked,
                         "chapter \(reopened.story.chapter)")
        }
        var legacy = save
        legacy.story = nil
        legacy.elsewhere = nil
        legacy.destination = nil
        let legacyData = (try? JSONEncoder().encode(legacy)) ?? Data()
        let legacyDecoded = try? JSONDecoder().decode(WorldSave.self, from: legacyData)
        report.check("a save from before the story still opens",
                     legacyDecoded != nil && legacyDecoded?.story == nil && legacyDecoded?.destination == nil,
                     "\(legacyData.count) bytes")

        print(report.lines.joined(separator: "\n"))
        if report.failed {
            print("[check] FAILED")
            exit(1)
        }
        print("[check] all passed — the story plays from the first radio to the last seed")
        exit(0)
    }
}

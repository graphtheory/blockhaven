import Foundation

/// Who steps out of the rocket: everything about the player that travels.
struct Arrival {
    var slots: [ItemStack?]
    var selectedSlot: Int
    var health: Int
    var hunger: Int
    var air: Int
    var chestplate: ItemType?
}

/// What an air maker reports when the crosshair is on it.
enum AirMakerStatus: Equatable {
    case sealed(cells: Int)
    case leak
    case tooBig
    case noPower

    var text: String {
        switch self {
        case .sealed(let cells):
            return L10n.t("Air maker: SEALED — \(cells) cells of air", "Luftmaskin: TÄT — \(cells) rutor luft")
        case .leak:
            return L10n.t("Air maker: LEAK — the room has a hole", "Luftmaskin: LÄCKA — rummet har ett hål")
        case .tooBig:
            return L10n.t("Air maker: TOO BIG — at most 256 cells", "Luftmaskin: FÖR STORT — högst 256 rutor")
        case .noPower:
            return L10n.t("Air maker: NO POWER — wire it to a sensor or signal torch",
                          "Luftmaskin: INGEN STRÖM — koppla den till en sensor eller signalfackla")
        }
    }
}

/// The storyline's half of a session: building its places, answering the
/// radios, the rocket and the plaques, keeping the Moon's air, checking the
/// garden, and carrying the player from one place to the other. Read
/// `specs/survival-storyline.md` for the shape of it.
extension GameSession {
    /// The demo world and the picture-taking harness keep the landscape
    /// they have always had.
    static let storyDisabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["BLOCKHAVEN_NO_STORY"] != nil { return true }
        if environment["BLOCKHAVEN_STORY"] != nil { return false }
        return environment.keys.contains {
            $0.hasPrefix("BLOCKHAVEN_SNAPSHOT") || $0.hasPrefix("BLOCKHAVEN_BENCH") || $0 == "BLOCKHAVEN_DEMO"
        }
    }()

    var storyActive: Bool { !isDemo && !GameSession.storyDisabled }

    /// The seed the Moon is grown from: the home world's, turned.
    static func moonSeed(for homeSeed: UInt64) -> UInt64 {
        homeSeed &* 0x9E3779B97F4A7C15 &+ 0x4D4F4F4E
    }

    // MARK: - Setting up

    /// Runs at the end of `start`: steps an arriving player out of the
    /// rocket, and builds whatever of the story this place does not have yet.
    func setUpStory() {
        if let arriving {
            inventory.restore(slots: arriving.slots, selectedHotbarSlot: arriving.selectedSlot)
            stats.restore(health: arriving.health, hunger: arriving.hunger, air: arriving.air,
                          equippedChestplate: arriving.chestplate)
        }
        guard storyActive else {
            RecipeBook.expeditionUnlocked = true
            return
        }
        switch destination {
        case .home: buildHomeStory()
        case .moon: buildMoonStory()
        }
        if arriving != nil { stepOutOfRocket() }
        arriving = nil
        RecipeBook.expeditionUnlocked = mode == .creative || story.hasAllPieces
        sky.beaconSteady = story.complete
    }

    private func buildHomeStory() {
        if story.station == nil {
            let spawn = world.spawnPosition()
            let site = StoryBuilder.stationSite(world, spawn: (Int(spawn.x), Int(spawn.z)))
            let station = StoryBuilder.buildStation(world, at: site)
            story.station = station.radio
            let chest = chests.chest(at: ChestStore.Key(station.chest.x, station.chest.y, station.chest.z))
            chest.add(ItemStack(.compass))
            chest.add(ItemStack(.torch, count: 6))
            chest.add(ItemStack(.cookedPorkchop, count: 3))
            GameSession.logLifecycle("story: survey station at \(site.x), \(site.z)")
        }
        if story.sites.isEmpty, let station = story.station {
            let centre = (station.x, station.z)
            story.sites = [
                StorySite(piece: .navigation, radio: StoryBuilder.buildSpire(world, near: centre)),
                StorySite(piece: .cabin, radio: StoryBuilder.buildVault(world, near: centre)),
                StorySite(piece: .engine, radio: StoryBuilder.buildWreck(world, near: centre)),
            ]
            for site in story.sites {
                GameSession.logLifecycle("story: \(site.piece.rawValue) at \(site.radio.x), \(site.radio.y), \(site.radio.z)")
            }
        }
    }

    private func buildMoonStory() {
        if story.moonPad == nil {
            story.moonPad = StoryBuilder.buildMoonLanding(world)
        }
        if story.garden == nil {
            let plan = StoryBuilder.buildGarden(world)
            story.garden = plan
            let sensorZ = plan.collector.z
            for dx in -1...1 {
                signals.daylightSensorPlaced(at: SignalNetwork.Key(plan.collector.x + dx, plan.collector.y, sensorZ))
            }
            for lamp in plan.lamps { signals.lampPlaced(at: SignalNetwork.Key(lamp.x, lamp.y, lamp.z)) }
            signals.leverPlaced(at: SignalNetwork.Key(plan.lever.x, plan.lever.y, plan.lever.z))
            let supply = StoryBuilder.gardenSupplyChest(plan)
            let chest = chests.chest(at: ChestStore.Key(supply.x, supply.y, supply.z))
            chest.add(ItemStack(.wire, count: 16))
            chest.add(ItemStack(.signalRelay, count: 3))
            chest.add(ItemStack(.signalTorch, count: 2))
            chest.add(ItemStack(.bucket))
            chest.add(ItemStack(.hoe))
            chest.add(ItemStack(.torch, count: 8))
            chest.add(ItemStack(.moonBrick, count: 32))
            signals.recompute(world: world, fuses: fuses)
        }
    }

    /// Puts an arriving player beside the rocket on this place's pad,
    /// building the rocket there if it is gone.
    private func stepOutOfRocket() {
        let pad: StoryCell?
        switch destination {
        case .moon: pad = story.moonPad
        case .home: pad = story.homePad
        }
        guard let pad else { return }
        if StoryBuilder.rocketCells(onPad: pad).contains(where: {
            !world.block(worldX: $0.x, y: $0.y, worldZ: $0.z).isRocket
        }) {
            world.setBlock(worldX: pad.x, y: pad.y, worldZ: pad.z, to: .padCore)
            StoryBuilder.placeRocket(world, onPad: pad)
        }
        player.recall(to: Vector3(CGFloat(pad.x) + 2.5, CGFloat(pad.y) + 1, CGFloat(pad.z) + 0.5))
        if destination == .moon, !story.breathedOnMoon {
            say(Keeper.landed)
        }
        travelFade = 1
    }

    // MARK: - KEEPER

    func say(_ lines: [String]) {
        keeperQueue.append(contentsOf: lines)
        if keeperLine == nil { advanceKeeper() }
    }

    func say(_ line: String) { say([line]) }

    private func advanceKeeper() {
        guard !keeperQueue.isEmpty else {
            keeperLine = nil
            return
        }
        keeperLine = keeperQueue.removeFirst()
        keeperTimer = 2.5 + Double(keeperLine?.count ?? 0) * 0.06
    }

    // MARK: - Right-click

    /// The story's answer to a right-click on one of its blocks, or false
    /// to let the ordinary rules handle it.
    func storyUse(_ hit: VoxelRayHit) -> Bool {
        let cell = StoryCell(hit.blockX, hit.blockY, hit.blockZ)
        switch hit.block {
        case .radio, .radioLit:
            useRadio(at: cell, block: hit.block)
            return true
        case .padCore:
            guard inventory.heldItem == .rocket else { return false }
            placeRocket(onPad: cell)
            return true
        case .rocketEngine, .rocketTank, .rocketCabin:
            useRocket(at: cell)
            return true
        default:
            if hit.block.isLever, let garden = story.garden, destination == .moon, cell == garden.lever {
                throwLever(at: (cell.x, cell.y, cell.z))
                pullGardenLever()
                return true
            }
            return false
        }
    }

    private func useRadio(at cell: StoryCell, block: BlockType) {
        // The station's radio: dead until a glow crystal is put in it. Any
        // radio on the home world will do while none has been mended, so a
        // station radio carried off and set down elsewhere — or one built
        // from the recipe — can never strand the story.
        let isSite = story.sites.contains { $0.radio == cell }
        if cell == story.station || (!story.radioRepaired && destination == .home && !isSite) {
            if story.radioRepaired || block == .radioLit {
                if story.station == nil { story.station = cell }
                story.radioRepaired = true
                world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .radioLit)
                replayStationLines()
                return
            }
            guard inventory.heldItem == .glowCrystal || mode == .creative else {
                showToast(Keeper.radioNeedsCrystal, seconds: 5)
                return
            }
            if mode.consumesPlacedBlocks { inventory.consumeHeldOne() }
            story.station = cell
            story.radioRepaired = true
            world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .radioLit)
            say(Keeper.stationWakes)
            return
        }
        // One of the three sites' radios: it gives up its piece.
        if let site = story.sites.first(where: { $0.radio == cell }) {
            if story.hasPiece(site.piece) {
                say(site.piece.lesson)
                return
            }
            story.pieces.append(site.piece)
            world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .radioLit)
            if mode.collectsDrops { inventory.add(ItemStack(.signalCore)) }
            say(L10n.t("\(site.piece.title.uppercased()) RECORDED.", "\(site.piece.title.uppercased()) SPARAD."))
            say(site.piece.lesson)
            if story.hasAllPieces {
                RecipeBook.expeditionUnlocked = true
                say(Keeper.allPieces)
            } else {
                let left = StoryPiece.allCases.filter { !story.hasPiece($0) }.count
                say(L10n.t("\(left) MORE TO FIND.", "\(left) KVAR ATT HITTA."))
            }
            return
        }
        // A radio someone built: it says where the story stands.
        replayStationLines()
    }

    /// What a mended radio says when spoken to again: where things stand.
    private func replayStationLines() {
        if story.complete {
            say(Keeper.ending)
        } else if !story.hasAllPieces {
            let missing = StoryPiece.allCases.filter { !story.hasPiece($0) }.map { $0.place }
            say(L10n.t("STILL LISTENING FOR: ", "LYSSNAR FORTFARANDE EFTER: ")
                + missing.joined(separator: ", ").uppercased())
        } else if !story.launched {
            say(Keeper.allPieces)
        } else {
            say(L10n.t("THE GARDEN IS WAITING.", "TRÄDGÅRDEN VÄNTAR."))
        }
    }

    // MARK: - The rocket

    private func placeRocket(onPad pad: StoryCell) {
        let cells = StoryBuilder.rocketCells(onPad: pad)
        guard cells.allSatisfy({ world.block(worldX: $0.x, y: $0.y, worldZ: $0.z) == .air }),
              !cells.contains(where: { player.overlaps(blockX: $0.x, y: $0.y, z: $0.z) }) else {
            showToast(L10n.t("A rocket needs three blocks of clear air above the pad",
                             "En raket behöver tre tomma block ovanför plattan"), seconds: 3)
            return
        }
        StoryBuilder.placeRocket(world, onPad: pad)
        if mode.consumesPlacedBlocks { inventory.consumeHeldOne() }
        if destination == .home { story.homePad = pad }
        showToast(L10n.t("Rocket ready. Right-click it to check it over.",
                         "Raketen är klar. Högerklicka på den för att kontrollera den."), seconds: 4)
    }

    /// What is still missing before this rocket may launch, in the words a
    /// checklist would use. Empty means go.
    func launchChecklist() -> [String] {
        guard mode == .survival else { return [] }
        var missing: [String] = []
        if destination == .home {
            if stats.equippedChestplate != .spaceSuit {
                missing.append(L10n.t("wear a space suit", "ta på en rymddräkt"))
            }
            let cellsNeeded = story.returnCellLoaded ? 1 : 2
            if inventory.count(of: .fuelCell) < cellsNeeded {
                missing.append(L10n.t("\(cellsNeeded) fuel cells (furnace: ice)", "\(cellsNeeded) bränsleceller (ugn: is)"))
            }
            if !story.launched {
                if inventory.count(of: .dirt) < 4 { missing.append(L10n.t("4 dirt", "4 jord")) }
                if inventory.count(of: .wheatSeeds) < 2 { missing.append(L10n.t("2 wheat seeds", "2 vetefrön")) }
                if inventory.count(of: .airMaker) < 1 { missing.append(L10n.t("an air maker", "en luftmaskin")) }
                if inventory.count(of: .signalTorch) < 1 { missing.append(L10n.t("a signal torch", "en signalfackla")) }
            }
        } else if !story.returnCellLoaded, inventory.count(of: .fuelCell) < 1 {
            missing.append(L10n.t("a fuel cell (furnace: ice)", "en bränslecell (ugn: is)"))
        }
        return missing
    }

    private func useRocket(at cell: StoryCell) {
        guard storyActive else { return }
        guard StoryBuilder.pad(under: cell, in: world) != nil else {
            showToast(L10n.t("A rocket only flies from a launch pad", "En raket startar bara från en startplatta"),
                      seconds: 3)
            return
        }
        if destination == .home, story.homePad == nil, let pad = StoryBuilder.pad(under: cell, in: world) {
            story.homePad = pad
        }
        let missing = launchChecklist()
        guard missing.isEmpty else {
            showToast(L10n.t("Before launch: ", "Före start: ") + missing.joined(separator: " · "), seconds: 6)
            return
        }
        guard launchArmedTimer > 0 else {
            launchArmedTimer = 6
            let where_ = destination == .home ? L10n.t("the Moon", "Månen") : L10n.t("home", "hem")
            showToast(L10n.t("Ready for \(where_). Right-click again to launch!",
                             "Redo för \(where_). Högerklicka igen för att starta!"), seconds: 6)
            return
        }
        launch()
    }

    /// Burns the fuel and starts the fade; the swap happens at its darkest.
    private func launch() {
        launchArmedTimer = 0
        if mode == .survival {
            if destination == .home {
                let needed = story.returnCellLoaded ? 1 : 2
                _ = inventory.remove(.fuelCell, count: needed)
                story.returnCellLoaded = true
            } else if story.returnCellLoaded {
                story.returnCellLoaded = false
            } else {
                _ = inventory.remove(.fuelCell, count: 1)
            }
        }
        if destination == .home { story.launched = true }
        travelFadeOut = true
        travelFade = 0
    }

    /// Builds the session for the other place and hands it to the front end.
    private func performTravel() {
        let target: Destination = destination == .home ? .moon : .home
        willCaptureSave?()
        var here = captureSave()
        here.elsewhere = nil
        here.story = nil
        let next = GameSession(
            mode: mode,
            name: worldName,
            fileURL: fileURL,
            seed: elsewhere == nil ? GameSession.moonSeed(for: world.seed) : nil,
            restoring: elsewhere,
            destination: target
        )
        next.elsewhere = here
        next.story = story
        next.arriving = Arrival(
            slots: inventory.slots,
            selectedSlot: inventory.selectedHotbarSlot,
            health: stats.health,
            hunger: stats.hunger,
            air: stats.air,
            chestplate: stats.equippedChestplate
        )
        hasTravelled = true
        travelFadeOut = false
        travelRequest = next
        GameSession.logLifecycle("travel: \(destination.rawValue) → \(target.rawValue)")
    }

    // MARK: - Breaking

    /// The story's say over a block being broken: the rocket comes off as
    /// one piece, the Moon's last rocket stays put, and the garden's door
    /// does not open to a pickaxe. Returns true when it handled the break.
    func storyBreak(_ hit: VoxelRayHit) -> Bool {
        let cell = StoryCell(hit.blockX, hit.blockY, hit.blockZ)
        if hit.block == .gardenSeal {
            say(Keeper.sealHolds)
            return true
        }
        // The old network's radios are bolted down: the station's, and any
        // site's that still holds its piece.
        if hit.block == .radio || hit.block == .radioLit {
            let holdsPiece = story.sites.contains { $0.radio == cell && !story.hasPiece($0.piece) }
            if (cell == story.station && destination == .home) || holdsPiece {
                showToast(L10n.t("This radio is bolted down", "Den här radion sitter fast"), seconds: 2)
                return true
            }
        }
        if hit.block.isRocket || hit.block == .padCore {
            let pad = hit.block == .padCore ? cell : StoryBuilder.pad(under: cell, in: world)
            if destination == .moon, let pad, pad == story.moonPad {
                say(Keeper.rocketGuardsHome)
                return true
            }
            guard hit.block.isRocket else { return false }
            var y = cell.y
            while y > 0, world.block(worldX: cell.x, y: y - 1, worldZ: cell.z).isRocket { y -= 1 }
            while world.block(worldX: cell.x, y: y, worldZ: cell.z).isRocket {
                world.setBlock(worldX: cell.x, y: y, worldZ: cell.z, to: .air)
                y += 1
            }
            if mode.collectsDrops { inventory.add(ItemStack(.rocket)) }
            return true
        }
        return false
    }

    // MARK: - The garden

    private func pullGardenLever() {
        guard story.gardenOpened, !story.gardenWoken, wakingStep < 0 else { return }
        wakingStep = 0
        wakingTimer = 0
    }

    private func checkGarden() {
        guard let garden = story.garden else { return }
        // Ice laid in the channel thaws as soon as there is a flame near
        // it, rather than waiting on the world's slow random thermal tick:
        // the channel is the one place the player is watching for it.
        for cell in garden.reservoir
        where world.block(worldX: cell.x, y: cell.y, worldZ: cell.z) == .ice
            && world.canMelt(atWorldX: cell.x, y: cell.y, worldZ: cell.z) {
            world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .water)
        }
        if !story.isFixed(.light),
           garden.lamps.allSatisfy({ world.block(worldX: $0.x, y: $0.y, worldZ: $0.z) == .signalLampLit }) {
            fix(.light)
        }
        if !story.isFixed(.water),
           garden.reservoir.allSatisfy({ world.block(worldX: $0.x, y: $0.y, worldZ: $0.z) == .water }) {
            fix(.water)
        }
        if !story.isFixed(.growth), nurseryHasRipeCrop(garden) {
            fix(.growth)
        }
        if story.allFaultsFixed, !story.gardenOpened {
            story.gardenOpened = true
            for cell in garden.seal { world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .air) }
            say(Keeper.gardenOpens)
        }
    }

    private func nurseryHasRipeCrop(_ garden: GardenPlan) -> Bool {
        for y in garden.nurseryMin.y...garden.nurseryMax.y {
            for z in garden.nurseryMin.z...garden.nurseryMax.z {
                for x in garden.nurseryMin.x...garden.nurseryMax.x
                where world.block(worldX: x, y: y, worldZ: z).isRipeCrop {
                    return true
                }
            }
        }
        return false
    }

    private func fix(_ fault: GardenFault) {
        story.faultsFixed.append(fault)
        say(fault.fixedText)
        let left = GardenFault.allCases.filter { !story.isFixed($0) }
        if !left.isEmpty {
            say(L10n.t("STILL MISSING: ", "SAKNAS FORTFARANDE: ") + left.map(\.panelText).joined(separator: ", "))
        }
    }

    private func advanceWaking(dt: Double) {
        guard wakingStep >= 0, let garden = story.garden else { return }
        wakingTimer -= dt
        guard wakingTimer <= 0 else { return }
        let lines = Keeper.waking
        guard wakingStep < lines.count else {
            wakingStep = -1
            return
        }
        say(lines[wakingStep])
        switch wakingStep {
        case 1:
            // Growing light that needs no sun: the roof beside each lamp
            // turns to glow crystal.
            for lamp in garden.lamps {
                for dx in [-1, 1] {
                    world.setBlock(worldX: lamp.x + dx, y: lamp.y, worldZ: lamp.z, to: .glowCrystal)
                }
            }
        case 2:
            for cell in garden.shutters where world.block(worldX: cell.x, y: cell.y, worldZ: cell.z) == .moonBrick {
                world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .prismGlass)
            }
        case 3:
            story.gardenWoken = true
            let chest = chests.chest(at: ChestStore.Key(garden.vaultChest.x, garden.vaultChest.y, garden.vaultChest.z))
            for seeds in [ItemType.lampBloomSeeds, .silverReedSeeds] {
                if let left = inventory.add(ItemStack(seeds, count: 4)) { chest.add(left) }
                chest.add(ItemStack(seeds, count: 8))
            }
            showToast(L10n.t("You got lamp bloom and silver reed seeds", "Du fick lampblomsfrön och silvervassfrön"),
                      seconds: 5)
        default:
            break
        }
        wakingStep += 1
        wakingTimer = 3
    }

    /// Called whenever a crop ripens. A garden seed grown to full height on
    /// the home world is the end of the story.
    func cropRipened(_ block: BlockType) {
        guard storyActive, destination == .home, story.gardenWoken, !story.complete,
              block == .lampBloomStage3 || block == .silverReedStage3 else { return }
        story.complete = true
        story.seedsTaken = true
        sky.beaconSteady = true
        if let station = story.station {
            world.setBlock(worldX: station.x, y: station.y, worldZ: station.z, to: .radioLit)
        }
        say(Keeper.ending)
        say(L10n.t("THE END — THANK YOU FOR PLAYING. THE WORLD IS STILL YOURS.",
                   "SLUT — TACK FÖR ATT DU SPELADE. VÄRLDEN ÄR FORTFARANDE DIN."))
    }

    /// Whether crops may grow in this cell. On the Moon only in a room
    /// someone can breathe in.
    func cropMayGrow(_ key: CropStore.Key) -> Bool {
        guard world.isLunar else { return true }
        return breathable.contains(StoryCell(key.x, key.y, key.z))
    }

    // MARK: - Air

    /// Lets air through: open space, and the thin things that stand in it.
    private func letsAirThrough(_ block: BlockType) -> Bool {
        if block == .air || block == .water { return true }
        if block.isDoor { return block.doorIsOpen }
        if block.isShaped { return !block.isStairs && !block.isBed && !block.isPane }
        return false
    }

    /// Rebuilds which cells hold air, from every air maker in the world.
    func sweepAir() {
        var cells: Set<StoryCell> = []
        var status: [StoryCell: AirMakerStatus] = [:]
        let plane = Chunk.width * Chunk.depth
        for (coord, entries) in world.editJournal {
            for (index, block) in entries where block == .airMaker {
                let y = index / plane
                let remainder = index % plane
                let maker = StoryCell(coord.x * Chunk.width + remainder % Chunk.width, y,
                                      coord.z * Chunk.depth + remainder / Chunk.width)
                guard world.block(worldX: maker.x, y: maker.y, worldZ: maker.z) == .airMaker else { continue }
                guard signals.isPowered(at: SignalNetwork.Key(maker.x, maker.y, maker.z)) else {
                    status[maker] = .noPower
                    continue
                }
                let result = floodRoom(from: maker)
                status[maker] = result.status
                if case .sealed = result.status { cells.formUnion(result.cells) }
            }
        }
        breathable = cells
        airMakerStatus = status
    }

    private func floodRoom(from maker: StoryCell) -> (status: AirMakerStatus, cells: Set<StoryCell>) {
        var visited: Set<StoryCell> = []
        var frontier: [StoryCell] = []
        let offsets = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
        for (dx, dy, dz) in offsets {
            let cell = StoryCell(maker.x + dx, maker.y + dy, maker.z + dz)
            if letsAirThrough(world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)) {
                visited.insert(cell)
                frontier.append(cell)
            }
        }
        guard !frontier.isEmpty else { return (.leak, []) }
        while let cell = frontier.popLast() {
            guard cell.y > 0, cell.y < Chunk.height - 1,
                  world.chunk(at: World.chunkCoord(forWorldX: cell.x, worldZ: cell.z)) != nil,
                  !world.isSkyOpen(worldX: cell.x, y: cell.y, worldZ: cell.z) else {
                return (.leak, [])
            }
            for (dx, dy, dz) in offsets {
                let next = StoryCell(cell.x + dx, cell.y + dy, cell.z + dz)
                guard !visited.contains(next),
                      letsAirThrough(world.block(worldX: next.x, y: next.y, worldZ: next.z)) else { continue }
                visited.insert(next)
                if visited.count > 256 { return (.tooBig, []) }
                frontier.append(next)
            }
        }
        return (.sealed(cells: visited.count), visited)
    }

    /// Whether the player can breathe where they stand right now.
    var isBreathing: Bool {
        guard world.isLunar else { return true }
        let eye = player.eyePosition, feet = player.position
        let eyeCell = StoryCell(Int(floor(eye.x)), Int(floor(eye.y)), Int(floor(eye.z)))
        let feetCell = StoryCell(Int(floor(feet.x)), Int(floor(feet.y)), Int(floor(feet.z)))
        if breathable.contains(eyeCell) || breathable.contains(feetCell) { return true }
        // The rocket's own cabin tops the suit up within a step of it.
        if let pad = story.moonPad {
            let dx = feet.x - (CGFloat(pad.x) + 0.5), dz = feet.z - (CGFloat(pad.z) + 0.5)
            let dy = feet.y - CGFloat(pad.y)
            if dx * dx + dz * dz < 2.6 * 2.6, dy > -1, dy < 4 { return true }
        }
        return false
    }

    // MARK: - Every frame

    /// The story's share of a frame of play.
    func updateStory(dt: Double) {
        if keeperLine != nil {
            keeperTimer -= dt
            if keeperTimer <= 0 { advanceKeeper() }
        }
        if launchArmedTimer > 0 { launchArmedTimer = max(0, launchArmedTimer - dt) }
        if travelFadeOut {
            travelFade = min(1, travelFade + dt / 1.4)
            if travelFade >= 1 { performTravel() }
            return
        } else if travelFade > 0 {
            travelFade = max(0, travelFade - dt / 1.2)
        }
        guard storyActive else { return }

        // Air: the suit holds more, and outside a room it runs down.
        let suited = stats.equippedChestplate == .spaceSuit && world.isLunar
        stats.airCapacity = suited ? PlayerStats.suitAirCapacity : PlayerStats.maxAir

        storyTickAccumulator += dt
        if storyTickAccumulator >= 1 {
            storyTickAccumulator = 0
            if world.isLunar {
                sweepAir()
                // Live wire round the garden draws its old sentries. Their
                // patrol never strayed from the garden, so a player's own
                // base by the landing pad is left alone.
                let home = StoryBuilder.gardenCentre
                skeletons.sentryAnchors = signals.poweredCells.compactMap { key in
                    let dx = key.x - home.x, dz = key.z - home.z
                    guard dx * dx + dz * dz < 40 * 40,
                          world.block(worldX: key.x, y: key.y, worldZ: key.z) == .wireOn else { return nil }
                    return Vector3(CGFloat(key.x) + 0.5, CGFloat(key.y), CGFloat(key.z) + 0.5)
                }
                if !story.breathedOnMoon, breathable.contains(where: { _ in true }), isBreathing,
                   !nearRocketOnly {
                    story.breathedOnMoon = true
                    say(Keeper.firstBreath)
                }
                checkGarden()
            }
        }
        advanceWaking(dt: dt)

        if world.isLunar, mode.hasSurvivalStats {
            let fraction = Double(stats.air) / Double(max(1, stats.airCapacity))
            if isBreathing {
                airWarningLevel = 0
            } else if fraction <= 0.25, airWarningLevel < 2 {
                airWarningLevel = 2
                showToast(L10n.t("AIR LOW — get to the rocket or a sealed room!",
                                 "LITE LUFT — skynda dig till raketen eller ett tätt rum!"), seconds: 4)
            } else if fraction <= 0.5, airWarningLevel < 1 {
                airWarningLevel = 1
                showToast(L10n.t("Air half gone", "Halva luften är slut"), seconds: 3)
            }
        }
    }

    /// True when the only air the player is in is the rocket's — which
    /// does not count as breathing on the Moon for the story's purposes.
    private var nearRocketOnly: Bool {
        let eye = player.eyePosition, feet = player.position
        let eyeCell = StoryCell(Int(floor(eye.x)), Int(floor(eye.y)), Int(floor(eye.z)))
        let feetCell = StoryCell(Int(floor(feet.x)), Int(floor(feet.y)), Int(floor(feet.z)))
        return !(breathable.contains(eyeCell) || breathable.contains(feetCell))
    }

    // MARK: - What the HUD shows

    /// The journal's one tracked line, and where it points if anywhere.
    func objective() -> (text: String, target: Vector3?)? {
        guard storyActive else { return nil }
        let atHome = destination == .home
        switch story.chapter {
        case 1:
            return (L10n.t("Find the blinking radio", "Hitta den blinkande radion"),
                    atHome ? story.station?.centre : nil)
        case 2:
            guard atHome else { return (L10n.t("Fly home", "Flyg hem"), nil) }
            let missing = story.sites.filter { !story.hasPiece($0.piece) }
            let here = player.position
            let nearest = missing.min { a, b in
                (a.radio.centre - here).length() < (b.radio.centre - here).length()
            }
            guard let nearest else { return nil }
            let found = story.pieces.count
            return (L10n.t("Find the radio at \(nearest.piece.place) (\(found)/3)",
                           "Hitta radion vid \(nearest.piece.place) (\(found)/3)"), nearest.radio.centre)
        case 3:
            guard atHome else { return nil }
            if story.homePad == nil {
                return (L10n.t("Build a launch pad and put a rocket on it", "Bygg en startplatta och ställ en raket på den"), nil)
            }
            return (L10n.t("Get ready, then launch the rocket", "Gör dig redo och starta raketen"), story.homePad?.centre)
        case 4:
            guard !atHome else { return (L10n.t("Fly back to the Moon", "Flyg tillbaka till Månen"), story.homePad?.centre) }
            return (L10n.t("Make a sealed room with a powered air maker", "Bygg ett tätt rum med en luftmaskin som har ström"), nil)
        case 5:
            guard !atHome else { return (L10n.t("Fly back to the Moon", "Flyg tillbaka till Månen"), story.homePad?.centre) }
            let left = GardenFault.allCases.filter { !story.isFixed($0) }.map(\.panelText).joined(separator: ", ")
            return (L10n.t("Wake the garden: ", "Väck trädgården: ") + left.lowercased(), story.garden?.panel.centre)
        case 6:
            if !story.gardenWoken {
                guard !atHome else { return (L10n.t("Fly back to the Moon", "Flyg tillbaka till Månen"), story.homePad?.centre) }
                return (L10n.t("Pull the lever in the seed vault", "Dra i spaken i frövalvet"), story.garden?.lever.centre)
            }
            guard atHome else { return (L10n.t("Fly home and grow a moon seed", "Flyg hem och odla ett månfrö"), story.moonPad?.centre) }
            return (L10n.t("Grow a moon seed on farmland at home", "Odla ett månfrö på åkerjord hemma"), nil)
        default:
            return nil
        }
    }

    /// Words for which way a target lies from where the player is facing.
    func objectiveDirection(to target: Vector3) -> String {
        let angle = Compass.needleAngle(from: player.position, home: target, cameraYaw: camera.yaw)
        let distance = Int(Compass.distance(from: player.position, home: target))
        var degrees = Double(angle) * 180 / .pi
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        if degrees > 180 { degrees -= 360 }
        if degrees < -180 { degrees += 360 }
        let way: String
        switch degrees {
        case -30...30: way = L10n.t("ahead", "framåt")
        case 30...150: way = L10n.t("to the right", "till höger")
        case -150 ... -30: way = L10n.t("to the left", "till vänster")
        default: way = L10n.t("behind you", "bakom dig")
        }
        return "\(distance) m \(way)"
    }

    /// What the crosshair reads off a story block, if it is on one.
    func lookText() -> String? {
        guard let target = highlightTarget else { return nil }
        let block = world.block(worldX: target.x, y: target.y, worldZ: target.z)
        let cell = StoryCell(target.x, target.y, target.z)
        switch block {
        case .plaque:
            return plaqueText(at: cell)
        case .airMaker:
            return (airMakerStatus[cell] ?? .noPower).text
        case .radio:
            if cell == story.station, !story.radioRepaired { return Keeper.radioNeedsCrystal }
            return L10n.t("Radio — right-click to listen", "Radio — högerklicka för att lyssna")
        case .rocketEngine, .rocketTank, .rocketCabin:
            return L10n.t("Rocket — right-click to check it over", "Raket — högerklicka för att kontrollera den")
        case .gardenSeal:
            return Keeper.sealHolds
        default:
            return nil
        }
    }

    private func plaqueText(at cell: StoryCell) -> String {
        if let garden = story.garden, cell == garden.panel {
            let left = GardenFault.allCases.filter { !story.isFixed($0) }
            if left.isEmpty { return L10n.t("KEEPER: ALL SYSTEMS WELL", "KEEPER: ALLA SYSTEM FUNGERAR") }
            var hints: [String] = []
            for fault in left {
                switch fault {
                case .light: hints.append(L10n.t("NO LIGHT: dig out the sun sensors on the ridge, mend the roof wire — long wire needs a relay",
                                                 "INGET LJUS: gräv fram solsensorerna på åsen, laga takets ledning — lång ledning behöver ett relä"))
                case .water: hints.append(L10n.t("NO WATER: fill the channel (ice melts by a torch)",
                                                 "INGET VATTEN: fyll rännan (is smälter vid en fackla)"))
                case .growth: hints.append(L10n.t("NOTHING GROWS: seal the nursery, give it air and light, grow wheat",
                                                  "INGET VÄXER: täta plantskolan, ge den luft och ljus, odla vete"))
                }
            }
            return hints.joined(separator: " · ")
        }
        if let station = story.station, cell.distanceSquared(to: station) < 16 {
            return L10n.t("\"The radio needs a glow crystal. Stone + 2 torches make two.\"",
                          "\"Radion behöver en glödkristall. Sten + 2 facklor ger två.\"")
        }
        if let site = story.sites.min(by: { $0.radio.distanceSquared(to: cell) < $1.radio.distanceSquared(to: cell) }),
           site.radio.distanceSquared(to: cell) < 64 {
            return "\"" + site.piece.lesson.capitalized + "\""
        }
        return L10n.t("The carving is too worn to read.", "Inskriptionen är för sliten för att läsas.")
    }

    /// The journal, as lines for the pause screen.
    func journalLines() -> [String] {
        guard storyActive else { return [] }
        func mark(_ done: Bool) -> String { done ? "[x]" : "[ ]" }
        var lines = [L10n.t("Journal", "Dagbok")]
        lines.append("\(mark(story.radioRepaired)) " + L10n.t("Mend the station radio", "Laga stationens radio"))
        for piece in StoryPiece.allCases {
            lines.append("\(mark(story.hasPiece(piece))) " + L10n.t("\(piece.title) from \(piece.place)",
                                                                   "\(piece.title) från \(piece.place)"))
        }
        lines.append("\(mark(story.launched)) " + L10n.t("Launch the rocket", "Starta raketen"))
        lines.append("\(mark(story.breathedOnMoon)) " + L10n.t("Breathe in a sealed room on the Moon",
                                                               "Andas i ett tätt rum på Månen"))
        for fault in GardenFault.allCases {
            lines.append("\(mark(story.isFixed(fault))) " + L10n.t("Garden: ", "Trädgården: ") + fault.panelText.lowercased())
        }
        lines.append("\(mark(story.gardenWoken)) " + L10n.t("Wake the garden", "Väck trädgården"))
        lines.append("\(mark(story.complete)) " + L10n.t("Grow a moon seed at home", "Odla ett månfrö hemma"))
        return lines
    }
}

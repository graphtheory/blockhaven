import Foundation

/// Headless proof of the game's signal primitives: a lever's on/off,
/// carried through wire, read by a door, a stick of TNT, a booster and a
/// hopper at the far end — plus the signal torch, which reads the network
/// as well as feeding it, and is the one piece capable of inverting a
/// signal, holding it past its switch, or referring to its own output.
///
/// `BLOCKHAVEN_CHECK_SIGNAL=1`. Exits nonzero if any line fails.
enum SignalCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_SIGNAL"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    private static func room(_ world: World, at spawn: Vector3) -> (x: Int, y: Int, z: Int) {
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dz in -2...2 {
            for dx in -2...2 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }
        let origin = (x: Int(spawn.x), y: 40, z: Int(spawn.z))
        for z in (origin.z - 6)...(origin.z + 6) {
            for x in (origin.x - 6)...(origin.x + 6) {
                world.setBlock(worldX: x, y: origin.y - 1, worldZ: z, to: .stone, remesh: false)
                world.setBlock(worldX: x, y: origin.y, worldZ: z, to: .air, remesh: false)
            }
        }
        return origin
    }

    static func run() -> Never {
        var report = Report()
        let world = World()
        let spawn = world.spawnPosition()
        let origin = room(world, at: spawn)

        // MARK: a lever powers wire in a line

        world.setBlock(worldX: origin.x, y: origin.y, worldZ: origin.z, to: .leverOff)
        for step in 1...5 {
            world.setBlock(worldX: origin.x + step, y: origin.y, worldZ: origin.z, to: .wireOff)
        }
        let signals = SignalNetwork()
        let fuses = FuseManager()
        signals.leverPlaced(at: SignalNetwork.Key(origin.x, origin.y, origin.z))

        signals.recompute(world: world, fuses: fuses)
        let allDarkYet = (1...5).allSatisfy {
            world.block(worldX: origin.x + $0, y: origin.y, worldZ: origin.z) == .wireOff
        }
        report.check(
            "wire stays dark while the lever is off",
            allDarkYet,
            "an off lever lit \((1...5).filter { world.block(worldX: origin.x + $0, y: origin.y, worldZ: origin.z) == .wireOn }.count) of 5 cells"
        )

        world.setBlock(worldX: origin.x, y: origin.y, worldZ: origin.z, to: .leverOn)
        signals.recompute(world: world, fuses: fuses)
        let allLit = (1...5).allSatisfy {
            world.block(worldX: origin.x + $0, y: origin.y, worldZ: origin.z) == .wireOn
        }
        report.check(
            "and lights every cell of wire it reaches once thrown",
            allLit,
            "\((1...5).filter { world.block(worldX: origin.x + $0, y: origin.y, worldZ: origin.z) == .wireOn }.count) of 5 lit"
        )

        world.setBlock(worldX: origin.x, y: origin.y, worldZ: origin.z, to: .leverOff)
        signals.recompute(world: world, fuses: fuses)
        let allDarkAgain = (1...5).allSatisfy {
            world.block(worldX: origin.x + $0, y: origin.y, worldZ: origin.z) == .wireOff
        }
        report.check(
            "and dims it again when thrown back",
            allDarkAgain,
            "\((1...5).filter { world.block(worldX: origin.x + $0, y: origin.y, worldZ: origin.z) == .wireOn }.count) of 5 still lit"
        )

        // MARK: reach gives out

        // Ten cells above the short run tested so far, so the two lines of
        // wire never join into one.
        let longRun = SignalNetwork.maxReach + 5
        for step in 1...longRun {
            world.setBlock(worldX: origin.x + step, y: origin.y + 10, worldZ: origin.z, to: .wireOff)
        }
        world.setBlock(worldX: origin.x, y: origin.y + 10, worldZ: origin.z, to: .leverOn)
        let farLever = SignalNetwork()
        farLever.leverPlaced(at: SignalNetwork.Key(origin.x, origin.y + 10, origin.z))
        farLever.recompute(world: world, fuses: fuses)
        let litCount = (1...longRun).filter {
            world.block(worldX: origin.x + $0, y: origin.y + 10, worldZ: origin.z) == .wireOn
        }.count
        report.check(
            "a signal gives out after its reach rather than running forever",
            litCount == SignalNetwork.maxReach,
            "\(litCount) of \(longRun) cells lit against a reach of \(SignalNetwork.maxReach)"
        )

        // MARK: a relay resets how far a signal has already travelled

        // A wire run up to a relay sitting right at the old cutoff — the
        // last cell plain wire would still have reached — then another full
        // `maxReach` of wire past it. Everything in that second stretch
        // only lights because the relay resets the count, and the run past
        // *that* still gives out somewhere, proving this isn't an
        // accidental unlimited reach either.
        let relayRunY = origin.y + 11
        let relayX = origin.x + SignalNetwork.maxReach
        for step in 1..<SignalNetwork.maxReach {
            world.setBlock(worldX: origin.x + step, y: relayRunY, worldZ: origin.z, to: .wireOff)
        }
        world.setBlock(worldX: relayX, y: relayRunY, worldZ: origin.z, to: .signalRelayOff)
        for step in 1...(SignalNetwork.maxReach + 5) {
            world.setBlock(worldX: relayX + step, y: relayRunY, worldZ: origin.z, to: .wireOff)
        }
        world.setBlock(worldX: origin.x, y: relayRunY, worldZ: origin.z, to: .leverOn)
        let relaySignals = SignalNetwork()
        relaySignals.leverPlaced(at: SignalNetwork.Key(origin.x, relayRunY, origin.z))
        relaySignals.recompute(world: world, fuses: fuses)

        let pastOldCutoff = world.block(
            worldX: relayX + SignalNetwork.maxReach - 2, y: relayRunY, worldZ: origin.z
        )
        report.check(
            "a relay past the old cutoff carries the signal on rather than ending it there",
            pastOldCutoff == .wireOn,
            "a cell only reachable through the relay reads \(String(describing: pastOldCutoff))"
        )
        let relayBlock = world.block(worldX: relayX, y: relayRunY, worldZ: origin.z)
        report.check(
            "and the relay itself lights up like any other powered wire",
            relayBlock == .signalRelayOn,
            "relay cell reads \(String(describing: relayBlock))"
        )
        let pastNewCutoff = world.block(
            worldX: relayX + SignalNetwork.maxReach + 4, y: relayRunY, worldZ: origin.z
        )
        report.check(
            "but one relay only buys one more reach, not an unlimited line",
            pastNewCutoff == .wireOff,
            "a cell past the relay's own extended reach reads \(String(describing: pastNewCutoff))"
        )
        world.setBlock(worldX: origin.x, y: relayRunY, worldZ: origin.z, to: .leverOff)
        relaySignals.recompute(world: world, fuses: fuses)
        let relayDarkened = world.block(worldX: relayX, y: relayRunY, worldZ: origin.z)
        report.check(
            "and the relay goes dark again the moment the lever behind it does",
            relayDarkened == .signalRelayOff,
            "relay cell reads \(String(describing: relayDarkened))"
        )

        // MARK: TNT at the end of a wire

        let blastX = origin.x, blastZ = origin.z - 8
        world.setBlock(worldX: blastX, y: origin.y, worldZ: blastZ, to: .leverOff)
        world.setBlock(worldX: blastX, y: origin.y, worldZ: blastZ - 1, to: .wireOff)
        world.setBlock(worldX: blastX, y: origin.y, worldZ: blastZ - 2, to: .tnt)
        let tntSignals = SignalNetwork()
        tntSignals.leverPlaced(at: SignalNetwork.Key(blastX, origin.y, blastZ))
        tntSignals.recompute(world: world, fuses: fuses)
        report.check(
            "TNT at the end of dark wire is not lit",
            fuses.live.isEmpty && world.block(worldX: blastX, y: origin.y, worldZ: blastZ - 2) == .tnt,
            "\(fuses.live.count) fuses burning, block is "
                + "\(String(describing: world.block(worldX: blastX, y: origin.y, worldZ: blastZ - 2)))"
        )
        world.setBlock(worldX: blastX, y: origin.y, worldZ: blastZ, to: .leverOn)
        tntSignals.recompute(world: world, fuses: fuses)
        report.check(
            "and lights the moment the lever throws power down the line",
            fuses.live.count == 1 && world.block(worldX: blastX, y: origin.y, worldZ: blastZ - 2) == .air,
            "\(fuses.live.count) fuses burning, block is "
                + "\(String(describing: world.block(worldX: blastX, y: origin.y, worldZ: blastZ - 2)))"
        )

        // MARK: a door held open by power

        let doorX = origin.x + 10, doorZ = origin.z
        world.setBlock(worldX: doorX, y: origin.y, worldZ: doorZ, to: .leverOff)
        world.setBlock(worldX: doorX, y: origin.y, worldZ: doorZ + 1, to: .wireOff)
        world.setBlock(worldX: doorX, y: origin.y, worldZ: doorZ + 2, to: .oakDoor(.lower, facing: .east, open: false))
        world.setBlock(worldX: doorX, y: origin.y + 1, worldZ: doorZ + 2, to: .oakDoor(.upper, facing: .east, open: false))
        let doorSignals = SignalNetwork()
        doorSignals.leverPlaced(at: SignalNetwork.Key(doorX, origin.y, doorZ))
        doorSignals.recompute(world: world, fuses: fuses)
        let closedStill = !world.block(worldX: doorX, y: origin.y, worldZ: doorZ + 2).doorIsOpen
        world.setBlock(worldX: doorX, y: origin.y, worldZ: doorZ, to: .leverOn)
        doorSignals.recompute(world: world, fuses: fuses)
        let openedBoth = world.block(worldX: doorX, y: origin.y, worldZ: doorZ + 2).doorIsOpen
            && world.block(worldX: doorX, y: origin.y + 1, worldZ: doorZ + 2).doorIsOpen
        report.check(
            "a door stays shut until power reaches it, then opens both halves",
            closedStill && openedBoth,
            "closed before power: \(closedStill), both halves open after: \(openedBoth)"
        )
        world.setBlock(worldX: doorX, y: origin.y, worldZ: doorZ, to: .leverOff)
        doorSignals.recompute(world: world, fuses: fuses)
        let closedAgain = !world.block(worldX: doorX, y: origin.y, worldZ: doorZ + 2).doorIsOpen
            && !world.block(worldX: doorX, y: origin.y + 1, worldZ: doorZ + 2).doorIsOpen
        report.check(
            "and swings itself shut again once the lever is thrown back",
            closedAgain,
            "lower open: \(world.block(worldX: doorX, y: origin.y, worldZ: doorZ + 2).doorIsOpen), "
                + "upper open: \(world.block(worldX: doorX, y: origin.y + 1, worldZ: doorZ + 2).doorIsOpen)"
        )

        // MARK: a lever nobody registered is still inert until it is

        // A lever the world placed rather than a hand — `leverPlaced` never
        // ran for it, the same gap that left a ruin's own lever silently
        // dead until `throwLever` started registering the cell it is
        // actually standing on before doing anything else. Proven at this
        // level rather than through `GameViewController` because the fix
        // belongs to the network's own contract: toggling a source has to
        // work regardless of how that source arrived.
        let foundLeverX = origin.x + 10, foundLeverZ = origin.z + 16
        world.setBlock(worldX: foundLeverX, y: origin.y, worldZ: foundLeverZ, to: .leverOff)
        world.setBlock(
            worldX: foundLeverX, y: origin.y, worldZ: foundLeverZ + 1,
            to: .oakDoor(.lower, facing: .east, open: false)
        )
        world.setBlock(
            worldX: foundLeverX, y: origin.y + 1, worldZ: foundLeverZ + 1,
            to: .oakDoor(.upper, facing: .east, open: false)
        )
        let foundSignals = SignalNetwork()
        // No `leverPlaced` call here — this is the state a chunk the
        // generator wrote leaves the network in.
        world.setBlock(worldX: foundLeverX, y: origin.y, worldZ: foundLeverZ, to: .leverOn)
        foundSignals.recompute(world: world, fuses: fuses)
        let ignoredBeforeRegistering = !world.block(
            worldX: foundLeverX, y: origin.y, worldZ: foundLeverZ + 1
        ).doorIsOpen
        // The registration `throwLever` now performs unconditionally,
        // before it touches the block at all.
        foundSignals.leverPlaced(at: SignalNetwork.Key(foundLeverX, origin.y, foundLeverZ))
        foundSignals.recompute(world: world, fuses: fuses)
        let openedOnceRegistered = world.block(worldX: foundLeverX, y: origin.y, worldZ: foundLeverZ + 1).doorIsOpen
        report.check(
            "a found lever does nothing until the hand that throws it registers it",
            ignoredBeforeRegistering && openedOnceRegistered,
            "door open before registering: \(!ignoredBeforeRegistering), "
                + "door open after: \(openedOnceRegistered)"
        )

        // MARK: an unwired booster is untouched

        let plainBoosterX = origin.x, plainBoosterZ = origin.z + 8
        world.setBlock(worldX: plainBoosterX, y: origin.y, worldZ: plainBoosterZ, to: .boosterNorthSouth)
        report.check(
            "a booster nobody wired up is always active",
            world.boosterIsActive(worldX: plainBoosterX, y: origin.y, worldZ: plainBoosterZ),
            "active: \(world.boosterIsActive(worldX: plainBoosterX, y: origin.y, worldZ: plainBoosterZ))"
        )

        // MARK: a wired booster follows the switch

        let wiredBoosterX = origin.x + 10, wiredBoosterZ = origin.z + 8
        world.setBlock(worldX: wiredBoosterX, y: origin.y, worldZ: wiredBoosterZ, to: .boosterNorthSouth)
        world.setBlock(worldX: wiredBoosterX, y: origin.y, worldZ: wiredBoosterZ - 1, to: .wireOff)
        world.setBlock(worldX: wiredBoosterX, y: origin.y, worldZ: wiredBoosterZ - 2, to: .leverOff)
        let boosterSignals = SignalNetwork()
        boosterSignals.leverPlaced(at: SignalNetwork.Key(wiredBoosterX, origin.y, wiredBoosterZ - 2))
        boosterSignals.recompute(world: world, fuses: fuses)
        let inertWhenDark = !world.boosterIsActive(worldX: wiredBoosterX, y: origin.y, worldZ: wiredBoosterZ)
        world.setBlock(worldX: wiredBoosterX, y: origin.y, worldZ: wiredBoosterZ - 2, to: .leverOn)
        boosterSignals.recompute(world: world, fuses: fuses)
        let activeWhenLit = world.boosterIsActive(worldX: wiredBoosterX, y: origin.y, worldZ: wiredBoosterZ)
        report.check(
            "a booster wired to a switch waits for it, then launches once it's thrown",
            inertWhenDark && activeWhenLit,
            "inert before power: \(inertWhenDark), active after: \(activeWhenLit)"
        )
        world.setBlock(worldX: wiredBoosterX, y: origin.y, worldZ: wiredBoosterZ - 2, to: .leverOff)
        boosterSignals.recompute(world: world, fuses: fuses)
        report.check(
            "and goes inert again when the switch is thrown back",
            !world.boosterIsActive(worldX: wiredBoosterX, y: origin.y, worldZ: wiredBoosterZ),
            "active: \(world.boosterIsActive(worldX: wiredBoosterX, y: origin.y, worldZ: wiredBoosterZ))"
        )

        // MARK: a wired hopper reads power without needing to be driven by it

        let hopperX = origin.x + 10, hopperZ = origin.z
        world.setBlock(worldX: hopperX, y: origin.y, worldZ: hopperZ, to: .hopper)
        world.setBlock(worldX: hopperX, y: origin.y, worldZ: hopperZ - 1, to: .wireOff)
        world.setBlock(worldX: hopperX, y: origin.y, worldZ: hopperZ - 2, to: .leverOff)
        let hopperSignals = SignalNetwork()
        let hopperKey = SignalNetwork.Key(hopperX, origin.y, hopperZ)
        hopperSignals.leverPlaced(at: SignalNetwork.Key(hopperX, origin.y, hopperZ - 2))
        hopperSignals.recompute(world: world, fuses: fuses)
        let unpoweredWhenDark = !hopperSignals.isPowered(at: hopperKey)
        world.setBlock(worldX: hopperX, y: origin.y, worldZ: hopperZ - 2, to: .leverOn)
        hopperSignals.recompute(world: world, fuses: fuses)
        let poweredWhenLit = hopperSignals.isPowered(at: hopperKey)
        report.check(
            "a hopper next to wire reads power without the network touching the block itself",
            unpoweredWhenDark && poweredWhenLit
                && world.block(worldX: hopperX, y: origin.y, worldZ: hopperZ) == .hopper,
            "unpowered before: \(unpoweredWhenDark), powered after: \(poweredWhenLit)"
        )
        world.setBlock(worldX: hopperX, y: origin.y, worldZ: hopperZ - 2, to: .leverOff)
        hopperSignals.recompute(world: world, fuses: fuses)
        report.check(
            "and reads unpowered again once the lever is thrown back",
            !hopperSignals.isPowered(at: hopperKey),
            "powered: \(hopperSignals.isPowered(at: hopperKey))"
        )

        // MARK: a pressure plate throws the network the way a lever does

        let plateX = origin.x, plateZ = origin.z + 16
        let plateDoorX = plateX + 4
        world.setBlock(worldX: plateX, y: origin.y, worldZ: plateZ, to: .pressurePlateOff)
        world.setBlock(worldX: plateDoorX, y: origin.y, worldZ: plateZ,
                       to: .oakDoor(.lower, facing: .north, open: false))
        world.setBlock(worldX: plateDoorX, y: origin.y + 1, worldZ: plateZ,
                       to: .oakDoor(.upper, facing: .north, open: false))
        for step in 1..<4 { world.setBlock(worldX: plateX + step, y: origin.y, worldZ: plateZ, to: .wireOff) }
        let plateSignals = SignalNetwork()
        let plateKey = SignalNetwork.Key(plateX, origin.y, plateZ)
        plateSignals.platePlaced(at: plateKey)
        plateSignals.recompute(world: world, fuses: fuses)

        var stoodOn = false
        let steppedOn = plateSignals.updatePlates(world: world, fuses: fuses) { $0 == plateKey && stoodOn }
        let litByStanding = world.block(worldX: plateX, y: origin.y, worldZ: plateZ) == .pressurePlateOn
        let doorOpenedByPlate = world.block(worldX: plateDoorX, y: origin.y, worldZ: plateZ).doorIsOpen
        report.check(
            "a pressure plate throws the network the moment something stands on it",
            !steppedOn && !litByStanding && !doorOpenedByPlate,
            "changed before anyone stood on it: \(steppedOn)"
        )
        stoodOn = true
        let nowChanged = plateSignals.updatePlates(world: world, fuses: fuses) { $0 == plateKey && stoodOn }
        report.check(
            "and opens a door wired to it, same as a lever would",
            nowChanged
                && world.block(worldX: plateX, y: origin.y, worldZ: plateZ) == .pressurePlateOn
                && world.block(worldX: plateDoorX, y: origin.y, worldZ: plateZ).doorIsOpen,
            "changed: \(nowChanged), plate: \(world.block(worldX: plateX, y: origin.y, worldZ: plateZ)), "
                + "door open: \(world.block(worldX: plateDoorX, y: origin.y, worldZ: plateZ).doorIsOpen)"
        )

        let noopChanged = plateSignals.updatePlates(world: world, fuses: fuses) { $0 == plateKey && stoodOn }
        report.check(
            "asking again with nothing new standing on it reports no change",
            !noopChanged,
            "changed: \(noopChanged)"
        )

        stoodOn = false
        let leftChanged = plateSignals.updatePlates(world: world, fuses: fuses) { $0 == plateKey && stoodOn }
        report.check(
            "and the door swings shut again once whatever was on it steps off",
            leftChanged
                && world.block(worldX: plateX, y: origin.y, worldZ: plateZ) == .pressurePlateOff
                && !world.block(worldX: plateDoorX, y: origin.y, worldZ: plateZ).doorIsOpen,
            "changed: \(leftChanged), plate: \(world.block(worldX: plateX, y: origin.y, worldZ: plateZ)), "
                + "door open: \(world.block(worldX: plateDoorX, y: origin.y, worldZ: plateZ).doorIsOpen)"
        )

        // MARK: a detector rail throws the network the way a plate does,
        // except nothing about the rail itself ever changes

        let detectorX = origin.x, detectorZ = origin.z + 24
        let detectorDoorX = detectorX + 4
        world.setBlock(worldX: detectorX, y: origin.y, worldZ: detectorZ, to: .detectorNorthSouth)
        world.setBlock(worldX: detectorDoorX, y: origin.y, worldZ: detectorZ,
                       to: .oakDoor(.lower, facing: .north, open: false))
        world.setBlock(worldX: detectorDoorX, y: origin.y + 1, worldZ: detectorZ,
                       to: .oakDoor(.upper, facing: .north, open: false))
        for step in 1..<4 { world.setBlock(worldX: detectorX + step, y: origin.y, worldZ: detectorZ, to: .wireOff) }
        let detectorSignals = SignalNetwork()
        let detectorKey = SignalNetwork.Key(detectorX, origin.y, detectorZ)
        detectorSignals.detectorPlaced(at: detectorKey)
        detectorSignals.recompute(world: world, fuses: fuses)

        var cartHere = false
        let arrived = detectorSignals.updateDetectors(world: world, fuses: fuses) { $0 == detectorKey && cartHere }
        report.check(
            "a detector rail throws the network the moment a cart parks on it",
            !arrived && !detectorSignals.poweredCells.contains(detectorKey)
                && !world.block(worldX: detectorDoorX, y: origin.y, worldZ: detectorZ).doorIsOpen,
            "changed before any cart arrived: \(arrived)"
        )
        cartHere = true
        let nowArrived = detectorSignals.updateDetectors(world: world, fuses: fuses) { $0 == detectorKey && cartHere }
        report.check(
            "and opens a door wired to it, same as a lever or a plate would — "
                + "the rail itself never changes block",
            nowArrived
                && detectorSignals.poweredCells.contains(detectorKey)
                && world.block(worldX: detectorX, y: origin.y, worldZ: detectorZ) == .detectorNorthSouth
                && world.block(worldX: detectorDoorX, y: origin.y, worldZ: detectorZ).doorIsOpen,
            "changed: \(nowArrived), rail: \(world.block(worldX: detectorX, y: origin.y, worldZ: detectorZ)), "
                + "door open: \(world.block(worldX: detectorDoorX, y: origin.y, worldZ: detectorZ).doorIsOpen)"
        )

        let noopArrived = detectorSignals.updateDetectors(world: world, fuses: fuses) { $0 == detectorKey && cartHere }
        report.check(
            "asking again with nothing new parked reports no change",
            !noopArrived,
            "changed: \(noopArrived)"
        )

        cartHere = false
        let left = detectorSignals.updateDetectors(world: world, fuses: fuses) { $0 == detectorKey && cartHere }
        report.check(
            "and the door swings shut again once the cart rolls off",
            left && !detectorSignals.poweredCells.contains(detectorKey)
                && !world.block(worldX: detectorDoorX, y: origin.y, worldZ: detectorZ).doorIsOpen,
            "changed: \(left), door open: \(world.block(worldX: detectorDoorX, y: origin.y, worldZ: detectorZ).doorIsOpen)"
        )

        // MARK: a signal torch inverts what reaches it, stably

        let torchX = origin.x, torchZ = origin.z + 28
        let torchDoorX = torchX + 4
        world.setBlock(worldX: torchX, y: origin.y, worldZ: torchZ - 3, to: .leverOff)
        world.setBlock(worldX: torchX, y: origin.y, worldZ: torchZ - 2, to: .wireOff)
        world.setBlock(worldX: torchX, y: origin.y, worldZ: torchZ - 1, to: .wireOff)
        world.setBlock(worldX: torchX, y: origin.y, worldZ: torchZ, to: .signalTorchOn)
        world.setBlock(worldX: torchX + 1, y: origin.y, worldZ: torchZ, to: .wireOff)
        world.setBlock(worldX: torchX + 2, y: origin.y, worldZ: torchZ, to: .wireOff)
        world.setBlock(worldX: torchX + 3, y: origin.y, worldZ: torchZ, to: .wireOff)
        world.setBlock(worldX: torchDoorX, y: origin.y, worldZ: torchZ,
                       to: .oakDoor(.lower, facing: .north, open: false))
        world.setBlock(worldX: torchDoorX, y: origin.y + 1, worldZ: torchZ,
                       to: .oakDoor(.upper, facing: .north, open: false))

        let torchSignals = SignalNetwork()
        let invLeverKey = SignalNetwork.Key(torchX, origin.y, torchZ - 3)
        let torchKey = SignalNetwork.Key(torchX, origin.y, torchZ)
        torchSignals.leverPlaced(at: invLeverKey)
        torchSignals.torchPlaced(at: torchKey)
        torchSignals.recompute(world: world, fuses: fuses)

        report.check(
            "a signal torch starts lit and powers a door through it, same as a lever would",
            world.block(worldX: torchX, y: origin.y, worldZ: torchZ) == .signalTorchOn
                && world.block(worldX: torchDoorX, y: origin.y, worldZ: torchZ).doorIsOpen,
            "torch: \(world.block(worldX: torchX, y: origin.y, worldZ: torchZ)), "
                + "door open: \(world.block(worldX: torchDoorX, y: origin.y, worldZ: torchZ).doorIsOpen)"
        )

        world.setBlock(worldX: torchX, y: origin.y, worldZ: torchZ - 3, to: .leverOn)
        torchSignals.recompute(world: world, fuses: fuses)
        let flippedByLever = torchSignals.updateTorches(world: world, fuses: fuses, dt: SignalNetwork.torchDelay)
        report.check(
            "and a lever powering it through wire turns it dark instead — the network's first inversion",
            flippedByLever
                && world.block(worldX: torchX, y: origin.y, worldZ: torchZ) == .signalTorchOff
                && !world.block(worldX: torchDoorX, y: origin.y, worldZ: torchZ).doorIsOpen,
            "flipped: \(flippedByLever), torch: \(world.block(worldX: torchX, y: origin.y, worldZ: torchZ)), "
                + "door open: \(world.block(worldX: torchDoorX, y: origin.y, worldZ: torchZ).doorIsOpen)"
        )

        // The torch's own output reaches the same wire on its far side that
        // the lever feeds on its near side — if that ever counted as the
        // torch reading its own light, this would now be flickering rather
        // than holding dark.
        let stillDarkOne = torchSignals.updateTorches(world: world, fuses: fuses, dt: SignalNetwork.torchDelay)
        let stillDarkTwo = torchSignals.updateTorches(world: world, fuses: fuses, dt: SignalNetwork.torchDelay)
        report.check(
            "and stays dark rather than oscillating — its own far-side output never counts as its own input",
            !stillDarkOne && !stillDarkTwo
                && world.block(worldX: torchX, y: origin.y, worldZ: torchZ) == .signalTorchOff,
            "changed on two more polls: \(stillDarkOne), \(stillDarkTwo)"
        )

        world.setBlock(worldX: torchX, y: origin.y, worldZ: torchZ - 3, to: .leverOff)
        torchSignals.recompute(world: world, fuses: fuses)
        let relitByLever = torchSignals.updateTorches(world: world, fuses: fuses, dt: SignalNetwork.torchDelay)
        report.check(
            "and relights the moment the lever is thrown back, reopening the door behind it",
            relitByLever
                && world.block(worldX: torchX, y: origin.y, worldZ: torchZ) == .signalTorchOn
                && world.block(worldX: torchDoorX, y: origin.y, worldZ: torchZ).doorIsOpen,
            "flipped: \(relitByLever), torch: \(world.block(worldX: torchX, y: origin.y, worldZ: torchZ))"
        )

        world.setBlock(worldX: torchX, y: origin.y, worldZ: torchZ - 3, to: .leverOn)
        torchSignals.recompute(world: world, fuses: fuses)
        let tooSoonChanged = torchSignals.updateTorches(world: world, fuses: fuses, dt: SignalNetwork.torchDelay * 0.1)
        report.check(
            "a torch still cooling down from its last flip does not flip again immediately",
            !tooSoonChanged && world.block(worldX: torchX, y: origin.y, worldZ: torchZ) == .signalTorchOn,
            "changed: \(tooSoonChanged), torch: \(world.block(worldX: torchX, y: origin.y, worldZ: torchZ))"
        )
        let afterCooldownChanged = torchSignals.updateTorches(world: world, fuses: fuses, dt: SignalNetwork.torchDelay)
        report.check(
            "and flips once its cooldown actually clears",
            afterCooldownChanged && world.block(worldX: torchX, y: origin.y, worldZ: torchZ) == .signalTorchOff,
            "changed: \(afterCooldownChanged), torch: \(world.block(worldX: torchX, y: origin.y, worldZ: torchZ))"
        )

        // MARK: three of them wired in a ring keep ticking — the clock
        // nobody had to write, the smallest possible answer to "what is
        // our signal": one invert-and-delay primitive, wired to read
        // itself through two others, and it never settles.

        let ringX = origin.x, ringZ = origin.z + 36
        let ringA = (x: ringX, z: ringZ)
        let ringW1 = (x: ringX + 1, z: ringZ)
        let ringB = (x: ringX + 2, z: ringZ)
        let ringW2 = (x: ringX + 2, z: ringZ + 1)
        let ringC = (x: ringX + 2, z: ringZ + 2)
        let ringW3 = (x: ringX + 1, z: ringZ + 2)
        let ringW4 = (x: ringX, z: ringZ + 2)
        let ringW5 = (x: ringX, z: ringZ + 1)
        for cell in [ringW1, ringW2, ringW3, ringW4, ringW5] {
            world.setBlock(worldX: cell.x, y: origin.y, worldZ: cell.z, to: .wireOff)
        }
        for cell in [ringA, ringB, ringC] {
            world.setBlock(worldX: cell.x, y: origin.y, worldZ: cell.z, to: .signalTorchOn)
        }

        let ring = SignalNetwork()
        let ringKeys = [ringA, ringB, ringC].map { SignalNetwork.Key($0.x, origin.y, $0.z) }
        for key in ringKeys { ring.torchPlaced(at: key) }
        ring.recompute(world: world, fuses: fuses)

        var flips = 0
        var lastStates = ringKeys.map { world.block(worldX: $0.x, y: $0.y, worldZ: $0.z) }
        for _ in 0..<40 {
            _ = ring.updateTorches(world: world, fuses: fuses, dt: SignalNetwork.torchDelay)
            let states = ringKeys.map { world.block(worldX: $0.x, y: $0.y, worldZ: $0.z) }
            for index in 0..<states.count where states[index] != lastStates[index] { flips += 1 }
            lastStates = states
        }
        report.check(
            "three torches wired in a ring keep flipping rather than settling",
            flips >= 6,
            "\(flips) flips over 40 polls of a 3-torch ring"
        )

        // MARK: pruning drops what the world no longer has

        let pruneTest = SignalNetwork()
        let leverKey = SignalNetwork.Key(origin.x, origin.y, origin.z)
        pruneTest.leverPlaced(at: leverKey)
        world.setBlock(worldX: origin.x, y: origin.y, worldZ: origin.z, to: .air)
        pruneTest.prune(world: world)
        report.check(
            "pruning drops a lever whose block is gone",
            pruneTest.leverCells.isEmpty,
            "\(pruneTest.leverCells.count) levers left after clearing the one cell"
        )

        let pruneDetector = SignalNetwork()
        let pruneDetectorKey = SignalNetwork.Key(origin.x + 1, origin.y, origin.z)
        world.setBlock(worldX: pruneDetectorKey.x, y: pruneDetectorKey.y, worldZ: pruneDetectorKey.z, to: .detectorEastWest)
        pruneDetector.detectorPlaced(at: pruneDetectorKey)
        world.setBlock(worldX: pruneDetectorKey.x, y: pruneDetectorKey.y, worldZ: pruneDetectorKey.z, to: .air)
        pruneDetector.prune(world: world)
        report.check(
            "pruning drops a detector rail whose block is gone",
            pruneDetector.detectorCells.isEmpty,
            "\(pruneDetector.detectorCells.count) detectors left after clearing the one cell"
        )

        let pruneTorch = SignalNetwork()
        let pruneTorchKey = SignalNetwork.Key(origin.x + 2, origin.y, origin.z)
        world.setBlock(worldX: pruneTorchKey.x, y: pruneTorchKey.y, worldZ: pruneTorchKey.z, to: .signalTorchOn)
        pruneTorch.torchPlaced(at: pruneTorchKey)
        world.setBlock(worldX: pruneTorchKey.x, y: pruneTorchKey.y, worldZ: pruneTorchKey.z, to: .air)
        pruneTorch.prune(world: world)
        report.check(
            "pruning drops a signal torch whose block is gone",
            pruneTorch.torchCells.isEmpty,
            "\(pruneTorch.torchCells.count) torches left after clearing the one cell"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the signal\n"
            : "[check] all passed — the signal\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

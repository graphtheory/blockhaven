import Foundation

/// Headless proof that the systems built across this session's gauntlet
/// iterations actually compose, rather than each merely passing its own
/// isolated check. Every other `*Check` proves one mechanic works; this
/// one runs a single continuous session — mine a real vein, smelt it
/// through a real hopper-fed furnace, grow a real crop through a real
/// storm faster than an unirrigated one beside it, raise a stretch of wall
/// with one placement instead of hundreds, open a door for a visitor who
/// presses a plate wired through a relay past the network's own plain
/// reach, and let a tamed wolf answer a skeleton at the doorstep — all
/// while a real fizzler manager watches the same ground — the shape of an
/// actual first hour, not unrelated demonstrations. First written before
/// the mason's line, the signal relay or taming existed; caught up here
/// the same way `PetCheck`'s own promise once was, rather than staying a
/// proof of only the oldest half of the game.
///
/// `BLOCKHAVEN_CHECK_HOMESTEAD=1`. Exits nonzero if any line fails.
enum HomesteadCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_HOMESTEAD"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    private static let dt = 1.0 / 60

    /// `SkyController` lives on the main actor — the live game only ever
    /// touches it from the render loop — and this is the first check to
    /// need one running rather than just reading its `nonisolated` static
    /// math. `main.swift` calls this via `MainActor.assumeIsolated`: its
    /// top level runs on the main thread but is not itself main-actor
    /// code, so the isolation has to be asserted rather than inherited.
    @MainActor
    static func run() -> Never {
        var report = Report()
        let world = World()
        let spawn = world.spawnPosition()
        let originX = Int(spawn.x), originZ = Int(spawn.z)
        world.forceGenerate(World.chunkCoord(forWorldX: originX, worldZ: originZ))

        // MARK: strike a real vein underground, not a planted block
        //
        // The whole claim iteration 12 made was that a find means there is
        // more beside it. Proving that here — rather than trusting the ORE
        // check's own census — means actually mining what the generator
        // put there and counting what comes up.
        let searchMin = World.chunkCoord(forWorldX: originX - 20, worldZ: originZ - 20)
        let searchMax = World.chunkCoord(forWorldX: originX + 20, worldZ: originZ + 20)
        for cz in searchMin.z...searchMax.z {
            for cx in searchMin.x...searchMax.x {
                world.forceGenerate(ChunkCoord(x: cx, z: cz))
            }
        }
        var oreFound = 0
        var veinCenter: (x: Int, y: Int, z: Int)?
        outer: for y in stride(from: 47, through: 5, by: -1) {
            for dz in -20...20 {
                for dx in -20...20 {
                    let x = originX + dx, z = originZ + dz
                    if world.block(worldX: x, y: y, worldZ: z) == .ironOre {
                        veinCenter = (x, y, z)
                        break outer
                    }
                }
            }
        }
        guard let vein = veinCenter else {
            StandardError.write(Data("[check] no iron vein found near spawn to mine — try another seed\n".utf8))
            exit(2)
        }
        for dz in -2...2 {
            for dy in -2...2 {
                for dx in -2...2 {
                    let x = vein.x + dx, y = vein.y + dy, z = vein.z + dz
                    if world.block(worldX: x, y: y, worldZ: z) == .ironOre {
                        world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                        oreFound += 1
                    }
                }
            }
        }
        report.check(
            "mining one found block of the vein turns up more beside it",
            oreFound >= 2,
            "\(oreFound) ironOre blocks mined out of one 5×5×5 pocket around the first one found"
        )

        // MARK: build the smelting line — chest of ore and fuel, hopper,
        // lit furnace — at a fixed surface cell near spawn

        let surface = world.generator.surfaceHeight(x: originX, z: originZ)
        let deck = (x: originX, y: surface + 1, z: originZ)
        world.setBlock(worldX: deck.x, y: deck.y + 2, worldZ: deck.z, to: .chest, remesh: false)
        world.setBlock(worldX: deck.x, y: deck.y + 1, worldZ: deck.z, to: .hopper, remesh: false)
        world.setBlock(worldX: deck.x, y: deck.y, worldZ: deck.z, to: .furnace, remesh: false)

        let chests = ChestStore()
        let furnaces = FurnaceStore()
        var minecarts = MinecartManager()
        let chestKey = ChestStore.Key(deck.x, deck.y + 2, deck.z)
        let furnaceKey = FurnaceStore.Key(deck.x, deck.y, deck.z)
        let hopperKey = HopperStore.Key(deck.x, deck.y + 1, deck.z)
        chests.chest(at: chestKey)[0] = ItemStack(.rawIron, count: oreFound)
        chests.chest(at: chestKey)[1] = ItemStack(.coal, count: 2)

        // MARK: plant one crop a few cells over, irrigated by a canal, and
        // one further off with no water near it — the same differential
        // CropCheck already proves in isolation, run here inside the full
        // multi-system session instead of on its own.

        let cropCell = (x: deck.x + 3, y: deck.y, z: deck.z)
        let dryCropCell = (x: deck.x + 3, y: deck.y, z: deck.z + 8)
        for site in [cropCell, dryCropCell] {
            world.setBlock(worldX: site.x, y: site.y - 1, worldZ: site.z, to: .farmland, remesh: false)
            for y in site.y..<(Chunk.height - 1) {
                world.setBlock(worldX: site.x, y: y, worldZ: site.z, to: .air, remesh: false)
            }
            world.setBlock(worldX: site.x, y: site.y, worldZ: site.z, to: .wheatStage0, remesh: false)
        }
        // A one-cell canal, two over from the irrigated planting — close
        // enough to hydrate it, the same reach `CropStore.isHydrated` uses
        // for a real player's own dug channel.
        world.setBlock(worldX: cropCell.x + 2, y: cropCell.y - 1, worldZ: cropCell.z, to: .water, remesh: false)
        let crops = CropStore()
        let dryCrops = CropStore()
        crops.planted(at: CropStore.Key(cropCell.x, cropCell.y, cropCell.z))
        dryCrops.planted(at: CropStore.Key(dryCropCell.x, dryCropCell.y, dryCropCell.z))

        // MARK: a pressure plate at the entrance, wired to a door — someone
        // arrives partway through the session and leaves before it ends.
        // The plate sits 18 cells out, past `SignalNetwork.maxReach` (15)
        // on its own, with a relay part way along the run — this chain
        // only works at all because of iteration 28's fix, not merely
        // because a relay happens to also be standing nearby.

        let doorCell = (x: deck.x - 3, y: deck.y, z: deck.z)
        let plateCell = (x: deck.x - 21, y: deck.y, z: deck.z)
        let relayCell = (x: deck.x - 12, y: deck.y, z: deck.z)
        world.setBlock(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z,
                       to: .oakDoor(.lower, facing: .north, open: false), remesh: false)
        world.setBlock(worldX: doorCell.x, y: doorCell.y + 1, worldZ: doorCell.z,
                       to: .oakDoor(.upper, facing: .north, open: false), remesh: false)
        world.setBlock(worldX: plateCell.x, y: plateCell.y, worldZ: plateCell.z, to: .pressurePlateOff, remesh: false)
        // Wire the whole run, doorCell.x - 1 the last cell short of the
        // door itself, then drop the relay in partway along it.
        for x in (plateCell.x + 1)...(doorCell.x - 1) {
            world.setBlock(worldX: x, y: plateCell.y, worldZ: plateCell.z, to: .wireOff, remesh: false)
        }
        world.setBlock(worldX: relayCell.x, y: relayCell.y, worldZ: relayCell.z, to: .signalRelayOff, remesh: false)
        let signals = SignalNetwork()
        let fuses = FuseManager()
        let plateKey = SignalNetwork.Key(plateCell.x, plateCell.y, plateCell.z)
        signals.platePlaced(at: plateKey)
        signals.recompute(world: world, fuses: fuses)
        var doorOpenedForVisitor = false
        var doorClosedAfterVisitor = false

        // MARK: raise a stretch of wall with one placement, mason's-line
        // style, well clear of everything else on the plot

        let wallBox = RegionFill.region(
            from: (deck.x + 10, deck.y, deck.z - 2), to: (deck.x + 12, deck.y + 2, deck.z + 2)
        )
        let wallPlaced = RegionFill.fill(
            wallBox, with: .stone, world: world, playerOverlaps: { _, _, _ in false }, available: .max
        )

        // MARK: a tamed wolf answers a skeleton at the doorstep, same
        // ground the fizzler manager is already watching

        var pack = AnimalManager(mode: .survival, seed: 0xD09E5)
        var guardDog = Animal(kind: .wolf, position: Vector3(CGFloat(deck.x) + 1.5, CGFloat(deck.y) + 1, CGFloat(deck.z) + 0.5), seed: 0xD09)
        guardDog.isTamed = true
        pack.adopt([guardDog])
        let guardID = pack.animals.keys.first!
        let skeletonThreat = AnimalManager.Threat(
            id: -1, isFizzler: false,
            position: Vector3(CGFloat(deck.x) + 2.5, CGFloat(deck.y) + 1, CGFloat(deck.z) + 0.5)
        )
        var guardBitSkeleton = false

        // MARK: run one continuous session: sky, hopper, furnace, crop and
        // fizzler danger all ticking together at the same doorstep, through
        // a stretch of storm

        let sky = SkyClock()
        sky.setTimeOfDay(0.2)
        var fizzlers = FizzlerManager(mode: .survival, seed: 0xF00D)
        let eye = Vector3(CGFloat(deck.x) + 0.5, CGFloat(deck.y) + 2, CGFloat(deck.z) + 0.5)
        var hopperCooldown = 0.0
        var sawFurnaceLit = false
        var peakFizzlers = 0
        var sawRain = false
        var irrigatedRipeAt: Double?
        var dryRipeAt: Double?

        let sessionSeconds = 90.0
        var elapsed = 0.0
        while elapsed < sessionSeconds {
            sky.advance(dt: dt)
            if sky.isRaining { sawRain = true }

            hopperCooldown -= dt
            if hopperCooldown <= 0 {
                hopperCooldown = 1.0
                HopperStore.transfer(at: hopperKey, world: world, chests: chests, furnaces: furnaces, minecarts: &minecarts)
            }
            var furnaceState = furnaces.state(at: furnaceKey)
            if furnaceState.tick(dt: dt) {
                world.setBlock(worldX: deck.x, y: deck.y, worldZ: deck.z, to: furnaceState.isBurning ? .furnaceLit : .furnace)
            }
            furnaces.set(furnaceState, at: furnaceKey)
            if furnaceState.isBurning { sawFurnaceLit = true }

            for key in crops.tick(dt: dt, world: world, isRaining: sky.isRaining) {
                let current = world.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: current.rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                    if next == .wheatStage3, irrigatedRipeAt == nil { irrigatedRipeAt = elapsed }
                }
            }
            for key in dryCrops.tick(dt: dt, world: world, isRaining: sky.isRaining) {
                let current = world.block(worldX: key.x, y: key.y, worldZ: key.z)
                if let next = BlockType(rawValue: current.rawValue + 1) {
                    world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: next)
                    if next == .wheatStage3, dryRipeAt == nil { dryRipeAt = elapsed }
                }
            }

            // A visitor arrives at the plate a third of the way through
            // the session and leaves two-thirds through — the pressure
            // plate's whole job, run alongside everything else rather than
            // in SignalCheck's isolation.
            let visiting = elapsed >= sessionSeconds / 3 && elapsed < sessionSeconds * 2 / 3
            if signals.updatePlates(world: world, fuses: fuses, occupied: { $0 == plateKey && visiting }) {
                let lowerOpen = world.block(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z).doorIsOpen
                if visiting, lowerOpen { doorOpenedForVisitor = true }
                if !visiting, doorOpenedForVisitor, !lowerOpen { doorClosedAfterVisitor = true }
            }

            _ = fizzlers.update(
                dt: dt, playerEye: eye, playerIsTargetable: false,
                isNight: sky.isNight, isRaining: sky.isRaining, world: world
            )
            peakFizzlers = max(peakFizzlers, fizzlers.fizzlers.count)

            // The guard dog's fight is over in the first few seconds —
            // it only has to prove combat composes with everything else
            // already ticking, not run the whole session.
            if elapsed < 4.0 {
                for bite in pack.update(dt: dt, playerEye: eye, world: world, threats: [skeletonThreat]) {
                    guardBitSkeleton = true
                    let distanceFromSpawn = (eye - world.spawnPosition()).length()
                    let retaliation = SkeletonManager.shotDamage(distanceFromSpawn: distanceFromSpawn)
                    _ = pack.damage(id: bite.wolfID, amount: retaliation, knockback: .zero)
                }
            }

            elapsed += dt
        }

        report.check(
            "the storm this session ran through actually arrived",
            sawRain,
            "isRaining was true at some point across \(String(format: "%.0f", sessionSeconds))s starting at t=0.2"
        )
        let output = furnaces.state(at: furnaceKey)
        report.check(
            "the mined ore came out the other end as ingots, moved there by the hopper alone",
            sawFurnaceLit && output.outputType == ItemType.rawIron.smeltedOutput,
            "furnace lit: \(sawFurnaceLit), output: \(String(describing: output.outputType)) × \(output.outputCount)"
        )
        let irrigatedBlock = world.block(worldX: cropCell.x, y: cropCell.y, worldZ: cropCell.z)
        report.check(
            "the crop advanced while all of that was happening, not just in isolation",
            irrigatedBlock != .wheatStage0,
            "block after \(String(format: "%.0f", sessionSeconds))s: \(String(describing: irrigatedBlock))"
        )
        report.check(
            "and the one with a canal dug to it ripened before the one without, same storm and all",
            irrigatedRipeAt != nil && dryRipeAt != nil && irrigatedRipeAt! < dryRipeAt!,
            "irrigated ripe at \(String(describing: irrigatedRipeAt)), dry ripe at \(String(describing: dryRipeAt))"
        )
        report.check(
            "a visitor stepping onto the plate opened the door, wire and all",
            doorOpenedForVisitor,
            "opened while visiting: \(doorOpenedForVisitor)"
        )
        report.check(
            "and it swung shut again once they walked off it",
            doorClosedAfterVisitor,
            "closed after leaving: \(doorClosedAfterVisitor)"
        )
        report.check(
            "and the doorstep stayed the doorstep — danger never left the flat, unscaled cap",
            peakFizzlers <= FizzlerManager.populationCap,
            "peak fizzlers at spawn distance 0, storm included: \(peakFizzlers) / \(FizzlerManager.populationCap)"
        )
        let plateToDoorRun = abs(plateCell.x - doorCell.x)
        report.check(
            "the plate-to-door run is genuinely past plain reach — the door above answered because of the relay",
            plateToDoorRun > SignalNetwork.maxReach,
            "run length \(plateToDoorRun) cells vs maxReach \(SignalNetwork.maxReach)"
        )
        report.check(
            "one placement raised the stretch of wall instead of dozens by hand",
            wallPlaced >= RegionFill.volume(of: wallBox) - 2,
            "\(wallPlaced) of \(RegionFill.volume(of: wallBox)) wall cells placed"
        )
        report.check(
            "the guard dog answered the skeleton at the doorstep while everything else was still running",
            guardBitSkeleton,
            "landed a bite: \(guardBitSkeleton)"
        )
        report.check(
            "and took the same retaliation a fight anywhere else in the game would cost it",
            (pack.animals[guardID]?.health ?? AnimalKind.wolf.maxHealth) < AnimalKind.wolf.maxHealth,
            "guard dog health after the fight: \(pack.animals[guardID]?.health ?? -1) / \(AnimalKind.wolf.maxHealth)"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the homestead\n"
            : "[check] all passed — the homestead\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

private extension ItemType {
    /// What one unit of this smelts into, for the one assertion above that
    /// wants the answer without hand-rolling the furnace's own table again.
    var smeltedOutput: ItemType? { FurnaceRecipe.output(for: self) }
}

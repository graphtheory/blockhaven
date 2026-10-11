import Foundation

/// Headless proof that a track is a track and a coaster is a coaster.
///
/// Two separate claims, and they fail in ways a screenshot cannot show.
/// The track has to *join up*: a rail laid beside another has to turn to
/// meet it, or a line is a row of stubs and a cart stops at the first one.
/// And the ride has to conserve something: a drop must pay for the rise
/// after it, or a coaster is a slide that ends at the bottom of the first
/// hill and every loop anyone builds simply stops.
///
/// `BLOCKHAVEN_CHECK_RAILS=1`. Exits nonzero if any line fails.
enum RailCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_RAILS"] != nil
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

    static func run() -> Never {
        var report = Report()
        let world = World()
        let spawn = world.spawnPosition()
        let originX = Int(spawn.x), originZ = Int(spawn.z)
        let deck = 70

        /// A flat stone platform to build track on, and air above it.
        ///
        /// Each deck brings its own ground. This used to be a fixed 9×9
        /// ring of chunks around spawn, and generating it was most of the
        /// check's running time for world that four narrow decks never
        /// touched. Deriving the chunks from the deck means the check pays
        /// for the ground it stands on and no more — and, which matters
        /// more than the speed, a deck moved or lengthened later cannot
        /// come to hang over chunks nobody generated. `setBlock` on an
        /// absent chunk quietly does nothing, so that would have read as
        /// the rails failing rather than as the check building on air.
        ///
        /// A chunk of margin on every side, so that the cells a rail reads
        /// just past the end of a deck hold the terrain they would have
        /// held under the old ring rather than the air of a chunk that was
        /// never made.
        func clearDeck(xRange: ClosedRange<Int>, zRange: ClosedRange<Int>, top: Int) {
            let low = World.chunkCoord(forWorldX: xRange.lowerBound, worldZ: zRange.lowerBound)
            let high = World.chunkCoord(forWorldX: xRange.upperBound, worldZ: zRange.upperBound)
            for cz in (low.z - 1)...(high.z + 1) {
                for cx in (low.x - 1)...(high.x + 1) {
                    world.forceGenerate(ChunkCoord(x: cx, z: cz))
                }
            }
            for z in zRange {
                for x in xRange {
                    for y in (top - 3)...top {
                        world.setBlock(worldX: x, y: y, worldZ: z, to: .stone, remesh: false)
                    }
                    for y in (top + 1)...(top + 12) {
                        world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                    }
                }
            }
        }

        /// Lays a rail and lets the network resolve it, exactly as placing
        /// one in the game does.
        func lay(_ x: Int, _ y: Int, _ z: Int, powered: Bool = false, facing: BlockFacing = .east) {
            world.setBlock(worldX: x, y: y, worldZ: z,
                           to: RailNetwork.straight(along: facing, powered: powered))
            RailNetwork.refresh(around: (x, y, z), preferring: facing, in: world)
        }

        // MARK: joining up

        clearDeck(xRange: (originX - 2)...(originX + 20), zRange: (originZ - 6)...(originZ + 6), top: deck)
        for step in 0...10 { lay(originX + step, deck + 1, originZ) }
        let straights = (0...10).filter {
            world.block(worldX: originX + $0, y: deck + 1, worldZ: originZ) == .railEastWest
        }
        report.check(
            "a line of rails joins itself up",
            straights.count == 11,
            "\(straights.count) of 11 cells came out east–west"
        )

        // A rail laid off to the side turns the corner — and turns the one
        // it met into a corner too, which is the half that would leave a
        // track as disconnected stubs if `refresh` only touched the new cell.
        lay(originX + 10, deck + 1, originZ + 1, facing: .south)
        let corner = world.block(worldX: originX + 10, y: deck + 1, worldZ: originZ)
        report.check(
            "and a rail laid beside one turns it into a corner",
            corner == .railCurveSouthWest,
            "the end of the line is now \(String(describing: corner))"
        )

        // A rail against a one-block step becomes a climb.
        lay(originX + 12, deck + 2, originZ)
        lay(originX + 11, deck + 1, originZ)
        let ramp = world.block(worldX: originX + 11, y: deck + 1, worldZ: originZ)
        report.check(
            "and one against a step becomes a slope",
            ramp.isRailSlope && ramp.railRise == .east,
            "the cell below the step is \(String(describing: ramp))"
        )

        // MARK: rolling

        clearDeck(xRange: (originX - 2)...(originX + 60), zRange: (originZ + 18)...(originZ + 22), top: deck)
        let runZ = originZ + 20
        for step in 0...50 { lay(originX + step, deck + 1, runZ) }

        var carts = MinecartManager()
        guard let id = carts.place(at: (originX, deck + 1, runZ), in: world) else {
            report.check("a cart can be put on a rail", false, "nothing was placed")
            finish(report)
        }
        report.check("a cart can be put on a rail", true, "cart \(id) is on the track")

        // A cart with a shove rolls, and keeps rolling for a good while.
        carts.shove(id, speed: 8, heading: .east)
        let startX = carts.cart(id)?.position.x ?? 0
        for _ in 0..<300 { _ = carts.update(dt: dt, world: world) }
        let rolled = (carts.cart(id)?.position.x ?? 0) - startX
        report.check(
            "and it rolls a long way on the flat",
            rolled > 12,
            String(format: "%.1f blocks in 5 s from a shove of 8 blocks/s", Double(rolled))
        )
        report.check(
            "and it stays on the middle of the rail",
            abs((carts.cart(id)?.position.z ?? 0) - (CGFloat(runZ) + 0.5)) < 0.01,
            String(format: "z %.3f against a rail centre of %.1f",
                   Double(carts.cart(id)?.position.z ?? 0), Double(runZ) + 0.5)
        )

        // MARK: the coaster

        // A drop and then a rise of the same height. The claim is that the
        // cart gets over the second hill — which is only true if going down
        // gave it what going up takes away, and is exactly what makes this a
        // coaster rather than a slide.
        let hillZ = originZ + 30
        clearDeck(xRange: (originX - 2)...(originX + 40), zRange: (originZ + 28)...(originZ + 32), top: deck)
        for x in (originX - 2)...(originX + 40) {
            for y in (deck + 1)...(deck + 14) {
                world.setBlock(worldX: x, y: y, worldZ: hillZ, to: .air, remesh: false)
            }
        }
        // Track: flat at the top, four cells down, flat, four cells up,
        // flat. Built by laying the deck under each cell and the rail on it.
        //
        // The lead-in is one cell, not four. Friction is 0.42 a second, so
        // a 1.5 blocks/s nudge carries about three and a half blocks on the
        // flat and no further — the first cut of this check gave the cart a
        // four-cell run-up and measured it coasting to a halt short of the
        // drop, which says nothing at all about slopes.
        // A four-block drop and a three-block rise, which is what a coaster
        // actually is: every hill lower than the one before it. A rise
        // equal to the drop cannot be cleared and should not be — see
        // `Minecart.friction`, which has the measured numbers.
        var profile: [(x: Int, y: Int)] = []
        var height = deck + 6
        profile.append((originX, height))
        for step in 1..<5 { height -= 1; profile.append((originX + step, height)) }
        for step in 5..<9 { profile.append((originX + step, height)) }
        // Appended *then* incremented, which is not a nicety. A slope cell
        // spans its own floor to one above, so the first cell of a climb
        // has to sit at the height of the flat leading into it. Incrementing
        // first puts it a block up and leaves a step at the foot of the
        // hill that the cart arrives at and stops dead against — which is
        // what the first cut of this did, and it read as the slope physics
        // being broken rather than as the track being built wrong.
        for step in 9..<12 { profile.append((originX + step, height)); height += 1 }
        for step in 12..<24 { profile.append((originX + step, height)) }
        for point in profile {
            world.setBlock(worldX: point.x, y: point.y - 1, worldZ: hillZ, to: .stone)
        }
        for point in profile { lay(point.x, point.y, hillZ) }

        var coaster = MinecartManager()
        guard let rider = coaster.place(at: (originX, deck + 6, hillZ), in: world) else {
            report.check("a coaster can be built", false, "the cart would not go on")
            finish(report)
        }
        // A gentle nudge — far less than it would take to climb the rise
        // from a standing start. Everything past the drop is bought with
        // height.
        coaster.shove(rider, speed: 1.5, heading: .east)
        var highestX = coaster.cart(rider)?.position.x ?? 0
        var fastest: CGFloat = 0
        for _ in 0..<900 {
            _ = coaster.update(dt: dt, world: world)
            guard let cart = coaster.cart(rider) else { break }
            highestX = max(highestX, cart.position.x)
            fastest = max(fastest, abs(cart.speed))
        }
        let travelled = highestX - CGFloat(originX)
        report.check(
            "a drop pays for a smaller rise after it",
            travelled > 14,
            String(format: "reached %.1f blocks from a 1.5 blocks/s nudge, over a 4-block drop and a 3-block rise",
                   Double(travelled))
        )
        report.check(
            "and the drop is what makes it quick",
            fastest > 6,
            String(format: "fastest %.1f blocks/s, from a nudge of 1.5", Double(fastest))
        )

        // MARK: the booster

        clearDeck(xRange: (originX - 2)...(originX + 40), zRange: (originZ - 22)...(originZ - 18), top: deck)
        let poweredZ = originZ - 20
        for step in 0...30 {
            lay(originX + step, deck + 1, poweredZ, powered: step < 6)
        }
        var powered = MinecartManager()
        guard let pushed = powered.place(at: (originX, deck + 1, poweredZ), in: world) else {
            report.check("a booster can be built", false, "the cart would not go on")
            finish(report)
        }
        powered.shove(pushed, speed: 0, heading: .east)
        let poweredStart = powered.cart(pushed)?.position.x ?? 0
        for _ in 0..<240 { _ = powered.update(dt: dt, world: world) }
        let pushedDistance = (powered.cart(pushed)?.position.x ?? 0) - poweredStart
        report.check(
            "a powered rail launches a cart that was standing still",
            pushedDistance > 8,
            String(format: "%.1f blocks in 4 s from a standing start on six powered rails",
                   Double(pushedDistance))
        )

        // MARK: the end of the line

        // Left running long enough to reach the buffer, the cart has to
        // still be there. This is the bug the low-friction tuning exposed:
        // a straight rail names both its ends whether or not there is track
        // beyond them, so the last rail of a line handed the cart out into
        // the air and it was deleted as derailed — taking the player with
        // it, if they were aboard.
        for _ in 0..<600 { _ = powered.update(dt: dt, world: world) }
        let survivor = powered.cart(pushed)
        report.check(
            "a cart reaching the end of the line stops rather than flying off it",
            survivor != nil && abs(survivor?.speed ?? 99) < 0.01,
            survivor == nil
                ? "the cart was lost off the end"
                : String(format: "stopped at x %.1f, the last rail is at %d",
                         Double(survivor?.position.x ?? 0), originX + 30)
        )

        // MARK: a detector rail keeps its shape and finds a parked cart

        // Spliced into an ordinary line rather than laid alone, so the real
        // risk — a neighbour's own edit re-resolving this cell back into a
        // plain rail — has a neighbour able to trigger it.
        let detectorZ = originZ + 30
        clearDeck(xRange: (originX - 2)...(originX + 10), zRange: (detectorZ - 2)...(detectorZ + 2), top: deck)
        for step in 0...3 { lay(originX + step, deck + 1, detectorZ) }
        world.setBlock(
            worldX: originX + 4, y: deck + 1, worldZ: detectorZ,
            to: RailNetwork.detectorStraight(along: .east)
        )
        let detectorRailKey = SignalNetwork.Key(originX + 4, deck + 1, detectorZ)
        let detectorRailSignals = SignalNetwork()
        let detectorRailFuses = FuseManager()
        detectorRailSignals.detectorPlaced(at: detectorRailKey)
        // Four more rails laid past it, each one re-resolving its own
        // neighbours through `refresh` — including the detector cell.
        for step in 5...8 { lay(originX + step, deck + 1, detectorZ) }
        report.check(
            "a detector rail draws its own tile, not a plain rail's",
            ShapedBlocks.parts(for: .detectorEastWest).first?.top == .railDetector,
            "tile: \(String(describing: ShapedBlocks.parts(for: .detectorEastWest).first?.top))"
        )
        report.check(
            "a detector rail keeps its own shape while a neighbouring line grows",
            world.block(worldX: originX + 4, y: deck + 1, worldZ: detectorZ) == .detectorEastWest,
            "block after the line grew past it: "
                + "\(String(describing: world.block(worldX: originX + 4, y: deck + 1, worldZ: detectorZ)))"
        )

        var detectorCarts = MinecartManager()
        guard let parkedCart = detectorCarts.place(at: (originX + 4, deck + 1, detectorZ), in: world) else {
            report.check("a cart can be parked on a detector rail", false, "the cart would not go on")
            finish(report)
        }
        detectorRailSignals.recompute(world: world, fuses: detectorRailFuses)
        let parkedChanged = detectorRailSignals.updateDetectors(world: world, fuses: detectorRailFuses) { key in
            detectorCarts.cartID(at: (key.x, key.y, key.z)) != nil
        }
        report.check(
            "a real, parked cart is exactly what the detector rail reads as live",
            parkedChanged && detectorRailSignals.poweredCells.contains(detectorRailKey),
            "changed: \(parkedChanged)"
        )
        detectorCarts.shove(parkedCart, speed: 6, heading: .east)
        for _ in 0..<30 { _ = detectorCarts.update(dt: dt, world: world) }
        let rolledOffChanged = detectorRailSignals.updateDetectors(world: world, fuses: detectorRailFuses) { key in
            detectorCarts.cartID(at: (key.x, key.y, key.z)) != nil
        }
        report.check(
            "and stops reading as live the moment the cart rolls off it",
            rolledOffChanged && !detectorRailSignals.poweredCells.contains(detectorRailKey),
            "changed: \(rolledOffChanged)"
        )

        // MARK: a cart survives leaving the world and coming back

        // A cart is not in the block journal — it rides a rail rather than
        // being one — so without its own save entry a coaster a player
        // spent an evening building would lose every cart on it the moment
        // they quit: still a railway to look at, but not one to ride.
        let saveZ = originZ + 40
        clearDeck(xRange: (originX - 2)...(originX + 10), zRange: (saveZ - 2)...(saveZ + 2), top: deck)
        for x in originX...(originX + 4) { lay(x, deck, saveZ) }
        var saved = MinecartManager()
        guard let savedID = saved.place(at: (originX, deck, saveZ), in: world) else {
            report.check("a cart can be placed to save", false, "placement failed")
            finish(report)
        }
        saved.shove(savedID, speed: 3.4, heading: .east)
        saved.setCargo(ItemStack(.rawGold, count: 5), for: savedID)
        let beforeSave = saved.cart(savedID)

        let snapshot = WorldSave(
            seed: world.seed, mode: .survival, name: "rail check",
            lastPlayed: Date().timeIntervalSince1970, edits: world.editJournal,
            position: spawn, yaw: 0, pitch: 0,
            inventory: Inventory(), stats: PlayerStats(), timeOfDay: 0.3,
            minecarts: saved
        )
        let fileURL = WorldSave.directoryURL.appendingPathComponent("rail-check.json")
        do {
            try snapshot.save(to: fileURL)
        } catch {
            report.check("the save writes", false, "\(error)")
        }
        if let reloaded = WorldSave.load(from: fileURL) {
            var restored = MinecartManager()
            restored.restore(reloaded.restoredMinecarts)
            let back = restored.carts.values.first
            report.check(
                "a cart's position, heading and speed all survive a save and reload",
                back != nil
                    && abs((back?.position.x ?? 0) - (beforeSave?.position.x ?? -1)) < 0.001
                    && abs((back?.position.y ?? 0) - (beforeSave?.position.y ?? -1)) < 0.001
                    && abs((back?.position.z ?? 0) - (beforeSave?.position.z ?? -1)) < 0.001
                    && back?.heading == beforeSave?.heading
                    && abs((back?.speed ?? 0) - (beforeSave?.speed ?? -1)) < 0.001,
                "before: \(String(describing: beforeSave)), after: \(String(describing: back))"
            )
            report.check(
                "and its cargo survives with it",
                back?.cargo?.type == .rawGold && back?.cargo?.count == 5,
                "cargo: \(String(describing: back?.cargo))"
            )
        } else {
            report.check("the save reloads", false, "WorldSave.load returned nil")
        }
        try? FileManager.default.removeItem(at: fileURL)

        finish(report)
    }

    private static func finish(_ report: Report) -> Never {
        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the rails\n"
            : "[check] all passed — the rails\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

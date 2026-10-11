import Foundation

/// Headless proof that the house blocks can be *played* — placed the way
/// the player is facing, opened, slept in, broken back into one item, and
/// found again after a save and a reload.
///
/// `ShapedBlockCheck` covers walking into them. This covers everything the
/// right mouse button does, which is the half that cannot be seen in a
/// picture either: a screenshot of a door says nothing about whether it
/// swings, whether breaking the top half takes the bottom one with it, or
/// whether the bed you slept in is still your spawn after quitting.
///
/// None of it needs a window, because none of the rules live in the view
/// controller: `ShapedPlacement`, `BedInteraction` and `WorldSave` are what
/// `GameViewController` calls, and they are what this calls. The one piece
/// of wiring that *is* asserted here is the targeting raycast, because
/// leaving it out is how an open door came to be unclosable: the controller
/// only ever acts on the cell `VoxelRaycast` returns, so a door the ray
/// cannot see is a door nothing can be done to. The door section below aims
/// with the real raycast and acts on what it hands back.
///
/// `BLOCKHAVEN_CHECK_HOUSE=1`, with `BLOCKHAVEN_SAVE_DIR` pointing somewhere
/// disposable: the save round-trip writes a real file, and this refuses to
/// run without being told where. Exits nonzero if any line fails.
enum HouseBlockCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_HOUSE"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    /// Yaws that point at each of the four horizontal directions, so the
    /// facing tests read as "stand looking north" rather than as radians.
    private static let yaws: [(BlockFacing, CGFloat)] = [
        (.south, 0),
        (.east, .pi / 2),
        (.north, .pi),
        (.west, 3 * .pi / 2),
    ]

    static func run() -> Never {
        guard ProcessInfo.processInfo.environment["BLOCKHAVEN_SAVE_DIR"] != nil else {
            StandardError.write(Data("""
                [check] BLOCKHAVEN_CHECK_HOUSE writes a real save file and needs \
                BLOCKHAVEN_SAVE_DIR set to somewhere disposable.

                """.utf8))
            exit(78)
        }

        let world = World()
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dz in -2...2 {
            for dx in -2...2 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        // A cleared stone deck, exactly as the walking check builds one, so
        // nothing below is really a hill or a tree.
        let originX = Int(spawn.x) - 8, originZ = Int(spawn.z) - 8
        var highest = 0
        for z in originZ...(originZ + 16) {
            for x in originX...(originX + 16) {
                var top = Chunk.height - 1
                while top > 0, !world.block(worldX: x, y: top, worldZ: z).isSolid { top -= 1 }
                highest = max(highest, top)
            }
        }
        let deck = highest + 2
        let ground = deck + 1
        guard deck + 8 < Chunk.height else {
            StandardError.write(Data("[check] no headroom over the terrain\n".utf8))
            exit(2)
        }
        for z in originZ...(originZ + 16) {
            for x in originX...(originX + 16) {
                world.setBlock(worldX: x, y: deck, worldZ: z, to: .stone, remesh: false)
                for y in ground...(deck + 6) {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }

        var report = Report()

        // MARK: stairs take the facing the player is looking
        var stairsRight = true
        var stairDetail: [String] = []
        for (index, (facing, yaw)) in yaws.enumerated() {
            let cell = (x: originX + 2 + index * 2, y: ground, z: originZ + 2)
            guard let edits = ShapedPlacement.edits(
                for: .oakStairs, at: cell, yaw: yaw, world: world
            ), edits.count == 1 else {
                stairsRight = false
                stairDetail.append("\(facing): refused")
                continue
            }
            ShapedPlacement.apply(edits, to: world)
            let placed = world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)
            // Both halves of the claim: the case is the one the constructor
            // makes, and its raw value is the one the mesher and the
            // collision table will look up.
            let wanted = BlockType.oakStairs(facing)
            if placed != wanted { stairsRight = false }
            stairDetail.append("\(facing)→raw \(placed.rawValue)/\(wanted.rawValue)")
        }
        report.check(
            "stairs face the way the player looks",
            stairsRight,
            stairDetail.joined(separator: ", ")
        )

        // A staircase item always drops itself, whichever way it is turned.
        report.check(
            "a stair drops its own item whatever the facing",
            BlockFacing.allCases.allSatisfy { BlockType.oakStairs($0).drop == .oakStairs }
                && BlockFacing.allCases.allSatisfy {
                    BlockType.cobbleStairs($0).drop == .cobbleStairs
                },
            "4 oak facings and 4 cobble facings"
        )

        // Stairs inherit the *whole* of their material's mining rules, not
        // just its hardness. Cobblestone gives nothing to bare hands, so
        // neither can a staircase cut from it — otherwise the fastest way
        // to a free block of stone is to craft it into stairs first.
        report.check(
            "stairs demand the same tool as the block they are cut from",
            BlockFacing.allCases.allSatisfy {
                BlockType.cobbleStairs($0).minimumTier == BlockType.cobblestone.minimumTier
                    && BlockType.cobbleStairs($0).requiresTool
                    && BlockType.oakStairs($0).minimumTier == BlockType.planks.minimumTier
                    && !BlockType.oakStairs($0).requiresTool
            },
            "cobble stairs \(BlockType.cobbleStairs(.north).minimumTier)"
                + " vs cobblestone \(BlockType.cobblestone.minimumTier);"
                + " oak stairs \(BlockType.oakStairs(.north).minimumTier)"
                + " vs planks \(BlockType.planks.minimumTier)"
        )

        // MARK: a door goes in as two cells and swings as two cells
        let doorCell = (x: originX + 4, y: ground, z: originZ + 6)
        // Looking north (yaw π) from the south side: the panel should end
        // up on the south edge, facing the player.
        guard let doorEdits = ShapedPlacement.edits(
            for: .oakDoor, at: doorCell, yaw: .pi, world: world
        ) else {
            StandardError.write(Data("[check] the door would not place at all\n".utf8))
            exit(1)
        }
        ShapedPlacement.apply(doorEdits, to: world)
        let lower = world.block(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z)
        let upper = world.block(worldX: doorCell.x, y: doorCell.y + 1, worldZ: doorCell.z)
        report.check(
            "a door places as two halves facing the player",
            lower == .oakDoor(.lower, facing: .south, open: false)
                && upper == .oakDoor(.upper, facing: .south, open: false),
            "lower \(lower), upper \(upper)"
        )

        // Opened from the top half, so the toggle has to find the other one
        // by looking rather than by being handed it.
        let upperCell = (x: doorCell.x, y: doorCell.y + 1, z: doorCell.z)
        if let toggle = ShapedPlacement.doorToggleEdits(at: upperCell, world: world) {
            ShapedPlacement.apply(toggle, to: world)
        }
        let openLower = world.block(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z)
        let openUpper = world.block(worldX: upperCell.x, y: upperCell.y, worldZ: upperCell.z)
        report.check(
            "opening a door opens both halves",
            openLower.doorIsOpen && openUpper.doorIsOpen
                && !openLower.isSolid && !openUpper.isSolid
                && openLower.doorFacing == .south && openUpper.doorFacing == .south,
            "lower \(openLower), upper \(openUpper)"
        )

        if let toggle = ShapedPlacement.doorToggleEdits(at: doorCell, world: world) {
            ShapedPlacement.apply(toggle, to: world)
        }
        let shutLower = world.block(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z)
        let shutUpper = world.block(worldX: upperCell.x, y: upperCell.y, worldZ: upperCell.z)
        report.check(
            "closing it puts both halves back",
            shutLower == lower && shutUpper == upper,
            "lower \(shutLower), upper \(shutUpper)"
        )

        // MARK: a closing door spares the player, box-precisely
        //
        // swingDoor tests the closing panel's boxes against the player
        // rather than the whole doorway cell: standing in the doorway
        // clear of where the panel lands is fine, and opening can never
        // be refused because an open door has no boxes at all. Checked
        // with the same predicate on the same edits swingDoor guards.
        if let reopen = ShapedPlacement.doorToggleEdits(at: doorCell, world: world) {
            ShapedPlacement.apply(reopen, to: world)
        }
        let closeEdits = ShapedPlacement.doorToggleEdits(at: doorCell, world: world) ?? []
        let panelEdit = closeEdits.first { !$0.block.collisionBoxes.isEmpty }
        let centred = PlayerController(spawn: Vector3(
            CGFloat(doorCell.x) + 0.5, CGFloat(doorCell.y), CGFloat(doorCell.z) + 0.5))
        let inPanel = panelEdit.map { edit -> PlayerController in
            let box = edit.block.collisionBoxes[0]
            return PlayerController(spawn: Vector3(
                CGFloat(edit.x) + (box.minX + box.maxX) / 2,
                CGFloat(doorCell.y),
                CGFloat(edit.z) + (box.minZ + box.maxZ) / 2))
        }
        report.check(
            "closing a door spares a clear player and refuses a wedged one",
            !closeEdits.isEmpty && panelEdit != nil
                && !closeEdits.contains {
                    centred.overlaps(boxes: $0.block.collisionBoxes, blockX: $0.x, y: $0.y, z: $0.z)
                }
                && closeEdits.contains {
                    inPanel!.overlaps(boxes: $0.block.collisionBoxes, blockX: $0.x, y: $0.y, z: $0.z)
                },
            "close edits \(closeEdits.count), panel edit \(panelEdit == nil ? "missing" : "found")"
        )
        // Leave the door the way the next section expects it: closed.
        ShapedPlacement.apply(closeEdits, to: world)

        // MARK: the crosshair can find the door — open as well as closed
        //
        // This is the wiring the rest of this file deliberately skips, and
        // it is where the feature broke: the game acts only on the cell
        // `VoxelRaycast` hands it, and the ray used to stop at `isSolid`.
        // An open door is not solid, so the ray walked straight through it
        // — and a door you cannot aim at can never be closed, mined or even
        // highlighted again. Every line below aims the way a player does,
        // through `VoxelRaycast`, and acts on what comes back.
        func aim(at cell: (x: Int, y: Int, z: Int)) -> VoxelRayHit? {
            VoxelRaycast.cast(
                from: Vector3(CGFloat(cell.x) - 2.5, CGFloat(cell.y) + 0.5, CGFloat(cell.z) + 0.5),
                direction: Vector3(1, 0, 0),
                maxDistance: 5,
                world: world
            )
        }
        func hits(_ hit: VoxelRayHit?, _ cell: (x: Int, y: Int, z: Int)) -> Bool {
            guard let hit else { return false }
            return hit.blockX == cell.x && hit.blockY == cell.y && hit.blockZ == cell.z
        }
        func describe(_ hit: VoxelRayHit?) -> String {
            guard let hit else { return "no hit" }
            return "\(hit.block) at \(hit.blockX),\(hit.blockY),\(hit.blockZ)"
        }

        let closedHit = aim(at: doorCell)
        report.check(
            "the crosshair finds a closed door",
            hits(closedHit, doorCell) && closedHit?.block.isDoor == true,
            describe(closedHit)
        )

        if let toggle = ShapedPlacement.doorToggleEdits(at: doorCell, world: world) {
            ShapedPlacement.apply(toggle, to: world)
        }
        let openLowerHit = aim(at: doorCell)
        let openUpperHit = aim(at: upperCell)
        report.check(
            "the crosshair still finds it once it is open",
            hits(openLowerHit, doorCell) && hits(openUpperHit, upperCell)
                && openLowerHit?.block.doorIsOpen == true
                && openLowerHit?.block.isInteractive == true
                && openUpperHit?.block.doorIsOpen == true,
            "lower: \(describe(openLowerHit)); upper: \(describe(openUpperHit))"
        )

        // The round trip a player makes: right-click, walk through,
        // right-click again. The second click acts on the raycast's cell,
        // not on a cell this check picked.
        if let hit = openLowerHit,
           let toggle = ShapedPlacement.doorToggleEdits(
               at: (x: hit.blockX, y: hit.blockY, z: hit.blockZ), world: world
           ) {
            ShapedPlacement.apply(toggle, to: world)
        }
        report.check(
            "right-clicking an open door closes it again",
            world.block(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z) == lower
                && world.block(worldX: upperCell.x, y: upperCell.y, worldZ: upperCell.z) == upper,
            "lower \(world.block(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z)),"
                + " upper \(world.block(worldX: upperCell.x, y: upperCell.y, worldZ: upperCell.z))"
        )

        // Open again, and prove the other half of the same mistake: an open
        // door's cell is not free ground. Placing into it would delete one
        // half and leave the other floating, unbreakable and unclosable.
        if let toggle = ShapedPlacement.doorToggleEdits(at: doorCell, world: world) {
            ShapedPlacement.apply(toggle, to: world)
        }
        report.check(
            "an open door's cells refuse a block placed into them",
            !ShapedPlacement.isReplaceable(doorCell, world)
                && !ShapedPlacement.isReplaceable(upperCell, world)
                && ShapedPlacement.edits(
                    for: .oakStairs, at: doorCell, yaw: 0, world: world
                ) == nil,
            "lower \(world.block(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z))"
        )

        // And mining it: the cell the ray returns is the one `breakBlock`
        // clears, both halves of it.
        if let hit = aim(at: doorCell) {
            for cell in ShapedPlacement.removalCells(
                of: hit.block, at: (x: hit.blockX, y: hit.blockY, z: hit.blockZ), world: world
            ) {
                world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .air)
            }
        }
        report.check(
            "an open door can be mined away",
            world.block(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z) == .air
                && world.block(worldX: upperCell.x, y: upperCell.y, worldZ: upperCell.z) == .air,
            "lower \(world.block(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z)),"
                + " upper \(world.block(worldX: upperCell.x, y: upperCell.y, worldZ: upperCell.z))"
        )

        // MARK: breaking either half takes both and drops one item
        var breakLines: [String] = []
        var breakOK = true
        for (name, clicked) in [("bottom", doorCell), ("top", upperCell)] {
            // Rebuild the door each time, so both directions are tested from
            // the same start.
            ShapedPlacement.apply(doorEdits, to: world)
            let block = world.block(worldX: clicked.x, y: clicked.y, worldZ: clicked.z)
            let cells = ShapedPlacement.removalCells(of: block, at: clicked, world: world)
            for cell in cells {
                world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .air)
            }
            let clearedBoth = world.block(worldX: doorCell.x, y: doorCell.y, worldZ: doorCell.z) == .air
                && world.block(worldX: upperCell.x, y: upperCell.y, worldZ: upperCell.z) == .air
            let oneItem = block.drop == .oakDoor
            if cells.count != 2 || !clearedBoth || !oneItem { breakOK = false }
            breakLines.append("\(name): \(cells.count) cells cleared, drop \(String(describing: block.drop))")
        }
        report.check("breaking either door half clears both and drops one door", breakOK,
                     breakLines.joined(separator: "; "))

        // MARK: a bed goes in head-away, and breaks the same way
        let bedCell = (x: originX + 8, y: ground, z: originZ + 10)
        guard let bedEdits = ShapedPlacement.edits(
            for: .bed, at: bedCell, yaw: .pi / 2, world: world  // looking east
        ) else {
            StandardError.write(Data("[check] the bed would not place at all\n".utf8))
            exit(1)
        }
        ShapedPlacement.apply(bedEdits, to: world)
        let foot = world.block(worldX: bedCell.x, y: bedCell.y, worldZ: bedCell.z)
        let head = world.block(worldX: bedCell.x + 1, y: bedCell.y, worldZ: bedCell.z)
        report.check(
            "a bed places foot-first with its head away from the player",
            foot == .bed(.foot, facing: .east) && head == .bed(.head, facing: .east),
            "foot \(foot) at \(bedCell.x), head \(head) at \(bedCell.x + 1)"
        )

        // MARK: sleeping
        let dayOutcome = BedInteraction.sleep(at: bedCell, world: world, isNight: false)
        report.check(
            "a bed used by day refuses and says so",
            dayOutcome == .tooEarly,
            "\(String(describing: dayOutcome))"
        )

        // Clicked on the *head*, to prove the spawn lands on the foot either
        // way — one bed, one respawn point.
        let headCell = (x: bedCell.x + 1, y: bedCell.y, z: bedCell.z)
        let nightOutcome = BedInteraction.sleep(at: headCell, world: world, isNight: true)
        let expectedSpawn = BedSpawn(x: bedCell.x, y: bedCell.y, z: bedCell.z)
        report.check(
            "a bed used at night sets the respawn point to its foot",
            nightOutcome == .slept(spawn: expectedSpawn),
            "\(String(describing: nightOutcome)), wanted \(expectedSpawn)"
        )

        // The clock the sleep moves to has to be a time the sky agrees is
        // morning — otherwise waking up would leave the bed usable again.
        let wasNight = SkyClock.isNight(at: 0.75)
        let stillNight = SkyClock.isNight(at: BedInteraction.morning)
        report.check(
            "sleeping lands on a morning the sky calls day",
            wasNight && !stillNight,
            String(format: "midnight 0.75 → %@, morning %.2f → %@ (%@)",
                   wasNight ? "night" : "day", BedInteraction.morning,
                   stillNight ? "still night" : "day",
                   SkyClock.clockText(at: BedInteraction.morning))
        )

        var bedBreakOK = true
        var bedBreakLines: [String] = []
        for (name, clicked) in [("foot", bedCell), ("head", headCell)] {
            ShapedPlacement.apply(bedEdits, to: world)
            let block = world.block(worldX: clicked.x, y: clicked.y, worldZ: clicked.z)
            let cells = ShapedPlacement.removalCells(of: block, at: clicked, world: world)
            for cell in cells {
                world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .air)
            }
            let clearedBoth = world.block(worldX: bedCell.x, y: bedCell.y, worldZ: bedCell.z) == .air
                && world.block(worldX: headCell.x, y: headCell.y, worldZ: headCell.z) == .air
            if cells.count != 2 || !clearedBoth || block.drop != .bed { bedBreakOK = false }
            bedBreakLines.append("\(name): \(cells.count) cells, drop \(String(describing: block.drop))")
        }
        report.check("breaking either bed half clears both and drops one bed", bedBreakOK,
                     bedBreakLines.joined(separator: "; "))

        // MARK: refusing cleanly
        //
        // The failure everything above is arranged to prevent: a two-cell
        // block whose second cell is occupied must place *neither* half.
        let blockedCell = (x: originX + 12, y: ground, z: originZ + 2)
        world.setBlock(worldX: blockedCell.x, y: blockedCell.y + 1, worldZ: blockedCell.z,
                       to: .cobblestone, remesh: false)
        let refusedDoor = ShapedPlacement.edits(
            for: .oakDoor, at: blockedCell, yaw: .pi, world: world
        )
        world.setBlock(worldX: blockedCell.x + 1, y: blockedCell.y, worldZ: blockedCell.z,
                       to: .cobblestone, remesh: false)
        let refusedBed = ShapedPlacement.edits(
            for: .bed, at: blockedCell, yaw: .pi / 2, world: world
        )
        report.check(
            "a two-cell block refuses rather than half-placing",
            refusedDoor == nil && refusedBed == nil
                && world.block(worldX: blockedCell.x, y: blockedCell.y,
                               worldZ: blockedCell.z) == .air,
            "door \(refusedDoor == nil ? "refused" : "placed"),"
                + " bed \(refusedBed == nil ? "refused" : "placed")"
        )

        // MARK: the save round-trip
        //
        // Every one of these is a raw value that has to survive JSON, and
        // the bed spawn is a field that has to survive being absent from
        // every save already on disk.
        let saveCell = (x: originX + 14, y: ground, z: originZ + 14)
        world.setBlock(worldX: saveCell.x, y: saveCell.y, worldZ: saveCell.z,
                       to: .cobbleStairs(.west))
        world.setBlock(worldX: saveCell.x, y: saveCell.y + 1, worldZ: saveCell.z,
                       to: .glassPane)
        world.setBlock(worldX: saveCell.x + 1, y: saveCell.y, worldZ: saveCell.z,
                       to: .oakDoor(.lower, facing: .north, open: true))
        world.setBlock(worldX: saveCell.x + 1, y: saveCell.y + 1, worldZ: saveCell.z,
                       to: .oakDoor(.upper, facing: .north, open: true))
        world.setBlock(worldX: saveCell.x + 2, y: saveCell.y, worldZ: saveCell.z,
                       to: .bed(.foot, facing: .south))
        world.setBlock(worldX: saveCell.x + 2, y: saveCell.y, worldZ: saveCell.z + 1,
                       to: .bed(.head, facing: .south))

        let inventory = Inventory()
        inventory.add(ItemStack(.oakStairs, count: 7))
        inventory.add(ItemStack(.bed, count: 1))
        let slept = BedSpawn(x: saveCell.x + 2, y: saveCell.y, z: saveCell.z)
        let snapshot = WorldSave(
            seed: world.seed,
            mode: .survival,
            name: "house check",
            lastPlayed: Date().timeIntervalSince1970,
            edits: world.editJournal,
            position: spawn,
            yaw: 0, pitch: 0,
            inventory: inventory,
            stats: PlayerStats(),
            timeOfDay: BedInteraction.morning,
            bedSpawn: slept
        )
        let fileURL = WorldSave.directoryURL.appendingPathComponent("house-check.json")
        do {
            try snapshot.save(to: fileURL)
        } catch {
            report.check("the save writes", false, "\(error)")
        }

        if let reloaded = WorldSave.load(from: fileURL) {
            let reopened = World(seed: reloaded.seed, edits: reloaded.editJournal)
            let centre = World.chunkCoord(forWorldX: saveCell.x, worldZ: saveCell.z)
            for dz in -1...1 {
                for dx in -1...1 {
                    reopened.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
                }
            }
            func there(_ dx: Int, _ dy: Int, _ dz: Int) -> BlockType {
                reopened.block(worldX: saveCell.x + dx, y: saveCell.y + dy, worldZ: saveCell.z + dz)
            }
            let stairsBack = there(0, 0, 0) == .cobbleStairs(.west)
            let paneBack = there(0, 1, 0) == .glassPane
            let doorBack = there(1, 0, 0) == .oakDoor(.lower, facing: .north, open: true)
                && there(1, 1, 0) == .oakDoor(.upper, facing: .north, open: true)
            let bedBack = there(2, 0, 0) == .bed(.foot, facing: .south)
                && there(2, 0, 1) == .bed(.head, facing: .south)
            report.check(
                "stairs, panes, an open door and a bed all survive a save and reload",
                stairsBack && paneBack && doorBack && bedBack,
                "stairs \(there(0, 0, 0)), pane \(there(0, 1, 0)),"
                    + " door \(there(1, 0, 0))/\(there(1, 1, 0)),"
                    + " bed \(there(2, 0, 0))/\(there(2, 0, 1))"
            )
            report.check(
                "the bed spawn survives with it",
                reloaded.bedSpawn == slept,
                "\(String(describing: reloaded.bedSpawn)), wanted \(slept)"
            )
            report.check(
                "the save is still a version 1 file",
                reloaded.version == 1 && WorldSave.currentVersion == 1,
                "version \(reloaded.version)"
            )
            report.check(
                "the shaped items come back in the inventory",
                reloaded.inventorySlots.contains { $0?.type == .oakStairs && $0?.count == 7 }
                    && reloaded.inventorySlots.contains { $0?.type == .bed },
                "\(reloaded.slots.map { "\($0.item)×\($0.count)" }.joined(separator: ", "))"
            )
        } else {
            report.check("the save reloads", false, "WorldSave.load returned nil for \(fileURL.path)")
        }

        // A save written by a build that never heard of beds — no key at all
        // — has to load, with no spawn rather than with a broken one. This
        // is the whole reason the field is `decodeIfPresent`.
        if var legacy = WorldSave.load(from: fileURL) {
            legacy.bedSpawn = nil
            let legacyURL = WorldSave.directoryURL.appendingPathComponent("house-check-legacy.json")
            try? legacy.save(to: legacyURL)
            let text = (try? String(contentsOf: legacyURL, encoding: .utf8)) ?? ""
            let back = WorldSave.load(from: legacyURL)
            report.check(
                "a save with no bed spawn still loads",
                back != nil && back?.bedSpawn == nil && !text.contains("bedSpawn"),
                "key written: \(text.contains("bedSpawn")), loaded: \(back != nil)"
            )
        }

        // MARK: the recipes are reachable
        var recipeLines: [String] = []
        var recipesOK = true
        let wanted: [(String, [[ItemType?]], ItemStack)] = [
            ("oak stairs", [
                [.planks, nil, nil],
                [.planks, .planks, nil],
                [.planks, .planks, .planks],
            ], ItemStack(.oakStairs, count: 4)),
            ("cobble stairs", [
                [.cobblestone, nil, nil],
                [.cobblestone, .cobblestone, nil],
                [.cobblestone, .cobblestone, .cobblestone],
            ], ItemStack(.cobbleStairs, count: 4)),
            ("oak door", [
                [.planks, .planks],
                [.planks, .planks],
                [.planks, .planks],
            ], ItemStack(.oakDoor, count: 3)),
            ("glass panes", [
                [.glass, .glass, .glass],
                [.glass, .glass, .glass],
            ], ItemStack(.glassPane, count: 8)),
            ("bed", [
                [.wool, .wool, .wool],
                [.planks, .planks, .planks],
            ], ItemStack(.bed, count: 1)),
        ]
        for (name, rows, expected) in wanted {
            var grid = CraftingGrid(size: 3)
            for (row, items) in rows.enumerated() {
                for (column, item) in items.enumerated() {
                    guard let item else { continue }
                    grid[row * 3 + column] = ItemStack(item)
                }
            }
            let result = RecipeBook.match(grid)
            if result != expected { recipesOK = false }
            recipeLines.append("\(name) → \(result.map { "\($0.type)×\($0.count)" } ?? "nothing")")
        }
        // Mirrored, because half the people laying out a staircase lay it
        // out the other way round.
        var mirrored = CraftingGrid(size: 3)
        for cell in [2, 4, 5, 6, 7, 8] { mirrored[cell] = ItemStack(.planks) }
        let mirroredResult = RecipeBook.match(mirrored)
        if mirroredResult != ItemStack(.oakStairs, count: 4) { recipesOK = false }
        recipeLines.append("mirrored stairs → \(mirroredResult.map { "\($0.type)×\($0.count)" } ?? "nothing")")

        // Glass without a furnace, in the 2×2 grid the player always has.
        var smelt = CraftingGrid(size: 2)
        smelt[0] = ItemStack(.sand)
        smelt[1] = ItemStack(.sand)
        smelt[2] = ItemStack(.coal)
        let smelted = RecipeBook.match(smelt)
        if smelted != ItemStack(.glass, count: 2) { recipesOK = false }
        recipeLines.append("sand+sand+coal → \(smelted.map { "\($0.type)×\($0.count)" } ?? "nothing")")

        report.check("every house recipe crafts", recipesOK, recipeLines.joined(separator: "; "))

        // MARK: the palette hands them over in creative
        let palette = Set(CreativeCatalogue.allItems)
        let missing = ShapedPlacement.placeableItems.filter { !palette.contains($0) }
        report.check(
            "the creative palette carries all five",
            missing.isEmpty,
            missing.isEmpty ? "oak stairs, cobble stairs, door, pane, bed"
                : "missing \(missing)"
        )

        report.lines.append(
            "[check] " + (report.failed ? "FAILED" : "all passed")
                + " — deck y \(deck), saves in \(WorldSave.directoryURL.path)"
        )
        StandardError.write(Data((report.lines.joined(separator: "\n") + "\n").utf8))
        exit(report.failed ? 1 : 0)
    }
}

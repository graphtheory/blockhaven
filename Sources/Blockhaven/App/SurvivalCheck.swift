#if canImport(AppKit)
import AppKit

/// Headless proof that survival costs something: that tools wear out and
/// break, that the wear on them survives a save, that the mode you are
/// playing decides whether any of it applies, and that hunger and air run
/// down the way the HUD claims they do.
///
/// A picture of the hotbar shows a bar under a pickaxe. It cannot show
/// that the bar reaches the end after exactly fifty-nine blocks, that the
/// sixtieth leaves the slot empty rather than a tool with negative life,
/// or that a world reopened tomorrow remembers how worn the pickaxe was.
/// So those are asserted here, against the same `Inventory`, `ItemStack`
/// and `WorldSave` the game uses.
///
/// `BLOCKHAVEN_CHECK_SURVIVAL=1`. Exits nonzero if any line fails.
enum SurvivalCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_SURVIVAL"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    static func run() -> Never {
        var report = Report()

        // MARK: every tool wears, and the ladder is worth climbing
        let tools = ItemType.allCases.filter { $0.toolClass != nil }
        let withoutLife = tools.filter { $0.durability == nil }
        let ladder: [ToolTier] = [.wood, .stone, .iron, .diamond]
        let lives = ladder.map { tier in
            tools.first { $0.toolTier == tier }?.durability ?? 0
        }
        report.check(
            "every tool has a life, and each tier outlasts the one below",
            withoutLife.isEmpty && zip(lives, lives.dropFirst()).allSatisfy { $0 < $1 },
            withoutLife.isEmpty
                ? "\(tools.count) tools, \(lives.map(String.init).joined(separator: " < ")) uses"
                : "no durability on \(withoutLife)"
        )
        // Nothing else may wear: a stack of dirt with a wear bar under it
        // is a slot the player cannot read.
        let wearable = ItemType.allCases.filter { $0.durability != nil }
        report.check(
            "only tools wear",
            Set(wearable) == Set(tools),
            "\(wearable.count) wearable items, \(tools.count) tools"
        )

        // MARK: a pickaxe lasts exactly as long as it says, then goes
        let bag = Inventory()
        bag[0] = ItemStack(.woodenPickaxe)
        bag.selectedHotbarSlot = 0
        let life = ItemType.woodenPickaxe.durability ?? 0
        var broke: ItemType?
        var brokeAfter = 0
        for use in 1...(life + 4) {
            if let broken = bag.wearHeldTool(), broke == nil {
                broke = broken
                brokeAfter = use
            }
        }
        report.check(
            "a wooden pickaxe breaks on its last use and leaves the slot empty",
            broke == .woodenPickaxe && brokeAfter == life && bag[0] == nil,
            "broke after \(brokeAfter) of \(life) uses, slot now"
                + " \(bag[0].map { "\($0.type)" } ?? "empty")"
        )

        // The bar under the icon is the same number seen from the side, so
        // it has to run down with it rather than alongside it.
        var halfWorn = ItemStack(.stonePickaxe)
        let stoneLife = ItemType.stonePickaxe.durability ?? 0
        for _ in 0..<(stoneLife / 2) { _ = halfWorn.wearOne() }
        let fraction = halfWorn.wearFraction ?? -1
        report.check(
            "the wear bar reads the uses left",
            abs(fraction - 0.5) < 0.02 && ItemStack(.stonePickaxe).wearFraction == nil,
            "half-worn reads \(String(format: "%.2f", fraction)),"
                + " and a fresh tool draws no bar at all"
        )

        // MARK: nothing that is not a tool can be worn out
        let blocks = Inventory()
        blocks[0] = ItemStack(.dirt, count: 64)
        blocks.selectedHotbarSlot = 0
        let blockBroke = blocks.wearHeldTool()
        report.check(
            "mining with a handful of dirt costs the dirt nothing",
            blockBroke == nil && blocks[0] == ItemStack(.dirt, count: 64),
            "slot still \(blocks[0].map { "\($0.type)×\($0.count)" } ?? "empty")"
        )

        // MARK: the mode decides whether any of this happens
        report.check(
            "tools wear in survival and never in creative",
            GameMode.survival.wearsTools && !GameMode.creative.wearsTools,
            "survival \(GameMode.survival.wearsTools), creative \(GameMode.creative.wearsTools)"
        )

        // MARK: the kit you start with is a survival kit
        let kit = Inventory()
        kit.grantStarterKit()
        let carried = (0..<Inventory.totalSize).compactMap { kit[$0]?.type }
        let stoneOrBetter = carried.filter { $0.toolClass != nil && $0.toolTier != .wood }
        report.check(
            "survival starts with a sword, and with nothing better than wood",
            carried.contains(.woodenSword) && stoneOrBetter.isEmpty
                && carried.contains(.woodenPickaxe),
            "\(carried.count) stacks: \(carried.map { $0.displayName }.joined(separator: ", "))")

        // A tool off the crafting grid is a new tool. Worn output would
        // make crafting a repair, which is a different game.
        let crafted = RecipeBook.all.filter { $0.output.type.durability != nil }
        report.check(
            "a crafted tool comes out unused",
            !crafted.isEmpty && crafted.allSatisfy { $0.output.wear == 0 },
            "\(crafted.count) tool recipes, all fresh"
        )

        // MARK: wear survives being written and read
        let saving = Inventory()
        saving[0] = ItemStack(.ironPickaxe, wear: 111)
        saving[9] = ItemStack(.cobblestone, count: 32)
        let store = ChestStore()
        let chest = store.chest(at: ChestStore.Key(3, 70, 9))
        chest.add(ItemStack(.diamondSword, wear: 7))
        let save = WorldSave(
            seed: 7, mode: .survival, name: "wear check", lastPlayed: 0, edits: [:],
            position: Vector3(0, 70, 0), yaw: 0, pitch: 0,
            inventory: saving, stats: PlayerStats(), timeOfDay: 0.2, chests: store
        )
        var reloaded: WorldSave?
        do {
            reloaded = try JSONDecoder().decode(
                WorldSave.self, from: try JSONEncoder().encode(save)
            )
        } catch {
            report.check("wear survives being written and read", false, "\(error)")
        }
        if let reloaded {
            let pick = reloaded.inventorySlots[0]
            let sword = reloaded.chestStore.existing(at: ChestStore.Key(3, 70, 9))?
                .contents.first { $0.type == .diamondSword }
            let stoneKey = reloaded.slots.first { $0.slot == 9 }?.wear
            report.check(
                "wear survives being written and read",
                pick == ItemStack(.ironPickaxe, wear: 111) && sword?.wear == 7 && stoneKey == nil,
                "pickaxe back at \(pick?.wear ?? -1)/\(ItemType.ironPickaxe.durability ?? 0),"
                    + " chest sword at \(sword?.wear ?? -1),"
                    + " and a stack of cobblestone writes no wear key"
            )
            // A file written before tools wore out has no key either, and
            // has to load as a tool with its whole life ahead of it.
            let legacy = WorldSave.SavedSlot(slot: 0, item: "woodenAxe", count: 1, wear: nil)
            let absurd = WorldSave.SavedSlot(slot: 1, item: "woodenAxe", count: 1, wear: 9_000)
            report.check(
                "a save from before tools wore out still loads",
                legacy.clampedWear(for: .woodenAxe) == 0
                    && absurd.clampedWear(for: .woodenAxe) == (ItemType.woodenAxe.durability ?? 1) - 1,
                "absent reads 0, and an impossible 9000 clamps to"
                    + " \(absurd.clampedWear(for: .woodenAxe)) rather than breaking the tool on load"
            )
        }

        // MARK: the body still runs down
        //
        // Hunger, starving and drowning are what the other half of the HUD
        // draws. They are pure arithmetic on a struct, so they are checked
        // here rather than left to whoever notices they stopped.
        var stats = PlayerStats()
        for _ in 0..<600 { stats.update(dt: 0.05, distanceMoved: 0.25, isSprinting: true, isSubmerged: false, isInLava: false) }
        let hungry = stats.hunger < PlayerStats.maxHunger
        var starving = PlayerStats()
        while starving.hunger > 0 {
            starving.update(dt: 0.05, distanceMoved: 0.5, isSprinting: true, isSubmerged: false, isInLava: false)
        }
        let healthBefore = starving.health
        for _ in 0..<200 { starving.update(dt: 0.05, distanceMoved: 0, isSprinting: false, isSubmerged: false, isInLava: false) }
        report.check(
            "running costs food, and an empty belly costs blood",
            hungry && starving.health < healthBefore,
            "sprinting 150 m left \(stats.hunger)/\(PlayerStats.maxHunger) drumsticks;"
                + " starving took \(healthBefore - starving.health) half-hearts"
        )

        var diving = PlayerStats()
        for _ in 0..<420 { diving.update(dt: 0.05, distanceMoved: 0, isSprinting: false, isSubmerged: true, isInLava: false) }
        let drowned = diving.air == 0 && diving.health < PlayerStats.maxHealth
        diving.update(dt: 0.05, distanceMoved: 0, isSprinting: false, isSubmerged: false, isInLava: false)
        report.check(
            "air runs out under water, and comes back at the surface",
            drowned && diving.air == PlayerStats.maxAir,
            "21 s under took air to 0 and health to"
                + " \(diving.health)/\(PlayerStats.maxHealth); one frame up refilled the air"
        )

        // MARK: a fizzler needs to see you before it blows your house up
        //
        // The complaint this answers is "the fizzlers eat all the houses".
        // They did: the fuse was lit on distance alone, and distance goes
        // through walls, so standing inside with one outside was enough to
        // take the wall out. A wall is an answer now, and the only way to
        // say that in a test is to build one.
        let world = World()
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dz in -1...1 {
            for dx in -1...1 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }
        let originX = Int(spawn.x), originZ = Int(spawn.z)
        // A flat stone yard, so neither body is standing in a hillside and
        // the only thing that can come between them is what is built here.
        let floorY = 40
        for z in (originZ - 6)...(originZ + 6) {
            for x in (originX - 6)...(originX + 6) {
                for y in (floorY - 1)...(floorY + 6) {
                    world.setBlock(
                        worldX: x, y: y, worldZ: z, to: y < floorY ? .stone : .air, remesh: false
                    )
                }
            }
        }

        let playerEye = Vector3(
            CGFloat(originX) + 0.5, CGFloat(floorY) + 1.62, CGFloat(originZ) + 0.5
        )
        /// Runs one fizzler for `seconds` against the world as it stands,
        /// answering whether it got as far as detonating.
        func runFizzler(seconds: Double) -> (exploded: Bool, fused: Bool) {
            var fizzler = Fizzler(
                position: Vector3(CGFloat(originX) + 0.5, CGFloat(floorY), CGFloat(originZ) + 2.5),
                seed: 99
            )
            var fused = false
            let frame = 1.0 / 60
            for _ in 0..<Int(seconds / frame) {
                let canSee = MobSight.canSee(from: fizzler.eyePosition, to: playerEye, world: world)
                fizzler.step(dt: frame, playerEye: playerEye, canSeePlayer: canSee, world: world)
                if fizzler.swell > 0 { fused = true }
                if fizzler.hasExploded { return (true, fused) }
            }
            return (false, fused)
        }

        let inTheOpen = runFizzler(seconds: 4)
        report.check(
            "a fizzler two blocks away in the open still goes off",
            inTheOpen.exploded,
            "fuse lit: \(inTheOpen.fused), detonated within 4 s: \(inTheOpen.exploded)"
        )

        // Now a house around the player: four walls and a roof, one block
        // thick, exactly as a player would build it — and the player
        // standing against the inside of the north wall, so the fizzler
        // outside is two blocks away and has a plank between. A single
        // free-standing wall is not the test: the fizzler simply walked
        // round the end of it, saw the player, and was right to.
        for y in (floorY - 1)...(floorY + 3) {
            for z in (originZ - 5)...(originZ + 1) {
                for x in (originX - 3)...(originX + 3) {
                    let interior = y >= floorY && y <= floorY + 2
                        && z >= originZ - 4 && z <= originZ
                        && x >= originX - 2 && x <= originX + 2
                    world.setBlock(
                        worldX: x, y: y, worldZ: z, to: interior ? .air : .planks, remesh: false
                    )
                }
            }
        }
        let indoors = MobSight.canSee(
            from: Vector3(CGFloat(originX) + 0.5, CGFloat(floorY) + 1.4, CGFloat(originZ) + 2.5),
            to: playerEye, world: world
        )
        let behindAWall = runFizzler(seconds: 6)
        report.check(
            "a wall between you is an answer \u{2014} the fuse never lights",
            !behindAWall.exploded && !behindAWall.fused && !indoors,
            "six seconds at two blocks through one plank:"
                + " sight \(indoors ? "clear" : "blocked"),"
                + " fuse lit \(behindAWall.fused), detonated \(behindAWall.exploded)"
        )
        // MARK: a torch is the wall you build against the night
        let yardX = originX + 4, yardZ = originZ - 4
        let darkYard = FizzlerManager.canSpawn(atX: yardX, y: floorY, z: yardZ, in: world)
        world.setBlock(worldX: yardX, y: floorY, worldZ: yardZ, to: .torch, remesh: false)
        let litYard = FizzlerManager.canSpawn(atX: yardX + 1, y: floorY, z: yardZ, in: world)
        let farYard = FizzlerManager.canSpawn(atX: yardX + 15, y: floorY, z: yardZ, in: world)
        report.check(
            "fizzlers spawn in the dark and not where a torch reaches",
            darkYard && !litYard && farYard,
            "unlit yard spawnable \(darkYard), beside a torch \(litYard),"
                + " fifteen blocks off \(farYard)"
        )

        // MARK: spawn always lands somewhere wood is a short walk away
        //
        // A fresh player starts with an empty inventory and a hunger clock
        // already running — nothing else hands out a starting kit. Seed 5
        // and seed 7 both used to land on desert or snowy ground with the
        // nearest tree 53+ blocks off, one of them beyond the old search's
        // own reach entirely. Every seed here is one of those two plus a
        // spread of others, checked directly against the biome a tree can
        // actually grow in rather than trusting the search found one.
        let strandedSeeds: [UInt64] = [1, 5, 7, 8, 20260823, 999_999]
        let strandedResults = strandedSeeds.map { seed -> (UInt64, WorldGenerator.Biome) in
            let spawn = World(seed: seed).spawnPosition()
            let gen = WorldGenerator(seed: seed)
            return (seed, gen.biome(x: Int(floor(spawn.x)), z: Int(floor(spawn.z))))
        }
        report.check(
            "every one of them lands in a biome that can actually grow a tree",
            strandedResults.allSatisfy { WorldGenerator.treeBiomes.contains($0.1) },
            "biomes: \(strandedResults.map { "\($0.0):\($0.1)" }.joined(separator: ", "))"
        )

        report.lines.append(
            "[check] " + (report.failed ? "FAILED" : "all passed")
                + " — \(tools.count) tools, wood lasts \(ItemType.woodenPickaxe.durability ?? 0) blocks"
        )
        StandardError.write(Data((report.lines.joined(separator: "\n") + "\n").utf8))
        exit(report.failed ? 1 : 0)
    }
}
#endif

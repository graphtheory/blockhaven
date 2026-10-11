import Foundation

/// Headless proof of the one thing worn rather than held: two chestplates
/// that blunt a hit, a burn or a blast, but do nothing at all against
/// starving or drowning — the two damage sources a chestplate was never
/// supposed to answer, and the reason `takeDamage` takes a `mitigable`
/// flag rather than reading a fraction off every caller by hand.
///
/// `BLOCKHAVEN_CHECK_ARMOR=1`. Exits nonzero if any line fails.
enum ArmorCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_ARMOR"] != nil
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

        // MARK: what a chestplate is, apart from what it does

        report.check(
            "iron and diamond are armor, nothing else is",
            ItemType.ironChestplate.isArmor && ItemType.diamondChestplate.isArmor
                && !ItemType.diamondSword.isArmor && !ItemType.woodenPickaxe.isArmor,
            "iron \(ItemType.ironChestplate.isArmor), diamond \(ItemType.diamondChestplate.isArmor), "
                + "sword \(ItemType.diamondSword.isArmor)"
        )
        report.check(
            "diamond blunts more than iron, and bare skin blunts nothing",
            ItemType.diamondChestplate.armorReduction > ItemType.ironChestplate.armorReduction
                && ItemType.ironChestplate.armorReduction > 0 && ItemType.woodenSword.armorReduction == 0,
            "iron \(ItemType.ironChestplate.armorReduction), diamond \(ItemType.diamondChestplate.armorReduction)"
        )
        report.check(
            "worn, not carried — a chestplate doesn't stack",
            ItemType.ironChestplate.maxStack == 1,
            "maxStack \(ItemType.ironChestplate.maxStack)"
        )

        // MARK: eight ingots, not a side effect of a haul

        let ironGrid = CraftingGrid(size: 3)
        var filled = ironGrid
        for index in [0, 2, 3, 4, 5, 6, 7, 8] { filled[index] = ItemStack(.ironIngot) }
        report.check(
            "eight iron ingots round a gap is a chestplate",
            RecipeBook.match(filled) == ItemStack(.ironChestplate),
            "matched \(String(describing: RecipeBook.match(filled)))"
        )
        var diamondFilled = CraftingGrid(size: 3)
        for index in [0, 2, 3, 4, 5, 6, 7, 8] { diamondFilled[index] = ItemStack(.diamond) }
        report.check(
            "the same ring in diamond is the diamond chestplate",
            RecipeBook.match(diamondFilled) == ItemStack(.diamondChestplate),
            "matched \(String(describing: RecipeBook.match(diamondFilled)))"
        )
        report.check(
            "too wide for the 2×2 grid every survival start carries",
            RecipeBook.all.first { $0.output.type == .ironChestplate }?.requiresTable == true,
            "requiresTable \(String(describing: RecipeBook.all.first { $0.output.type == .ironChestplate }?.requiresTable))"
        )

        // MARK: equipping is a swap, not a consumption

        var stats = PlayerStats()
        let nothingBefore = stats.equip(.ironChestplate)
        report.check(
            "equipping with nothing worn hands back nothing",
            nothingBefore == nil && stats.equippedChestplate == .ironChestplate,
            "returned \(String(describing: nothingBefore)), now wearing \(String(describing: stats.equippedChestplate))"
        )
        let ironBack = stats.equip(.diamondChestplate)
        report.check(
            "equipping a second piece hands back the first, not the new one",
            ironBack == .ironChestplate && stats.equippedChestplate == .diamondChestplate,
            "returned \(String(describing: ironBack)), now wearing \(String(describing: stats.equippedChestplate))"
        )
        let diamondBack = stats.equip(nil)
        report.check(
            "unequipping bare hands back what was worn and leaves nothing on",
            diamondBack == .diamondChestplate && stats.equippedChestplate == nil,
            "returned \(String(describing: diamondBack)), now wearing \(String(describing: stats.equippedChestplate))"
        )

        // MARK: a chestplate blunts a hit, and a better one blunts it more

        var bare = PlayerStats()
        var ironWorn = PlayerStats()
        ironWorn.equip(.ironChestplate)
        var diamondWorn = PlayerStats()
        diamondWorn.equip(.diamondChestplate)
        bare.takeDamage(10, mitigable: true)
        ironWorn.takeDamage(10, mitigable: true)
        diamondWorn.takeDamage(10, mitigable: true)
        report.check(
            "ten mitigable damage costs less health in iron than bare, and less still in diamond",
            bare.health < ironWorn.health && ironWorn.health < diamondWorn.health,
            "bare \(bare.health), iron \(ironWorn.health), diamond \(diamondWorn.health) (of \(PlayerStats.maxHealth))"
        )
        report.check(
            "the numbers match the fractions: iron 20%, diamond 40%, floored",
            (PlayerStats.maxHealth - ironWorn.health) == 8 && (PlayerStats.maxHealth - diamondWorn.health) == 6,
            "iron lost \(PlayerStats.maxHealth - ironWorn.health), diamond lost \(PlayerStats.maxHealth - diamondWorn.health)"
        )

        var alwaysSomeDamage = PlayerStats()
        alwaysSomeDamage.equip(.diamondChestplate)
        alwaysSomeDamage.takeDamage(1, mitigable: true)
        report.check(
            "armor blunts a hit, it never cancels one — chip damage still lands",
            alwaysSomeDamage.health == PlayerStats.maxHealth - 1,
            "health after one point of diamond-mitigated damage: \(alwaysSomeDamage.health)"
        )

        // MARK: starving and drowning don't care what's worn

        var starvingBare = PlayerStats()
        var starvingArmored = PlayerStats()
        starvingArmored.equip(.diamondChestplate)
        while starvingBare.hunger > 0 {
            starvingBare.update(dt: 0.05, distanceMoved: 0.5, isSprinting: true, isSubmerged: false, isInLava: false)
        }
        while starvingArmored.hunger > 0 {
            starvingArmored.update(
                dt: 0.05, distanceMoved: 0.5, isSprinting: true, isSubmerged: false, isInLava: false
            )
        }
        for _ in 0..<200 {
            starvingBare.update(dt: 0.05, distanceMoved: 0, isSprinting: false, isSubmerged: false, isInLava: false)
            starvingArmored.update(
                dt: 0.05, distanceMoved: 0, isSprinting: false, isSubmerged: false, isInLava: false
            )
        }
        report.check(
            "starving costs the same in diamond as bare-chested",
            starvingBare.health == starvingArmored.health,
            "bare \(starvingBare.health), diamond-armored \(starvingArmored.health)"
        )

        // MARK: it does answer the one hazard that already burns through gear

        var burningBare = PlayerStats()
        var burningArmored = PlayerStats()
        burningArmored.equip(.diamondChestplate)
        for _ in 0..<25 {
            burningBare.update(dt: 0.05, distanceMoved: 0, isSprinting: false, isSubmerged: false, isInLava: true)
            burningArmored.update(dt: 0.05, distanceMoved: 0, isSprinting: false, isSubmerged: false, isInLava: true)
        }
        report.check(
            "a diamond chestplate blunts a lava burn same as any other mitigable hit",
            burningArmored.health > burningBare.health,
            "bare \(burningBare.health), diamond-armored \(burningArmored.health) after 1.25s in lava"
        )

        // MARK: a save remembers what was worn, forgivingly

        let inventory = Inventory()
        var savedStats = PlayerStats()
        savedStats.equip(.diamondChestplate)
        let save = WorldSave(
            seed: 1, mode: .survival, name: "Armor test", lastPlayed: 0,
            edits: [:], position: Vector3(0, 70, 0), yaw: 0, pitch: 0,
            inventory: inventory, stats: savedStats, timeOfDay: 0
        )
        report.check(
            "what's worn round-trips through a save",
            save.equippedChestplate == .diamondChestplate,
            "decoded \(String(describing: save.equippedChestplate))"
        )
        var bareSave = save
        bareSave.equippedChestplateRaw = nil
        report.check(
            "a file with nothing worn comes back bare-chested, not crashed",
            bareSave.equippedChestplate == nil,
            "decoded \(String(describing: bareSave.equippedChestplate))"
        )
        var futureSave = save
        futureSave.equippedChestplateRaw = "goldHelmet"
        report.check(
            "a name this build has never heard of drops out rather than throwing",
            futureSave.equippedChestplate == nil,
            "decoded \(String(describing: futureSave.equippedChestplate))"
        )

        // MARK: filed on a shelf, not lost in the catch-all

        report.check(
            "both chestplates are filed under Tools, not dumped in the catch-all",
            CreativeCatalogue.shelf(for: .ironChestplate) == .tools
                && CreativeCatalogue.shelf(for: .diamondChestplate) == .tools,
            "iron shelf \(CreativeCatalogue.shelf(for: .ironChestplate)), "
                + "diamond shelf \(CreativeCatalogue.shelf(for: .diamondChestplate))"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the armor\n"
            : "[check] all passed — the armor\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

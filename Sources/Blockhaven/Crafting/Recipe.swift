import Foundation

/// A crafting recipe. Shaped recipes care where ingredients sit relative to
/// each other (and are matched at any offset within the grid, so a 2×2
/// pattern works in the top-left or bottom-right of a 3×3 table); shapeless
/// ones only care which items are present.
struct Recipe {
    enum Pattern {
        /// Rows of item slots, `nil` for empty. All rows equal length.
        case shaped([[ItemType?]])
        /// An unordered bag of ingredients.
        case shapeless([ItemType])
    }

    let pattern: Pattern
    let output: ItemStack

    /// Whether this recipe can physically be laid out on a square grid of
    /// this size — a 3-wide pattern has nowhere to go in a 2×2.
    func fits(gridSize: Int) -> Bool {
        switch pattern {
        case .shaped(let rows):
            return rows.count <= gridSize && rows.allSatisfy { $0.count <= gridSize }
        case .shapeless(let items):
            return items.count <= gridSize * gridSize
        }
    }

    /// What the three pieces of the old network unlock. Until all three
    /// are recorded these recipes are not offered in survival — the
    /// storyline's one gate, and the only recipe gate in the game.
    var isExpeditionRecipe: Bool {
        switch output.type {
        case .launchPad, .rocket, .spaceSuit, .airMaker: return true
        default: return false
        }
    }

    /// Recipes wider or taller than 2 need a crafting table — which is the
    /// same statement as "won't fit in the grid you carry around".
    var requiresTable: Bool { !fits(gridSize: 2) }

    /// How many of each ingredient one craft costs.
    var ingredientCounts: [ItemType: Int] {
        var needed: [ItemType: Int] = [:]
        switch pattern {
        case .shaped(let rows):
            for row in rows {
                for item in row {
                    guard let item else { continue }
                    needed[item, default: 0] += 1
                }
            }
        case .shapeless(let items):
            for item in items { needed[item, default: 0] += 1 }
        }
        return needed
    }

    /// Which shelf of the recipe book this sits on, decided by what it
    /// makes rather than what it is made of: a child looking for stairs
    /// looks under the things you build a house out of, not under wood.
    enum Group: Int, CaseIterable {
        case wood, stoneAndGlass, house, tools, expedition, other

        var title: String {
            switch self {
            case .wood: return L10n.t("Wood", "Trä")
            case .stoneAndGlass: return L10n.t("Stone & Glass", "Sten & glas")
            case .house: return L10n.t("House", "Hus")
            case .tools: return L10n.t("Tools", "Verktyg")
            case .expedition: return L10n.t("Expedition", "Expedition")
            case .other: return L10n.t("Other", "Övrigt")
            }
        }
    }

    /// `.other` is the shelf nothing should land on: `RecipeBookCheck`
    /// fails if anything does, so a newly added recipe has to be filed.
    var group: Group {
        switch output.type {
        case .planks, .stick, .craftingTable, .chest:
            return .wood
        case .stone, .sandstone, .sandstoneCarved, .glass, .brick, .ironIngot, .goldIngot,
             .goldBlock, .seaStone, .diamondBlock, .sandstonePillar, .pillarCapital,
             .plaster:
            return .stoneAndGlass
        case .oakStairs, .cobbleStairs, .oakDoor, .glassPane, .bed, .torch, .tnt,
             .rail, .poweredRail, .detectorRail, .minecart, .seaLantern, .furnace, .lever, .wire, .hopper,
             .pressurePlate, .signalTorch, .signalRelay, .daylightSensor, .signalLamp,
             .radiantRed, .radiantYellow, .radiantGreen, .radiantCyan, .glowCrystal,
             .pearlLight, .timberFrame, .cloud, .balloonCanvas:
            return .house
        case .hoe, .bucket, .compass, .masonLine, .blueprint, .ironChestplate, .diamondChestplate:
            return .tools
        case .radio, .launchPad, .rocket, .spaceSuit, .airMaker, .silverThatch:
            return .expedition
        default:
            return output.type.toolClass != nil ? .tools : .other
        }
    }
}

/// A square crafting grid — 2×2 in the inventory, 3×3 at a table.
struct CraftingGrid {
    let size: Int
    private(set) var slots: [ItemStack?]

    init(size: Int) {
        self.size = size
        slots = Array(repeating: nil, count: size * size)
    }

    subscript(index: Int) -> ItemStack? {
        get { slots.indices.contains(index) ? slots[index] : nil }
        set {
            guard slots.indices.contains(index) else { return }
            slots[index] = newValue
        }
    }

    var isEmpty: Bool { slots.allSatisfy { $0 == nil } }

    mutating func clear() {
        slots = Array(repeating: nil, count: size * size)
    }

    /// Removes one of everything on the grid — one craft's worth.
    mutating func consumeOne() {
        for index in slots.indices {
            guard var stack = slots[index] else { continue }
            stack.count -= 1
            slots[index] = stack.count > 0 ? stack : nil
        }
    }

    /// The types laid out as a rectangular grid of the occupied region,
    /// trimmed of empty border rows/columns so a shape matches wherever
    /// the player put it.
    func trimmedShape() -> [[ItemType?]] {
        var minRow = size, maxRow = -1, minCol = size, maxCol = -1
        for row in 0..<size {
            for col in 0..<size where slots[row * size + col] != nil {
                minRow = min(minRow, row); maxRow = max(maxRow, row)
                minCol = min(minCol, col); maxCol = max(maxCol, col)
            }
        }
        guard maxRow >= minRow, maxCol >= minCol else { return [] }
        return (minRow...maxRow).map { row in
            (minCol...maxCol).map { col in slots[row * size + col]?.type }
        }
    }

    /// Every non-empty item, for shapeless matching.
    func contents() -> [ItemType] {
        slots.compactMap { $0?.type }
    }
}

enum RecipeBook {
    static let all: [Recipe] = [
        // Wood chain
        Recipe(pattern: .shapeless([.log]), output: ItemStack(.planks, count: 4)),
        Recipe(pattern: .shaped([[.planks], [.planks]]), output: ItemStack(.stick, count: 4)),
        Recipe(pattern: .shaped([[.planks, .planks], [.planks, .planks]]),
               output: ItemStack(.craftingTable, count: 1)),
        // A ring of eight planks round an empty middle — the original's own
        // chest, and the one recipe in the game whose shape is a picture
        // of what it makes.
        Recipe(pattern: .shaped([
            [.planks, .planks, .planks],
            [.planks, nil, .planks],
            [.planks, .planks, .planks],
        ]), output: ItemStack(.chest, count: 1)),

        // Stone chain
        Recipe(pattern: .shaped([[.cobblestone, .cobblestone], [.cobblestone, .cobblestone]]),
               output: ItemStack(.stone, count: 1)),
        // A ring of eight cobblestone round an empty middle — the chest's
        // own recipe, in the stone the first furnace is always built from.
        Recipe(pattern: .shaped([
            [.cobblestone, .cobblestone, .cobblestone],
            [.cobblestone, nil, .cobblestone],
            [.cobblestone, .cobblestone, .cobblestone],
        ]), output: ItemStack(.furnace, count: 1)),
        // A ring of iron round a chest — the funnel is the chest's own
        // mouth, drawn narrower, which is exactly what a hopper does to
        // whatever passes through it.
        Recipe(pattern: .shaped([
            [.ironIngot, nil, .ironIngot],
            [.ironIngot, .chest, .ironIngot],
            [nil, .ironIngot, nil],
        ]), output: ItemStack(.hopper, count: 1)),
        Recipe(pattern: .shapeless([.sand, .sand, .sand, .sand]), output: ItemStack(.sandstone, count: 1)),
        // Raw iron and raw gold are ore, not ingots — smelting them takes a
        // furnace and a fire under it, not a grid. See `Furnace.swift`.
        Recipe(pattern: .shaped([[.ironIngot, .ironIngot], [.ironIngot, .ironIngot]]),
               output: ItemStack(.brick, count: 2)),
        // The pyramid's two blocks, craftable so finding them is not the
        // only way to have them: gold squared into a block, and sandstone
        // stacked and carved.
        Recipe(pattern: .shaped([[.goldIngot, .goldIngot], [.goldIngot, .goldIngot]]),
               output: ItemStack(.goldBlock, count: 1)),
        Recipe(pattern: .shaped([[.sandstone], [.sandstone]]),
               output: ItemStack(.sandstoneCarved, count: 2)),
        // The sunken city's pair: stone tinted by glass, and a lamp that is
        // glass with fire sealed inside it.
        Recipe(pattern: .shapeless([.cobblestone, .cobblestone, .glass]),
               output: ItemStack(.seaStone, count: 2)),
        Recipe(pattern: .shapeless([.glass, .glass, .torch, .torch]),
               output: ItemStack(.seaLantern, count: 1)),
        Recipe(pattern: .shaped([[.diamond, .diamond], [.diamond, .diamond]]),
               output: ItemStack(.diamondBlock, count: 1)),
        // The radiant lamps: a sea lantern stained with something the right
        // colour. The cactus is the odd one out because nothing else in
        // this world is reliably green and pickable.
        Recipe(pattern: .shapeless([.seaLantern, .poppy]),
               output: ItemStack(.radiantRed, count: 1)),
        Recipe(pattern: .shapeless([.seaLantern, .dandelion]),
               output: ItemStack(.radiantYellow, count: 1)),
        Recipe(pattern: .shapeless([.seaLantern, .cactus]),
               output: ItemStack(.radiantGreen, count: 1)),
        Recipe(pattern: .shapeless([.seaLantern, .cornflower]),
               output: ItemStack(.radiantCyan, count: 1)),
        // Glow Crystal: torchlight cooked into stone. Two blocks, because a
        // mineral you pave with should not cost a torch a block.
        Recipe(pattern: .shapeless([.stone, .torch, .torch]),
               output: ItemStack(.glowCrystal, count: 2)),
        // The pearl lamp: both stains at once, red and blue making pink.
        Recipe(pattern: .shapeless([.seaLantern, .poppy, .cornflower]),
               output: ItemStack(.pearlLight, count: 1)),

        // The painted columns: three sandstone stacked into a fluted
        // shaft — one taller than the carved block's two, because a
        // column is what a wall becomes when you keep going — and the
        // capital painted the way the temple painters painted them,
        // green from a cactus, red from a poppy, blue from a cornflower.
        Recipe(pattern: .shaped([[.sandstone], [.sandstone], [.sandstone]]),
               output: ItemStack(.sandstonePillar, count: 3)),
        Recipe(pattern: .shapeless([.sandstonePillar, .cactus, .poppy, .cornflower]),
               output: ItemStack(.pillarCapital, count: 1)),

        // The sky city's fabric. Plaster is lime the old way, sand and
        // crushed stone; cross it with sticks for half-timbering. The
        // softer pair are sewn rather than mixed: a cloud is wool made
        // weightless by feathers, and balloon canvas is wool dyed in
        // gores with a poppy.
        Recipe(pattern: .shapeless([.sand, .sand, .gravel]),
               output: ItemStack(.plaster, count: 4)),
        Recipe(pattern: .shapeless([.plaster, .stick, .stick]),
               output: ItemStack(.timberFrame, count: 2)),
        Recipe(pattern: .shapeless([.wool, .feather]),
               output: ItemStack(.cloud, count: 2)),
        Recipe(pattern: .shapeless([.wool, .wool, .poppy]),
               output: ItemStack(.balloonCanvas, count: 3)),

        // Glass. There is no furnace in this game, so smelting sand is a
        // recipe rather than a machine — without it glass is something you
        // can only find, and a survival house has no windows.
        Recipe(pattern: .shapeless([.sand, .sand, .coal]), output: ItemStack(.glass, count: 2)),

        // Light and the lack of it.
        //
        // Four torches from one coal, as the original gives, because the first
        // thing anyone does with a torch is use up eight of them lighting
        // one tunnel. TNT is the original's five-gunpowder recipe cut to four
        // in a square: gunpowder only drops from fizzlers here, five is
        // most of a night's hunting, and a block you are going to watch
        // explode once should not cost an evening.
        Recipe(pattern: .shaped([[.coal], [.stick]]), output: ItemStack(.torch, count: 4)),
        Recipe(pattern: .shaped([
            [.gunpowder, .sand],
            [.sand, .gunpowder],
        ]), output: ItemStack(.tnt, count: 1)),

        // Track. the original's rail is six iron and a stick for sixteen; this
        // keeps the shape and the generosity, because a track is measured in
        // hundreds of cells and a recipe that yields four is a recipe nobody
        // builds a coaster with. The powered one swaps the iron for gold,
        // which is the only thing gold is for in this game so far.
        Recipe(pattern: .shaped([
            [.ironIngot, nil, .ironIngot],
            [.ironIngot, .stick, .ironIngot],
            [.ironIngot, nil, .ironIngot],
        ]), output: ItemStack(.rail, count: 16)),
        Recipe(pattern: .shaped([
            [.goldIngot, nil, .goldIngot],
            [.goldIngot, .stick, .goldIngot],
            [.goldIngot, nil, .goldIngot],
        ]), output: ItemStack(.poweredRail, count: 6)),
        // The detector rail: a plate built into a length of track — the
        // iron border rail already costs, a plate for the sensing, and
        // yields far fewer than plain track does, the same reason a plate
        // itself only ever comes one at a time. A player lays one, not a
        // line of them.
        Recipe(pattern: .shaped([
            [.ironIngot, nil, .ironIngot],
            [.ironIngot, .pressurePlate, .ironIngot],
            [.ironIngot, nil, .ironIngot],
        ]), output: ItemStack(.detectorRail, count: 4)),
        Recipe(pattern: .shaped([
            [.ironIngot, nil, .ironIngot],
            [.ironIngot, .ironIngot, .ironIngot],
        ]), output: ItemStack(.minecart, count: 1)),

        // The signal. A lever is the original's own stick-on-cobblestone, kept
        // because it is exactly the shape a switch is — no table needed,
        // the first thing a new circuit costs. Wire drawn thin from an
        // ingot, generous the way rail is: a circuit is built in cells, not
        // in ones.
        Recipe(pattern: .shaped([[.stick], [.cobblestone]]), output: ItemStack(.lever, count: 1)),
        Recipe(pattern: .shapeless([.ironIngot]), output: ItemStack(.wire, count: 6)),
        // The plate. Two cobblestone side by side — nothing pressing it is
        // the whole shape, which is also why one is all a single craft
        // gives: a lever is thrown once and kept, a plate is a doorway you
        // build one of at a time.
        Recipe(pattern: .shaped([[.cobblestone, .cobblestone]]), output: ItemStack(.pressurePlate, count: 1)),
        // The torch that reads the network instead of just lighting a
        // room — an ordinary torch with an ingot's worth of wire wound
        // round the stick, the same iron every other signal part costs.
        Recipe(pattern: .shaped([[.ironIngot], [.torch]]), output: ItemStack(.signalTorch, count: 1)),
        // The relay. Twice the iron and twice the wire a plain length
        // costs, because what it buys is not another cell of reach but a
        // reset on the fifteen every other cell already has.
        Recipe(pattern: .shaped([
            [.ironIngot, .ironIngot],
            [.wire, .wire],
        ]), output: ItemStack(.signalRelay, count: 1)),
        // The sensor that reads the sky: a glass face to see it through, a
        // wired core to say so, and a plank base to stand the thing on.
        // Glass across the top is what makes it read as an instrument
        // pointed upward rather than another block with wire in it.
        Recipe(pattern: .shaped([
            [.glass, .glass, .glass],
            [.wire, .ironIngot, .wire],
            [.planks, .planks, .planks],
        ]), output: ItemStack(.daylightSensor, count: 1)),
        // The lamp the network can switch: a block of caught light with
        // wire run to all four sides, so the thing that lights it is
        // visibly the thing that carries current everywhere else.
        Recipe(pattern: .shaped([
            [nil, .wire, nil],
            [.wire, .glowCrystal, .wire],
            [nil, .wire, nil],
        ]), output: ItemStack(.signalLamp, count: 1)),

        // House blocks. All five are three cells wide or tall, so all five
        // want a crafting table — which is the same rule the original has and
        // the same one `requiresTable` already derives.
        Recipe(pattern: .shaped([
            [.planks, nil, nil],
            [.planks, .planks, nil],
            [.planks, .planks, .planks],
        ]), output: ItemStack(.oakStairs, count: 4)),
        Recipe(pattern: .shaped([
            [.cobblestone, nil, nil],
            [.cobblestone, .cobblestone, nil],
            [.cobblestone, .cobblestone, .cobblestone],
        ]), output: ItemStack(.cobbleStairs, count: 4)),
        Recipe(pattern: .shaped([
            [.planks, .planks],
            [.planks, .planks],
            [.planks, .planks],
        ]), output: ItemStack(.oakDoor, count: 3)),
        Recipe(pattern: .shaped([
            [.glass, .glass, .glass],
            [.glass, .glass, .glass],
        ]), output: ItemStack(.glassPane, count: 8)),
        Recipe(pattern: .shaped([
            [.wool, .wool, .wool],
            [.planks, .planks, .planks],
        ]), output: ItemStack(.bed, count: 1)),

        // Pickaxes — three heads over two sticks
        Recipe(pattern: .shaped([
            [.planks, .planks, .planks],
            [nil, .stick, nil],
            [nil, .stick, nil],
        ]), output: ItemStack(.woodenPickaxe)),
        Recipe(pattern: .shaped([
            [.cobblestone, .cobblestone, .cobblestone],
            [nil, .stick, nil],
            [nil, .stick, nil],
        ]), output: ItemStack(.stonePickaxe)),
        Recipe(pattern: .shaped([
            [.ironIngot, .ironIngot, .ironIngot],
            [nil, .stick, nil],
            [nil, .stick, nil],
        ]), output: ItemStack(.ironPickaxe)),
        Recipe(pattern: .shaped([
            [.diamond, .diamond, .diamond],
            [nil, .stick, nil],
            [nil, .stick, nil],
        ]), output: ItemStack(.diamondPickaxe)),

        // Axes
        Recipe(pattern: .shaped([
            [.planks, .planks],
            [.planks, .stick],
            [nil, .stick],
        ]), output: ItemStack(.woodenAxe)),
        Recipe(pattern: .shaped([
            [.cobblestone, .cobblestone],
            [.cobblestone, .stick],
            [nil, .stick],
        ]), output: ItemStack(.stoneAxe)),
        Recipe(pattern: .shaped([
            [.ironIngot, .ironIngot],
            [.ironIngot, .stick],
            [nil, .stick],
        ]), output: ItemStack(.ironAxe)),

        // Shovels — one head over two sticks
        Recipe(pattern: .shaped([[.planks], [.stick], [.stick]]), output: ItemStack(.woodenShovel)),
        Recipe(pattern: .shaped([[.cobblestone], [.stick], [.stick]]), output: ItemStack(.stoneShovel)),
        Recipe(pattern: .shaped([[.ironIngot], [.stick], [.stick]]), output: ItemStack(.ironShovel)),

        // Swords — two heads over one stick
        Recipe(pattern: .shaped([[.planks], [.planks], [.stick]]), output: ItemStack(.woodenSword)),
        Recipe(pattern: .shaped([[.cobblestone], [.cobblestone], [.stick]]), output: ItemStack(.stoneSword)),
        Recipe(pattern: .shaped([[.ironIngot], [.ironIngot], [.stick]]), output: ItemStack(.ironSword)),
        Recipe(pattern: .shaped([[.diamond], [.diamond], [.stick]]), output: ItemStack(.diamondSword)),

        // The hoe — one head over two sticks, like the other tools, but
        // one head is all it ever needs: it has no tier to grow into,
        // because tilling ground is a yes-or-no act, not a race against
        // hardness.
        Recipe(pattern: .shaped([[.planks, .planks], [nil, .stick], [nil, .stick]]), output: ItemStack(.hoe)),

        // Armor — a hollow ring of eight, the same picture-of-what-it-makes
        // shape as the chest above: a plate over the shoulders and a gap
        // for the head. Eight ingots is a full stack and a half of ore
        // smelted down, deliberately more than a sword and a pickaxe cost
        // together — armor is the investment a diamond haul buys, not a
        // side effect of it.
        Recipe(pattern: .shaped([
            [.ironIngot, nil, .ironIngot],
            [.ironIngot, .ironIngot, .ironIngot],
            [.ironIngot, .ironIngot, .ironIngot],
        ]), output: ItemStack(.ironChestplate)),
        Recipe(pattern: .shaped([
            [.diamond, nil, .diamond],
            [.diamond, .diamond, .diamond],
            [.diamond, .diamond, .diamond],
        ]), output: ItemStack(.diamondChestplate)),

        // The bucket — three iron ingots bent into the V real buckets are
        // stamped from. One recipe, not a tiered ladder: what it unlocks
        // is carrying water somewhere else, not mining anything faster.
        Recipe(pattern: .shaped([
            [.ironIngot, nil, .ironIngot],
            [nil, .ironIngot, nil],
        ]), output: ItemStack(.bucket)),

        // The compass — a ring of iron around the one item in this game
        // that already carries a signal somewhere else. Needs a table: a
        // ring is a 3×3 shape no 2×2 grid can hold, which fits a tool
        // meant for a real expedition rather than the first afternoon.
        Recipe(pattern: .shaped([
            [nil, .ironIngot, nil],
            [.ironIngot, .wire, .ironIngot],
            [nil, .ironIngot, nil],
        ]), output: ItemStack(.compass)),

        // The mason's line — a stick pinned at each end by the iron that
        // makes it worth the wall it saves: two corners, a straight run
        // between them. Fits the everyday 2×2 grid, the same as the hoe,
        // because what it unlocks is speed at scale, not a new material
        // tier to earn first.
        Recipe(pattern: .shaped([[.ironIngot, .stick], [.stick, nil]]), output: ItemStack(.masonLine)),

        // The blueprint — a mason's line bound in diamond and iron, needing
        // the table a mason's line never did: what it buys is not a bigger
        // wall but a repeatable one, and a tool that lets a design be built
        // once and paid for again and again is worth gating behind a
        // diamond haul, not the first afternoon.
        Recipe(pattern: .shaped([
            [.diamond, .masonLine, .diamond],
            [nil, .ironIngot, nil],
        ]), output: ItemStack(.blueprint)),

        // The Sleeping Garden's hardware. A radio is the one piece anyone
        // can build from the start: a world whose station was never found
        // can still pick up the thread with one of its own. The rest are
        // what the three pieces of the old network teach — see
        // `isExpeditionRecipe`.
        Recipe(pattern: .shaped([
            [.ironIngot, .glowCrystal, .ironIngot],
            [.ironIngot, .wire, .ironIngot],
        ]), output: ItemStack(.radio)),
        Recipe(pattern: .shaped([
            [.ironIngot, .meteorIngot, .ironIngot],
            [.meteorIngot, .signalCore, .meteorIngot],
            [.ironIngot, .meteorIngot, .ironIngot],
        ]), output: ItemStack(.launchPad)),
        Recipe(pattern: .shaped([
            [.meteorIngot, .glass, .meteorIngot],
            [.meteorIngot, .furnace, .meteorIngot],
            [.ironIngot, nil, .ironIngot],
        ]), output: ItemStack(.rocket)),
        Recipe(pattern: .shaped([
            [.ironIngot, .glass, .ironIngot],
            [.wool, .meteorIngot, .wool],
            [.wool, nil, .wool],
        ]), output: ItemStack(.spaceSuit)),
        Recipe(pattern: .shaped([
            [.ironIngot, .glass, .ironIngot],
            [.sapling, .wire, .sapling],
            [.ironIngot, .meteorIngot, .ironIngot],
        ]), output: ItemStack(.airMaker)),
        Recipe(pattern: .shapeless([.silverReed, .silverReed, .silverReed, .silverReed]),
               output: ItemStack(.silverThatch, count: 4)),
        // A furnace from the Moon's own rock, since there is no cobblestone
        // there to build the usual one from.
        Recipe(pattern: .shaped([
            [.moonRock, .moonRock, .moonRock],
            [.moonRock, nil, .moonRock],
            [.moonRock, .moonRock, .moonRock],
        ]), output: ItemStack(.furnace)),
    ]

    /// Set by the world in play: false until its journal holds all three
    /// pieces. True everywhere else — creative, the demo, and every check
    /// that builds recipes without a world behind them.
    static var expeditionUnlocked = true

    /// Every recipe the player can make use of right now.
    static var available: [Recipe] {
        expeditionUnlocked ? all : all.filter { !$0.isExpeditionRecipe }
    }

    /// The result of what's currently on the grid, or nil if it matches
    /// nothing. A 2×2 grid only ever sees recipes that fit in 2×2.
    static func match(_ grid: CraftingGrid) -> ItemStack? {
        guard !grid.isEmpty else { return nil }
        let shape = grid.trimmedShape()
        // A shaped recipe matches its own mirror image too. the original does
        // this, and the reason is the staircase: half the people who lay
        // six planks out in a stair shape lay them out the other way round,
        // and being told that isn't a recipe is the sort of thing a child
        // stops trying after. Mirroring the *grid* rather than listing both
        // patterns keeps the recipe hint strip one row per recipe.
        let mirrored = shape.map { $0.reversed().map { $0 } }
        let contents = grid.contents().sorted { $0.rawValue < $1.rawValue }

        for recipe in available {
            if recipe.requiresTable, grid.size < 3 { continue }
            switch recipe.pattern {
            case .shaped(let rows):
                if rows == shape || rows == mirrored { return recipe.output }
            case .shapeless(let items):
                if items.sorted(by: { $0.rawValue < $1.rawValue }) == contents { return recipe.output }
            }
        }
        return nil
    }

    /// Whether the player could make this one right now: it fits the grid
    /// they are standing at, and the ingredients are somewhere in the bag.
    static func canCraft(_ recipe: Recipe, from inventory: Inventory, gridSize: Int) -> Bool {
        guard recipe.fits(gridSize: gridSize) else { return false }
        return recipe.ingredientCounts.allSatisfy { inventory.count(of: $0.key) >= $0.value }
    }

    /// Recipes the player could make right now from their inventory —
    /// backing for the recipe hint strip in the inventory screen.
    static func craftable(from inventory: Inventory, gridSize: Int) -> [Recipe] {
        available.filter { canCraft($0, from: inventory, gridSize: gridSize) }
    }

    /// Every recipe on its shelf, in the order the recipe book lists them.
    /// Indices into `all`, so a row in the book can be traced back to the
    /// recipe it draws. Each recipe appears under exactly one heading and
    /// none is left out — `RecipeBookCheck` asserts both.
    static var shelves: [(group: Recipe.Group, entries: [Int])] {
        Recipe.Group.allCases.compactMap { group in
            let entries = all.indices.filter {
                all[$0].group == group && (expeditionUnlocked || !all[$0].isExpeditionRecipe)
            }
            return entries.isEmpty ? nil : (group, entries)
        }
    }
}

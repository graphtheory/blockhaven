#if canImport(AppKit)
import AppKit

/// Headless proof that the recipe book tells the truth and that clicking it
/// cannot cost you anything.
///
/// A picture of the book shows the rows; it cannot show that the row you
/// clicked is the recipe that got laid out, that a 2×2 grid really refuses
/// the recipes it draws greyed, or — the one that actually matters — that
/// auto-fill moves items rather than inventing or eating them. So all of
/// that is asserted here instead, against the same `RecipeBookPanel` the
/// screen draws with and the same `RecipeAutoFill` the click calls.
///
/// The panel is laid out but never drawn, which is why this needs no window
/// and no `NSApplication`: row geometry is arithmetic, and it is the
/// arithmetic that decides which recipe a click lands on.
///
/// `BLOCKHAVEN_CHECK_BOOK=1`. Exits nonzero if any line fails.
enum RecipeBookCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_BOOK"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    /// Total items held anywhere the player can get at them.
    private static func tally(_ inventory: Inventory, _ grid: CraftingGrid) -> [ItemType: Int] {
        var counts: [ItemType: Int] = [:]
        for slot in inventory.slots {
            guard let stack = slot else { continue }
            counts[stack.type, default: 0] += stack.count
        }
        for index in 0..<(grid.size * grid.size) {
            guard let stack = grid[index] else { continue }
            counts[stack.type, default: 0] += stack.count
        }
        return counts
    }

    /// An inventory stocked with exactly one recipe's shopping list, plus a
    /// little of something unrelated so conservation has an item that ought
    /// *not* to move.
    /// One slot, for a failure line: what is in it, or that it is empty.
    private static func describe(_ stack: ItemStack?) -> String {
        guard let stack else { return "empty" }
        return "\(stack.type)×\(stack.count)"
    }

    private static func stocked(for recipe: Recipe) -> Inventory {
        let inventory = Inventory()
        for (item, count) in recipe.ingredientCounts {
            inventory.add(ItemStack(item, count: count))
        }
        inventory.add(ItemStack(.gravel, count: 5))
        return inventory
    }

    static func run() -> Never {
        var report = Report()
        let panel = RecipeBookPanel()
        panel.isOpen = true

        // MARK: every recipe is on a shelf, exactly once
        let listed = panel.entries.compactMap { entry -> Int? in
            if case .recipe(let index) = entry { return index }
            return nil
        }
        report.check(
            "every recipe listed exactly once",
            listed.sorted() == Array(RecipeBook.all.indices),
            "\(listed.count) rows for \(RecipeBook.all.count) recipes,"
                + " \(panel.entries.count - listed.count) headings"
        )

        let unfiled = RecipeBook.all.filter { $0.group == .other }
        report.check(
            "no recipe fell off the shelves",
            unfiled.isEmpty,
            unfiled.isEmpty
                ? RecipeBook.shelves.map { "\($0.group.title) \($0.entries.count)" }
                    .joined(separator: ", ")
                : "unfiled: \(unfiled.map(\.output.type))"
        )

        // MARK: every row is reachable, and clicking it hits the row it drew
        //
        // The book is taller than any window it fits in, so this scrolls it
        // through from top to bottom and aims a click at every row that
        // comes into view. Both halves matter: a row whose centre never
        // lands inside the viewport at any scroll position is a recipe the
        // player cannot click at all, and a row that hit-tests as its
        // neighbour is a click that crafts the wrong thing.
        panel.layout(
            in: CGRect(x: 0, y: 0, width: 1280, height: 800),
            beside: CGRect(x: 406, y: 192, width: 468, height: 416),
            gap: 16
        )
        var mappingOK = panel.rowFrames.count == panel.entries.count
        var reached = Set<Int>()
        var offset: CGFloat = 0
        while true {
            panel.setScroll(offset)
            for index in panel.entries.indices {
                guard let centre = panel.center(ofEntry: index) else { continue }
                if panel.hitEntry(at: centre) == index {
                    reached.insert(index)
                } else {
                    mappingOK = false
                }
            }
            if panel.scrollOffset >= panel.scrollLimit { break }
            offset += panel.scrollStep / 2
        }
        panel.setScroll(0)
        let unreachable = panel.entries.indices.filter { !reached.contains($0) }
        report.check(
            "every row can be clicked, and hits the row it drew",
            mappingOK && unreachable.isEmpty,
            mappingOK && unreachable.isEmpty
                ? "\(reached.count) rows reached by scrolling a"
                    + " \(Int(panel.viewport.height))pt viewport through"
                    + " \(Int(panel.scrollLimit))pt of list"
                : "unreachable \(unreachable), mapping \(mappingOK ? "ok" : "crossed")"
        )

        // MARK: auto-fill crafts what the row promised, at both grid sizes
        var fillFailures: [String] = []
        var conservationFailures: [String] = []
        var refusals = 0
        var fills = 0

        for gridSize in [2, 3] {
            for recipe in RecipeBook.all {
                let name = "\(recipe.output.type) @\(gridSize)×\(gridSize)"
                let inventory = stocked(for: recipe)
                var grid = CraftingGrid(size: gridSize)
                // Junk already on the grid: auto-fill has to put this back
                // before laying anything out, and it is what makes the
                // conservation line below mean something.
                grid[0] = ItemStack(.dirt, count: 3)
                if gridSize * gridSize > 1 { grid[gridSize * gridSize - 1] = ItemStack(.snow, count: 2) }

                let before = tally(inventory, grid)
                let expected = RecipeBook.canCraft(recipe, from: inventory, gridSize: gridSize)
                let filled = RecipeAutoFill.fill(&grid, with: recipe, from: inventory)
                let after = tally(inventory, grid)

                if after != before {
                    conservationFailures.append(name)
                }
                if filled != expected {
                    fillFailures.append("\(name) filled=\(filled) expected=\(expected)")
                } else if filled {
                    fills += 1
                    if RecipeBook.match(grid) != recipe.output {
                        fillFailures.append(
                            "\(name) laid out → \(RecipeBook.match(grid).map { "\($0.type)×\($0.count)" } ?? "nothing")"
                        )
                    }
                } else {
                    refusals += 1
                    // A refusal has to be a no-op, not a half-done move: the
                    // junk is still exactly where it was put.
                    if grid[0] != ItemStack(.dirt, count: 3) {
                        fillFailures.append("\(name) disturbed the grid while refusing")
                    }
                }
            }
        }
        report.check(
            "auto-fill crafts the recipe its row draws",
            fillFailures.isEmpty,
            fillFailures.isEmpty
                ? "\(fills) laid out and matched, \(refusals) correctly refused"
                : fillFailures.prefix(4).joined(separator: "; ")
        )
        report.check(
            "auto-fill moves items, never mints or eats them",
            conservationFailures.isEmpty,
            conservationFailures.isEmpty
                ? "inventory + grid totals identical across \(RecipeBook.all.count * 2) fills"
                : conservationFailures.prefix(4).joined(separator: "; ")
        )

        // MARK: a dimmed row refuses at 2×2, and says so for the right reason
        let tableOnly = RecipeBook.all.filter(\.requiresTable)
        var dimmedOK = !tableOnly.isEmpty
        for recipe in tableOnly {
            let inventory = stocked(for: recipe)
            var small = CraftingGrid(size: 2)
            if RecipeAutoFill.fill(&small, with: recipe, from: inventory) { dimmedOK = false }
            if !small.isEmpty { dimmedOK = false }
            // …and the same recipe, same stock, does fill at a table.
            var table = CraftingGrid(size: 3)
            if !RecipeAutoFill.fill(&table, with: recipe, from: inventory) { dimmedOK = false }
        }
        report.check(
            "a dimmed row will not fill a 2×2 grid",
            dimmedOK,
            "\(tableOnly.count) table recipes refused at 2×2, all of them filled at 3×3"
        )

        // MARK: an empty bag fills nothing, and loses nothing trying
        //
        // Gravel, because auto-fill hands the grid back to the inventory
        // before it lays anything out — so a log parked here would become a
        // log the planks recipe could suddenly afford, and this line would
        // be testing the wrong thing.
        let empty = Inventory()
        var grid = CraftingGrid(size: 3)
        grid[4] = ItemStack(.gravel, count: 2)
        let beforeEmpty = tally(empty, grid)
        var anyFilled = false
        for recipe in RecipeBook.all where RecipeAutoFill.fill(&grid, with: recipe, from: empty) {
            anyFilled = true
        }
        report.check(
            "nothing fills from an empty inventory",
            !anyFilled && tally(empty, grid) == beforeEmpty
                && grid[4] == ItemStack(.gravel, count: 2),
            "all \(RecipeBook.all.count) rows refused, the gravel on the grid stayed on the grid"
        )

        // MARK: clicking a row with something on the cursor
        //
        // The click puts the held stack down before it prices the recipe,
        // and the row it clicked may still refuse. `Inventory.add` scatters
        // a stack into partial stacks and then hotbar-first, so a refusal
        // that had already put it down would leave the bag reshuffled by a
        // click the book had just shaken to say it ignored.
        var cursorFailures: [String] = []

        // Refused: a table recipe clicked at the 2×2 grid, holding planks.
        for recipe in tableOnly.prefix(3) {
            let inventory = stocked(for: recipe)
            inventory.add(ItemStack(.dirt, count: 7))
            var held: ItemStack? = ItemStack(.planks, count: 40)
            var small = CraftingGrid(size: 2)
            let slotsBefore = inventory.slots
            let filled = RecipeAutoFill.fill(
                &small, with: recipe, from: inventory, cursor: &held
            )
            if filled { cursorFailures.append("\(recipe.output.type) filled a 2×2") }
            if held != ItemStack(.planks, count: 40) {
                cursorFailures.append("\(recipe.output.type) took the cursor: \(String(describing: held))")
            }
            if inventory.slots != slotsBefore {
                // Name the slot. "The bag moved" is true of a hundred
                // different bugs and points at none of them; the slot that
                // moved and what it moved between points at one.
                let now = inventory.slots
                var moved: [String] = []
                for index in slotsBefore.indices where index < now.count {
                    guard slotsBefore[index] != now[index], moved.count < 3 else { continue }
                    moved.append(
                        "\(index): \(describe(slotsBefore[index])) → \(describe(now[index]))"
                    )
                }
                cursorFailures.append(
                    "\(recipe.output.type) reshuffled the bag while refusing"
                        + (moved.isEmpty
                            ? " (\(slotsBefore.count) → \(now.count) slots)"
                            : " — " + moved.joined(separator: ", "))
                )
            }
            if !small.isEmpty { cursorFailures.append("\(recipe.output.type) left the grid dirty") }
        }

        // Accepted, and the held stack is one of the ingredients: it has to
        // go down *before* the recipe is priced, or the last log of the
        // batch is the one the player is holding and the row reads as
        // unaffordable while they hold what it needs.
        var lastIngredientFills = 0
        for recipe in RecipeBook.all where !recipe.requiresTable {
            guard let (item, _) = recipe.ingredientCounts.first else { continue }
            let inventory = stocked(for: recipe)
            guard inventory.remove(item, count: 1) == 1 else { continue }
            var held: ItemStack? = ItemStack(item, count: 1)
            var grid = CraftingGrid(size: 2)
            let before = tally(inventory, grid).merging([item: 1]) { $0 + $1 }
            let filled = RecipeAutoFill.fill(
                &grid, with: recipe, from: inventory, cursor: &held
            )
            if !filled {
                cursorFailures.append("\(recipe.output.type) refused while its last \(item) was on the cursor")
                continue
            }
            lastIngredientFills += 1
            if held != nil { cursorFailures.append("\(recipe.output.type) left the cursor loaded") }
            if tally(inventory, grid) != before {
                cursorFailures.append("\(recipe.output.type) lost the cursor's \(item)")
            }
        }

        // Nowhere to put it down: every slot full of something else. The
        // player keeps hold of the whole stack rather than the fraction of
        // it that fitted.
        let stuffed = Inventory()
        while stuffed.add(ItemStack(.cobblestone, count: 64)) == nil {}
        var stuck: ItemStack? = ItemStack(.planks, count: 3)
        var stuffedGrid = CraftingGrid(size: 2)
        let stuffedBefore = stuffed.slots
        if RecipeAutoFill.fill(
            &stuffedGrid, with: RecipeBook.all[0], from: stuffed, cursor: &stuck
        ) {
            cursorFailures.append("filled with no room to put the cursor down")
        }
        if stuck != ItemStack(.planks, count: 3) {
            cursorFailures.append("a full bag ate part of the cursor: \(String(describing: stuck))")
        }
        if stuffed.slots != stuffedBefore { cursorFailures.append("a full bag was disturbed") }

        report.check(
            "a refused row hands the cursor back untouched",
            cursorFailures.isEmpty,
            cursorFailures.isEmpty
                ? "\(tableOnly.prefix(3).count) refusals and a full bag left the cursor and every"
                    + " slot alone, \(lastIngredientFills) rows filled from the held ingredient"
                : cursorFailures.prefix(4).joined(separator: "; ")
        )

        report.lines.append(
            "[check] " + (report.failed ? "FAILED" : "all passed")
                + " — \(RecipeBook.all.count) recipes on \(RecipeBook.shelves.count) shelves"
        )
        StandardError.write(Data((report.lines.joined(separator: "\n") + "\n").utf8))
        exit(report.failed ? 1 : 0)
    }
}
#endif

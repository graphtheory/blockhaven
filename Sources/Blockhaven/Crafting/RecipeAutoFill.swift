import Foundation

/// Laying a recipe out on the crafting grid for the player — what clicking
/// a row in the recipe book does.
///
/// This is the part of the book that can lose you your things, so it is
/// deliberately not view code: moving items between an `Inventory` and a
/// `CraftingGrid` is arithmetic, and arithmetic can be checked headlessly
/// (`BLOCKHAVEN_CHECK_BOOK`). Two rules it keeps, in this order:
///
///   1. Whatever was already on the grid goes back to the inventory first.
///      Auto-fill that quietly ate the half-finished thing you had laid out
///      is worse than auto-fill that refuses.
///   2. Every move is a transfer, never a copy. Items come off the grid by
///      being added to the inventory, and go onto it by being removed from
///      the inventory, so the total across both is the same number before
///      and after — including on the failure path, which rolls the whole
///      thing back rather than leaving it half done.
enum RecipeAutoFill {
    /// Where each ingredient goes on a grid of this size: shaped patterns
    /// land in the top-left corner (`match` trims the grid before comparing,
    /// so a corner-placed pattern is the same pattern), shapeless ones fill
    /// cells in reading order because nothing looks at where they sit.
    ///
    /// Empty when the recipe does not fit, which is the caller's cue that
    /// there is nothing to do.
    static func placement(for recipe: Recipe, gridSize: Int) -> [(cell: Int, item: ItemType)] {
        guard recipe.fits(gridSize: gridSize) else { return [] }
        var result: [(cell: Int, item: ItemType)] = []
        switch recipe.pattern {
        case .shaped(let rows):
            for (row, items) in rows.enumerated() {
                for (column, item) in items.enumerated() {
                    guard let item else { continue }
                    result.append((row * gridSize + column, item))
                }
            }
        case .shapeless(let items):
            for (index, item) in items.enumerated() {
                result.append((index, item))
            }
        }
        return result
    }

    /// Clears the grid back into the inventory and lays this recipe out on
    /// it. Returns false — having changed nothing at all — when the recipe
    /// doesn't fit this grid, when the ingredients aren't there, or when
    /// the inventory is too full to take back what the grid was holding.
    @discardableResult
    static func fill(
        _ grid: inout CraftingGrid, with recipe: Recipe, from inventory: Inventory
    ) -> Bool {
        let placement = placement(for: recipe, gridSize: grid.size)
        guard !placement.isEmpty else { return false }

        let savedSlots = inventory.slots
        let savedSelection = inventory.selectedHotbarSlot
        let savedGrid = grid
        func rollback() -> Bool {
            inventory.restore(slots: savedSlots, selectedHotbarSlot: savedSelection)
            grid = savedGrid
            return false
        }

        // Clear first. This can only ever *raise* the inventory's counts,
        // so the affordability test below is asked after it rather than
        // before: laying out planks using the planks you had already put on
        // the grid is the common case, not an edge one.
        for index in 0..<(grid.size * grid.size) {
            guard let stack = grid[index] else { continue }
            guard inventory.add(stack) == nil else { return rollback() }
            grid[index] = nil
        }

        guard RecipeBook.canCraft(recipe, from: inventory, gridSize: grid.size) else {
            return rollback()
        }

        for (cell, item) in placement {
            guard inventory.remove(item, count: 1) == 1 else { return rollback() }
            grid[cell] = ItemStack(item)
        }
        return true
    }

    /// The same fill for a player with something on the cursor, which is
    /// what a click in the book actually is.
    ///
    /// Putting the held stack down is part of the move, not something the
    /// caller does first: it may itself be an ingredient, and auto-fill
    /// must not shuffle slots about underneath a stack the cursor is
    /// holding. It has to be undone by the same rollback, too — `add`
    /// scatters a stack into partial stacks and then hotbar-first, nowhere
    /// near the slot it was picked up from, so a caller that put it down
    /// has no way to put it *back*. A refused row that quietly reorganised
    /// the bag would be the one thing the shake was promising it hadn't.
    ///
    /// True with `cursor` emptied into the bag on success; false having
    /// changed nothing at all — bag, grid or cursor — on a refusal.
    @discardableResult
    static func fill(
        _ grid: inout CraftingGrid,
        with recipe: Recipe,
        from inventory: Inventory,
        cursor: inout ItemStack?
    ) -> Bool {
        let savedSlots = inventory.slots
        let savedSelection = inventory.selectedHotbarSlot
        let savedCursor = cursor
        func rollback() -> Bool {
            inventory.restore(slots: savedSlots, selectedHotbarSlot: savedSelection)
            cursor = savedCursor
            return false
        }

        if let held = cursor {
            cursor = inventory.add(held)
            // Nowhere to put it: refuse rather than leave the player
            // holding the half of it that did fit.
            guard cursor == nil else { return rollback() }
        }
        guard fill(&grid, with: recipe, from: inventory) else { return rollback() }
        return true
    }
}

import Foundation

/// What a click does on the inventory screen — the rules, without the
/// screen. Both front ends draw their own slots and then hand every click
/// here, so a stack splits, merges and shift-moves the same way on the Mac
/// and on Windows.
final class InventoryInteraction {
    enum SlotKind: Equatable {
        case inventory(Int)
        case craft(Int)
        case craftOutput
        case chest(Int)
    }

    let inventory: Inventory
    var craftingGrid: CraftingGrid
    let chest: Chest?
    /// The stack riding on the cursor.
    var heldStack: ItemStack?

    init(inventory: Inventory, gridSize: Int, chest: Chest?) {
        self.inventory = inventory
        self.craftingGrid = CraftingGrid(size: gridSize)
        self.chest = chest
    }

    /// What a slot is showing right now. The crafting output is whatever
    /// the grid currently makes.
    func stack(in kind: SlotKind) -> ItemStack? {
        switch kind {
        case .inventory(let index): return inventory[index]
        case .craft(let index): return craftingGrid[index]
        case .craftOutput: return chest == nil ? RecipeBook.match(craftingGrid) : nil
        case .chest(let index): return chest?[index]
        }
    }

    /// A click on a slot: left takes, places or swaps; right splits or
    /// drops one; shift-left sends the stack across.
    func click(_ kind: SlotKind, secondary: Bool, shiftHeld: Bool) {
        switch kind {
        case .craftOutput:
            takeCraftingOutput(all: shiftHeld)
        case .inventory(let index):
            if shiftHeld, !secondary {
                quickMove(inventoryIndex: index)
            } else {
                clickSlot(
                    get: { self.inventory[index] },
                    set: { self.inventory[index] = $0 },
                    secondary: secondary
                )
            }
        case .craft(let index):
            clickSlot(
                get: { self.craftingGrid[index] },
                set: { self.craftingGrid[index] = $0 },
                secondary: secondary
            )
        case .chest(let index):
            guard let chest else { return }
            if shiftHeld, !secondary {
                if let stack = chest[index] {
                    chest[index] = inventory.add(stack)
                }
            } else {
                clickSlot(
                    get: { chest[index] },
                    set: { chest[index] = $0 },
                    secondary: secondary
                )
            }
        }
    }

    /// Taking something off the creative palette. A plain click fills the
    /// cursor with a full stack, a right-click with one, and shift sends it
    /// straight to the bag.
    ///
    /// Whatever was already on the cursor is put back in the bag first, and
    /// if there is no room for it the click is *refused* rather than
    /// swallowing it. An infinite supply of blocks is not a reason to be
    /// careless with the one thing the player actually made.
    func takeFromPalette(_ item: ItemType, secondary: Bool, shiftHeld: Bool) {
        let count = secondary ? 1 : item.maxStack
        if shiftHeld {
            inventory.add(ItemStack(item, count: count))
            return
        }
        if var held = heldStack, held.type == item {
            held.count = min(held.maxStack, held.count + count)
            heldStack = held
            return
        }
        if let held = heldStack {
            if let leftover = inventory.add(held) {
                heldStack = leftover
                return
            }
            heldStack = nil
        }
        heldStack = ItemStack(item, count: count)
    }

    /// The palette's bin: whatever is on the cursor is gone.
    func discardHeld() {
        heldStack = nil
    }

    /// The recipe book's click: lays a recipe into the grid from the bag.
    /// False when the bag cannot cover it.
    func fill(with recipe: Recipe) -> Bool {
        RecipeAutoFill.fill(&craftingGrid, with: recipe, from: inventory, cursor: &heldStack)
    }

    /// The standard inventory click: swap the cursor stack with the slot,
    /// merging when they're the same item. Right-click splits a stack in
    /// half, or drops a single item onto the slot.
    private func clickSlot(get: () -> ItemStack?, set: (ItemStack?) -> Void, secondary: Bool) {
        let slotStack = get()

        if secondary {
            if var held = heldStack {
                // Place one from the cursor.
                if var existing = slotStack {
                    guard existing.type == held.type, !existing.isFull else { return }
                    existing.count += 1
                    set(existing)
                } else {
                    set(ItemStack(held.type, count: 1))
                }
                held.count -= 1
                heldStack = held.count > 0 ? held : nil
            } else if let existing = slotStack {
                // Pick up half.
                let take = (existing.count + 1) / 2
                heldStack = ItemStack(existing.type, count: take)
                let left = existing.count - take
                set(left > 0 ? ItemStack(existing.type, count: left) : nil)
            }
            return
        }

        if let held = heldStack {
            if var existing = slotStack, existing.type == held.type {
                heldStack = existing.merging(held)
                set(existing)
            } else {
                set(held)
                heldStack = slotStack
            }
        } else {
            heldStack = slotStack
            set(nil)
        }
    }

    /// Shift-click: shuttle a stack between the hotbar and the main grid,
    /// which is what the modifier does in the original's own inventory — or
    /// into the chest, when there is one open, which is what it does there.
    private func quickMove(inventoryIndex index: Int) {
        guard let stack = inventory[index] else { return }
        if let chest {
            inventory[index] = chest.add(stack)
            return
        }
        let destination = index < Inventory.hotbarSize
            ? Inventory.hotbarSize..<Inventory.totalSize
            : 0..<Inventory.hotbarSize

        var remaining: ItemStack? = stack
        // Merge into matching stacks first, then the first empty slot.
        for target in destination {
            guard var existing = inventory[target], existing.type == stack.type, !existing.isFull else { continue }
            guard let incoming = remaining else { break }
            remaining = existing.merging(incoming)
            inventory[target] = existing
            if remaining == nil { break }
        }
        if let leftover = remaining, let empty = destination.first(where: { inventory[$0] == nil }) {
            inventory[empty] = leftover
            remaining = nil
        }
        inventory[index] = remaining
    }

    /// Takes the crafted item. Shift-click crafts repeatedly until the
    /// ingredients run out.
    private func takeCraftingOutput(all: Bool) {
        guard let output = RecipeBook.match(craftingGrid) else { return }

        if all {
            var crafted = 0
            while let next = RecipeBook.match(craftingGrid), crafted < 64 {
                if inventory.add(next) != nil { break }
                craftingGrid.consumeOne()
                crafted += 1
            }
            return
        }

        if var held = heldStack {
            guard held.type == output.type, held.count + output.count <= held.maxStack else { return }
            held.count += output.count
            heldStack = held
        } else {
            heldStack = output
        }
        craftingGrid.consumeOne()
    }

    /// Everything the player left on the crafting grid or the cursor goes
    /// back to the inventory when the screen closes — never silently lost.
    /// The chest keeps its own slots, which is the point of a chest.
    func returnHeldItems() {
        if let held = heldStack {
            putBack(held)
            heldStack = nil
        }
        for index in 0..<(craftingGrid.size * craftingGrid.size) {
            if let stack = craftingGrid[index] {
                putBack(stack)
                craftingGrid[index] = nil
            }
        }
    }

    /// Into the bag, and into the open chest with whatever the bag would
    /// not take. A screen closing with a full inventory is the one moment
    /// this view could quietly eat a stack, and an open chest is twenty-
    /// seven slots standing right there.
    private func putBack(_ stack: ItemStack) {
        guard let leftover = inventory.add(stack) else { return }
        chest?.add(leftover)
    }
}

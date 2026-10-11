import Foundation

/// The player's inventory: nine hotbar slots plus a 27-slot main grid,
/// addressed by a single flat index so UI drag-and-drop can move a stack
/// between the two without caring which is which.
///
/// Slot layout (matching the original's own ordering in the inventory screen):
///   0..<9    hotbar
///   9..<36   main grid, three rows of nine
final class Inventory {
    static let hotbarSize = 9
    static let mainSize = 27
    static let totalSize = hotbarSize + mainSize

    private(set) var slots: [ItemStack?]
    /// Which hotbar slot the player is holding, 0..<9.
    var selectedHotbarSlot = 0

    init() {
        slots = Array(repeating: nil, count: Inventory.totalSize)
    }

    var heldStack: ItemStack? {
        slots[selectedHotbarSlot]
    }

    var heldItem: ItemType? {
        heldStack?.type
    }

    subscript(index: Int) -> ItemStack? {
        get { slots.indices.contains(index) ? slots[index] : nil }
        set {
            guard slots.indices.contains(index) else { return }
            if let stack = newValue, stack.count > 0 {
                slots[index] = stack
            } else {
                slots[index] = nil
            }
        }
    }

    /// Adds items, filling partial stacks of the same type first and then
    /// empty slots — hotbar before main grid, as the original does. Returns
    /// what didn't fit.
    @discardableResult
    func add(_ stack: ItemStack) -> ItemStack? {
        var remaining: ItemStack? = stack

        for index in slots.indices {
            guard var existing = slots[index], existing.type == stack.type, !existing.isFull else { continue }
            guard let incoming = remaining else { break }
            remaining = existing.merging(incoming)
            slots[index] = existing
            if remaining == nil { return nil }
        }

        for index in slots.indices where slots[index] == nil {
            guard let incoming = remaining else { break }
            let placed = min(incoming.maxStack, incoming.count)
            // Carrying the wear across matters for exactly one kind of
            // item and matters completely: a tool rebuilt as a fresh
            // `ItemStack` here comes out of the slot unused, so putting a
            // half-dead pickaxe in a chest and taking it out again would
            // repair it.
            slots[index] = ItemStack(incoming.type, count: placed, wear: incoming.wear)
            let leftover = incoming.count - placed
            remaining = leftover > 0 ? ItemStack(incoming.type, count: leftover) : nil
            if remaining == nil { return nil }
        }

        return remaining
    }

    /// Consumes one of the held item — placing a block. Returns false when
    /// the slot was empty.
    @discardableResult
    func consumeHeldOne() -> Bool {
        guard var stack = slots[selectedHotbarSlot] else { return false }
        stack.count -= 1
        slots[selectedHotbarSlot] = stack.count > 0 ? stack : nil
        return true
    }

    /// Total count of an item across every slot — used to test recipes.
    func count(of type: ItemType) -> Int {
        var total = 0
        for slot in slots {
            guard let stack = slot, stack.type == type else { continue }
            total += stack.count
        }
        return total
    }

    /// Removes up to `count` of `type` wherever it's found. Returns how
    /// many were actually removed.
    @discardableResult
    func remove(_ type: ItemType, count: Int) -> Int {
        var left = count
        for index in slots.indices {
            guard left > 0, var stack = slots[index], stack.type == type else { continue }
            let taken = min(stack.count, left)
            stack.count -= taken
            left -= taken
            slots[index] = stack.count > 0 ? stack : nil
        }
        return count - left
    }

    /// Puts a saved inventory back, slot for slot. `restored` is expected
    /// to be `totalSize` long; anything shorter leaves the rest empty, so a
    /// save from a build with fewer slots still loads.
    func restore(slots restored: [ItemStack?], selectedHotbarSlot selected: Int) {
        // One assignment, not a loop of element writes.
        //
        // The loop this replaces read `restored[index]` and wrote
        // `slots[index]` in the same statement, and the caller's saved copy
        // very often *is* this array — `let saved = inventory.slots` shares
        // storage until something mutates. Written that way the release
        // build corrupted the caller's copy: `BLOCKHAVEN_CHECK_BOOK` came
        // back with slot 0 of a saved bag reading `grass×0`, a stack with a
        // count no initialiser can produce, out of memory that had been
        // zeroed. Debug never showed it. Assigning the array whole leaves
        // the copy to the standard library, which is where the question of
        // who owns which buffer belongs.
        if restored.count == Inventory.totalSize {
            slots = restored
        } else {
            slots = (0..<Inventory.totalSize).map {
                restored.indices.contains($0) ? restored[$0] : nil
            }
        }
        selectedHotbarSlot = min(max(0, selected), Inventory.hotbarSize - 1)
    }

    /// Fills the inventory with a starter kit, so a fresh survival spawn
    /// isn't bare-handed with stone unminable.
    ///
    /// Wood, all of it, and not much of it. The kit it replaces handed
    /// over stone tools, sixty-four planks and thirty-two glass, which is
    /// most of a house before the first tree is cut — survival that opens
    /// with the reward already in the bag is creative with extra steps.
    /// These four tools are the ladder's bottom rung and they wear out,
    /// so the first hour is about earning the next rung.
    ///
    /// The sword is the one that has to be there. Night comes whether or
    /// not you have found coal, and a player with no weapon has no answer
    /// to a fizzler except running.
    func grantStarterKit() {
        slots[0] = ItemStack(.woodenSword)
        slots[1] = ItemStack(.woodenPickaxe)
        slots[2] = ItemStack(.woodenAxe)
        slots[3] = ItemStack(.woodenShovel)
        slots[4] = ItemStack(.craftingTable, count: 1)
        slots[5] = ItemStack(.planks, count: 8)
        slots[6] = ItemStack(.torch, count: 4)
    }

    /// Spends one use of the held tool, and empties the slot if that used
    /// it up. Returns the tool that broke, for whoever wants to say so.
    @discardableResult
    func wearHeldTool() -> ItemType? {
        guard var stack = slots[selectedHotbarSlot], stack.type.durability != nil else { return nil }
        if stack.wearOne() {
            slots[selectedHotbarSlot] = stack
            return nil
        }
        slots[selectedHotbarSlot] = nil
        return stack.type
    }

    /// What a creative world opens with: nine blocks on the hotbar, and
    /// the bag behind them left empty.
    ///
    /// It used to be all thirty-six slots — every block in the game, one
    /// per slot, with nothing left over. That is why crafting in creative
    /// did not work: a crafted item has to land in a slot, and there was
    /// never one free. The unlimited supply lives in `CreativePalettePanel`
    /// now, which is a shelf beside the bag rather than the bag itself, so
    /// these nine are a starting hand and not the whole hand there is.
    func grantCreativeKit() {
        let starters: [ItemType] = [
            .grass, .stone, .cobblestone, .planks, .log, .glass, .sandstone, .torch, .craftingTable,
        ]
        for (index, item) in starters.prefix(Inventory.hotbarSize).enumerated() {
            slots[index] = ItemStack(item, count: item.maxStack)
        }
    }
}

/// A row of slots something can be put into. The player's bag and a chest
/// are the same shape from the inventory screen's side of the glass, and
/// this is that shape — which is what lets one set of click handlers, one
/// shift-click and one "give this back on close" serve both.
protocol SlotStorage: AnyObject {
    var slotCount: Int { get }
    subscript(index: Int) -> ItemStack? { get set }
    /// Adds items, returning whatever didn't fit.
    @discardableResult func add(_ stack: ItemStack) -> ItemStack?
}

extension Inventory: SlotStorage {
    var slotCount: Int { Inventory.totalSize }
}

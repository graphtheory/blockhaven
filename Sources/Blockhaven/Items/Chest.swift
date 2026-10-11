import Foundation

/// A chest's contents: twenty-seven slots, the same three rows of nine the
/// player's own bag has.
///
/// The block in the world is a byte and cannot hold this, so the contents
/// live beside the world in `ChestStore`, keyed by where the chest is —
/// the same arrangement the original calls a block entity, minus the entity.
final class Chest: SlotStorage {
    static let size = 27

    private(set) var slots: [ItemStack?]

    init(slots: [ItemStack?] = Array(repeating: nil, count: Chest.size)) {
        self.slots = slots.count == Chest.size
            ? slots
            : (0..<Chest.size).map { slots.indices.contains($0) ? slots[$0] : nil }
    }

    var slotCount: Int { Chest.size }

    var isEmpty: Bool { slots.allSatisfy { $0 == nil } }

    /// Everything in it, for emptying it into the player when the block
    /// comes out of the world.
    var contents: [ItemStack] { slots.compactMap { $0 } }

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

    /// Fills partial stacks of the same type first, then empty slots —
    /// the same order `Inventory.add` uses, so a shift-click behaves the
    /// same way whichever direction it moves in.
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
}

/// Every chest in a world, by where it stands.
///
/// Keyed by cell rather than by chunk: a chest is a single cell, chunks
/// come and go under the streamer, and a chest whose contents unloaded
/// with its chunk would be a chest that ate what you put in it.
final class ChestStore {
    struct Key: Hashable {
        var x: Int
        var y: Int
        var z: Int

        init(_ x: Int, _ y: Int, _ z: Int) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    private(set) var chests: [Key: Chest] = [:]

    /// The chest at a cell, made if it isn't there yet — which is what
    /// placing one does.
    func chest(at key: Key) -> Chest {
        if let existing = chests[key] { return existing }
        let chest = Chest()
        chests[key] = chest
        return chest
    }

    /// The chest at a cell only if one is really there. Used by everything
    /// that must not conjure storage as a side effect of looking.
    func existing(at key: Key) -> Chest? { chests[key] }

    /// Takes a chest out of the world, handing back what was in it.
    @discardableResult
    func remove(at key: Key) -> Chest? {
        chests.removeValue(forKey: key)
    }

    var isEmpty: Bool { chests.isEmpty }

    /// Drops every chest that is no longer standing where it says it is.
    ///
    /// A chest can leave the world without anyone asking this store: an
    /// explosion takes whole cells out at once. Rather than thread the
    /// store through the blast, the store is swept afterwards against the
    /// world it claims to describe.
    func prune(where blockIsGone: (Key) -> Bool) {
        for key in chests.keys where blockIsGone(key) {
            chests.removeValue(forKey: key)
        }
    }
}

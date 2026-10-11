import Foundation

/// What death costs: everything the player was carrying, left in a chest
/// where they fell — the same "a chest exists here" seam every landmark's
/// own loot already goes through, not a new kind of thing in the world.
enum Grave {
    /// Empties `inventory` into a chest at `position`, placing the chest
    /// block if nothing was there. Whatever the chest's 27 slots can't
    /// hold stays in `inventory` rather than vanishing: losing everything
    /// you're braced to lose is the stake, losing what no chest could
    /// ever have taken back anyway is just a bug wearing the death
    /// system's clothes.
    ///
    /// Hands back the key it dropped into, or nil for the one case
    /// nothing happened — an empty inventory leaves no grave to point a
    /// compass at.
    @discardableResult
    static func drop(
        inventory: Inventory, chests: ChestStore, world: World, at position: Vector3
    ) -> ChestStore.Key? {
        guard inventory.slots.contains(where: { $0 != nil }) else { return nil }
        let x = Int(floor(position.x)), z = Int(floor(position.z))
        var y = Int(floor(position.y))
        // Dying to lava leaves the fall itself standing in it — the one
        // hazard death was supposed to be a consequence of, not a second
        // trip through to collect the bill. Rise through the lava to the
        // first clear cell above it, the same upward search
        // `resolveSpawnOverlap` already uses for the opposite problem.
        var attempts = 0
        while world.block(worldX: x, y: y, worldZ: z) == .lava, attempts < Chunk.height {
            y += 1
            attempts += 1
        }
        world.setBlock(worldX: x, y: y, worldZ: z, to: .chest)
        let key = ChestStore.Key(x, y, z)
        let grave = chests.chest(at: key)
        for index in inventory.slots.indices {
            guard let stack = inventory[index] else { continue }
            inventory[index] = grave.add(stack)
        }
        return key
    }

    /// Where a compass should point while a grave is still owed to the
    /// player: the nearest one still both there and still holding
    /// something — dying twice before walking the first grave back never
    /// used to lose the loot, just the only thing pointing at it, which is
    /// a loss in every way a player can actually feel. Every grave that's
    /// still valid comes back in `stillPending`, not just the one aimed
    /// at, so a second death doesn't quietly drop the first grave from the
    /// list the moment its neighbour becomes the nearer target. A grave
    /// stops needing tracking the moment it stops qualifying — mined,
    /// blown up, or simply emptied by hand — with nothing needing to
    /// notice it was ever settled.
    static func compassTarget(
        pendingGraves: [ChestStore.Key], chests: ChestStore, home: Vector3, playerPosition: Vector3
    ) -> (position: Vector3, isGrave: Bool, stillPending: [ChestStore.Key]) {
        let valid = pendingGraves.filter { key in
            guard let chest = chests.existing(at: key) else { return false }
            return !chest.isEmpty
        }
        guard let nearest = valid.min(by: { lhs, rhs in
            let toLhs = Vector3(CGFloat(lhs.x) + 0.5, CGFloat(lhs.y) + 0.5, CGFloat(lhs.z) + 0.5) - playerPosition
            let toRhs = Vector3(CGFloat(rhs.x) + 0.5, CGFloat(rhs.y) + 0.5, CGFloat(rhs.z) + 0.5) - playerPosition
            return toLhs.length() < toRhs.length()
        }) else {
            return (home, false, [])
        }
        let position = Vector3(CGFloat(nearest.x) + 0.5, CGFloat(nearest.y) + 0.5, CGFloat(nearest.z) + 0.5)
        return (position, true, valid)
    }
}

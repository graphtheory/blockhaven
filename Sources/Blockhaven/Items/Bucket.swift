import Foundation

/// The two things a bucket does to the world — pulled out of
/// `GameViewController.use()` the same way `HopperStore.transfer` was, so
/// a headless check can prove them without a window: `GameViewController`
/// is the only thing that ever calls these, but proving what they do
/// should not require one.
enum BucketInteraction {
    /// Scoops water or lava and returns the filled item type (.waterBucket or .lavaBucket).
    @discardableResult
    static func fillFluid(at cell: (x: Int, y: Int, z: Int), world: World) -> ItemType? {
        let block = world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)
        if block == .water {
            guard world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .air) else { return nil }
            return .waterBucket
        } else if block == .lava {
            guard world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .air) else { return nil }
            return .lavaBucket
        }
        return nil
    }

    /// Backwards-compatible fill method for existing callers expecting Bool.
    @discardableResult
    static func fill(at cell: (x: Int, y: Int, z: Int), world: World) -> Bool {
        fillFluid(at: cell, world: world) != nil
    }

    /// Places a water source at a cell, backwards-compatible with water bucket.
    @discardableResult
    static func empty(at cell: (x: Int, y: Int, z: Int), world: World, playerOverlaps: Bool) -> Bool {
        empty(fluid: .water, at: cell, world: world, playerOverlaps: playerOverlaps)
    }

    /// Places a fluid source block (.water or .lava) at a cell.
    @discardableResult
    static func empty(fluid: BlockType, at cell: (x: Int, y: Int, z: Int), world: World, playerOverlaps: Bool) -> Bool {
        guard !playerOverlaps, ShapedPlacement.isReplaceable(cell, world) else { return false }
        guard world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: fluid) else { return false }
        if fluid == .water {
            WaterFlow.spread(from: cell, world: world)
        }
        return true
    }
}

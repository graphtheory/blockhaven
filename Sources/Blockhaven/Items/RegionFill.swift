import Foundation

/// The box a mason's line marks, and what filling it actually does to the
/// world — pulled out of `GameViewController` the same way
/// `BucketInteraction` was, so the shape and cost of a fill can be proven
/// without a window.
///
/// A mason's line marks two corners; the *next* block an ordinary material
/// places lands in the whole box between them instead of the one cell it
/// would otherwise take. Reusing the normal placement gesture as the
/// trigger, rather than inventing a second one, is the whole design:
/// nothing about *how* a block is placed changes, only how much of it
/// lands at once — the same relationship a relay has to plain wire.
enum RegionFill {
    /// A fill this large is a wall nobody would place by hand anyway —
    /// capping it keeps one click bounded rather than a way to raise
    /// arbitrarily large structures for free, and keeps a single frame's
    /// worth of `setBlock` calls cheap enough not to stall.
    static let maxVolume = 4096

    typealias Box = (minX: Int, maxX: Int, minY: Int, maxY: Int, minZ: Int, maxZ: Int)

    /// The axis-aligned box between two marked corners, inclusive of both.
    static func region(from a: (x: Int, y: Int, z: Int), to b: (x: Int, y: Int, z: Int)) -> Box {
        (min(a.x, b.x), max(a.x, b.x), min(a.y, b.y), max(a.y, b.y), min(a.z, b.z), max(a.z, b.z))
    }

    static func volume(of box: Box) -> Int {
        (box.maxX - box.minX + 1) * (box.maxY - box.minY + 1) * (box.maxZ - box.minZ + 1)
    }

    /// Fills every replaceable, unoccupied cell in the box with `block`,
    /// stopping the moment `available` items run out — a fill that outruns
    /// the stack places as much of the wall as could actually be afforded
    /// and no more, the same as buying it one block at a time would.
    /// Returns how many cells were actually placed, oldest corner first.
    @discardableResult
    static func fill(
        _ box: Box,
        with block: BlockType,
        world: World,
        playerOverlaps: (_ x: Int, _ y: Int, _ z: Int) -> Bool,
        available: Int
    ) -> Int {
        guard block.isBulkFillable, available > 0, volume(of: box) <= maxVolume else { return 0 }
        var placed = 0
        for y in box.minY...box.maxY {
            for z in box.minZ...box.maxZ {
                for x in box.minX...box.maxX {
                    guard placed < available else { return placed }
                    guard !playerOverlaps(x, y, z) else { continue }
                    guard ShapedPlacement.isReplaceable((x, y, z), world) else { continue }
                    guard world.setBlock(worldX: x, y: y, worldZ: z, to: block) else { continue }
                    placed += 1
                }
            }
        }
        return placed
    }

    /// The reverse of `fill`: clears every non-air, `isBulkFillable` cell in
    /// the box back to air, stopping the moment `availableUses` runs out —
    /// a clear that outruns a tool's remaining durability removes as much
    /// of the box as could actually be dug and no more, the same as digging
    /// it out one block at a time would. `isBulkFillable` already excludes
    /// anything that carries its own state (a chest, a furnace, a hopper, a
    /// crop, a lever) and anything a mason's line can't place either, so a
    /// mark spanning a stocked chest or a live wire touches neither by
    /// accident. Returns how many cells were actually cleared, oldest
    /// corner first, calling `onCleared` for each one so the caller can
    /// hand back a drop, spend a tool's use, or notice a wire went with it.
    @discardableResult
    static func clear(
        _ box: Box,
        world: World,
        playerOverlaps: (_ x: Int, _ y: Int, _ z: Int) -> Bool,
        availableUses: Int,
        onCleared: (_ block: BlockType, _ x: Int, _ y: Int, _ z: Int) -> Void
    ) -> Int {
        guard availableUses > 0, volume(of: box) <= maxVolume else { return 0 }
        var cleared = 0
        for y in box.minY...box.maxY {
            for z in box.minZ...box.maxZ {
                for x in box.minX...box.maxX {
                    guard cleared < availableUses else { return cleared }
                    guard !playerOverlaps(x, y, z) else { continue }
                    let existing = world.block(worldX: x, y: y, worldZ: z)
                    guard existing != .air, existing.isBulkFillable else { continue }
                    guard world.setBlock(worldX: x, y: y, worldZ: z, to: .air) else { continue }
                    onCleared(existing, x, y, z)
                    cleared += 1
                }
            }
        }
        return cleared
    }

    // MARK: - Blueprints

    /// A captured shape: every non-air, `isBulkFillable` cell in a marked
    /// box, kept relative to that box's own least corner so it can be
    /// stamped down anywhere. Deliberately not `Codable` or attached to an
    /// item stack — it lives only as long as the play session that captured
    /// it, the same as a mason's line's own pending mark does, and costs
    /// nothing to lose: recapturing is one more pair of clicks against the
    /// original structure, which is still standing.
    struct Blueprint {
        let cells: [(dx: Int, dy: Int, dz: Int, block: BlockType)]
    }

    /// Reads a marked box back out as a `Blueprint`. Skips air outright —
    /// there is nothing to stamp back — and anything that fails
    /// `isBulkFillable` for the same reason `fill`/`clear` already refuse
    /// it: a chest's contents are not a pattern of blocks, so a box drawn
    /// around one comes back with a chest-shaped hole rather than a second
    /// chest with none of the first one's things in it.
    static func capture(_ box: Box, world: World) -> Blueprint {
        var cells: [(dx: Int, dy: Int, dz: Int, block: BlockType)] = []
        for y in box.minY...box.maxY {
            for z in box.minZ...box.maxZ {
                for x in box.minX...box.maxX {
                    let block = world.block(worldX: x, y: y, worldZ: z)
                    guard block != .air, block.isBulkFillable else { continue }
                    cells.append((x - box.minX, y - box.minY, z - box.minZ, block))
                }
            }
        }
        return Blueprint(cells: cells)
    }

    /// Stamps a captured shape down with its least corner at `anchor`.
    ///
    /// Unlike `fill`, a stamp can need several different materials in one
    /// pass, so `available` is asked per block type rather than handed one
    /// number up front — the same running balance either way, just kept per
    /// kind instead of in a single counter, so running out of planks stops
    /// the walls without also stopping a roof made of something else. Calls
    /// `onPlaced` for every cell that actually lands, so the caller can
    /// charge the right inventory slot and notice a wire or a relay went in
    /// live, the same two things `fill` already does inline.
    @discardableResult
    static func stamp(
        _ blueprint: Blueprint,
        at anchor: (x: Int, y: Int, z: Int),
        world: World,
        playerOverlaps: (_ x: Int, _ y: Int, _ z: Int) -> Bool,
        available: (BlockType) -> Int,
        onPlaced: (_ block: BlockType, _ x: Int, _ y: Int, _ z: Int) -> Void
    ) -> Int {
        guard blueprint.cells.count <= maxVolume else { return 0 }
        var remaining: [BlockType: Int] = [:]
        var placed = 0
        for cell in blueprint.cells {
            let x = anchor.x + cell.dx, y = anchor.y + cell.dy, z = anchor.z + cell.dz
            guard !playerOverlaps(x, y, z) else { continue }
            guard ShapedPlacement.isReplaceable((x, y, z), world) else { continue }
            let left = remaining[cell.block] ?? available(cell.block)
            guard left > 0 else { remaining[cell.block] = left; continue }
            guard world.setBlock(worldX: x, y: y, worldZ: z, to: cell.block) else { continue }
            remaining[cell.block] = left - 1
            placed += 1
            onPlaced(cell.block, x, y, z)
        }
        return placed
    }
}

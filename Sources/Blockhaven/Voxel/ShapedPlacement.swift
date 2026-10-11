import Foundation

/// Placing, opening and breaking the blocks that are not a plain cube.
///
/// A simple block is an `ItemType` with a `placedBlock` and the whole of
/// placing it is one `setBlock`. None of the shaped blocks are that: which
/// case a stair places depends on where the player is standing, a door and
/// a bed are two cells that have to arrive and leave together, and opening
/// a door rewrites both halves at once.
///
/// All of that lives here rather than in `GameViewController` for one
/// reason: the controller needs a window, a scene and a run loop, and none
/// of these rules do. Everything below is a pure function of a `World` and
/// a few integers, which is what lets `HouseBlockCheck` drive the same code
/// the right mouse button drives, headless, and fail the build when it
/// stops working.
enum ShapedPlacement {
    /// One cell to write. A placement is all of its edits or none of them.
    struct Edit: Equatable {
        var x: Int
        var y: Int
        var z: Int
        var block: BlockType
    }

    // MARK: - Facing

    /// Which way the player is looking, snapped to the nearest of the four
    /// horizontal directions. Forward is `(sin yaw, cos yaw)`, and `+Z` is
    /// south in this world's frame — the same convention the debug HUD's
    /// compass uses.
    static func facing(fromYaw yaw: CGFloat) -> BlockFacing {
        let forwardX = sin(yaw), forwardZ = cos(yaw)
        if abs(forwardX) >= abs(forwardZ) { return forwardX >= 0 ? .east : .west }
        return forwardZ >= 0 ? .south : .north
    }

    // MARK: - Placing

    /// The edits placing `item` at `cell` would make, or nil if this item
    /// does not place a shaped block or the space it needs is not there.
    ///
    /// Nothing here writes: a caller gets the whole placement or nothing,
    /// so a door can never end up as a lower half with open sky above it.
    /// The caller still has to check the player is not standing in the way
    /// — that is a question about the player, not about the world.
    static func edits(
        for item: ItemType,
        at cell: (x: Int, y: Int, z: Int),
        yaw: CGFloat,
        world: World
    ) -> [Edit]? {
        let look = facing(fromYaw: yaw)

        switch item {
        case .oakStairs, .cobbleStairs:
            guard isReplaceable(cell, world) else { return nil }
            // Stairs ascend *toward* their facing, so facing the way the
            // player is looking makes them climb away from them — which is
            // what someone laying a run of steps in front of themselves is
            // trying to do.
            let block = item == .cobbleStairs
                ? BlockType.cobbleStairs(look) : BlockType.oakStairs(look)
            return [Edit(x: cell.x, y: cell.y, z: cell.z, block: block)]

        case .glassPane:
            guard isReplaceable(cell, world) else { return nil }
            return [Edit(x: cell.x, y: cell.y, z: cell.z, block: .glassPane)]

        case .rail, .poweredRail:
            guard isReplaceable(cell, world) else { return nil }
            guard RailNetwork.canPlace(at: cell, in: world) else { return nil }
            // Laid flat along the way the player is looking. The shape is
            // then resolved against the neighbours — including turning the
            // rails already there to meet this one — by `refresh`, which
            // the caller runs once the block is down.
            return [Edit(
                x: cell.x, y: cell.y, z: cell.z,
                block: RailNetwork.straight(along: look, powered: item == .poweredRail)
            )]

        case .detectorRail:
            guard isReplaceable(cell, world) else { return nil }
            guard RailNetwork.canPlace(at: cell, in: world) else { return nil }
            // Its axis, like a booster's, is chosen once and never
            // resolved against neighbours afterward — see the guard in
            // `RailNetwork.resolve`.
            return [Edit(x: cell.x, y: cell.y, z: cell.z, block: RailNetwork.detectorStraight(along: look))]

        case .torch:
            guard isReplaceable(cell, world) else { return nil }
            // A torch needs a floor. Without this it plants happily in mid
            // air, and a cave lit by a scatter of floating flames is both
            // wrong and — because a torch is the only light there is — the
            // sort of wrong that gets built into every mineshaft before
            // anyone thinks to mention it.
            //
            // Any full-cube top will do, which is a deliberately looser rule
            // than a plant's: you light the cave you are standing in, and
            // the floor of a cave is stone, gravel, ore, whatever is there.
            let below = world.block(worldX: cell.x, y: cell.y - 1, worldZ: cell.z)
            guard cell.y > 0, below.isSolid, !below.isShaped else { return nil }
            return [Edit(x: cell.x, y: cell.y, z: cell.z, block: .torch)]

        case .oakDoor:
            let upper = (x: cell.x, y: cell.y + 1, z: cell.z)
            guard cell.y + 1 < Chunk.height,
                  isReplaceable(cell, world), isReplaceable(upper, world) else { return nil }
            // The panel sits against the edge the player is on, so the door
            // they just placed is facing them rather than turning its back.
            let doorFacing = look.opposite
            return [
                Edit(x: cell.x, y: cell.y, z: cell.z,
                     block: .oakDoor(.lower, facing: doorFacing, open: false)),
                Edit(x: upper.x, y: upper.y, z: upper.z,
                     block: .oakDoor(.upper, facing: doorFacing, open: false)),
            ]

        case .bed:
            // The head goes away from the player, so you lie looking the way
            // you were walking.
            let head = (x: cell.x + look.dx, y: cell.y, z: cell.z + look.dz)
            guard isReplaceable(cell, world), isReplaceable(head, world),
                  hasSupport(cell, world), hasSupport(head, world) else { return nil }
            return [
                Edit(x: cell.x, y: cell.y, z: cell.z, block: .bed(.foot, facing: look)),
                Edit(x: head.x, y: head.y, z: head.z, block: .bed(.head, facing: look)),
            ]

        default:
            return nil
        }
    }

    /// The five that have no `placedBlock` at all — one item covering
    /// every facing of a staircase, every case of a door. Nothing else can
    /// enumerate them, because the item→block mapping only runs the other
    /// way, so the creative palette and the checks read them from here.
    static let placeableItems: [ItemType] = [
        .oakStairs, .cobbleStairs, .oakDoor, .glassPane, .bed,
    ]

    /// True for every item this file, rather than `placedBlock`, is
    /// responsible for placing.
    static func places(_ item: ItemType) -> Bool {
        switch item {
        case .oakStairs, .cobbleStairs, .oakDoor, .glassPane, .bed: return true
        // The torch has a `placedBlock`, so without naming it here it would
        // take the plain cube path and never reach the floor test above.
        case .torch, .rail, .poweredRail, .detectorRail: return true
        default: return false
        }
    }

    /// Whether a cell is free to be written into. Every placement in the
    /// game goes through this, the plain one-block kind included, so there
    /// is one answer to "is this space taken" rather than two.
    ///
    /// It asks `occupiesCell`, not `isSolid`: an open door is walked
    /// through but must not be built over, or the block would replace one
    /// half and strand the other.
    static func isReplaceable(_ cell: (x: Int, y: Int, z: Int), _ world: World) -> Bool {
        guard cell.y >= 0, cell.y < Chunk.height else { return false }
        return !world.block(worldX: cell.x, y: cell.y, worldZ: cell.z).occupiesCell
    }

    private static func hasSupport(_ cell: (x: Int, y: Int, z: Int), _ world: World) -> Bool {
        cell.y > 0 && world.isSolid(worldX: cell.x, y: cell.y - 1, worldZ: cell.z)
    }

    // MARK: - Two-cell blocks

    /// The other half of a door or a bed, if the world really has one
    /// there. Checked rather than assumed: a half whose partner was blown
    /// up by a fizzler is a cell like any other, and clearing the cell next
    /// to it because a table says so would eat whatever had moved in.
    static func partner(
        of block: BlockType, at cell: (x: Int, y: Int, z: Int), world: World
    ) -> (x: Int, y: Int, z: Int)? {
        if block.isDoor, let part = block.doorPart {
            let other = (x: cell.x, y: cell.y + (part == .lower ? 1 : -1), z: cell.z)
            guard other.y >= 0, other.y < Chunk.height else { return nil }
            let there = world.block(worldX: other.x, y: other.y, worldZ: other.z)
            guard there.isDoor, there.doorPart != part,
                  there.doorFacing == block.doorFacing else { return nil }
            return other
        }
        if block.isBed, let part = block.bedPart, let facing = block.bedFacing {
            // Facing points foot → head, so the foot looks along it and the
            // head looks back.
            let step = part == .foot ? facing : facing.opposite
            let other = (x: cell.x + step.dx, y: cell.y, z: cell.z + step.dz)
            let there = world.block(worldX: other.x, y: other.y, worldZ: other.z)
            guard there.isBed, there.bedPart != part, there.bedFacing == facing else { return nil }
            return other
        }
        return nil
    }

    /// Every cell breaking `block` at `cell` has to clear — both halves of
    /// a door or a bed, and just the one cell for anything else.
    static func removalCells(
        of block: BlockType, at cell: (x: Int, y: Int, z: Int), world: World
    ) -> [(x: Int, y: Int, z: Int)] {
        guard let other = partner(of: block, at: cell, world: world) else { return [cell] }
        return [cell, other]
    }

    // MARK: - Opening a door

    /// Both halves of the door at `cell`, with their open flag flipped, or
    /// nil if there is no door there. A door whose other half has gone
    /// still swings — it is a broken door, not a stuck one.
    static func doorToggleEdits(at cell: (x: Int, y: Int, z: Int), world: World) -> [Edit]? {
        let block = world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)
        guard block.isDoor, let flipped = block.doorToggled else { return nil }
        var edits = [Edit(x: cell.x, y: cell.y, z: cell.z, block: flipped)]
        if let other = partner(of: block, at: cell, world: world) {
            let there = world.block(worldX: other.x, y: other.y, worldZ: other.z)
            if let otherFlipped = there.doorToggled {
                edits.append(Edit(x: other.x, y: other.y, z: other.z, block: otherFlipped))
            }
        }
        return edits
    }

    // MARK: - Applying

    /// Writes a placement through the world's ordinary edit path — the same
    /// one a single block goes through, so the mesh rebuild and the
    /// buried-geometry reveal both fan out exactly as they always have.
    /// Both cells go in back to back, inside one frame.
    @discardableResult
    static func apply(_ edits: [Edit], to world: World) -> Bool {
        var allAccepted = true
        for edit in edits {
            if !world.setBlock(worldX: edit.x, y: edit.y, worldZ: edit.z, to: edit.block) {
                allAccepted = false
            }
        }
        return allAccepted
    }
}

// MARK: - Sleeping

/// What right-clicking a bed did.
enum BedUse: Equatable {
    /// Slept: the clock jumps to morning and this becomes the respawn point.
    case slept(spawn: BedSpawn)
    /// Beds only work at night, and saying so is the whole of the daytime
    /// behaviour.
    case tooEarly
}

/// Where a bed puts the player when they die. Stored as a cell rather than
/// a position so it survives a save as three integers.
struct BedSpawn: Equatable, Sendable {
    var x: Int
    var y: Int
    var z: Int

    /// Feet one cell above the bed, so waking up is not waking up inside
    /// it. `resolveSpawnOverlap` still has the last word if something has
    /// been built on top since.
    var position: Vector3 {
        Vector3(CGFloat(x) + 0.5, CGFloat(y) + 1, CGFloat(z) + 0.5)
    }
}

enum BedInteraction {
    /// Where the clock lands after a night's sleep: just past the end of
    /// `SkyController.isNight`, so waking up is unambiguously morning and
    /// cannot immediately be slept through again.
    static let morning: Double = 0.03

    /// Sleeping in the bed at `cell`. The spawn point is always the bed's
    /// *foot*, whichever half was clicked, so two clicks on one bed set the
    /// same point.
    static func sleep(
        at cell: (x: Int, y: Int, z: Int), world: World, isNight: Bool
    ) -> BedUse? {
        let block = world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)
        guard block.isBed else { return nil }
        guard isNight else { return .tooEarly }

        var foot = cell
        if block.bedPart == .head,
           let other = ShapedPlacement.partner(of: block, at: cell, world: world) {
            foot = other
        }
        return .slept(spawn: BedSpawn(x: foot.x, y: foot.y, z: foot.z))
    }
}

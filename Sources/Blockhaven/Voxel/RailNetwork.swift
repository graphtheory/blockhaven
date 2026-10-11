import Foundation

/// How a rail works out what shape it is.
///
/// A rail is the only block here whose appearance is a statement about its
/// neighbours, and it has to be, because laying track any other way is
/// miserable: without this you would place a rail and then pick from twelve
/// items to say which way it turns, for every cell of a track that is
/// hundreds of cells long. Placing one and having it join up is most of
/// what makes building a line — never mind a coaster — something a child
/// will actually do.
///
/// The original resolves the same way and this follows it: connect to whatever
/// is already there, prefer a straight over a corner, and climb when the
/// neighbour is a step up.
enum RailNetwork {
    /// The four horizontal directions, in a fixed order so a resolve is
    /// deterministic — two candidate shapes that are equally good must not
    /// be chosen between by dictionary ordering.
    static let directions: [BlockFacing] = [.north, .south, .east, .west]

    /// Whether a rail at `cell` can join a neighbour in `facing`, and at
    /// what height difference.
    ///
    /// Returns 0 for a rail on the same level, +1 for one a step up, -1 for
    /// one a step down, or nil when there is nothing there to join.
    static func connection(
        from cell: (x: Int, y: Int, z: Int), toward facing: BlockFacing, in world: World
    ) -> Int? {
        let x = cell.x + facing.dx, z = cell.z + facing.dz
        if world.block(worldX: x, y: cell.y, worldZ: z).isRail { return 0 }
        // A step up: a rail one cell higher, which this one will climb to.
        if world.block(worldX: x, y: cell.y + 1, worldZ: z).isRail { return 1 }
        // A step down: a rail one cell lower, which the *neighbour* will
        // climb. Reported so this cell knows it has a connection there, but
        // it does not make this cell a slope.
        if world.block(worldX: x, y: cell.y - 1, worldZ: z).isRail { return -1 }
        return nil
    }

    /// The shape a rail at `cell` should be, given what is around it.
    ///
    /// `preferred` is the axis the player was facing when they placed it,
    /// used only when there is nothing at all to connect to — the first
    /// rail of a new line has no neighbours and still has to point
    /// somewhere sensible.
    static func shape(
        at cell: (x: Int, y: Int, z: Int),
        preferring preferred: BlockFacing,
        powered: Bool,
        in world: World
    ) -> BlockType {
        var links: [(facing: BlockFacing, rise: Int)] = []
        for facing in directions {
            guard let rise = connection(from: cell, toward: facing, in: world) else { continue }
            links.append((facing, rise))
        }

        // Nothing to join: lie along the axis the player is facing.
        guard !links.isEmpty else {
            return straight(along: preferred, powered: powered)
        }

        // One neighbour: a straight pointing at it, climbing if it is up.
        if links.count == 1 {
            let link = links[0]
            if link.rise == 1, !powered { return slope(rising: link.facing) }
            return straight(along: link.facing, powered: powered)
        }

        // Two or more. A straight beats a corner — a run of track that
        // kinks every time it passes a siding is not a run of track — so
        // opposite pairs are looked for first.
        for facing in directions where links.contains(where: { $0.facing == facing }) {
            guard links.contains(where: { $0.facing == facing.opposite }) else { continue }
            // If one end of the straight is a step up, this cell climbs
            // toward it. A powered rail never slopes: there is no sloped
            // powered case, and a booster on a hill would be a fifth pair
            // of block types for something a flat one at the bottom does.
            if !powered, let up = links.first(where: { $0.rise == 1 }),
               up.facing == facing || up.facing == facing.opposite {
                return slope(rising: up.facing)
            }
            return straight(along: facing, powered: powered)
        }

        // No opposite pair, so it is a corner. Powered rails have no corner
        // case either, so one that finds itself on a bend lies straight
        // along its first link and lets the player sort it out.
        guard !powered else { return straight(along: links[0].facing, powered: true) }
        return curve(links[0].facing, links[1].facing) ?? straight(along: links[0].facing, powered: false)
    }

    static func straight(along facing: BlockFacing, powered: Bool) -> BlockType {
        switch facing {
        case .north, .south: return powered ? .boosterNorthSouth : .railNorthSouth
        case .east, .west: return powered ? .boosterEastWest : .railEastWest
        }
    }

    /// A detector rail's own axis, chosen once from the way the player is
    /// facing when it is placed — not threaded through `straight(along:
    /// powered:)`, because a detector is not a third value of "powered", it
    /// is a third kind of rail that shares none of that function's
    /// curve/slope behaviour: see the guard in `resolve` below, which never
    /// lets one be reshaped at all once it is down.
    static func detectorStraight(along facing: BlockFacing) -> BlockType {
        switch facing {
        case .north, .south: return .detectorNorthSouth
        case .east, .west: return .detectorEastWest
        }
    }

    static func slope(rising facing: BlockFacing) -> BlockType {
        switch facing {
        case .north: return .railSlopeNorth
        case .south: return .railSlopeSouth
        case .east: return .railSlopeEast
        case .west: return .railSlopeWest
        }
    }

    static func curve(_ a: BlockFacing, _ b: BlockFacing) -> BlockType? {
        let pair = Set([a, b])
        if pair == Set([.north, .east]) { return .railCurveNorthEast }
        if pair == Set([.north, .west]) { return .railCurveNorthWest }
        if pair == Set([.south, .east]) { return .railCurveSouthEast }
        if pair == Set([.south, .west]) { return .railCurveSouthWest }
        return nil
    }

    /// Re-resolves a cell and every rail touching it.
    ///
    /// Called after a rail is placed or broken. The neighbours matter as
    /// much as the cell itself: laying the second rail of a line has to
    /// turn the *first* one to meet it, or a track builds itself as a row
    /// of disconnected stubs all pointing the way the player happened to be
    /// looking.
    static func refresh(
        around cell: (x: Int, y: Int, z: Int), preferring preferred: BlockFacing, in world: World
    ) {
        resolve(cell, preferring: preferred, in: world)
        for facing in directions {
            for dy in [0, 1, -1] {
                let neighbour = (x: cell.x + facing.dx, y: cell.y + dy, z: cell.z + facing.dz)
                resolve(neighbour, preferring: preferred, in: world)
            }
        }
    }

    /// Rewrites one cell to the shape it should be, if it holds a rail at
    /// all and the shape it should be is not the shape it already is.
    private static func resolve(
        _ cell: (x: Int, y: Int, z: Int), preferring preferred: BlockFacing, in world: World
    ) {
        let existing = world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)
        guard existing.isRail else { return }
        // A detector rail's axis is fixed at placement and never
        // renegotiated by a neighbour's edit — `shape` has no concept of a
        // detector, only plain and powered, so letting it through here
        // would silently demote a detector rail to a plain one the moment
        // anything next to it changed.
        guard !existing.isDetectorRail else { return }
        let wanted = shape(at: cell, preferring: preferred, powered: existing.isBooster, in: world)
        guard wanted != existing else { return }
        world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: wanted)
    }

    /// Whether a rail may be laid here: it needs a full block under it, the
    /// same way a torch does. A track hanging in the air is a track a cart
    /// falls off the moment it reaches it.
    static func canPlace(at cell: (x: Int, y: Int, z: Int), in world: World) -> Bool {
        guard cell.y > 0 else { return false }
        let below = world.block(worldX: cell.x, y: cell.y - 1, worldZ: cell.z)
        return below.isSolid && !below.isShaped
    }
}

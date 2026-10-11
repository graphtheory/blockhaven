import Foundation

/// A cart on a track, and the reason the track is worth building.
///
/// The whole model is one signed scalar: how fast the cart is going along
/// the rail it is on, and which way it entered. Position is derived from
/// that and from the shape of the cell, never integrated freely — a cart is
/// *on* a rail or it is nowhere, so there is no case where it drifts off
/// the line and no floating-point creep to correct for.
///
/// Speed is what makes it a roller coaster rather than a tram. A slope
/// trades height for speed both ways, so a drop builds momentum that
/// carries up the next rise, and the ride is limited by how much you lose
/// to friction rather than by a constant the cart is clamped to. Boosters
/// are how you put the height back at the bottom.
struct Minecart {
    /// Where the cart is, in world coordinates, at the height of the rail
    /// it is riding.
    private(set) var position: Vector3
    /// Blocks a second along the track. Signed against `heading`.
    var speed: CGFloat = 0
    /// The way it is travelling. Reset at every cell boundary from the
    /// shape of the rail it enters.
    var heading: BlockFacing

    /// True while the player is aboard. A ridden cart is the one the camera
    /// follows and the one boosters are worth spending gold on.
    var isRidden = false

    /// What it's hauling, one stack at a time — a cart is a single slot,
    /// not a chest on wheels. See `HopperStore.transfer`: a hopper fills
    /// or drains this exactly the way it fills or drains a chest's one
    /// stocked slot, which is what turns a rail line into a belt a mine
    /// can empty onto without a hand ever touching the ore.
    var cargo: ItemStack?

    /// The cell it is currently over.
    var cell: (x: Int, y: Int, z: Int) {
        (Int(floor(position.x)), Int(floor(position.y)), Int(floor(position.z)))
    }

    init(position: Vector3, heading: BlockFacing) {
        self.position = position
        self.heading = heading
    }

    // MARK: - Tuning

    /// Downhill acceleration, in blocks per second squared.
    ///
    /// Not the world's gravity. A rail slope is 45 degrees, so the honest
    /// component would be about 0.7g — which on this scale sends a cart off
    /// the end of a two-block drop at a speed nothing on the track can slow
    /// down. This is tuned for a ride rather than for physics, and it is
    /// still a genuine exchange: what a drop gives, the matching rise takes
    /// back.
    static let slopeAcceleration: CGFloat = 11.0

    /// Fraction of speed shed per second. Low, because the entire pleasure
    /// of a coaster is that a drop early on is still carrying you three
    /// hundred blocks later.
    ///
    /// It cannot be zero, and the reason is worth knowing before building a
    /// track: with any loss at all, a rise the same height as the drop
    /// before it cannot be cleared. Measured — a four-block drop leaves a
    /// cart at 8.4 blocks/s and climbing four blocks back needs 9.4. That
    /// is not a bug to tune away, it is what makes a coaster a coaster:
    /// every hill has to be lower than the one before, exactly as a real
    /// one is, and a powered rail at the bottom is how you put the height
    /// back and start again.
    static let friction: CGFloat = 0.12

    /// What a powered rail adds per second while the cart is on it.
    static let boost: CGFloat = 26.0

    /// The fastest a booster will drive a cart. A drop can carry it past
    /// this — gravity is not clamped, and a cart that comes off a big fall
    /// faster than any booster could push it is the payoff for building the
    /// fall — but a flat run of powered rail settles here.
    static let boostedSpeed: CGFloat = 9.5

    /// Below this the cart is treated as stopped, so it does not creep for
    /// ever at a millionth of a block a second.
    static let stallSpeed: CGFloat = 0.05

    /// A hard ceiling, for the same reason every simulation has one: a
    /// coaster built as a thousand-block vertical drop should be
    /// spectacular, not a tunnelling bug that skips whole cells in a frame.
    static let maximumSpeed: CGFloat = 26.0

    /// How high above the cell floor the cart rides.
    static let railHeight: CGFloat = 0.12

    /// What the rider leaning on the controls adds per second.
    ///
    /// A quarter of what a powered rail gives, and it exists because
    /// without it a cart is only ever moved by the track. Get into one
    /// parked on the flat and nothing happens: movement input is suspended
    /// while riding, so there is no way to start, no way to choose which
    /// way to go, and no way off the track short of getting out. A gentle
    /// shove solves all three without turning the cart into a car — you can
    /// get yourself rolling and pick a direction, but the interesting speed
    /// still comes from hills and boosters.
    static let riderPush: CGFloat = 6.0

    /// The fastest the rider can drive a cart on their own. Well under
    /// `boostedSpeed`, so pushing is a way to get going rather than a way
    /// to beat the track.
    static let riderTopSpeed: CGFloat = 4.5

    // MARK: - Simulation

    /// Advances the cart along the track.
    ///
    /// Returns false when it has come off — no rail under it — which is the
    /// caller's cue to drop it back into the world as an item, or in the
    /// player's case to stand them up.
    @discardableResult
    mutating func step(dt: Double, world: World) -> Bool {
        let delta = CGFloat(dt)
        guard let (rail, railY) = railHere(world) else { return false }
        // A booster nobody has wired up is always on, exactly as it always
        // was; one a player has run wire to only pushes while the signal
        // network says it should — see `World.boosterIsActive`.
        let boosterActive = rail.isBooster
            && world.boosterIsActive(worldX: cell.x, y: railY, worldZ: cell.z)

        // Gravity along the rail. A slope's uphill direction is known, so
        // this is a sign rather than a dot product: travelling toward the
        // rise is climbing.
        if let rise = rail.railRise {
            let climbing = (heading == rise)
            speed -= (climbing ? 1 : -1) * Minecart.slopeAcceleration * delta
        } else if boosterActive {
            // A booster pushes the way the cart is already going, which is
            // what makes a powered rail a launcher rather than a wall. A
            // cart sitting still on one has no direction to be pushed in
            // and gets a nudge along the rail instead.
            let sign: CGFloat = abs(speed) < Minecart.stallSpeed ? 1 : (speed > 0 ? 1 : -1)
            if abs(speed) < Minecart.boostedSpeed {
                speed += sign * Minecart.boost * delta
                speed = min(max(speed, -Minecart.boostedSpeed), Minecart.boostedSpeed)
            }
        }

        speed *= max(0, 1 - Minecart.friction * delta)
        speed = min(max(speed, -Minecart.maximumSpeed), Minecart.maximumSpeed)
        if abs(speed) < Minecart.stallSpeed, rail.railRise == nil, !boosterActive {
            speed = 0
        }

        // Reversed: carry on the other way rather than sliding backwards
        // through a heading that no longer describes the travel.
        if speed < 0 {
            heading = heading.opposite
            speed = -speed
        }

        var remaining = speed * delta
        // Walked one cell at a time, so a fast cart cannot skip a corner, a
        // booster or the end of the line. The cap is a backstop against a
        // pathological dt; at the maximum speed and a sane frame this is
        // one or two passes.
        var guardCount = 0
        while remaining > 0, guardCount < 64 {
            guardCount += 1
            guard let (rail, railY) = railHere(world) else { return false }
            guard let exit = exitDirection(of: rail) else {
                // A rail that does not lead on from where we came: the end
                // of the line. Stop on it rather than running off it.
                speed = 0
                snapToCell(rail, railY: railY)
                return true
            }
            heading = exit

            // Is there anything to roll on to? A straight rail names both
            // its ends whether or not there is track beyond them, so
            // without this the last rail of a line hands the cart out into
            // the air and `railHere` then reports a derailment — which
            // loses the cart, and loses the player with it if they were in
            // it. A buffer stop is both kinder and what anyone building a
            // line expects the end of one to do.
            if !hasTrack(beyond: exit, from: railY, world: world) {
                speed = 0
                centreInCell()
                snapToCell(rail, railY: railY)
                return true
            }

            // Distance to the far edge of this cell along the heading.
            let toEdge = distanceToEdge()
            if remaining < toEdge {
                advance(remaining)
                remaining = 0
            } else {
                // Step just past the boundary, so the next pass reads the
                // next cell rather than this one again.
                advance(toEdge + 0.001)
                remaining -= toEdge
            }
            if let (next, nextY) = railHere(world) {
                snapToCell(next, railY: nextY)
            } else {
                return false
            }
        }
        return true
    }

    /// The rail the cart is over, if any. A cart on a slope is standing in
    /// the cell whose floor the slope starts at, so this also looks one
    /// cell down — otherwise a cart cresting a rise reads the air above the
    /// next rail and falls off the track at every hill.
    private func railHere(_ world: World) -> (rail: BlockType, y: Int)? {
        let c = cell
        let here = world.block(worldX: c.x, y: c.y, worldZ: c.z)
        if here.isRail { return (here, c.y) }
        let below = world.block(worldX: c.x, y: c.y - 1, worldZ: c.z)
        return below.isRail ? (below, c.y - 1) : nil
    }

    /// Whether the next cell along holds a rail — level with this one, a
    /// step up, or a step down, which are the three a track can join.
    private func hasTrack(beyond facing: BlockFacing, from railY: Int, world: World) -> Bool {
        let c = cell
        let x = c.x + facing.dx, z = c.z + facing.dz
        for dy in [0, 1, -1] where world.block(worldX: x, y: railY + dy, worldZ: z).isRail {
            return true
        }
        return false
    }

    /// Puts the cart in the middle of the cell it is in, along the track as
    /// well as across it — what a buffer stop does to a cart that reaches
    /// it, rather than leaving it hanging over the edge.
    private mutating func centreInCell() {
        position.x = floor(position.x) + 0.5
        position.z = floor(position.z) + 0.5
    }

    /// Which way out of this cell, given the way we came in.
    ///
    /// A rail joins two sides. Leaving by the side we entered from would be
    /// a bounce; leaving by the other is the track.
    private func exitDirection(of rail: BlockType) -> BlockFacing? {
        guard let ends = rail.railEnds else { return nil }
        if ends.0 == heading || ends.1 == heading { return heading }
        // Came in through one end: leave by the other.
        if ends.0 == heading.opposite { return ends.1 }
        if ends.1 == heading.opposite { return ends.0 }

        // Arrived across the rail rather than along it, which is what a
        // T-junction is: a rail only has two ends, so the through line
        // stays straight and a spur meeting it points at its side. Turn
        // onto it. Returning nil here instead — which is what this did
        // while the comment above claimed otherwise — parks the cart on
        // that cell for ever, because every later frame reads the same
        // mismatch and stops it again. Since the two ends are both square
        // to the arrival there is nothing to choose between them, so the
        // first is taken and a junction always sends you the same way.
        return ends.0
    }

    /// How far the cart is from leaving this cell along its heading.
    private func distanceToEdge() -> CGFloat {
        let fx = position.x - floor(position.x)
        let fz = position.z - floor(position.z)
        switch heading {
        case .east: return 1 - fx
        case .west: return fx
        case .south: return 1 - fz
        case .north: return fz
        }
    }

    private mutating func advance(_ distance: CGFloat) {
        position.x += CGFloat(heading.dx) * distance
        position.z += CGFloat(heading.dz) * distance
    }

    /// Puts the cart on the middle line of its rail and at the right height
    /// for it — including part-way up a slope, which is what makes a hill
    /// read as a hill from inside the cart.
    private mutating func snapToCell(_ rail: BlockType, railY: Int) {
        let c = cell
        // Centred across the track, left alone along it.
        if heading == .north || heading == .south {
            position.x = CGFloat(c.x) + 0.5
        } else {
            position.z = CGFloat(c.z) + 0.5
        }

        // Off the rail's own y, not the cart's cell. A cart cresting a
        // drop is standing in the cell *above* the rail it is riding — the
        // rail is one down — and taking the height from the cart's cell
        // would float it a block over the track for the whole descent.
        var height = CGFloat(railY) + Minecart.railHeight
        if let rise = rail.railRise {
            // How far along the climb the cart is, 0 at the low edge and 1
            // at the high one.
            let fx = position.x - floor(position.x)
            let fz = position.z - floor(position.z)
            let along: CGFloat
            switch rise {
            case .east: along = fx
            case .west: along = 1 - fx
            case .south: along = fz
            case .north: along = 1 - fz
            }
            height += along
        }
        position.y = height
    }

    /// Puts a cart on the rail at a cell, facing along it.
    static func placed(at cell: (x: Int, y: Int, z: Int), in world: World) -> Minecart? {
        let rail = world.block(worldX: cell.x, y: cell.y, worldZ: cell.z)
        guard rail.isRail, let ends = rail.railEnds else { return nil }
        var cart = Minecart(
            position: Vector3(
                CGFloat(cell.x) + 0.5,
                CGFloat(cell.y) + Minecart.railHeight,
                CGFloat(cell.z) + 0.5
            ),
            heading: ends.0
        )
        cart.snapToCell(rail, railY: cell.y)
        return cart
    }
}

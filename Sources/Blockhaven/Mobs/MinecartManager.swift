import Foundation

/// Every cart in the world, and which one the player is sitting in.
///
/// Small and deliberately dumb: carts do not interact with each other, do
/// not couple, and do not knock one another along. One cart per track is
/// what a coaster needs, and every rule two carts would need — do they
/// bump, do they stack, what happens when one catches another on a hill —
/// is a rule that can be added the day somebody wants a second cart.
struct MinecartManager {
    private(set) var carts: [Int: Minecart] = [:]
    private var nextID = 0

    /// The cart the player is in, if any.
    private(set) var ridingID: Int?

    /// Puts a cart on the rail at a cell. Returns its id, or nil if there
    /// is no rail there to put it on.
    @discardableResult
    mutating func place(at cell: (x: Int, y: Int, z: Int), in world: World) -> Int? {
        guard let cart = Minecart.placed(at: cell, in: world) else { return nil }
        nextID += 1
        carts[nextID] = cart
        return nextID
    }

    /// Climbs into a cart. The player's own physics stop mattering from
    /// here until they get out.
    mutating func ride(_ id: Int) {
        guard carts[id] != nil else { return }
        if let previous = ridingID { carts[previous]?.isRidden = false }
        ridingID = id
        carts[id]?.isRidden = true
    }

    /// Gets out. Returns where to stand the player, which is beside the
    /// cart rather than in it — standing them exactly on it drops them
    /// straight back through the rail.
    @discardableResult
    mutating func dismount() -> Vector3? {
        guard let id = ridingID, let cart = carts[id] else { return nil }
        carts[id]?.isRidden = false
        ridingID = nil
        // A step to the side of the track, and half a block up, so the
        // player lands on the ground beside the rail.
        let sideways = cart.heading.turnedLeft
        return Vector3(
            cart.position.x + CGFloat(sideways.dx) * 0.9,
            cart.position.y + 0.6,
            cart.position.z + CGFloat(sideways.dz) * 0.9
        )
    }

    /// The cart the player is in, for the camera to follow.
    var ridden: Minecart? {
        guard let ridingID else { return nil }
        return carts[ridingID]
    }

    /// The rider leaning forward or back, before the carts are stepped.
    ///
    /// `throttle` is +1 for forward and -1 for back. Which way that is
    /// along the track is decided by where the player is *looking*, not by
    /// which way the cart is already pointing: a cart has a heading even
    /// when stopped, and a rider who has to guess it in order to set off
    /// has a cart that goes the wrong way half the time. Looking down the
    /// track and pressing forward should go down the track.
    mutating func drive(throttle: CGFloat, cameraYaw: CGFloat, dt: Double) {
        guard throttle != 0, let id = ridingID, var cart = carts[id] else { return }
        // The camera's forward, against the rail's axis. Exactly on the
        // beam — looking square across the track — counts as forward, which
        // is arbitrary but has to be something.
        let facing = sin(cameraYaw) * CGFloat(cart.heading.dx)
            + cos(cameraYaw) * CGFloat(cart.heading.dz)
        let along = throttle * (facing >= 0 ? 1 : -1)

        // Pushing is capped; slowing down never is. A cart coming off a big
        // drop is doing far more than a rider could ever manage, so leaning
        // forward in one must not add to it — but leaning *back* is a
        // brake, and a brake that stops working above 4.5 blocks a second
        // is a brake for exactly the speeds nobody needs one at.
        let pushed = cart.speed + along * Minecart.riderPush * CGFloat(dt)
        if abs(pushed) <= Minecart.riderTopSpeed || abs(pushed) < abs(cart.speed) {
            cart.speed = pushed
        }

        // A negative speed is left as it is: `step` reads it as travelling
        // the other way and flips the heading, which is how backing out of
        // somewhere works.
        carts[id] = cart
    }

    /// Steps every cart. Returns the position to put the player at when
    /// they are riding one, or nil when they are not.
    ///
    /// A cart that comes off the track is removed, and if the player was in
    /// it they are handed back their own legs at the last place it was.
    mutating func update(dt: Double, world: World) -> Vector3? {
        var derailed: [Int] = []
        for id in carts.keys.sorted() {
            guard var cart = carts[id] else { continue }
            if !cart.step(dt: dt, world: world) {
                derailed.append(id)
                continue
            }
            carts[id] = cart
        }

        var standAt: Vector3?
        for id in derailed {
            if ridingID == id {
                standAt = carts[id].map {
                    Vector3($0.position.x, $0.position.y + 0.6, $0.position.z)
                }
                ridingID = nil
            }
            carts[id] = nil
        }

        if let ridden {
            // The player sits a little above the cart floor.
            return Vector3(ridden.position.x, ridden.position.y + 0.35, ridden.position.z)
        }
        return standAt
    }

    /// The nearest cart to a point within `reach`, for deciding what a
    /// right-click landed on.
    func nearest(to point: Vector3, within reach: CGFloat) -> Int? {
        var best: (id: Int, distance: CGFloat)?
        for (id, cart) in carts {
            let distance = (cart.position - point).length()
            guard distance <= reach else { continue }
            if best == nil || distance < best!.distance { best = (id, distance) }
        }
        return best?.id
    }

    /// Gives a cart a shove. The checks' way in, and the only thing that
    /// writes a cart's speed from outside its own physics — a shove is what
    /// a slope, a booster or a player pushing would all eventually be, and
    /// having one named entry point for it keeps `carts` closed.
    mutating func shove(_ id: Int, speed: CGFloat, heading: BlockFacing) {
        carts[id]?.heading = heading
        carts[id]?.speed = speed
    }

    /// Where a cart is, for the checks and for anything that wants to look
    /// without being able to move it.
    func cart(_ id: Int) -> Minecart? { carts[id] }

    /// The cart currently standing in this exact cell, if any — the way a
    /// hopper finds one to load or drain. Not a block, so `World.block`
    /// can never answer this; a cart is the one thing in the game a
    /// hopper's above/below check has to ask the manager about instead of
    /// the world.
    func cartID(at cell: (x: Int, y: Int, z: Int)) -> Int? {
        for (id, cart) in carts where cart.cell.x == cell.x && cart.cell.y == cell.y && cart.cell.z == cell.z {
            return id
        }
        return nil
    }

    /// Replaces a cart's cargo outright — a hopper's whole write access,
    /// the same single mutation `setCooldown` is for a hopper's own clock.
    mutating func setCargo(_ stack: ItemStack?, for id: Int) {
        carts[id]?.cargo = stack
    }

    /// Puts saved carts back, each under a freshly assigned id — ids are
    /// only ever session-local bookkeeping, never written to a save, so
    /// there is nothing for a reload to match them back up against and
    /// nothing lost by not trying.
    mutating func restore(_ recovered: [Minecart]) {
        for cart in recovered {
            nextID += 1
            carts[nextID] = cart
        }
    }

    /// Drops every cart — leaving a world should not leave carts rolling
    /// about in the next one.
    mutating func clear() {
        carts.removeAll()
        ridingID = nil
    }
}

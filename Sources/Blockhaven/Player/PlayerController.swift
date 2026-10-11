import Foundation

/// Pure movement physics: position, velocity, gravity, jumping, swimming
/// and creative flight, resolved against the voxel volume with a swept
/// axis-aligned box. No scene-graph dependency, so it stays testable as
/// plain Swift.
struct PlayerController {
    static let walkSpeed: CGFloat = 4.3
    static let sprintSpeed: CGFloat = 5.6
    static let sneakSpeed: CGFloat = 1.3
    static let flySpeed: CGFloat = 11.0
    static let swimSpeed: CGFloat = 3.0
    static let jumpImpulse: CGFloat = 8.4
    static let gravity: CGFloat = 26.0
    static let terminalVelocity: CGFloat = -55.0
    /// Buoyancy pulls up in water and caps how fast you sink.
    static let waterGravity: CGFloat = 6.0
    static let waterTerminalVelocity: CGFloat = -3.0
    static let swimUpSpeed: CGFloat = 4.0

    /// How high a blocked step can lift the player to get over something.
    ///
    /// It has to clear the two things you are meant to walk onto — a stair
    /// tread at 8/16 and a bed at 9/16 — and refuse the one you are not, a
    /// full block at 16/16. 0.55 was the first number tried and it is
    /// wrong by a sixteenth: it clears a tread and stops dead against a
    /// bed, which is exactly the sort of "why won't it let me" a six-year
    /// old gives up on. 0.6 clears both with room to spare and is still
    /// nowhere near a whole block, so you must still jump onto a crate and
    /// can never levitate up the side of a house.
    static let stepHeight: CGFloat = 0.6

    static let halfWidth: CGFloat = 0.3
    static let standingHeight: CGFloat = 1.8
    static let standingEyeHeight: CGFloat = 1.62
    static let sneakingEyeHeight: CGFloat = 1.44

    /// Ground acceleration, 1/s — how fast velocity closes on the input
    /// direction. Air control is a fraction of it.
    static let groundAcceleration: CGFloat = 14.0
    static let airAcceleration: CGFloat = 3.0

    /// Feet position. The collision box spans up from here.
    var position: Vector3
    var velocity = Vector3.zero
    var isGrounded = false
    var isSneaking = false
    var isSprinting = false
    var isFlying = false
    var isInWater = false
    /// Feet fully submerged — drives the swim physics and the water tint.
    var isSubmerged = false
    /// Feet touching lava — burns the moment it's true, unlike drowning
    /// there is no grace period and no full-submersion threshold: lava
    /// hurts on contact, the same as the original's own.
    var isInLava = false

    /// Distance fallen since leaving the ground, for fall damage.
    private var fallStartY: CGFloat = 0
    private var wasGrounded = true

    init(spawn: Vector3) {
        position = spawn
        fallStartY = spawn.y
    }

    var height: CGFloat { PlayerController.standingHeight }
    var eyeHeight: CGFloat {
        isSneaking ? PlayerController.sneakingEyeHeight : PlayerController.standingEyeHeight
    }
    var eyePosition: Vector3 {
        position + Vector3(0, eyeHeight, 0)
    }
    /// Puts the player somewhere without any physics having taken them
    /// there — climbing into a cart, riding one, and getting back out.
    ///
    /// A named method rather than an open setter on `position`, for the
    /// same reason `Animal.recall` is: this is a teleport, and a teleport
    /// should read as one at the call site.
    mutating func recall(to place: Vector3) {
        position = place
        velocity = .zero
    }

    var horizontalSpeed: CGFloat {
        (velocity.x * velocity.x + velocity.z * velocity.z).squareRoot()
    }

    /// Turns the WASD axes into a camera-relative world direction; zero
    /// when nothing is pressed.
    static func moveDirection(input: InputSnapshot, cameraYaw: CGFloat) -> Vector3 {
        let axisX: CGFloat = (input.rightDown ? 1 : 0) - (input.leftDown ? 1 : 0)
        let axisZ: CGFloat = (input.forwardDown ? 1 : 0) - (input.backDown ? 1 : 0)
        guard axisX != 0 || axisZ != 0 else { return .zero }
        let forward = Vector3(sin(cameraYaw), 0, cos(cameraYaw))
        let right = Vector3(-forward.z, 0, forward.x)
        return ((forward * axisZ) + (right * axisX)).normalized()
    }

    mutating func jump() {
        if isFlying { return }
        if isInWater {
            velocity.y = PlayerController.swimUpSpeed
        } else if isGrounded {
            velocity.y = PlayerController.jumpImpulse
            isGrounded = false
        }
    }

    /// Advances one frame. Returns fall damage in half-hearts to apply, or
    /// zero — landing is the only place damage originates right now.
    @discardableResult
    mutating func step(
        dt: CGFloat,
        moveDirection: Vector3,
        wantsUp: Bool,
        wantsDown: Bool,
        world: World
    ) -> Int {
        guard dt > 0 else { return 0 }

        isInWater = world.isWater(worldX: Int(floor(position.x)), y: Int(floor(position.y + 0.4)), worldZ: Int(floor(position.z)))
        isSubmerged = world.isWater(worldX: Int(floor(position.x)), y: Int(floor(position.y + eyeHeight)), worldZ: Int(floor(position.z)))
        isInLava = world.isLava(worldX: Int(floor(position.x)), y: Int(floor(position.y + 0.4)), worldZ: Int(floor(position.z)))

        let targetSpeed = currentSpeed()
        let acceleration = (isGrounded || isFlying || isInWater)
            ? PlayerController.groundAcceleration
            : PlayerController.airAcceleration
        let blend = min(1, acceleration * dt)
        velocity.x += (moveDirection.x * targetSpeed - velocity.x) * blend
        velocity.z += (moveDirection.z * targetSpeed - velocity.z) * blend

        if isFlying {
            // Creative flight: vertical input directly drives velocity, and
            // there is no gravity to fight.
            let vertical: CGFloat = (wantsUp ? 1 : 0) - (wantsDown ? 1 : 0)
            velocity.y += (vertical * PlayerController.flySpeed - velocity.y) * blend
        } else if isInWater {
            if wantsUp {
                velocity.y += (PlayerController.swimUpSpeed - velocity.y) * min(1, 8 * dt)
            } else {
                velocity.y -= PlayerController.waterGravity * dt
                velocity.y = max(PlayerController.waterTerminalVelocity, velocity.y)
            }
        } else {
            velocity.y -= PlayerController.gravity * dt
            velocity.y = max(PlayerController.terminalVelocity, velocity.y)
        }

        // Sneaking must not walk you off a ledge. Each horizontal step is
        // taken provisionally and rolled back if it leaves the player
        // standing on nothing — the original's edge-sneak, which is what makes
        // building out over a drop survivable.
        let sneakEdgeGuard = isSneaking && isGrounded && !isFlying && !isInWater
        // Auto-step only applies with your feet on the ground: in the air
        // it would be a second jump, and flying already goes over things.
        let canStep = isGrounded && !isFlying
        moveHorizontally(.x, delta: velocity.x * dt, world: world,
                         edgeGuard: sneakEdgeGuard, autoStep: canStep)
        moveHorizontally(.z, delta: velocity.z * dt, world: world,
                         edgeGuard: sneakEdgeGuard, autoStep: canStep)
        let fallingDelta = velocity.y * dt
        let landed = moveAxis(.y, delta: fallingDelta, world: world) && fallingDelta < 0

        var damage = 0
        if landed, !wasGrounded {
            let fallDistance = fallStartY - position.y
            // The original's rule: three blocks free, then a half-heart per
            // block beyond.
            if fallDistance > 3, !isInWater {
                damage = Int((fallDistance - 3).rounded(.down))
            }
        }
        if isGrounded || isFlying || isInWater {
            fallStartY = position.y
        }
        wasGrounded = isGrounded
        return damage
    }

    private func currentSpeed() -> CGFloat {
        if isFlying { return PlayerController.flySpeed }
        if isInWater { return PlayerController.swimSpeed }
        if isSneaking { return PlayerController.sneakSpeed }
        return isSprinting ? PlayerController.sprintSpeed : PlayerController.walkSpeed
    }

    private enum Axis { case x, y, z }

    /// A horizontal step that can be rolled back wholesale — used for the
    /// sneak edge guard, which needs "would this leave me unsupported?"
    /// answered after the move rather than during it.
    private mutating func moveHorizontally(
        _ axis: Axis, delta: CGFloat, world: World, edgeGuard: Bool, autoStep: Bool
    ) {
        let before: CGFloat = axis == .x ? position.x : position.z
        let blocked = moveAxis(axis, delta: delta, world: world)
        if blocked, autoStep {
            stepUp(axis, from: before, delta: delta, world: world)
        }
        // The sneak guard below can only roll back the axis, not the height
        // `stepUp` may have changed — which would leave a sneaking player
        // hanging in the air at their old footing. It cannot happen, and
        // for one reason: `stepUp` only keeps a step that has ground under
        // it, and this rolls back only when there is none, so after a
        // successful step the guard is already satisfied.
        guard edgeGuard, !hasGroundSupport(world: world) else { return }
        setAxis(axis, to: before)
        switch axis {
        case .x: velocity.x = 0
        case .z: velocity.z = 0
        case .y: break
        }
    }

    /// Retries a blocked horizontal step from up to `stepHeight` higher and
    /// settles back down onto whatever is up there.
    ///
    /// This is what makes a staircase walkable without touching the jump
    /// key, and the reason it is a *retry* rather than a lift is that the
    /// same three tests then rule out everything it must not climb: the
    /// raised box has to be clear (so there is headroom over the step), the
    /// retried move has to actually get somewhere (so a full block, which
    /// still overlaps the box at 0.55, refuses), and the settled position
    /// has to have ground under it (so you cannot step out over a drop).
    /// Any of the three failing puts the player back exactly where the
    /// blocked move left them.
    private mutating func stepUp(_ axis: Axis, from before: CGFloat, delta: CGFloat, world: World) {
        let blockedPosition = position
        let blockedVelocity = velocity
        let footY = position.y

        setAxis(axis, to: before)
        position.y = footY + PlayerController.stepHeight
        guard !collides(at: position, world: world) else {
            position = blockedPosition
            return
        }

        moveAxis(axis, delta: delta, world: world)
        let reached: CGFloat = axis == .x ? position.x : position.z
        let blockedAt: CGFloat = axis == .x ? blockedPosition.x : blockedPosition.z
        // Ahead of where the blocked move stopped, by more than the
        // bisection's own resolution.
        guard abs(reached - before) > abs(blockedAt - before) + 1e-4 else {
            position = blockedPosition
            velocity = blockedVelocity
            return
        }

        moveAxis(.y, delta: -PlayerController.stepHeight, world: world)
        guard position.y >= footY, hasGroundSupport(world: world) else {
            position = blockedPosition
            velocity = blockedVelocity
            return
        }
        // The step succeeded, so the horizontal velocity `moveAxis` zeroed
        // on the way in has to come back — otherwise walking up stairs
        // stalls for a frame on every tread.
        velocity.x = blockedVelocity.x
        velocity.z = blockedVelocity.z
        velocity.y = 0
        isGrounded = true
    }

    /// Moves along one axis and resolves any collision by backing off to
    /// the last free position. Returns true when the move hit something —
    /// for a downward Y move, that is a landing.
    @discardableResult
    private mutating func moveAxis(_ axis: Axis, delta: CGFloat, world: World) -> Bool {
        guard delta != 0 else { return false }
        let start: CGFloat
        switch axis {
        case .x: start = position.x
        case .y: start = position.y
        case .z: start = position.z
        }
        let target = start + delta

        setAxis(axis, to: target)
        guard collides(at: position, world: world) else {
            if axis == .y, delta < 0 { isGrounded = false }
            return false
        }

        // Binary search back to the furthest free point. Robust against
        // corner overlap without special-casing each face.
        var free = start
        var blocked = target
        for _ in 0..<18 {
            let mid = (free + blocked) / 2
            setAxis(axis, to: mid)
            if collides(at: position, world: world) { blocked = mid } else { free = mid }
        }
        setAxis(axis, to: free)

        switch axis {
        case .x: velocity.x = 0
        case .z: velocity.z = 0
        case .y:
            velocity.y = 0
            isGrounded = delta < 0
        }
        return true
    }

    private mutating func setAxis(_ axis: Axis, to value: CGFloat) {
        switch axis {
        case .x: position.x = value
        case .y: position.y = value
        case .z: position.z = value
        }
    }

    /// True when solid ground sits directly under the collision box —
    /// used to keep a sneaking player from stepping off an edge.
    private func hasGroundSupport(world: World) -> Bool {
        var probe = position
        probe.y -= 0.05
        return collides(at: probe, world: world)
    }

    /// Any solid block overlapping the player's AABB.
    private func collides(at feet: Vector3, world: World) -> Bool {
        let minX = feet.x - PlayerController.halfWidth
        let maxX = feet.x + PlayerController.halfWidth
        let minZ = feet.z - PlayerController.halfWidth
        let maxZ = feet.z + PlayerController.halfWidth
        let minY = feet.y
        let maxY = feet.y + height

        // `maxY`/`maxX`/`maxZ` are exclusive bounds: a box ending exactly on
        // a block boundary must not count that next block as overlapping.
        let x0 = Int(floor(minX)), x1 = Int(ceil(maxX)) - 1
        let y0 = Int(floor(minY)), y1 = Int(ceil(maxY)) - 1
        let z0 = Int(floor(minZ)), z1 = Int(ceil(maxZ)) - 1
        guard x1 >= x0, y1 >= y0, z1 >= z0 else { return false }

        for y in y0...y1 {
            for z in z0...z1 {
                for x in x0...x1 {
                    let block = world.block(worldX: x, y: y, worldZ: z)
                    guard block.isSolid else { continue }
                    // The cell-granular answer, which is the right one for
                    // every full block and is where all but a handful of
                    // cells in a world end up.
                    guard BlockType.shapedByRawValue[Int(block.rawValue)] else { return true }
                    // Every shaped block's boxes are a property of its own
                    // raw value — except a pane's, which are grown toward
                    // its neighbours at mesh time. Asking the world for them
                    // here is what keeps the player from being stopped by an
                    // arm the pane never drew.
                    let boxes = block.isPane
                        ? ShapedBlocks.paneBoxes(
                            connections: ShapedBlocks.paneConnections(
                                atX: x, y: y, z: z, world: world
                            )
                          )
                        : BlockType.collisionBoxesByRawValue[Int(block.rawValue)]
                    let originX = CGFloat(x), originY = CGFloat(y), originZ = CGFloat(z)
                    for box in boxes
                    where originX + box.minX < maxX && originX + box.maxX > minX
                        && originY + box.minY < maxY && originY + box.maxY > minY
                        && originZ + box.minZ < maxZ && originZ + box.maxZ > minZ {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// True when the given block cell overlaps the player — used to stop
    /// placing a block inside yourself.
    func overlaps(blockX x: Int, y: Int, z: Int) -> Bool {
        let minX = position.x - PlayerController.halfWidth
        let maxX = position.x + PlayerController.halfWidth
        let minZ = position.z - PlayerController.halfWidth
        let maxZ = position.z + PlayerController.halfWidth
        return CGFloat(x) < maxX && CGFloat(x + 1) > minX
            && CGFloat(z) < maxZ && CGFloat(z + 1) > minZ
            && CGFloat(y) < position.y + height && CGFloat(y + 1) > position.y
    }

    /// True when any of `boxes`, placed in the cell at (x, y, z), would
    /// overlap the player. The cell-granular test above refuses a whole
    /// doorway; this one lets a door close beside a player standing clear
    /// of where the panel actually lands.
    func overlaps(boxes: [BlockBox], blockX x: Int, y: Int, z: Int) -> Bool {
        let minX = position.x - PlayerController.halfWidth
        let maxX = position.x + PlayerController.halfWidth
        let minZ = position.z - PlayerController.halfWidth
        let maxZ = position.z + PlayerController.halfWidth
        return boxes.contains { box in
            CGFloat(x) + box.minX < maxX && CGFloat(x) + box.maxX > minX
                && CGFloat(z) + box.minZ < maxZ && CGFloat(z) + box.maxZ > minZ
                && CGFloat(y) + box.minY < position.y + height
                && CGFloat(y) + box.maxY > position.y
        }
    }

    /// Lifts the player to the surface if they spawned inside terrain, or
    /// standing in lava — chunks stream in after the spawn point is chosen,
    /// so the first frames can find the player embedded in a hillside, and
    /// a bed set near an exposed pocket makes every later death respawn
    /// straight into the one hazard in this game that burns on contact
    /// with no grace period. Lava is deliberately not solid (see
    /// `BlockType.lava`'s own doc comment — you sink into it rather than
    /// stand on it), so `collides` alone never catches this the way it
    /// already catches a hillside.
    mutating func resolveSpawnOverlap(world: World) {
        var attempts = 0
        while attempts < Chunk.height {
            let inLava = world.isLava(
                worldX: Int(floor(position.x)), y: Int(floor(position.y)), worldZ: Int(floor(position.z))
            )
            guard collides(at: position, world: world) || inLava else { break }
            position.y += 1
            attempts += 1
        }
    }
}

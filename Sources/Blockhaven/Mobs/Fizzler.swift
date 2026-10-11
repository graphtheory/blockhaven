import Foundation

/// One fizzler: position, physics and the stalk/fuse state machine.
///
/// Pure simulation over the voxel volume, with no scene-graph dependency —
/// the renderer reads `position`, `facing` and `swell` once a frame and
/// moves an entity to match. Same split as `PlayerController`.
struct Fizzler {
    /// Collision box, matching the original's: slightly narrower than a block
    /// and a shade under two blocks tall.
    static let halfWidth: CGFloat = 0.3
    static let height: CGFloat = 1.7

    static let walkSpeed: CGFloat = 2.6
    static let gravity: CGFloat = 26.0
    static let terminalVelocity: CGFloat = -55.0
    static let jumpImpulse: CGFloat = 7.4

    /// Half-hearts, on the same scale as `PlayerStats` — twenty punches to
    /// kill one bare-handed, five with a wooden sword, four with an iron.
    static let maxHealth = 20
    /// How hard a hit shoves it, and how much of that shove is upward. The
    /// pop matters more than the push: it stops the fizzler walking the
    /// knockback off before it has finished travelling.
    static let knockbackSpeed: CGFloat = 7.0
    static let knockbackLift: CGFloat = 4.6
    /// How long the red hurt flash lasts — purely a renderer cue.
    static let hurtFlashDuration: Double = 0.3
    /// How long a hit keeps hold of the fizzler's horizontal velocity. A
    /// separate clock from the flash because it is doing a different job:
    /// without it the steering blend eats the knockback in a few frames,
    /// and a fusing fizzler — which steers toward a standstill — would not
    /// move at all. Roughly the airtime `knockbackLift` buys
    /// (2 × 4.6 / 26 ≈ 0.35s).
    static let knockbackControlDuration: Double = 0.3
    /// How long the body lies there red before the manager clears it, so a
    /// kill reads as a kill rather than as the fizzler blinking out.
    static let dyingDuration: Double = 0.35

    /// How far away a fizzler notices the player.
    static let sightRange: CGFloat = 16
    /// Inside this it stops walking and lights the fuse.
    static let fuseRange: CGFloat = 3.0
    /// Past this while fusing, it backs down and goes hunting again.
    static let fuseBreakRange: CGFloat = 7.0
    /// Seconds from hiss to detonation.
    static let fuseDuration: Double = 1.5

    /// Dynamic sight range scaled by industrial disturbance: 16 blocks up to 32 blocks.
    static func effectiveSightRange(disturbance: Double) -> CGFloat {
        let factor = 1.0 + min(max(disturbance, 0.0), 100.0) / 100.0
        return min(32.0, sightRange * CGFloat(factor))
    }

    /// Dynamic fuse duration scaled by disturbance: 1.5s down to 1.2s.
    static func effectiveFuseDuration(disturbance: Double) -> Double {
        let factor = 1.0 - 0.20 * (min(max(disturbance, 0.0), 100.0) / 100.0)
        return max(1.0, fuseDuration * factor)
    }

    /// Blast radius in blocks, and the damage at ground zero.
    static let blastRadius: CGFloat = 3.0
    static let maxBlastDamage = 24

    enum Activity: Equatable {
        /// No player in range: ambling around on its own.
        case wandering
        /// Player spotted, closing in.
        case stalking
        /// Fuse lit, swelling. Payload is seconds burned so far.
        case fusing(elapsed: Double)
        /// Detonated this frame; the manager removes it.
        case exploded
    }

    private(set) var position: Vector3
    private(set) var velocity = Vector3.zero
    private(set) var activity = Activity.wandering
    /// Yaw in radians, so the renderer can face it where it's heading.
    private(set) var facing: CGFloat = 0
    private(set) var isGrounded = false
    private(set) var health = Fizzler.maxHealth
    /// Seconds left on the hurt flash, counted down by `step`.
    private(set) var hurtTimer: Double = 0
    /// Seconds the knockback still owns the horizontal velocity for.
    private(set) var knockbackTimer: Double = 0
    /// Seconds left of the dying window; only meaningful once dead.
    private(set) var dyingTimer: Double = 0

    /// 0 while calm, ramping to 1 at detonation — drives the scale-up and
    /// colour flash the renderer applies.
    var swell: Double {
        guard case .fusing(let elapsed) = activity else { return 0 }
        return min(1, elapsed / Fizzler.fuseDuration)
    }

    var hasExploded: Bool {
        if case .exploded = activity { return true }
        return false
    }

    var isDead: Bool { health <= 0 }

    /// Dead and finished lying there — the manager's cue to remove it.
    var isFinished: Bool { isDead && dyingTimer <= 0 }

    /// True while the renderer should be flashing it red. A body stays red
    /// for the whole dying window.
    var isHurt: Bool { hurtTimer > 0 || isDead }

    var eyePosition: Vector3 { position + Vector3(0, Fizzler.height * 0.85, 0) }

    /// Where it's currently ambling, in `wandering`.
    private var wanderDirection = Vector3.zero
    private var wanderTimer: Double = 0
    /// Its own deterministic noise stream, so two fizzlers spawned on the
    /// same frame don't wander in lockstep.
    private var rng: SeededGenerator

    init(position: Vector3, seed: UInt64) {
        self.position = position
        self.rng = SeededGenerator(seed: seed)
    }

    /// Advances one frame. `playerEye` is nil when the player can't be
    /// targeted at all (creative mode), which keeps fizzlers wandering.
    ///
    /// `canSeePlayer` is the caller's answer to "is there a wall in the
    /// way" — the manager asks the world once per fizzler per frame, so
    /// the simulation here stays a function of numbers it was handed.
    mutating func step(
        dt: Double,
        playerEye: Vector3?,
        canSeePlayer: Bool,
        sightRange: CGFloat? = nil,
        disturbance: Double = 0.0,
        world: World
    ) {
        guard dt > 0, !hasExploded else { return }
        let delta = CGFloat(dt)

        if isDead {
            // The dying window: `updateActivity` is skipped entirely, which
            // is what stops a fizzler killed with the fuse lit detonating
            // anyway. The killing blow's knockback and gravity still play
            // out, so the body is thrown rather than frozen.
            dyingTimer = max(0, dyingTimer - dt)
        } else {
            steer(
                dt: dt,
                delta: delta,
                playerEye: playerEye,
                canSee: canSeePlayer,
                sightRange: sightRange,
                disturbance: disturbance
            )
        }

        velocity.y -= Fizzler.gravity * delta
        velocity.y = max(Fizzler.terminalVelocity, velocity.y)

        let blockedX = !moveAxis(.x, delta: velocity.x * delta, world: world)
        let blockedZ = !moveAxis(.z, delta: velocity.z * delta, world: world)
        _ = moveAxis(.y, delta: velocity.y * delta, world: world)

        // Walked into a wall: hop it, the way the original's mobs climb a step.
        if (blockedX || blockedZ), isGrounded, !isDead, canStepUp(world: world) {
            velocity.y = Fizzler.jumpImpulse
            isGrounded = false
        }
    }

    /// One frame of the stalk/fuse machine and the steering it drives, kept
    /// apart from the physics above so the dying window can skip it whole.
    /// Only ever runs while the fizzler is alive.
    private mutating func steer(
        dt: Double,
        delta: CGFloat,
        playerEye: Vector3?,
        canSee: Bool,
        sightRange: CGFloat?,
        disturbance: Double
    ) {
        let toPlayer = playerEye.map { $0 - position }
        let distance = toPlayer?.length() ?? .greatestFiniteMagnitude
        let effectiveSight = sightRange ?? Fizzler.effectiveSightRange(disturbance: disturbance)
        let effectiveFuse = Fizzler.effectiveFuseDuration(disturbance: disturbance)

        updateActivity(dt: dt, distance: distance, canSee: canSee, effectiveSight: effectiveSight, effectiveFuse: effectiveFuse)

        var desired = Vector3.zero
        switch activity {
        case .wandering:
            desired = wanderStep(dt: dt)
        case .stalking:
            if let toPlayer {
                desired = Vector3(toPlayer.x, 0, toPlayer.z).normalized()
            }
        case .fusing, .exploded:
            // Rooted while the fuse burns — that's what makes them dodgeable.
            desired = .zero
        }

        if desired.x != 0 || desired.z != 0 {
            facing = atan2(desired.x, desired.z)
        }

        if knockbackTimer > 0 {
            knockbackTimer = max(0, knockbackTimer - dt)
        } else {
            // Accelerate toward the desired direction rather than snapping,
            // so it doesn't jitter when the target flips side to side.
            let target = desired * Fizzler.walkSpeed
            let blend = min(1, 10 * delta)
            velocity.x += (target.x - velocity.x) * blend
            velocity.z += (target.z - velocity.z) * blend
        }

        if hurtTimer > 0 { hurtTimer = max(0, hurtTimer - dt) }
    }

    /// Takes a melee hit: subtracts health, throws the body along
    /// `knockback` and lights the hurt flash.
    ///
    /// Nothing here touches `activity`. A shove that opens the gap past
    /// `fuseBreakRange` defuses the fizzler through the ordinary
    /// transition in `updateActivity`, which is also what makes the fuse
    /// restart from zero when it closes back in.
    mutating func damage(_ amount: Int, knockback: Vector3) {
        guard amount > 0, !isDead, !hasExploded else { return }
        health = max(0, health - amount)
        hurtTimer = Fizzler.hurtFlashDuration
        knockbackTimer = Fizzler.knockbackControlDuration
        if isDead { dyingTimer = Fizzler.dyingDuration }

        let push = Vector3(knockback.x, 0, knockback.z)
        if push.length() > 0.0001 {
            let direction = push.normalized()
            velocity.x = direction.x * Fizzler.knockbackSpeed
            velocity.z = direction.z * Fizzler.knockbackSpeed
        }
        velocity.y = Fizzler.knockbackLift
        isGrounded = false
    }

    /// The stalk/fuse transitions, kept apart from the movement so the
    /// hysteresis between `fuseRange` and `fuseBreakRange` is readable.
    private mutating func updateActivity(
        dt: Double,
        distance: CGFloat,
        canSee: Bool,
        effectiveSight: CGFloat,
        effectiveFuse: Double
    ) {
        switch activity {
        case .wandering:
            // Noticing you takes seeing you. Without this a fizzler
            // spawned on the far side of a hill walked at a player it had
            // no way of knowing was there.
            if distance <= effectiveSight, canSee { activity = .stalking }
        case .stalking:
            // Losing sight does *not* call the hunt off: a player who
            // ducks behind a tree is still being hunted, and a fizzler
            // that forgot them the instant they broke the line would be a
            // fizzler nobody could be caught by. Sight is what the fuse
            // needs, not what the walk needs.
            if distance > effectiveSight {
                activity = .wandering
            } else if distance <= Fizzler.fuseRange, canSee {
                activity = .fusing(elapsed: 0)
            }
        case .fusing(let elapsed):
            // Getting clear defuses it — but only well clear, otherwise it
            // flickers on and off at the boundary. Getting *out of sight*
            // defuses it immediately, and that is the whole difference
            // between a fizzler and a demolition charge: a wall between
            // the two of you is an answer, so a house is worth building
            // and worth keeping shut.
            if distance > Fizzler.fuseBreakRange || !canSee {
                activity = .stalking
            } else {
                let next = elapsed + dt
                activity = next >= effectiveFuse ? .exploded : .fusing(elapsed: next)
            }
        case .exploded:
            break
        }
    }

    /// Picks a new heading every few seconds and holds it.
    private mutating func wanderStep(dt: Double) -> Vector3 {
        wanderTimer -= dt
        guard wanderTimer <= 0 else { return wanderDirection }
        wanderTimer = 2.5 + Double.random(in: 0..<1, using: &rng) * 3.5
        // A quarter of the time it just stands still, which reads far more
        // like an animal than constant motion.
        if Double.random(in: 0..<1, using: &rng) < 0.25 {
            wanderDirection = .zero
        } else {
            let angle = Double.random(in: 0..<1, using: &rng) * 2 * .pi
            wanderDirection = Vector3(CGFloat(sin(angle)), 0, CGFloat(cos(angle)))
        }
        return wanderDirection
    }

    // MARK: - Collision

    private enum Axis { case x, y, z }

    /// Moves along one axis, backing off to the last free position on a
    /// hit. Returns true when the full step was taken.
    @discardableResult
    private mutating func moveAxis(_ axis: Axis, delta: CGFloat, world: World) -> Bool {
        guard delta != 0 else { return true }
        let start = value(of: axis)
        let target = start + delta

        setValue(target, of: axis)
        guard collides(at: position, world: world) else {
            if axis == .y, delta < 0 { isGrounded = false }
            return true
        }

        var free = start
        var blocked = target
        for _ in 0..<14 {
            let mid = (free + blocked) / 2
            setValue(mid, of: axis)
            if collides(at: position, world: world) { blocked = mid } else { free = mid }
        }
        setValue(free, of: axis)

        switch axis {
        case .x: velocity.x = 0
        case .z: velocity.z = 0
        case .y:
            isGrounded = delta < 0
            velocity.y = 0
        }
        return false
    }

    private func value(of axis: Axis) -> CGFloat {
        switch axis {
        case .x: return position.x
        case .y: return position.y
        case .z: return position.z
        }
    }

    private mutating func setValue(_ value: CGFloat, of axis: Axis) {
        switch axis {
        case .x: position.x = value
        case .y: position.y = value
        case .z: position.z = value
        }
    }

    /// True when there's headroom to hop up one block from here.
    private func canStepUp(world: World) -> Bool {
        var lifted = position
        lifted.y += 1.05
        return !collides(at: lifted, world: world)
    }

    private func collides(at feet: Vector3, world: World) -> Bool {
        let x0 = Int(floor(feet.x - Fizzler.halfWidth))
        let x1 = Int(ceil(feet.x + Fizzler.halfWidth)) - 1
        let y0 = Int(floor(feet.y))
        let y1 = Int(ceil(feet.y + Fizzler.height)) - 1
        let z0 = Int(floor(feet.z - Fizzler.halfWidth))
        let z1 = Int(ceil(feet.z + Fizzler.halfWidth)) - 1
        guard x1 >= x0, y1 >= y0, z1 >= z0 else { return false }

        for y in y0...y1 {
            for z in z0...z1 {
                for x in x0...x1 where world.obstructsMob(worldX: x, y: y, worldZ: z) {
                    return true
                }
            }
        }
        return false
    }

    /// True when this fizzler's bounding box overlaps the given block cell.
    /// A dead or exploded fizzler does not occupy space or trigger plates.
    func overlaps(blockX x: Int, y: Int, z: Int) -> Bool {
        guard !isDead, !hasExploded else { return false }
        return OccupancyQuery.overlaps(
            position: position,
            halfWidth: Fizzler.halfWidth,
            height: Fizzler.height,
            blockX: x, y: y, z: z
        )
    }
}

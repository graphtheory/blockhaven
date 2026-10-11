import Foundation

/// One skeleton: a ranged threat that never closes the distance a fizzler
/// always does. Pure simulation over the voxel volume, no scene-graph
/// dependency — same split as `Fizzler` and `PlayerController`.
///
/// The whole point of it is what it does to sightlines. A fizzler only ever
/// punishes standing still where it can *reach* you; a skeleton punishes
/// standing anywhere it can *see* you, at any range. That is a genuinely
/// different demand on the player than "hit it before it hits you" — it is
/// "get out of the light, or get behind something" — and it means the same
/// cover a wall gives against a fizzler's fuse now also matters at forty
/// blocks, not just at three.
struct Skeleton {
    /// Collision box: a shade taller and narrower than a fizzler, so the
    /// silhouette reads differently even before the skin does.
    static let halfWidth: CGFloat = 0.28
    static let height: CGFloat = 1.9

    static let walkSpeed: CGFloat = 2.2
    static let gravity: CGFloat = 26.0
    static let terminalVelocity: CGFloat = -55.0
    static let jumpImpulse: CGFloat = 7.4

    /// Half-hearts. Fewer than a fizzler's twenty — the threat here is the
    /// arrow, not the melee trade, so a skeleton that closes to melee range
    /// by accident (cornered, or chased into a dead end) should die fast
    /// once it's caught.
    static let maxHealth = 12
    static let knockbackSpeed: CGFloat = 6.0
    static let knockbackLift: CGFloat = 4.0
    static let hurtFlashDuration: Double = 0.3
    static let knockbackControlDuration: Double = 0.3
    static let dyingDuration: Double = 0.35

    /// How far away it notices the player at all.
    static let sightRange: CGFloat = 18
    /// Closer than this it backs away rather than holding ground — this is
    /// the one number that makes it kite instead of walk up like a fizzler.
    static let retreatRange: CGFloat = 6.0
    /// Past this it closes back in, so it doesn't camp at the edge of
    /// `sightRange` and never actually re-engage after being chased off.
    static let approachRange: CGFloat = 12.0
    /// Past this an arrow can't reach at all — wider than `approachRange`
    /// on purpose, so there is a band where it holds ground and shoots
    /// rather than always being caught mid-step.
    static let attackRange: CGFloat = 14.0
    /// Seconds between shots once it has a clean line.
    static let shotInterval: Double = 1.6
    /// Half-hearts an arrow costs the player — a third of a fizzler blast
    /// at ground zero, because this is meant to be survivable chip damage
    /// that pressures a bad approach, not a second way to be one-shot.
    static let shotDamage = 2

    static let fireDuration: Double = 8.0
    static let burnDamageInterval: Double = 1.0
    static let burnDamage: Int = 1
    static let shelterSearchRadius: Int = 8

    /// Dynamic sight range scaled by industrial disturbance: 18 blocks up to 32 blocks.
    static func effectiveSightRange(disturbance: Double) -> CGFloat {
        let factor = 1.0 + min(max(disturbance, 0.0), 100.0) / 100.0
        return min(32.0, sightRange * CGFloat(factor))
    }

    /// Dynamic shot interval scaled by disturbance: 1.6s down to 1.2s.
    static func effectiveShotInterval(disturbance: Double) -> Double {
        let factor = 1.0 - 0.25 * (min(max(disturbance, 0.0), 100.0) / 100.0)
        return max(1.0, shotInterval * factor)
    }

    enum Activity: Equatable {
        case wandering
        case stalking
    }

    private(set) var position: Vector3
    private(set) var velocity = Vector3.zero
    private(set) var activity = Activity.wandering
    private(set) var facing: CGFloat = 0
    private(set) var isGrounded = false
    private(set) var health = Skeleton.maxHealth
    private(set) var hurtTimer: Double = 0
    private(set) var knockbackTimer: Double = 0
    private(set) var dyingTimer: Double = 0

    private(set) var fireTicks: Double = 0
    private var burnDamageTimer: Double = 0
    private var shelterDirection: Vector3? = nil
    private var shelterScanTimer: Double = 0

    var isOnFire: Bool { fireTicks > 0 }

    /// True for exactly the frame a shot loosed. Read once by the manager
    /// right after `step` and never persisted — the same one-shot shape
    /// `Fizzler.hasExploded` uses, just without removing anything.
    private(set) var firedThisFrame = false
    private var shotCooldown: Double

    var isDead: Bool { health <= 0 }
    var isFinished: Bool { isDead && dyingTimer <= 0 }
    var isHurt: Bool { hurtTimer > 0 || isDead }
    var eyePosition: Vector3 { position + Vector3(0, Skeleton.height * 0.9, 0) }

    private var wanderDirection = Vector3.zero
    private var wanderTimer: Double = 0
    private var rng: SeededGenerator

    init(position: Vector3, seed: UInt64) {
        self.position = position
        self.rng = SeededGenerator(seed: seed)
        // Staggered from a fresh spawn rather than ready to fire the
        // instant it notices you — ties the first shot to how long it's
        // actually held a line, same as everything else about it.
        self.shotCooldown = Skeleton.shotInterval
    }

    /// True when any cell occupied by the skeleton's body holds water.
    func isInWater(world: World) -> Bool {
        let px = Int(floor(position.x))
        let py = Int(floor(position.y))
        let pz = Int(floor(position.z))
        return world.isWater(worldX: px, y: py, worldZ: pz)
            || world.isWater(worldX: px, y: py + 1, worldZ: pz)
    }

    /// True when the skeleton is in direct daytime sunlight.
    func isExposedToSunlight(isNight: Bool, isRaining: Bool, world: World) -> Bool {
        guard !isNight, !isRaining else { return false }
        guard !isInWater(world: world) else { return false }
        let px = Int(floor(position.x))
        let py = Int(floor(position.y + Skeleton.height))
        let pz = Int(floor(position.z))
        return world.isSkyOpen(worldX: px, y: py, worldZ: pz)
    }

    /// Applies periodic burn damage without knockback push or jump lift.
    mutating func takeBurnDamage(_ amount: Int) {
        guard amount > 0, !isDead else { return }
        health = max(0, health - amount)
        hurtTimer = Skeleton.hurtFlashDuration
        if isDead {
            dyingTimer = Skeleton.dyingDuration
            fireTicks = 0
        }
    }

    /// Updates solar ignition, fire countdown, and periodic burn damage.
    private mutating func updateBurn(dt: Double, isNight: Bool, isRaining: Bool, world: World) {
        guard !isDead else {
            fireTicks = 0
            burnDamageTimer = 0
            return
        }

        if isInWater(world: world) {
            fireTicks = 0
            burnDamageTimer = 0
            return
        }

        if isExposedToSunlight(isNight: isNight, isRaining: isRaining, world: world) {
            fireTicks = Skeleton.fireDuration
        }

        if fireTicks > 0 {
            fireTicks = max(0, fireTicks - dt)
            burnDamageTimer += dt
            if burnDamageTimer >= Skeleton.burnDamageInterval {
                burnDamageTimer = 0
                takeBurnDamage(Skeleton.burnDamage)
            }
        } else {
            burnDamageTimer = 0
        }
    }

    /// Scans the local neighborhood for water or shaded standable ground.
    ///
    /// Ring by ring outward rather than a solid box, and it stops as soon as
    /// nothing further out could beat what it already has. The box was
    /// 5 x 17 x 17 — fourteen hundred and forty-five cells, up to four world
    /// lookups each, four times a second for every skeleton on fire. At dawn
    /// with a full population that was tens of thousands of voxel reads per
    /// quarter second on the main thread, and almost all of it was spent
    /// confirming that the shade eight blocks away was worse than the shade
    /// already found one block away.
    ///
    /// The vertical span is one step rather than two for a plainer reason:
    /// what comes back is a flat bearing, so a hit two blocks up produced a
    /// skeleton sprinting at a ledge it had no way of climbing. One step up
    /// or down is what a walker can actually reach.
    private func shelterBearing(world: World) -> Vector3? {
        let radius = Skeleton.shelterSearchRadius
        let cx = Int(floor(position.x)), cy = Int(floor(position.y)), cz = Int(floor(position.z))
        var bestTarget: Vector3?
        var bestDistSq: CGFloat = .greatestFiniteMagnitude

        // Every cell of Chebyshev ring `r` is at least `r` away in Euclidean
        // terms, and water is preferred by a factor of 0.8 — so once
        // 0.8 * r^2 can no longer beat the best distance found, no ring from
        // here out can either.
        for ring in 0...radius {
            if bestTarget != nil {
                let floorDistSq = CGFloat(ring) * CGFloat(ring) * 0.8
                if floorDistSq >= bestDistSq { break }
            }

            for (dx, dz) in Skeleton.ringOffsets(ring) {
                let tx = cx + dx
                let tz = cz + dz
                let offset = Vector3(CGFloat(tx) + 0.5 - position.x, 0, CGFloat(tz) + 0.5 - position.z)
                let distSq = offset.x * offset.x + offset.z * offset.z
                guard distSq > 0.04 else { continue }

                for dy in -1...1 {
                    let ty = cy + dy
                    let isWater = world.isWater(worldX: tx, y: ty, worldZ: tz)
                    let isShade: Bool
                    if !isWater {
                        isShade = world.isSolid(worldX: tx, y: ty - 1, worldZ: tz)
                            && !world.obstructsMob(worldX: tx, y: ty, worldZ: tz)
                            && !world.obstructsMob(worldX: tx, y: ty + 1, worldZ: tz)
                            && !world.isSkyOpen(worldX: tx, y: ty + 1, worldZ: tz)
                    } else {
                        isShade = false
                    }
                    guard isWater || isShade else { continue }

                    let effectiveDistSq = isWater ? distSq * 0.8 : distSq
                    if effectiveDistSq < bestDistSq {
                        bestDistSq = effectiveDistSq
                        bestTarget = offset.normalized()
                    }
                }
            }
        }
        return bestTarget
    }

    /// The cells whose Chebyshev distance from the centre is exactly `ring`,
    /// walked once each — the perimeter of the square, not the square.
    private static func ringOffsets(_ ring: Int) -> [(Int, Int)] {
        guard ring > 0 else { return [(0, 0)] }
        var cells: [(Int, Int)] = []
        cells.reserveCapacity(8 * ring)
        for d in -ring...ring {
            cells.append((d, -ring))
            cells.append((d, ring))
        }
        if ring > 1 {
            for d in (-ring + 1)...(ring - 1) {
                cells.append((-ring, d))
                cells.append((ring, d))
            }
        }
        return cells
    }

    /// Advances one frame. `playerEye` is nil when the player can't be
    /// targeted (creative), which keeps it wandering same as a fizzler.
    mutating func step(
        dt: Double,
        playerEye: Vector3?,
        canSeePlayer: Bool,
        isNight: Bool = false,
        isRaining: Bool = false,
        sightRange: CGFloat? = nil,
        disturbance: Double = 0.0,
        world: World
    ) {
        guard dt > 0 else { return }
        firedThisFrame = false
        let delta = CGFloat(dt)

        updateBurn(dt: dt, isNight: isNight, isRaining: isRaining, world: world)

        if isDead {
            dyingTimer = max(0, dyingTimer - dt)
        } else {
            steer(
                dt: dt,
                delta: delta,
                playerEye: playerEye,
                canSee: canSeePlayer,
                isNight: isNight,
                isRaining: isRaining,
                sightRange: sightRange,
                disturbance: disturbance,
                world: world
            )
        }

        velocity.y -= Skeleton.gravity * delta
        velocity.y = max(Skeleton.terminalVelocity, velocity.y)

        let blockedX = !moveAxis(.x, delta: velocity.x * delta, world: world)
        let blockedZ = !moveAxis(.z, delta: velocity.z * delta, world: world)
        _ = moveAxis(.y, delta: velocity.y * delta, world: world)

        if (blockedX || blockedZ), isGrounded, !isDead, canStepUp(world: world) {
            velocity.y = Skeleton.jumpImpulse
            isGrounded = false
        }
    }

    private mutating func steer(
        dt: Double,
        delta: CGFloat,
        playerEye: Vector3?,
        canSee: Bool,
        isNight: Bool,
        isRaining: Bool,
        sightRange: CGFloat?,
        disturbance: Double,
        world: World
    ) {
        let toPlayer = playerEye.map { $0 - position }
        let distance = toPlayer?.length() ?? .greatestFiniteMagnitude
        let effectiveSight = sightRange ?? Skeleton.effectiveSightRange(disturbance: disturbance)

        updateActivity(distance: distance, canSee: canSee, effectiveSight: effectiveSight)
        updateAim(dt: dt, distance: distance, canSee: canSee, disturbance: disturbance)

        var desired = Vector3.zero

        if isOnFire || isExposedToSunlight(isNight: isNight, isRaining: isRaining, world: world) {
            shelterScanTimer -= dt
            if shelterScanTimer <= 0 {
                shelterScanTimer = 0.25
                shelterDirection = shelterBearing(world: world)
            }
            if let heading = shelterDirection {
                desired = heading
                facing = atan2(desired.x, desired.z)
            } else {
                desired = wanderStep(dt: dt)
                if desired.x != 0 || desired.z != 0 {
                    facing = atan2(desired.x, desired.z)
                }
            }
        } else {
            shelterDirection = nil
            shelterScanTimer = 0
            switch activity {
            case .wandering:
                desired = wanderStep(dt: dt)
            case .stalking:
                if let toPlayer {
                    let flat = Vector3(toPlayer.x, 0, toPlayer.z)
                    if distance < Skeleton.retreatRange {
                        // Back away rather than turn tail: it keeps facing you
                        // the whole time it retreats, which is what makes the
                        // arrow you eat mid-retreat read as aimed rather than
                        // lucky.
                        desired = Vector3.zero - flat.normalized()
                    } else if distance > Skeleton.approachRange {
                        desired = flat.normalized()
                    }
                    // Between the two ranges: hold ground and shoot.
                }
            }
        }

        if isOnFire || isExposedToSunlight(isNight: isNight, isRaining: isRaining, world: world) {
            // Facing handled above
        } else if let toPlayer, activity == .stalking {
            // Faces the player continuously while engaged, retreating or
            // not — a fizzler only turns to face where it's walking.
            facing = atan2(toPlayer.x, toPlayer.z)
        } else if desired.x != 0 || desired.z != 0 {
            facing = atan2(desired.x, desired.z)
        }

        if knockbackTimer > 0 {
            knockbackTimer = max(0, knockbackTimer - dt)
        } else {
            let target = desired * Skeleton.walkSpeed
            let blend = min(1, 10 * delta)
            velocity.x += (target.x - velocity.x) * blend
            velocity.z += (target.z - velocity.z) * blend
        }

        if hurtTimer > 0 { hurtTimer = max(0, hurtTimer - dt) }
    }

    private mutating func updateActivity(distance: CGFloat, canSee: Bool, effectiveSight: CGFloat) {
        switch activity {
        case .wandering:
            if distance <= effectiveSight, canSee { activity = .stalking }
        case .stalking:
            // Same as a fizzler: losing sight does not call the hunt off,
            // only losing range does. A player who breaks the sightline is
            // still being hunted, not forgotten.
            if distance > effectiveSight { activity = .wandering }
        }
    }

    /// Counts the shot clock down and fires whenever it reaches zero with a
    /// clean line inside range — gated on activity so a wandering skeleton
    /// never fires blind, and on `canSee` so a wall between the two of you
    /// is exactly as much of an answer to an arrow as it is to a fuse.
    private mutating func updateAim(dt: Double, distance: CGFloat, canSee: Bool, disturbance: Double) {
        guard !isDead else { return }
        shotCooldown = max(0, shotCooldown - dt)
        guard activity == .stalking, canSee, distance <= Skeleton.attackRange, shotCooldown <= 0 else { return }
        shotCooldown = Skeleton.effectiveShotInterval(disturbance: disturbance)
        firedThisFrame = true
    }

    /// Takes a melee hit: same shape as `Fizzler.damage`.
    mutating func damage(_ amount: Int, knockback: Vector3) {
        guard amount > 0, !isDead else { return }
        health = max(0, health - amount)
        hurtTimer = Skeleton.hurtFlashDuration
        knockbackTimer = Skeleton.knockbackControlDuration
        if isDead { dyingTimer = Skeleton.dyingDuration }

        let push = Vector3(knockback.x, 0, knockback.z)
        if push.length() > 0.0001 {
            let direction = push.normalized()
            velocity.x = direction.x * Skeleton.knockbackSpeed
            velocity.z = direction.z * Skeleton.knockbackSpeed
        }
        velocity.y = Skeleton.knockbackLift
        isGrounded = false
    }

    private mutating func wanderStep(dt: Double) -> Vector3 {
        wanderTimer -= dt
        guard wanderTimer <= 0 else { return wanderDirection }
        wanderTimer = 2.5 + Double.random(in: 0..<1, using: &rng) * 3.5
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

    private func canStepUp(world: World) -> Bool {
        var lifted = position
        lifted.y += 1.05
        return !collides(at: lifted, world: world)
    }

    private func collides(at feet: Vector3, world: World) -> Bool {
        let x0 = Int(floor(feet.x - Skeleton.halfWidth))
        let x1 = Int(ceil(feet.x + Skeleton.halfWidth)) - 1
        let y0 = Int(floor(feet.y))
        let y1 = Int(ceil(feet.y + Skeleton.height)) - 1
        let z0 = Int(floor(feet.z - Skeleton.halfWidth))
        let z1 = Int(ceil(feet.z + Skeleton.halfWidth)) - 1
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

    /// True when this skeleton's bounding box overlaps the given block cell.
    /// A dead skeleton does not occupy space or trigger plates.
    func overlaps(blockX x: Int, y: Int, z: Int) -> Bool {
        guard !isDead else { return false }
        return OccupancyQuery.overlaps(
            position: position,
            halfWidth: Skeleton.halfWidth,
            height: Skeleton.height,
            blockX: x, y: y, z: z
        )
    }
}

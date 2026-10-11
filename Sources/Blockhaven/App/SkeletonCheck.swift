import Foundation

/// Headless proof of the second shape of threat: something that never
/// closes the distance a fizzler always does, and that a wall answers just
/// as completely — the same sightline primitive `DangerCheck` already
/// proves a fizzler's fuse respects, now doing a second, different job.
///
/// `BLOCKHAVEN_CHECK_SKELETON=1`. Exits nonzero if any line fails.
enum SkeletonCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_SKELETON"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    private static let dt = 1.0 / 60

    static func run() -> Never {
        var report = Report()

        // MARK: a dark, roofed platform, and a wall down its middle

        let world = World()
        let spawn = world.spawnPosition()
        let originX = Int(spawn.x), originY = Int(spawn.y), originZ = Int(spawn.z)
        let half = 20
        for cz in stride(from: -half, through: half, by: Chunk.depth) {
            for cx in stride(from: -half, through: half, by: Chunk.width) {
                world.forceGenerate(World.chunkCoord(forWorldX: originX + cx, worldZ: originZ + cz))
            }
        }
        for dz in -half...half {
            for dx in -half...half {
                world.setBlock(worldX: originX + dx, y: originY - 1, worldZ: originZ + dz, to: .stone, remesh: false)
                world.setBlock(worldX: originX + dx, y: originY, worldZ: originZ + dz, to: .air, remesh: false)
                world.setBlock(worldX: originX + dx, y: originY + 1, worldZ: originZ + dz, to: .air, remesh: false)
                world.setBlock(worldX: originX + dx, y: originY + 2, worldZ: originZ + dz, to: .stone, remesh: false)
            }
        }
        // A floor-to-roof wall a few blocks from the player, tall enough
        // that nothing here paths over it by hopping — it exists purely to
        // block sight, not to be climbed.
        let wallX = originX + 5
        for dz in -half...half {
            world.setBlock(worldX: wallX, y: originY, worldZ: originZ + dz, to: .stone, remesh: false)
            world.setBlock(worldX: wallX, y: originY + 1, worldZ: originZ + dz, to: .stone, remesh: false)
        }

        let playerEye = Vector3(CGFloat(originX) + 0.5, CGFloat(originY) + 1, CGFloat(originZ) + 0.5)

        // MARK: spawning answers to the same night and the same darkness a
        // fizzler already does — no separate rule invented for it

        var nightManager = SkeletonManager(mode: .survival, seed: 7)
        var dayManager = SkeletonManager(mode: .survival, seed: 7)
        var elapsed = 0.0
        while elapsed < 40 {
            _ = nightManager.update(
                dt: dt, playerEye: playerEye, playerIsTargetable: false,
                isNight: true, isRaining: false, world: world
            )
            _ = dayManager.update(
                dt: dt, playerEye: playerEye, playerIsTargetable: false,
                isNight: false, isRaining: false, world: world
            )
            elapsed += dt
        }
        report.check(
            "it spawns into a dark night the same platform grows fizzlers on",
            nightManager.skeletons.count > 0,
            "\(nightManager.skeletons.count) skeletons after 40s of night"
        )
        report.check(
            "and never spawns at all in daylight",
            dayManager.skeletons.count == 0,
            "\(dayManager.skeletons.count) skeletons after 40s of day"
        )

        // MARK: the water column is not a safe room any more — a fully
        // submerged dark floor spawns a skeleton exactly like a dry one,
        // but a shallow puddle with its head sticking out still does not

        func floodedPlatform(headDepth: Int) -> (world: World, playerEye: Vector3) {
            let flooded = World()
            let fSpawn = flooded.spawnPosition()
            let fx = Int(fSpawn.x), fy = Int(fSpawn.y), fz = Int(fSpawn.z)
            // Wider than SkeletonManager's own maximum spawn distance, and
            // with no roof: the spawn search scans from the top of the
            // world down, so anything short of clearing every column all
            // the way up would hand it a hill or an overhang to stand on
            // instead of the lake bed this is actually testing.
            let fHalf = Int(SkeletonManager.maximumSpawnDistance) + 6
            for cz in stride(from: -fHalf, through: fHalf, by: Chunk.depth) {
                for cx in stride(from: -fHalf, through: fHalf, by: Chunk.width) {
                    flooded.forceGenerate(World.chunkCoord(forWorldX: fx + cx, worldZ: fz + cz))
                }
            }
            for dz in -fHalf...fHalf {
                for dx in -fHalf...fHalf {
                    flooded.setBlock(worldX: fx + dx, y: fy - 1, worldZ: fz + dz, to: .stone, remesh: false)
                    flooded.setBlock(worldX: fx + dx, y: fy, worldZ: fz + dz, to: .water, remesh: false)
                    let head: BlockType = headDepth >= 2 ? .water : .air
                    flooded.setBlock(worldX: fx + dx, y: fy + 1, worldZ: fz + dz, to: head, remesh: false)
                    for y in (fy + 2)...(fy + 40) {
                        flooded.setBlock(worldX: fx + dx, y: y, worldZ: fz + dz, to: .air, remesh: false)
                    }
                }
            }
            let eye = Vector3(CGFloat(fx) + 0.5, CGFloat(fy) + 1, CGFloat(fz) + 0.5)
            return (flooded, eye)
        }

        let (submergedWorld, submergedEye) = floodedPlatform(headDepth: 2)
        var submergedManager = SkeletonManager(mode: .survival, seed: 11)
        elapsed = 0
        while elapsed < 40 {
            _ = submergedManager.update(
                dt: dt, playerEye: submergedEye, playerIsTargetable: false,
                isNight: true, isRaining: false, world: submergedWorld
            )
            elapsed += dt
        }
        report.check(
            "a lake bed two cells deep is dark enough to spawn one, same as dry land",
            submergedManager.skeletons.count > 0,
            "\(submergedManager.skeletons.count) skeletons after 40s of night, fully submerged"
        )

        let (puddleWorld, puddleEye) = floodedPlatform(headDepth: 1)
        var puddleManager = SkeletonManager(mode: .survival, seed: 11)
        elapsed = 0
        while elapsed < 40 {
            _ = puddleManager.update(
                dt: dt, playerEye: puddleEye, playerIsTargetable: false,
                isNight: true, isRaining: false, world: puddleWorld
            )
            elapsed += dt
        }
        report.check(
            "but never half-submerged, head sticking out of an ankle-deep puddle",
            puddleManager.skeletons.count == 0,
            "\(puddleManager.skeletons.count) skeletons after 40s of night, one cell of water only"
        )

        // MARK: it can still see and hit you through the water that no
        // longer blocks anything else in the game either

        let underwaterShooter = Vector3(CGFloat(originX) + 2, CGFloat(originY), CGFloat(originZ))
        world.setBlock(worldX: Int(underwaterShooter.x), y: Int(underwaterShooter.y) + 1, worldZ: Int(underwaterShooter.z), to: .water)
        let sightThroughWater = MobSight.canSee(from: underwaterShooter, to: playerEye, world: world)
        report.check(
            "and sight itself never treated water as cover to begin with",
            sightThroughWater,
            "canSee through a flooded cell between shooter and player: \(sightThroughWater)"
        )
        world.setBlock(worldX: Int(underwaterShooter.x), y: Int(underwaterShooter.y) + 1, worldZ: Int(underwaterShooter.z), to: .air)

        // MARK: it keeps its distance instead of closing in like a fizzler

        func flatDistance(_ a: Vector3, _ b: Vector3) -> CGFloat {
            let d = a - b
            return CGFloat(d.x * d.x + d.z * d.z).squareRoot()
        }

        var kiter = Skeleton(position: Vector3(CGFloat(originX) + 2, CGFloat(originY), CGFloat(originZ)), seed: 99)
        let startDistance = flatDistance(playerEye, kiter.position)
        elapsed = 0
        while elapsed < 6 {
            let canSee = MobSight.canSee(from: kiter.eyePosition, to: playerEye, world: world)
            kiter.step(dt: dt, playerEye: playerEye, canSeePlayer: canSee, world: world)
            elapsed += dt
        }
        let endDistance = flatDistance(playerEye, kiter.position)
        report.check(
            "spawned point-blank, it backs off rather than holding or closing like a fizzler",
            endDistance > startDistance + 2,
            "distance went from \(startDistance) to \(endDistance) over 6s standing still"
        )

        // MARK: it fires on a clean line, and stops the instant a wall
        // breaks that line — even at the exact same range

        let nearSide = Vector3(CGFloat(wallX) - 2, CGFloat(originY), CGFloat(originZ))
        let farSide = Vector3(CGFloat(wallX) + 2, CGFloat(originY), CGFloat(originZ))

        var visible = Skeleton(position: nearSide, seed: 5)
        var shotsVisible = 0
        elapsed = 0
        while elapsed < 5 {
            let canSee = MobSight.canSee(from: visible.eyePosition, to: playerEye, world: world)
            visible.step(dt: dt, playerEye: playerEye, canSeePlayer: canSee, world: world)
            if visible.firedThisFrame { shotsVisible += 1 }
            elapsed += dt
        }
        report.check(
            "it fires when it can actually see you",
            shotsVisible > 0,
            "\(shotsVisible) shots over 5s with a clean line, "
                + "shot interval \(Skeleton.shotInterval)s"
        )

        var blocked = Skeleton(position: farSide, seed: 5)
        var shotsBlocked = 0
        elapsed = 0
        while elapsed < 5 {
            let canSee = MobSight.canSee(from: blocked.eyePosition, to: playerEye, world: world)
            blocked.step(dt: dt, playerEye: playerEye, canSeePlayer: canSee, world: world)
            if blocked.firedThisFrame { shotsBlocked += 1 }
            elapsed += dt
        }
        report.check(
            "and never fires through the same wall a fizzler's fuse already respects",
            shotsBlocked == 0,
            "\(shotsBlocked) shots over 5s at the same range with a wall between"
        )

        // MARK: an arrow costs more the farther the shot is loosed from
        // spawn — the same ramp `DangerCheck` proves for a fizzler's own
        // blast, so a skeleton is not stuck at day-one chip damage forever

        report.check(
            "chip damage right at the doorstep, same as it always was",
            SkeletonManager.shotDamage(distanceFromSpawn: 0) == Skeleton.shotDamage,
            "damage at 0: \(SkeletonManager.shotDamage(distanceFromSpawn: 0)), "
                + "unscaled: \(Skeleton.shotDamage)"
        )
        report.check(
            "and up to three times that once the ramp is behind you",
            SkeletonManager.shotDamage(distanceFromSpawn: FizzlerManager.dangerRampDistance)
                == Int((Double(Skeleton.shotDamage) * 3.0).rounded()),
            "damage at \(FizzlerManager.dangerRampDistance): "
                + "\(SkeletonManager.shotDamage(distanceFromSpawn: FizzlerManager.dangerRampDistance))"
        )

        // MARK: melee still kills it, same contract as a fizzler

        var manager = SkeletonManager(mode: .survival, seed: 3)
        var solo: Int?
        elapsed = 0
        while solo == nil, elapsed < 40 {
            _ = manager.update(
                dt: dt, playerEye: playerEye, playerIsTargetable: false,
                isNight: true, isRaining: false, world: world
            )
            solo = manager.skeletons.keys.first
            elapsed += dt
        }
        if let id = solo {
            let killed = manager.damage(id: id, amount: Skeleton.maxHealth, knockback: Vector3(1, 0, 0))
            report.check(
                "a single solid hit for its full health kills it",
                killed,
                "killed: \(killed)"
            )
        } else {
            report.check("a single solid hit for its full health kills it", false, "no skeleton ever spawned to test")
        }

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the skeleton\n"
            : "[check] all passed — the skeleton\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

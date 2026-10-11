import Foundation

/// Headless proof that the world is not the same everywhere: a night spent
/// at the doorstep and the same night spent far out are different amounts
/// of danger, not the same eight fizzlers wherever the player happens to
/// be standing.
///
/// `BLOCKHAVEN_CHECK_DANGER=1`. Exits nonzero if any line fails.
enum DangerCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_DANGER"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    /// A frame, at the rate the game runs its simulation.
    private static let dt = 1.0 / 60

    static func run() -> Never {
        var report = Report()

        // MARK: the ramp itself — a pure function of distance

        report.check(
            "flat safety right at the doorstep",
            FizzlerManager.dangerScale(distanceFromSpawn: 0) == 1.0,
            "scale at 0: \(FizzlerManager.dangerScale(distanceFromSpawn: 0))"
        )
        report.check(
            "triple pressure once the ramp is behind you",
            FizzlerManager.dangerScale(distanceFromSpawn: FizzlerManager.dangerRampDistance) == 3.0,
            "scale at \(FizzlerManager.dangerRampDistance): "
                + "\(FizzlerManager.dangerScale(distanceFromSpawn: FizzlerManager.dangerRampDistance))"
        )
        report.check(
            "and never past triple, however much further you go",
            FizzlerManager.dangerScale(distanceFromSpawn: FizzlerManager.dangerRampDistance * 4) == 3.0,
            "scale at 4x the ramp: "
                + "\(FizzlerManager.dangerScale(distanceFromSpawn: FizzlerManager.dangerRampDistance * 4))"
        )
        let midScale = FizzlerManager.dangerScale(distanceFromSpawn: FizzlerManager.dangerRampDistance / 2)
        report.check(
            "and climbs smoothly in between, not in one jump",
            midScale > 1.0 && midScale < 3.0,
            "scale at half the ramp: \(midScale)"
        )

        // MARK: the same ramp also decides what a hit costs, not just how
        // many land — otherwise "danger" only ever meant "more often"

        report.check(
            "a blast at the doorstep costs exactly what it always did",
            FizzlerManager.blastDamageMaximum(distanceFromSpawn: 0) == Fizzler.maxBlastDamage,
            "maximum at 0: \(FizzlerManager.blastDamageMaximum(distanceFromSpawn: 0)), "
                + "unscaled: \(Fizzler.maxBlastDamage)"
        )
        report.check(
            "and up to three times that once the ramp is behind you",
            FizzlerManager.blastDamageMaximum(distanceFromSpawn: FizzlerManager.dangerRampDistance)
                == Int((Double(Fizzler.maxBlastDamage) * 3.0).rounded()),
            "maximum at \(FizzlerManager.dangerRampDistance): "
                + "\(FizzlerManager.blastDamageMaximum(distanceFromSpawn: FizzlerManager.dangerRampDistance))"
        )

        // MARK: a dark flat platform, far enough from the ring that every
        // spawn attempt on it lands on floor rather than off the edge

        let world = World()
        let spawnPoint = world.spawnPosition()

        func darkPlatform(around centre: (x: Int, y: Int, z: Int), radius: Int) {
            let minCoord = World.chunkCoord(forWorldX: centre.x - radius, worldZ: centre.z - radius)
            let maxCoord = World.chunkCoord(forWorldX: centre.x + radius, worldZ: centre.z + radius)
            for cz in minCoord.z...maxCoord.z {
                for cx in minCoord.x...maxCoord.x {
                    world.forceGenerate(ChunkCoord(x: cx, z: cz))
                }
            }
            for dz in -radius...radius {
                for dx in -radius...radius {
                    world.setBlock(worldX: centre.x + dx, y: centre.y - 1, worldZ: centre.z + dz, to: .stone, remesh: false)
                    world.setBlock(worldX: centre.x + dx, y: centre.y, worldZ: centre.z + dz, to: .air, remesh: false)
                    world.setBlock(worldX: centre.x + dx, y: centre.y + 1, worldZ: centre.z + dz, to: .air, remesh: false)
                    // A roof, not open sky — this is measuring the danger
                    // ramp, not the lighting engine `SurvivalCheck` already
                    // covers, so both platforms have to be equally dark.
                    world.setBlock(worldX: centre.x + dx, y: centre.y + 2, worldZ: centre.z + dz, to: .stone, remesh: false)
                }
            }
        }

        let platformRadius = Int(FizzlerManager.maximumSpawnDistance) + 4
        // Built at spawn's own height, not some fixed depth — the ramp
        // reads three-dimensional distance on purpose (see `dangerScale`),
        // so a "near" platform dug far below spawn would already have
        // scaled up on depth alone and this check would be measuring the
        // wrong thing.
        let nearCentre = (x: Int(spawnPoint.x), y: Int(spawnPoint.y), z: Int(spawnPoint.z))
        darkPlatform(around: nearCentre, radius: platformRadius)
        let nearEye = Vector3(CGFloat(nearCentre.x) + 0.5, CGFloat(nearCentre.y) + 1, CGFloat(nearCentre.z) + 0.5)

        let farCentre = (
            x: nearCentre.x + Int(FizzlerManager.dangerRampDistance) + 100, y: nearCentre.y, z: nearCentre.z
        )
        darkPlatform(around: farCentre, radius: platformRadius)
        let farEye = Vector3(CGFloat(farCentre.x) + 0.5, CGFloat(farCentre.y) + 1, CGFloat(farCentre.z) + 0.5)

        report.check(
            "the far platform really is past the ramp",
            (farEye - spawnPoint).length() >= FizzlerManager.dangerRampDistance,
            "distance: \((farEye - spawnPoint).length())"
        )

        // MARK: the same stretch of night spawns more, faster, far out

        var near = FizzlerManager(mode: .survival, seed: 1)
        var far = FizzlerManager(mode: .survival, seed: 1)
        var elapsed = 0.0
        let budget = 45.0
        while elapsed < budget {
            _ = near.update(dt: dt, playerEye: nearEye, playerIsTargetable: false, isNight: true, isRaining: false, world: world)
            _ = far.update(dt: dt, playerEye: farEye, playerIsTargetable: false, isNight: true, isRaining: false, world: world)
            elapsed += dt
        }
        report.check(
            "the same night spawns more fizzlers far from spawn than at it",
            far.fizzlers.count > near.fizzlers.count,
            "near: \(near.fizzlers.count), far: \(far.fizzlers.count), "
                + "over \(String(format: "%.0f", budget))s of night"
        )
        report.check(
            "and the near population still respects the flat, unscaled cap",
            near.fizzlers.count <= FizzlerManager.populationCap,
            "near: \(near.fizzlers.count) against a cap of \(FizzlerManager.populationCap)"
        )
        report.check(
            "while the far population is allowed past it",
            far.fizzlers.count > FizzlerManager.populationCap,
            "far: \(far.fizzlers.count) against an unscaled cap of \(FizzlerManager.populationCap)"
        )

        // MARK: floor scenery is not a wall — a fizzler crosses a rail or a
        // wire the same way the player already walks over it, rather than
        // catching on cells whose only real shape is `[]`

        report.check(
            "a rail carries no obstruction, same as the player already sees it",
            !BlockType.railNorthSouth.obstructsMovement,
            "railNorthSouth.obstructsMovement: \(BlockType.railNorthSouth.obstructsMovement)"
        )
        report.check(
            "wire and a lever are floor scenery too",
            !BlockType.wireOff.obstructsMovement && !BlockType.leverOff.obstructsMovement,
            "wireOff: \(BlockType.wireOff.obstructsMovement), leverOff: \(BlockType.leverOff.obstructsMovement)"
        )
        report.check(
            "and so is a signal torch and a relay",
            !BlockType.signalTorchOff.obstructsMovement && !BlockType.signalRelayOff.obstructsMovement,
            "signalTorchOff: \(BlockType.signalTorchOff.obstructsMovement), "
                + "signalRelayOff: \(BlockType.signalRelayOff.obstructsMovement)"
        )
        report.check(
            "while an actual wall still obstructs exactly as it always did",
            BlockType.stone.obstructsMovement,
            "stone.obstructsMovement: \(BlockType.stone.obstructsMovement)"
        )

        // Far enough from the player that closing the gap to the near face
        // of the wire never enters `fuseRange` and detonates mid-test —
        // this is proving movement, not the fuse.
        let wireRow = nearCentre.x + 6
        for dz in -1...1 {
            world.setBlock(worldX: wireRow, y: nearCentre.y, worldZ: nearCentre.z + dz, to: .wireOff, remesh: false)
        }
        var crosser = Fizzler(
            position: Vector3(CGFloat(nearCentre.x) + 9, CGFloat(nearCentre.y), CGFloat(nearCentre.z)), seed: 3
        )
        elapsed = 0
        while elapsed < 1.5 {
            crosser.step(dt: dt, playerEye: nearEye, canSeePlayer: true, world: world)
            elapsed += dt
        }
        report.check(
            "and a fizzler actually crosses a strip of wire laid across its path",
            crosser.position.x < CGFloat(wireRow) - 0.5,
            "ended at x=\(crosser.position.x), wire at x=\(wireRow) — "
                + "a block treating `isSolid` alone as the obstruction test would stop dead at its face"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the danger\n"
            : "[check] all passed — the danger\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

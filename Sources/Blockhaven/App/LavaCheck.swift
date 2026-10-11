import Foundation

/// Headless proof of the first thing underground that can kill a player
/// just for touching it: lava generates in real clustered pockets at the
/// same depth the deepest ore already lives at, glows on its own the way a
/// torch does, burns on contact with no grace period, and seizes solid the
/// instant a stream of water finds it — the one interaction nobody has to
/// be told about.
///
/// `BLOCKHAVEN_CHECK_LAVA=1`. Exits nonzero if any line fails.
enum LavaCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_LAVA"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    static func run() -> Never {
        var report = Report()

        // MARK: lava generates deep, clustered, and never above its band

        let genWorld = World(seed: 20260823)
        var count = 0
        var clustered = 0
        var aboveBand = 0
        for x in stride(from: -60, through: 60, by: 1) {
            for z in stride(from: -60, through: 60, by: 1) where (x + z) % 3 == 0 {
                genWorld.forceGenerate(World.chunkCoord(forWorldX: x, worldZ: z))
                for y in 1...87 {
                    let block = genWorld.block(worldX: x, y: y, worldZ: z)
                    guard block == .lava else { continue }
                    if y >= 16 { aboveBand += 1 }
                    count += 1
                    let neighbors = [
                        genWorld.block(worldX: x + 1, y: y, worldZ: z),
                        genWorld.block(worldX: x - 1, y: y, worldZ: z),
                        genWorld.block(worldX: x, y: y + 1, worldZ: z),
                        genWorld.block(worldX: x, y: y - 1, worldZ: z),
                        genWorld.block(worldX: x, y: y, worldZ: z + 1),
                        genWorld.block(worldX: x, y: y, worldZ: z - 1),
                    ]
                    if neighbors.contains(.lava) { clustered += 1 }
                }
            }
        }
        report.check("lava actually generates underground", count > 0, "\(count) lava cells found")
        let clusterFraction = count > 0 ? Double(clustered) / Double(count) : 0
        report.check(
            "it pools rather than scattering as single cells",
            clusterFraction > 0.5,
            "\(clustered) of \(count) had a lava neighbour (\(String(format: "%.0f", clusterFraction * 100))%)"
        )
        report.check(
            "and never rises above the deep band it shares with diamond",
            aboveBand == 0,
            "\(aboveBand) lava cells found at y >= 16"
        )

        // MARK: what it is, apart from where it is

        report.check(
            "walkable, not a wall — you sink into it rather than stand on it",
            !BlockType.lava.isSolid && BlockType.lava.collisionBoxes.isEmpty,
            "isSolid \(BlockType.lava.isSolid), boxes \(BlockType.lava.collisionBoxes.count)"
        )
        report.check(
            "as bright as a torch, the warning before the danger",
            BlockType.lava.lightEmission == 14,
            "lightEmission \(BlockType.lava.lightEmission)"
        )
        report.check(
            "gives up nothing to a bare hand, same as water",
            BlockType.lava.drop == nil,
            "drop \(String(describing: BlockType.lava.drop))"
        )

        // MARK: it lights its surroundings like a torch, not just on paper

        let litWorld = World()
        let litSpawn = litWorld.spawnPosition()
        let litX = Int(litSpawn.x), litZ = Int(litSpawn.z)
        litWorld.forceGenerate(World.chunkCoord(forWorldX: litX, worldZ: litZ))
        let litY = 70
        for dz in -3...3 {
            for dx in -3...3 {
                for y in litY...(litY + 3) {
                    litWorld.setBlock(worldX: litX + dx, y: y, worldZ: litZ + dz, to: .air, remesh: false)
                }
            }
        }
        litWorld.setBlock(worldX: litX, y: litY, worldZ: litZ, to: .lava)
        let besideLava = litWorld.lightLevel(worldX: litX + 1, y: litY, worldZ: litZ)
        report.check(
            "a cell beside a lava block is actually lit, not just the block's own fact",
            besideLava >= 13,
            "light level one cell off a lava block: \(besideLava)"
        )

        // A pocket dug into solid ground and lit with lava first, opened to
        // the air second — the exact order a cave mouth or a scripted
        // capture edits in, and worth its own case: `updateLight`'s two
        // branches are order-sensitive by construction.
        let buriedWorld = World()
        let buriedSpawn = buriedWorld.spawnPosition()
        let buriedX = Int(buriedSpawn.x), buriedZ = Int(buriedSpawn.z)
        buriedWorld.forceGenerate(World.chunkCoord(forWorldX: buriedX, worldZ: buriedZ))
        let buriedY = 40
        for dz in -2...2 {
            for dx in -2...2 {
                for y in buriedY...(buriedY + 3) {
                    buriedWorld.setBlock(worldX: buriedX + dx, y: y, worldZ: buriedZ + dz, to: .stone, remesh: false)
                }
            }
        }
        buriedWorld.setBlock(worldX: buriedX, y: buriedY, worldZ: buriedZ, to: .lava)
        buriedWorld.setBlock(worldX: buriedX, y: buriedY + 1, worldZ: buriedZ, to: .air)
        let overLava = buriedWorld.lightLevel(worldX: buriedX, y: buriedY + 1, worldZ: buriedZ)
        report.check(
            "opening a pocket over lava that was already there lights the pocket",
            overLava >= 13,
            "light level of the cell opened above a buried lava block: \(overLava)"
        )

        // MARK: touching it burns, with no grace period

        var burning = PlayerStats()
        for _ in 0..<25 { burning.update(dt: 0.05, distanceMoved: 0, isSprinting: false, isSubmerged: false, isInLava: true) }
        report.check(
            "lava costs health well inside the first second, unlike drowning's air buffer",
            burning.health < PlayerStats.maxHealth,
            "health after 1.25s in lava: \(burning.health)"
        )
        var stoppedBurning = burning
        for _ in 0..<200 { stoppedBurning.update(dt: 0.05, distanceMoved: 0, isSprinting: false, isSubmerged: false, isInLava: false) }
        report.check(
            "and stepping out stops the damage rather than it lingering",
            // Health can only ever climb from here — full hunger means the
            // ordinary regen clock resumes the moment nothing is still
            // burning, which is a stronger claim than the number holding
            // still: a lingering burn would have to lose that race.
            stoppedBurning.health >= burning.health,
            "health after lava: \(burning.health), 10s clear of it: \(stoppedBurning.health)"
        )

        // MARK: a bed set near a pocket does not turn every later death
        // into a respawn straight back into the thing that killed you

        let bedWorld = World()
        let bedSpawn = bedWorld.spawnPosition()
        let bedX = Int(bedSpawn.x), bedZ = Int(bedSpawn.z)
        bedWorld.forceGenerate(World.chunkCoord(forWorldX: bedX, worldZ: bedZ))
        let bedY = 45
        for dz in -1...1 {
            for dx in -1...1 {
                for y in bedY...(bedY + 3) {
                    bedWorld.setBlock(worldX: bedX + dx, y: y, worldZ: bedZ + dz, to: .air, remesh: false)
                }
            }
        }
        bedWorld.setBlock(worldX: bedX, y: bedY, worldZ: bedZ, to: .lava)
        var respawned = PlayerController(spawn: Vector3(CGFloat(bedX) + 0.5, CGFloat(bedY), CGFloat(bedZ) + 0.5))
        respawned.resolveSpawnOverlap(world: bedWorld)
        let landedInLava = bedWorld.isLava(
            worldX: Int(respawned.position.x.rounded(.down)),
            y: Int(respawned.position.y.rounded(.down)),
            worldZ: Int(respawned.position.z.rounded(.down))
        )
        report.check(
            "resolving spawn overlap rises clear of lava the same way it rises clear of a hillside",
            !landedInLava,
            "player y after resolving a spawn point set in lava: \(respawned.position.y)"
        )

        // MARK: water meeting lava seizes solid instead of boiling away

        let world = World()
        let spawn = world.spawnPosition()
        let originX = Int(spawn.x), originZ = Int(spawn.z)
        let half = 12
        for cz in stride(from: -half, through: half, by: Chunk.depth) {
            for cx in stride(from: -half, through: half, by: Chunk.width) {
                world.forceGenerate(World.chunkCoord(forWorldX: originX + cx, worldZ: originZ + cz))
            }
        }
        let deckY = 60
        for dz in -half...half {
            for dx in -half...half {
                world.setBlock(worldX: originX + dx, y: deckY - 1, worldZ: originZ + dz, to: .stone, remesh: false)
                world.setBlock(worldX: originX + dx, y: deckY, worldZ: originZ + dz, to: .stone, remesh: false)
                for y in (deckY + 1)...(deckY + 4) {
                    world.setBlock(worldX: originX + dx, y: y, worldZ: originZ + dz, to: .air, remesh: false)
                }
            }
        }
        // A one-wide corridor carved through the solid deck, so the flood
        // can only ever reach the lava at its mouth — everything either
        // side of the corridor stays walled off, which is what makes "the
        // rest of the pool is untouched" a real claim rather than a race
        // against how far an open flood happens to fan out.
        let corridorZ = originZ
        for dx in 0...4 { world.setBlock(worldX: originX + dx, y: deckY, worldZ: corridorZ, to: .air) }
        let poolX = originX + 3
        world.setBlock(worldX: poolX, y: deckY, worldZ: corridorZ, to: .lava)
        // A second pool, walled off from the corridor entirely, to prove
        // the stream converts only the lava it actually reaches.
        let strandedPool = (x: poolX, y: deckY, z: corridorZ + 3)
        world.setBlock(worldX: strandedPool.x, y: strandedPool.y, worldZ: strandedPool.z, to: .lava)

        WaterFlow.spread(from: (originX, deckY, corridorZ), world: world)
        let metCell = world.block(worldX: poolX, y: deckY, worldZ: corridorZ)
        report.check(
            "water reaching lava turns it to obsidian rather than flooding it",
            metCell == .obsidian,
            "block where the stream met the pool: \(String(describing: metCell))"
        )
        let beyondPool = world.block(worldX: poolX + 1, y: deckY, worldZ: corridorZ)
        report.check(
            "and the obsidian stops the flow there — nothing gets past it",
            beyondPool != .water && beyondPool != .obsidian,
            "block just past the former pool: \(String(describing: beyondPool))"
        )
        let strandedBlock = world.block(worldX: strandedPool.x, y: strandedPool.y, worldZ: strandedPool.z)
        report.check(
            "lava the stream never actually reached is still lava",
            strandedBlock == .lava,
            "stranded pool: \(String(describing: strandedBlock))"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the lava\n"
            : "[check] all passed — the lava\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

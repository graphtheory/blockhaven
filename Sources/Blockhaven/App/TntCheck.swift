import Foundation

/// Headless proof that TNT goes off, and that a stack of it goes off as a
/// chain rather than as one bang or as a stack overflow.
///
/// The chain is the whole feature and it is the part that cannot be seen in
/// a still frame. A screenshot of a crater cannot tell you whether the
/// second stick was lit by the first or simply destroyed by it, whether
/// forty of them recursed down the Swift stack, or whether the one at the
/// bottom of the pile was quietly skipped.
///
/// `BLOCKHAVEN_CHECK_TNT=1`. Exits nonzero if any line fails.
enum TntCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_TNT"] != nil
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
        let world = World()
        let spawn = world.spawnPosition()
        let centre = World.chunkCoord(forWorldX: Int(spawn.x), worldZ: Int(spawn.z))
        for dz in -4...4 {
            for dx in -4...4 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        let originX = Int(spawn.x), originZ = Int(spawn.z)
        let floorY = 40
        // A solid room of stone to blow up, so every count below is about
        // the blast and not about whatever terrain happened to be there.
        func fillStone() {
            for y in (floorY - 6)...(floorY + 10) {
                for z in (originZ - 10)...(originZ + 10) {
                    for x in (originX - 10)...(originX + 10) {
                        world.setBlock(worldX: x, y: y, worldZ: z, to: .stone, remesh: false)
                    }
                }
            }
        }

        // MARK: one stick

        fillStone()
        var fuses = FuseManager()
        world.setBlock(worldX: originX, y: floorY, worldZ: originZ, to: .tnt)
        let lit = fuses.light(atX: originX, y: floorY, z: originZ, in: world,
                              fuse: FuseManager.litFuse)
        report.check(
            "a torch lights a stick of TNT",
            lit && fuses.live.count == 1
                && world.block(worldX: originX, y: floorY, worldZ: originZ) == .air,
            "lit \(lit), \(fuses.live.count) burning, block is now"
                + " \(String(describing: world.block(worldX: originX, y: floorY, worldZ: originZ)))"
        )

        // It must not go off early, and it must go off.
        var elapsed = 0.0
        var blasts: [FizzlerManager.Explosion] = []
        var wentOffAt = -1.0
        while elapsed < FuseManager.litFuse + 1 {
            let round = fuses.update(dt: dt, world: world, playerEye: spawn)
            elapsed += dt
            if !round.isEmpty, wentOffAt < 0 { wentOffAt = elapsed }
            blasts.append(contentsOf: round)
        }
        report.check(
            "and it burns for its whole fuse",
            wentOffAt > FuseManager.litFuse - 0.05 && wentOffAt < FuseManager.litFuse + 0.05,
            String(format: "went off at %.2f s against a %.2f s fuse", wentOffAt, FuseManager.litFuse)
        )
        report.check(
            "and it leaves a hole",
            blasts.count == 1 && blasts[0].blocksDestroyed > 100,
            "\(blasts.count) blast, \(blasts.first?.blocksDestroyed ?? 0) blocks destroyed"
        )

        // The crater has to be round, which is to say the corners of its
        // bounding box have to still be stone.
        let reach = Int(FuseManager.blastRadius)
        let corner = world.block(worldX: originX + reach, y: floorY + reach, worldZ: originZ + reach)
        let straight = world.block(worldX: originX + reach, y: floorY, worldZ: originZ)
        report.check(
            "and the hole is round, not a cube",
            corner == .stone && straight == .air,
            "corner \(String(describing: corner)), straight out \(String(describing: straight))"
        )

        // MARK: the chain

        fillStone()
        fuses = FuseManager()
        // A line of eight, spaced two apart so each one's blast reaches the
        // next but no one blast reaches them all.
        var line: [(x: Int, y: Int, z: Int)] = []
        for step in 0..<8 {
            let cell = (x: originX + step * 2, y: floorY, z: originZ)
            world.setBlock(worldX: cell.x, y: cell.y, worldZ: cell.z, to: .tnt)
            line.append(cell)
        }
        // Every one of them has to have actually landed. A cell in a chunk
        // that never generated silently swallows a `setBlock`, and a line
        // that is quietly four sticks long instead of eight makes the chain
        // below look broken when it is doing exactly what it should.
        let placed = line.filter { world.block(worldX: $0.x, y: $0.y, worldZ: $0.z) == .tnt }
        report.check(
            "the line of TNT is actually there to light",
            placed.count == line.count,
            "\(placed.count) of \(line.count) sticks placed"
        )
        fuses.light(atX: line[0].x, y: line[0].y, z: line[0].z, in: world, fuse: 0.1)

        var chainBlasts = 0
        var maximumAtOnce = 0
        var frames = 0
        var lastBlastFrame = 0
        while frames < 600 {
            let round = fuses.update(dt: dt, world: world, playerEye: spawn)
            frames += 1
            if !round.isEmpty {
                chainBlasts += round.count
                maximumAtOnce = max(maximumAtOnce, round.count)
                lastBlastFrame = frames
            }
            if fuses.live.isEmpty && chainBlasts > 0 { break }
        }

        report.check(
            "one stick sets off the whole line",
            chainBlasts == line.count,
            "\(chainBlasts) blasts from \(line.count) sticks, first lit by hand"
        )
        let leftover = line.filter { world.block(worldX: $0.x, y: $0.y, worldZ: $0.z) == .tnt }
        report.check(
            "and none of it is left standing",
            leftover.isEmpty,
            leftover.isEmpty ? "every stick went off" : "\(leftover.count) still there"
        )
        report.check(
            "and it goes off as a chain, not as one bang",
            maximumAtOnce < line.count && lastBlastFrame > 6,
            "most in any one frame \(maximumAtOnce) of \(line.count),"
                + String(format: " last at %.2f s", Double(lastBlastFrame) * dt)
        )

        // MARK: the pile

        // Forty in a solid block, all touching. This is the shape that
        // recurses if the chain is done inline, and the one that leaves
        // stragglers if a cell can be lit twice.
        fillStone()
        fuses = FuseManager()
        var pile = 0
        for y in floorY...(floorY + 3) {
            for z in (originZ - 1)...(originZ + 1) {
                for x in (originX - 1)...(originX + 1) {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .tnt)
                    pile += 1
                }
            }
        }
        fuses.light(atX: originX, y: floorY, z: originZ, in: world, fuse: 0.1)

        var pileBlasts = 0
        frames = 0
        while frames < 900 {
            pileBlasts += fuses.update(dt: dt, world: world, playerEye: spawn).count
            frames += 1
            if fuses.live.isEmpty && pileBlasts > 0 { break }
        }
        report.check(
            "a solid pile detonates every stick exactly once",
            pileBlasts == pile,
            "\(pileBlasts) blasts from a pile of \(pile)"
        )

        // MARK: what survives

        fillStone()
        fuses = FuseManager()
        for step in -2...2 {
            world.setBlock(worldX: originX + step, y: floorY - 1, worldZ: originZ + 3, to: .obsidian)
        }
        world.setBlock(worldX: originX, y: floorY, worldZ: originZ, to: .tnt)
        fuses.light(atX: originX, y: floorY, z: originZ, in: world, fuse: 0.1)
        frames = 0
        while frames < 60, !fuses.live.isEmpty {
            _ = fuses.update(dt: dt, world: world, playerEye: spawn)
            frames += 1
        }
        let obsidian = world.block(worldX: originX, y: floorY - 1, worldZ: originZ + 3)
        report.check(
            "obsidian shrugs it off",
            obsidian == .obsidian,
            "the slab is still \(String(describing: obsidian))"
        )

        // MARK: what it does to you

        let closeUp = Blast.damage(
            maximum: FuseManager.maximumDamage,
            at: Vector3(CGFloat(originX) + 0.5, CGFloat(floorY), CGFloat(originZ) + 0.5),
            from: Vector3(CGFloat(originX) + 0.5, CGFloat(floorY), CGFloat(originZ) + 0.5),
            radius: FuseManager.blastRadius
        )
        let farOff = Blast.damage(
            maximum: FuseManager.maximumDamage,
            at: Vector3(CGFloat(originX) + 30, CGFloat(floorY), CGFloat(originZ)),
            from: Vector3(CGFloat(originX), CGFloat(floorY), CGFloat(originZ)),
            radius: FuseManager.blastRadius
        )
        report.check(
            "standing on it hurts and standing away from it does not",
            closeUp == FuseManager.maximumDamage && farOff == 0,
            "\(closeUp) half-hearts at the centre, \(farOff) thirty blocks off"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the TNT\n"
            : "[check] all passed — the TNT\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

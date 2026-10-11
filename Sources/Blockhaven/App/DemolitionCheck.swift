import Foundation

/// Headless measurement of the one thing in the demo world that exists to be
/// destroyed: the dynamite Burj Khalifa, a hundred and twenty-seven blocks of
/// TNT that a single lit fuse is supposed to take down.
///
/// This is a stopwatch as much as a check. "Light it and watch it go" is the
/// demo's best trick, and a trick that takes a minute to finish is not a
/// trick — so the claims here are about *how long*, in simulated seconds and
/// in blasts, rather than only about whether the tower ends up gone.
///
/// Run via `BLOCKHAVEN_CHECK_DEMOLITION=1`. Exits nonzero on failure.
enum DemolitionCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_DEMOLITION"] != nil
    }

    /// How long the whole tower gets to come down, in simulated seconds.
    ///
    /// The chain climbs at one blast radius per fuse, so the floor under this
    /// is set by the tower's height rather than by anything tunable here: a
    /// hundred and twenty-seven blocks at 4.2 per link cannot finish in less
    /// than about thirty links of fuse. The budget is that, with room for the
    /// wings and the spire, and it is deliberately far under the minute the
    /// original took — a player who lights this and walks away has already
    /// stopped watching.
    static let simulatedSecondsBudget: Double = 12

    /// The fraction of the tower's dynamite that has to have gone off.
    static let demolishedFraction: Double = 0.98

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[demolition] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }

        mutating func note(_ detail: String) {
            lines.append("[demolition] \(detail)")
        }
    }

    static func run() -> Never {
        var report = Report()
        let world = World(seed: DemoWorld.seed)
        DemoWorld.build(in: world)

        let site = DemoWorld.dynamiteBurjSite
        let centre = World.chunkCoord(forWorldX: site.x, worldZ: site.z)
        // The tower's footprint plus the reach of the blasts coming off it.
        for dz in -3...3 {
            for dx in -3...3 {
                world.forceGenerate(ChunkCoord(x: centre.x + dx, z: centre.z + dz))
            }
        }

        let span = 28
        let deck = DemoWorld.deck
        func countTNT() -> Int {
            var total = 0
            for z in (site.z - span)...(site.z + span) {
                for x in (site.x - span)...(site.x + span) {
                    for y in deck...(Chunk.height - 1) where world.block(worldX: x, y: y, worldZ: z) == .tnt {
                        total += 1
                    }
                }
            }
            return total
        }

        let standing = countTNT()
        report.note("the dynamite tower stands in \(standing) blocks of TNT")

        // The lowest stick in the tower, which is where a player with a
        // flint and steel would start.
        var ignition: (x: Int, y: Int, z: Int)?
        outer: for y in deck...(Chunk.height - 1) {
            for z in (site.z - span)...(site.z + span) {
                for x in (site.x - span)...(site.x + span) where world.block(worldX: x, y: y, worldZ: z) == .tnt {
                    ignition = (x, y, z)
                    break outer
                }
            }
        }

        guard let start = ignition else {
            report.check("the dynamite tower has TNT to light", false, "found none between y \(deck) and \(Chunk.height - 1)")
            for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
            StandardError.write(Data("[demolition] FAILED — the demolition\n".utf8))
            exit(1)
        }

        let fuses = FuseManager()
        fuses.light(atX: start.x, y: start.y, z: start.z, in: world, fuse: FuseManager.litFuse)

        // Far enough away that the player takes nothing and the damage maths
        // stays out of the measurement.
        let eye = Vector3(CGFloat(site.x + 400), CGFloat(deck + 2), CGFloat(site.z))
        let step = 1.0 / 60.0
        var simulated: Double = 0
        var explosions = 0
        var destroyed = 0
        var peakPrimed = 0
        // Frames in which at least one blast went off. The world-wide
        // bookkeeping after a blast (store prunes, and a re-flood of every
        // signal source) is per frame rather than per explosion, so this is
        // how many times it actually runs.
        var framesWithBlasts = 0
        let wallStart = Date()

        // A generous cap: this is the runaway detector, not the budget.
        while !fuses.primed.isEmpty && simulated < 120 {
            peakPrimed = max(peakPrimed, fuses.primed.count)
            let wave = fuses.update(dt: step, world: world, playerEye: eye)
            explosions += wave.count
            if !wave.isEmpty { framesWithBlasts += 1 }
            for blast in wave { destroyed += blast.blocksDestroyed }
            simulated += step
        }
        let wall = Date().timeIntervalSince(wallStart)

        // The fuse the player lit burns before anything happens, and that
        // wait is the trick working rather than the trick being slow.
        let chainSeconds = max(0, simulated - FuseManager.litFuse)
        let remaining = countTNT()
        let goneFraction = standing > 0 ? Double(standing - remaining) / Double(standing) : 0

        report.note(
            "\(explosions) blasts took out \(destroyed) blocks in \(String(format: "%.2f", chainSeconds))s of chain "
            + "(\(String(format: "%.2f", simulated))s including the lit fuse), peak \(peakPrimed) primed at once"
        )
        report.note("wall clock for the whole demolition: \(String(format: "%.2f", wall))s")

        report.check(
            "one lit fuse brings the whole dynamite tower down",
            goneFraction >= demolishedFraction,
            "\(standing - remaining) of \(standing) sticks went off (\(String(format: "%.1f", goneFraction * 100))%), \(remaining) left standing"
        )

        report.check(
            "the tower comes down inside its time budget",
            chainSeconds <= simulatedSecondsBudget,
            "\(String(format: "%.2f", chainSeconds))s of chain against a \(String(format: "%.0f", simulatedSecondsBudget))s budget"
        )

        // The sweep is the expensive half and it is bounded by frames, not by
        // blasts. Before this was hoisted out of the per-explosion path the
        // two numbers were the same, and the ratio below is how much work
        // lighting this tower used to do for no additional effect.
        report.check(
            "world-wide blast bookkeeping is bounded by frames rather than by blasts",
            framesWithBlasts < explosions / 10,
            "\(framesWithBlasts) frames carried \(explosions) blasts "
            + "(\(String(format: "%.1f", Double(explosions) / Double(max(framesWithBlasts, 1))))x fewer sweeps)"
        )

        report.check(
            "the chain finishes rather than running to the cap",
            simulated < 120,
            "stopped at \(String(format: "%.2f", simulated))s with \(fuses.primed.count) still primed"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[demolition] FAILED — the demolition\n"
            : "[demolition] all passed — the demolition\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

import Foundation

/// Headless proof of the one underground find that isn't a resource: a
/// cavern is a room, not a corridor, and the room itself is the discovery —
/// the same job a ruin does on the surface, but for a player who went down
/// instead of out.
///
/// `BLOCKHAVEN_CHECK_CAVERN=1`. Exits nonzero if any line fails.
enum CavernCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_CAVERN"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    /// The offsets a cell has to be air at, along all six axis directions,
    /// to count as standing in the open rather than in a corridor. Four
    /// blocks out is well past anything the ordinary tunnel noise carves —
    /// `isCave`'s own threshold winds a passage two or three cells wide —
    /// so a cell that is air out to four in every direction is standing
    /// somewhere the winding tunnels don't reach on their own.
    private static let openReach = 4
    private static let axisOffsets: [(Int, Int, Int)] = [
        (openReach, 0, 0), (-openReach, 0, 0),
        (0, openReach, 0), (0, -openReach, 0),
        (0, 0, openReach), (0, 0, -openReach),
    ]

    static func run() -> Never {
        var report = Report()
        let world = World()

        var airCells = 0
        var openCells = 0
        var openBelowBand = 0
        var openAboveBand = 0
        var firstOpen: (x: Int, y: Int, z: Int)?

        for x in stride(from: -60, through: 60, by: 1) {
            for z in stride(from: -60, through: 60, by: 1) where (x + z) % 3 == 0 {
                world.forceGenerate(World.chunkCoord(forWorldX: x, worldZ: z))
                for y in 5...60 {
                    guard world.block(worldX: x, y: y, worldZ: z) == .air else { continue }
                    airCells += 1
                    let isOpen = CavernCheck.axisOffsets.allSatisfy { dx, dy, dz in
                        world.block(worldX: x + dx, y: y + dy, worldZ: z + dz) == .air
                    }
                    guard isOpen else { continue }
                    openCells += 1
                    if firstOpen == nil { firstOpen = (x, y, z) }
                    if y <= 8 { openBelowBand += 1 }
                    if y >= 50 { openAboveBand += 1 }
                }
            }
        }

        report.check(
            "a cavern actually generates — a cell open four blocks in every direction",
            openCells > 0,
            "\(openCells) open cells found among \(airCells) air cells scanned"
        )
        report.check(
            "and it is a genuinely different find from the winding tunnels, not more of them",
            airCells > 0 && Double(openCells) / Double(airCells) < 0.05,
            "\(openCells) of \(airCells) air cells qualify as open "
                + "(\(String(format: "%.1f", airCells > 0 ? Double(openCells) / Double(airCells) * 100 : 0))%)"
        )
        report.check(
            "and stays inside the band ore already lives in",
            openBelowBand == 0 && openAboveBand == 0,
            "\(openBelowBand) open cells at y <= 8, \(openAboveBand) at y >= 50"
        )

        if let cell = firstOpen {
            StandardError.write(Data(
                "[check] first open cell found at \(cell.x),\(cell.y),\(cell.z)\n".utf8
            ))
        }

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the cavern\n"
            : "[check] all passed — the cavern\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

import Foundation

/// Headless proof that a compass needle actually tracks home rather than
/// just decorating the hotbar: it points dead ahead when home is dead
/// ahead regardless of which way that "ahead" is, swings to match a turn,
/// and its distance reading shrinks as the player walks in.
///
/// `BLOCKHAVEN_CHECK_COMPASS=1`. Exits nonzero if any line fails.
enum CompassCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_COMPASS"] != nil
    }

    private struct Report {
        var lines: [String] = []
        var failed = false

        mutating func check(_ name: String, _ passed: Bool, _ detail: String) {
            lines.append("[check] \(name): \(passed ? "ok" : "FAILED") — \(detail)")
            if !passed { failed = true }
        }
    }

    private static func nearlyEqual(_ a: CGFloat, _ b: CGFloat, tolerance: CGFloat = 0.001) -> Bool {
        var diff = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if diff > .pi { diff -= 2 * .pi }
        if diff < -.pi { diff += 2 * .pi }
        return abs(diff) <= tolerance
    }

    static func run() -> Never {
        var report = Report()
        let player = Vector3(0, 70, 0)

        // Home due south of the player (matches the game's own yaw=0
        // convention: facing south is +Z). Facing yaw 0 should read as
        // dead ahead — needle angle 0.
        let south = Vector3(0, 70, 10)
        report.check(
            "home straight ahead reads as dead ahead",
            nearlyEqual(Compass.needleAngle(from: player, home: south, cameraYaw: 0), 0),
            "angle: \(Compass.needleAngle(from: player, home: south, cameraYaw: 0))"
        )

        // Turning 90 degrees toward home (facing east, yaw = pi/2) with
        // home still due south should swing the needle a quarter turn.
        report.check(
            "turning toward home swings the needle back toward dead ahead",
            nearlyEqual(Compass.needleAngle(from: player, home: south, cameraYaw: .pi / 2), -.pi / 2),
            "angle: \(Compass.needleAngle(from: player, home: south, cameraYaw: .pi / 2))"
        )

        // Home directly behind (still facing south, home due north) reads
        // as a half turn either way.
        let north = Vector3(0, 70, -10)
        let behind = Compass.needleAngle(from: player, home: north, cameraYaw: 0)
        report.check(
            "home directly behind reads as a half turn",
            nearlyEqual(abs(behind), .pi),
            "angle: \(behind)"
        )

        // Home due east of a player facing south reads a quarter turn one
        // way; due west, a quarter turn the other — proving left and right
        // aren't mirrored.
        let east = Vector3(10, 70, 0)
        let west = Vector3(-10, 70, 0)
        let eastAngle = Compass.needleAngle(from: player, home: east, cameraYaw: 0)
        let westAngle = Compass.needleAngle(from: player, home: west, cameraYaw: 0)
        report.check(
            "east and west of dead-ahead read as opposite turns",
            nearlyEqual(eastAngle, .pi / 2) && nearlyEqual(westAngle, -.pi / 2),
            "east: \(eastAngle), west: \(westAngle)"
        )

        // Distance shrinks as the player walks toward home, and reads zero
        // once standing on it.
        let far = Compass.distance(from: Vector3(0, 70, 0), home: Vector3(0, 70, 100))
        let near = Compass.distance(from: Vector3(0, 70, 80), home: Vector3(0, 70, 100))
        let atHome = Compass.distance(from: Vector3(0, 70, 100), home: Vector3(0, 70, 100))
        report.check(
            "distance shrinks while walking in, and reads zero standing on it",
            far > near && near > atHome && atHome == 0,
            "far: \(far), near: \(near), atHome: \(atHome)"
        )

        // A recipe exists and the item is filed, so it's actually reachable
        // through the crafting book rather than only through this check.
        let recipe = RecipeBook.all.first { $0.output.type == .compass }
        report.check(
            "a recipe makes a compass, and it needs a table",
            recipe != nil && recipe!.requiresTable,
            "recipe: \(String(describing: recipe?.pattern)), requiresTable: \(String(describing: recipe?.requiresTable))"
        )
        report.check(
            "the recipe book files it under tools rather than leaving it unfiled",
            recipe?.group == .tools,
            "group: \(String(describing: recipe?.group))"
        )

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the compass\n"
            : "[check] all passed — the compass\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

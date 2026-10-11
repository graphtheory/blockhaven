import Foundation

/// Headless proof that the rename keeps everyone's worlds and settings:
/// an earlier build's save folder and settings, laid out in a scratch
/// directory and a scratch settings domain, come across to the new names
/// whole — and the old ones are left exactly as they were.
///
/// `BLOCKHAVEN_CHECK_MIGRATION=1`. Exits nonzero if any line fails. Never
/// touches the real save folder or the real settings.
enum MigrationCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CHECK_MIGRATION"] != nil
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
        let manager = FileManager.default
        let scratch = manager.temporaryDirectory
            .appendingPathComponent("blockhaven-migration-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        defer { try? manager.removeItem(at: scratch) }
        let old = scratch.appendingPathComponent(LegacyMigration.legacyFolderName, isDirectory: true)
        let new = scratch.appendingPathComponent("Blockhaven", isDirectory: true)
        let world = Data(#"{"name":"Kids' castle"}"#.utf8)
        try? manager.createDirectory(at: old.appendingPathComponent("saves"), withIntermediateDirectories: true)
        try? world.write(to: old.appendingPathComponent("saves/castle.json"))
        try? world.write(to: old.appendingPathComponent("world.json"))

        // MARK: a fresh computer — nothing new yet

        let first = LegacyMigration.copySaves(from: old, to: new)
        let copiedWorld = try? Data(contentsOf: new.appendingPathComponent("saves/castle.json"))
        report.check(
            "an earlier save folder is copied to the new name, worlds intact",
            copiedWorld == world && manager.fileExists(atPath: new.appendingPathComponent("world.json").path),
            first
        )
        report.check(
            "the earlier folder is left in place as the backup",
            (try? Data(contentsOf: old.appendingPathComponent("saves/castle.json"))) == world,
            "old world still readable"
        )
        let leftovers = ((try? manager.contentsOfDirectory(atPath: new.path)) ?? []).filter { $0.hasSuffix(".copying") }
        report.check("no half-copied items are left behind", leftovers.isEmpty, "leftovers: \(leftovers)")

        // MARK: the new folder already exists (the run log made it first)

        try? manager.removeItem(at: new)
        try? manager.createDirectory(at: new, withIntermediateDirectories: true)
        try? Data("log".utf8).write(to: new.appendingPathComponent("last-run.log"))
        let second = LegacyMigration.copySaves(from: old, to: new)
        report.check(
            "worlds still come across when the new folder already holds a log",
            (try? Data(contentsOf: new.appendingPathComponent("saves/castle.json"))) == world,
            second
        )

        // MARK: an empty `saves` folder is already there

        try? manager.removeItem(at: new)
        try? manager.createDirectory(at: new.appendingPathComponent("saves"), withIntermediateDirectories: true)
        let third = LegacyMigration.copySaves(from: old, to: new)
        report.check(
            "worlds still come across into a saves folder something created empty",
            (try? Data(contentsOf: new.appendingPathComponent("saves/castle.json"))) == world,
            third
        )

        // MARK: nothing is overwritten

        let newer = Data(#"{"name":"played since"}"#.utf8)
        try? newer.write(to: new.appendingPathComponent("saves/castle.json"))
        _ = LegacyMigration.copySaves(from: old, to: new)
        report.check(
            "a world already under the new name is never overwritten",
            (try? Data(contentsOf: new.appendingPathComponent("saves/castle.json"))) == newer,
            "kept the newer copy"
        )

        // MARK: settings, including the chosen worlds folder

        let oldSuite = "blockhaven.check.old.\(ProcessInfo.processInfo.processIdentifier)"
        let newSuite = "blockhaven.check.new.\(ProcessInfo.processInfo.processIdentifier)"
        if let oldDefaults = UserDefaults(suiteName: oldSuite), let newDefaults = UserDefaults(suiteName: newSuite) {
            oldDefaults.set("/Users/kid/OneDrive/Games", forKey: LegacyMigration.legacyKeyPrefix + "worldsFolder")
            oldDefaults.set("sv", forKey: LegacyMigration.legacyKeyPrefix + "language")
            oldDefaults.set(false, forKey: LegacyMigration.legacyKeyPrefix + "fullscreen")
            newDefaults.set("en", forKey: "blockhaven.language")
            let copied = LegacyMigration.copySettings(from: [oldDefaults], into: newDefaults)
            report.check(
                "the chosen worlds folder and other settings carry over",
                newDefaults.string(forKey: "blockhaven.worldsFolder") == "/Users/kid/OneDrive/Games"
                    && newDefaults.object(forKey: "blockhaven.fullscreen") as? Bool == false,
                "copied \(copied)"
            )
            report.check(
                "a setting already made under the new name wins",
                newDefaults.string(forKey: "blockhaven.language") == "en",
                "language: \(String(describing: newDefaults.string(forKey: "blockhaven.language")))"
            )
            oldDefaults.removePersistentDomain(forName: oldSuite)
            newDefaults.removePersistentDomain(forName: newSuite)
        } else {
            report.check("scratch settings domains open", false, "UserDefaults(suiteName:) returned nil")
        }

        for line in report.lines { StandardError.write(Data((line + "\n").utf8)) }
        let verdict = report.failed
            ? "[check] FAILED — the migration from the earlier name\n"
            : "[check] all passed — the migration from the earlier name\n"
        StandardError.write(Data(verdict.utf8))
        exit(report.failed ? 1 : 0)
    }
}

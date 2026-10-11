import Foundation

/// Every world on disk, and the rules for adding one.
///
/// A world is one JSON file under `<saveDir>/saves/`. There is no index and
/// no database: the directory listing *is* the catalogue, so a world can
/// only go missing by its file going missing, and a half-written index can
/// never disagree with what is actually there.
///
/// Nothing here deletes anything. There is no delete-world call to reach
/// for, which is the point — the person playing this is seven, and the
/// worst thing a menu can do is turn a mis-click into a lost afternoon.
enum WorldCatalog {
    /// Where the world files live.
    static var directoryURL: URL {
        if let chosen = chosenFolder { return chosen }
        return defaultDirectoryURL
    }

    /// Where worlds live unless the player has chosen somewhere else.
    static var defaultDirectoryURL: URL {
        WorldSave.directoryURL.appendingPathComponent("saves", isDirectory: true)
    }

    /// The folder the player chose, if they chose one and it is usable.
    ///
    /// Ignored whenever `BLOCKHAVEN_SAVE_DIR` is set: that override is what
    /// keeps a test run away from real worlds, and a setting that could
    /// send the run somewhere else would undo it.
    static var chosenFolder: URL? {
        guard ProcessInfo.processInfo.environment["BLOCKHAVEN_SAVE_DIR"] == nil,
              let path = GameSettings.worldsFolder, !path.isEmpty, isAbsolutePath(path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Points the catalogue at `folder` — nil for the default — and copies
    /// in every world from the old one that the new one does not already
    /// have, so changing folders never makes a world disappear from the
    /// list. Nothing is moved or deleted: the old copies stay where they
    /// were, as a backup. Returns how many worlds were copied.
    @discardableResult
    static func choose(folder: URL?) -> Int {
        let manager = FileManager.default
        let old = directoryURL
        GameSettings.worldsFolder = folder.map { url in
            url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        }
        let new = directoryURL
        guard old.standardizedFileURL != new.standardizedFileURL else { return 0 }
        try? manager.createDirectory(at: new, withIntermediateDirectories: true)
        let worlds = (try? manager.contentsOfDirectory(at: old, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var copied = 0
        for file in worlds where file.pathExtension == "json" {
            let destination = new.appendingPathComponent(file.lastPathComponent)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            do {
                try manager.copyItem(at: file, to: destination)
                copied += 1
            } catch {
                report("could not copy \(file.lastPathComponent) to the new worlds folder: \(error)")
            }
        }
        return copied
    }

    /// One world as the menus need it: enough to draw a row without
    /// decoding the edit journal behind it.
    struct Entry {
        var url: URL
        var name: String
        var mode: GameMode
        var lastPlayed: Double
    }

    // MARK: - Reading

    /// Every playable world, most recently played first.
    ///
    /// Reading only. Migration used to happen here, on the grounds that the
    /// start menu is the first thing to ask — but it is not the only thing:
    /// the snapshot harness draws the menu screens off this list too, and a
    /// command whose whole job is to write a PNG should not be what
    /// restructures somebody's saves. `AppDelegate` migrates at launch
    /// instead, once, before anything can claim a file name.
    ///
    /// With saving switched off it answers "no worlds" without touching the
    /// disk at all.
    static func entries() -> [Entry] {
        guard WorldSave.isEnabled else { return [] }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let worlds = contents.filter { $0.pathExtension == "json" }.compactMap { url -> Entry? in
            guard let save = WorldSave.load(from: url) else { return nil }
            return Entry(url: url, name: save.name, mode: save.mode, lastPlayed: save.lastPlayed)
        }
        // Newest first, and by file name under a tie so the order is stable
        // between launches rather than however the directory came back.
        return worlds.sorted {
            $0.lastPlayed == $1.lastPlayed
                ? $0.url.lastPathComponent < $1.url.lastPathComponent
                : $0.lastPlayed > $1.lastPlayed
        }
    }

    // MARK: - Migration

    /// The file that says the migration below finished.
    ///
    /// `saves/` existing cannot be that marker, however tempting it is:
    /// saving *any* world creates the directory (`WorldSave.save(to:)` makes
    /// the parent it is handed), so a single run that skips the menu — a
    /// `BLOCKHAVEN_MODE` harness run, say — would leave the directory there
    /// with the migration never having happened, and the check would then
    /// swallow the one world it exists to rescue, forever.
    ///
    /// Hidden and not a `.json`, so nothing listing the catalogue sees it.
    static var migrationMarkerURL: URL {
        defaultDirectoryURL.appendingPathComponent(".migrated")
    }

    /// Copies the one world older builds saved into the catalogue, once.
    ///
    /// Everything that can fail — an unreadable legacy file, a write that
    /// throws — leaves the marker unwritten and is retried next launch,
    /// because "we got as far as `mkdir`" is not a reason to give up on the
    /// only copy of someone's world. The marker is written only once the
    /// copy is on disk (or once there is provably nothing to copy), and
    /// after that this never runs again — which is what stops a world the
    /// player later renamed from reappearing under its old name every
    /// launch.
    ///
    /// The legacy file is read and never written. It stays where it is
    /// forever as a backup: it costs a few kilobytes and it is the only
    /// copy of that world that predates any of this code.
    static func migrateIfNeeded() {
        guard WorldSave.isEnabled else { return }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: migrationMarkerURL.path) else { return }

        let legacy = WorldSave.legacyFileURL
        guard manager.fileExists(atPath: legacy.path) else {
            // Nothing to migrate, and nothing that could appear later: no
            // build writes `world.json` any more. Done for good.
            markMigrated()
            return
        }
        guard var save = WorldSave.load(from: legacy) else {
            // Unreadable, or from a version this build doesn't know. Leaving
            // it alone is the whole policy: it is still on disk, it is still
            // unmarked, and a build that understands it will migrate it.
            report("legacy world.json is not readable by this build — left in place, will try again next launch")
            return
        }

        save.name = WorldSave.legacyName
        // The file's own date, not now: this world was last played whenever
        // it was last written, and dating it "now" would jump it to the top
        // of a list it may not belong at the top of.
        if save.lastPlayed <= 0 { save.lastPlayed = WorldSave.modificationTime(of: legacy) }

        let destination = availableURL(for: save.name)
        do {
            // `save(to:)` creates `saves/` on the way past, so the directory
            // and the world in it arrive together.
            try save.save(to: destination)
            markMigrated()
            report("migrated world.json to saves/\(destination.lastPathComponent) as \"\(save.name)\"")
        } catch {
            report("could not migrate world.json: \(error) — will try again next launch")
        }
    }

    /// Writes the marker. A failure here is worth a line but not a fuss: the
    /// world is already copied, and the worst the next launch can do is copy
    /// it a second time — a duplicate in the list, which the player can see
    /// and open, rather than a world nothing will ever read again.
    private static func markMigrated() {
        let note = """
            This file records that the pre-catalogue world.json was copied \
            into saves/. Delete it and the game will copy it in again.

            """
        do {
            try FileManager.default.createDirectory(at: defaultDirectoryURL, withIntermediateDirectories: true)
            try Data(note.utf8).write(to: migrationMarkerURL)
        } catch {
            report("could not record that the migration is done: \(error)")
        }
    }

    // MARK: - Naming

    /// The longest name the menus will keep. Long enough for "Kid's Giant
    /// Castle World", short enough to fit a card without shrinking the
    /// type.
    static let maximumNameLength = 24

    /// Trims a typed name, caps it, and falls back to `default` when
    /// there's nothing left. Whitespace-only is nothing.
    static func sanitize(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return String(trimmed.prefix(maximumNameLength))
    }

    /// A file name for a world called `name` that no world is using.
    ///
    /// The slug is only there to make the directory readable from a
    /// terminal; the suffix is what actually keeps two worlds apart, so two
    /// worlds may happily share a display name. The loop is not paranoia
    /// about the random bytes — it is that a name is checked against the
    /// disk, which is the only thing that knows what already exists.
    static func availableURL(for name: String) -> URL {
        let stem = slug(name)
        for _ in 0..<64 {
            let candidate = directoryURL.appendingPathComponent("\(stem)-\(suffix()).json")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // Sixty-four collisions on six random hex digits is not something
        // that happens, but a save with nowhere to go is not an option, so
        // fall back to something that cannot collide.
        let unique = UUID().uuidString.lowercased()
        return directoryURL.appendingPathComponent("\(stem)-\(unique).json")
    }

    /// Lowercase, alphanumerics and single dashes — a name a person can
    /// recognise in a file listing without any of it needing to be quoted.
    private static func slug(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(character)
            } else {
                pendingDash = true
            }
        }
        let capped = String(out.prefix(maximumNameLength))
        return capped.isEmpty ? "world" : capped
    }

    private static func suffix() -> String {
        String(format: "%06x", Int.random(in: 0..<0x1000000))
    }

    // MARK: - Time

    /// "2 days ago", for a world list row. Deliberately coarse: the exact
    /// minute never matters, and "3 weeks ago" is what tells you which
    /// world you abandoned.
    static func relativeTime(since epoch: Double) -> String {
        guard epoch > 0 else { return L10n.t("never played", "aldrig spelad") }
        let seconds = Date().timeIntervalSince1970 - epoch
        // A clock that moved backwards, or a file dated in the future.
        guard seconds > 0 else { return L10n.t("just now", "nyss") }

        // Each unit carries its Swedish forms alongside: English counts
        // "\(n) unit(s) ago" where Swedish wraps the count, "för n enheter
        // sedan" — whole phrases per language, not words slotted in.
        func plural(_ count: Int, _ unit: (en: String, sv: String, svPlural: String)) -> String {
            L10n.t("\(count) \(unit.en)\(count == 1 ? "" : "s") ago",
                   "för \(count) \(count == 1 ? unit.sv : unit.svPlural) sedan")
        }

        switch seconds {
        case ..<90: return L10n.t("just now", "nyss")
        case ..<3600: return plural(Int(seconds / 60), ("minute", "minut", "minuter"))
        case ..<86_400: return plural(Int(seconds / 3600), ("hour", "timme", "timmar"))
        case ..<(86_400 * 7): return plural(Int(seconds / 86_400), ("day", "dag", "dagar"))
        case ..<(86_400 * 30): return plural(Int(seconds / (86_400 * 7)), ("week", "vecka", "veckor"))
        case ..<(86_400 * 365): return plural(Int(seconds / (86_400 * 30)), ("month", "månad", "månader"))
        default: return plural(Int(seconds / (86_400 * 365)), ("year", "år", "år"))
        }
    }

    private static func report(_ message: String) {
        StandardError.write(Data("[worlds] \(message)\n".utf8))
    }
}

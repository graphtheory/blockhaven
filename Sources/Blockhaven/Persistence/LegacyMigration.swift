import Foundation

/// Brings worlds and settings across from the game's earlier name.
///
/// Builds before the rename kept everything under another folder name and
/// other settings keys. On the first launch after it, this copies the whole
/// old save folder to the new one and every old setting to its new key —
/// including the chosen worlds folder, which is how a OneDrive setup
/// survives. Nothing old is deleted or changed: if anything goes wrong,
/// the old folder is still the backup it always was.
///
/// The old names below are the only place they appear, on purpose.
enum LegacyMigration {
    static let legacyFolderName = "Minecraft Clone"
    static let legacyKeyPrefix = "minecraft."
    /// Where the old settings were stored: the Mac app's bundle id, and the
    /// executable name a bundle-less build (Windows) used as its domain.
    static let legacyDomains = ["com.john-z.minecraft-clone", "Minecraft"]
    /// Every setting `GameSettings` keeps, by the part after the prefix.
    static let settingNames = ["sensitivity", "craftingHintShown", "fullscreen", "language", "worldsFolder"]

    private static let doneKey = "blockhaven.legacyMigrationDone"

    /// Runs once per computer, at launch, before anything reads a save.
    /// Harness runs that point saving elsewhere never touch real folders.
    static func runIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BLOCKHAVEN_SAVE_DIR"] == nil, environment["BLOCKHAVEN_NO_SAVE"] == nil else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        let support = WorldSave.directoryURL.deletingLastPathComponent()
        let legacy = support.appendingPathComponent(legacyFolderName, isDirectory: true)
        let folder = copySaves(from: legacy, to: WorldSave.directoryURL)
        let sources = [defaults] + legacyDomains.compactMap { UserDefaults(suiteName: $0) }
        let keys = copySettings(from: sources, into: defaults)
        defaults.set(true, forKey: doneKey)
        StandardError.write(Data("[migrate] \(legacy.path) → \(WorldSave.directoryURL.path): \(folder) · settings copied: \(keys)\n".utf8))
    }

    /// Copies everything in `old` that `new` does not already have, going
    /// into folders both have — a `saves` folder something created empty
    /// first must still receive the worlds. Nothing is ever overwritten.
    /// Each item goes through a temporary name, so an interrupted copy
    /// never looks like a finished world.
    static func copySaves(from old: URL, to new: URL) -> String {
        guard FileManager.default.fileExists(atPath: old.path) else { return "no earlier folder" }
        do {
            let copied = try merge(old, into: new)
            return "\(copied) item(s) copied from \(old.lastPathComponent)"
        } catch {
            return "copy failed: \(error)"
        }
    }

    private static func merge(_ source: URL, into destination: URL) throws -> Int {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var copied = 0
        for item in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            var targetIsFolder: ObjCBool = false
            if manager.fileExists(atPath: target.path, isDirectory: &targetIsFolder) {
                var itemIsFolder: ObjCBool = false
                if targetIsFolder.boolValue, manager.fileExists(atPath: item.path, isDirectory: &itemIsFolder),
                   itemIsFolder.boolValue {
                    copied += try merge(item, into: target)
                }
                continue
            }
            let staging = destination.appendingPathComponent(item.lastPathComponent + ".copying")
            try? manager.removeItem(at: staging)
            do {
                try manager.copyItem(at: item, to: staging)
                try manager.moveItem(at: staging, to: target)
                copied += 1
            } catch {
                try? manager.removeItem(at: staging)
                throw error
            }
        }
        return copied
    }

    /// Fills in each setting the new store lacks from the first old store
    /// that has it. Returns how many were copied.
    static func copySettings(from sources: [UserDefaults], into target: UserDefaults) -> Int {
        var copied = 0
        for name in settingNames {
            let newKey = "blockhaven." + name
            guard target.object(forKey: newKey) == nil else { continue }
            for source in sources {
                if let value = source.object(forKey: legacyKeyPrefix + name) {
                    target.set(value, forKey: newKey)
                    copied += 1
                    break
                }
            }
        }
        return copied
    }
}

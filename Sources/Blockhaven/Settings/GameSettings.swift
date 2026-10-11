import Foundation
import Foundation

/// Persisted player settings — a small namespaced UserDefaults wrapper.
enum GameSettings {
    private static let defaults = UserDefaults.standard

    /// Mouse sensitivity multiplier over the built-in feel, 0.4...2.0.
    static var mouseSensitivity: CGFloat {
        get {
            let stored = defaults.double(forKey: "blockhaven.sensitivity")
            return stored == 0 ? 1.0 : CGFloat(min(2.0, max(0.4, stored)))
        }
        set { defaults.set(Double(min(2.0, max(0.4, newValue))), forKey: "blockhaven.sensitivity") }
    }

    /// Whether the player has ever opened the inventory — gates the HUD's
    /// one-time "press E to craft" hint.
    static var craftingHintShown: Bool {
        get { defaults.bool(forKey: "blockhaven.craftingHintShown") }
        set { defaults.set(newValue, forKey: "blockhaven.craftingHintShown") }
    }

    /// Whether the game covers the screen. True until somebody says
    /// otherwise, because a game belongs fullscreen — but it is a stored
    /// choice rather than a fact of the build, since fullscreen here hides
    /// the menu bar, and a player who cannot find the menu bar and cannot
    /// find a Quit button cannot leave.
    ///
    /// `BLOCKHAVEN_WINDOWED=1` still forces a window for a run without
    /// touching the stored choice, the way the language override does.
    static var fullscreen: Bool {
        get {
            if ProcessInfo.processInfo.environment["BLOCKHAVEN_WINDOWED"] == "1" { return false }
            // `object` for the presence test and `bool` for the value, so
            // a `-blockhaven.fullscreen NO` on the command line — which
            // arrives as the string "NO" — reads as false rather than as
            // "not a Bool, so use the default".
            guard defaults.object(forKey: "blockhaven.fullscreen") != nil else { return true }
            return defaults.bool(forKey: "blockhaven.fullscreen")
        }
        set {
            guard ProcessInfo.processInfo.environment["BLOCKHAVEN_WINDOWED"] != "1" else { return }
            defaults.set(newValue, forKey: "blockhaven.fullscreen")
        }
    }

    /// The language the UI speaks. Until the player picks one, it follows
    /// the Mac's own language — a Swedish machine comes up in Swedish on
    /// first launch instead of asking.
    ///
    /// BLOCKHAVEN_LANGUAGE pins it for a run without touching the stored
    /// choice, the way BLOCKHAVEN_NO_SAVE keeps test runs off the saves —
    /// so a snapshot of the Swedish menu can't flip the real setting.
    static var language: Language {
        get {
            if let forced = ProcessInfo.processInfo.environment["BLOCKHAVEN_LANGUAGE"],
               let pinned = Language(spelledOut: forced) {
                return pinned
            }
            if let raw = defaults.string(forKey: "blockhaven.language"),
               let chosen = Language(rawValue: raw) {
                return chosen
            }
            return Locale.preferredLanguages.first?.hasPrefix("sv") == true ? .swedish : .english
        }
        set {
            // A pinned run never writes. The override exists so a test can
            // look Swedish without flipping the stored choice underneath
            // the player — a setter that wrote anyway would break exactly
            // that promise on the toggle's ordinary path.
            if let forced = ProcessInfo.processInfo.environment["BLOCKHAVEN_LANGUAGE"],
               Language(spelledOut: forced) != nil {
                return
            }
            defaults.set(newValue.rawValue, forKey: "blockhaven.language")
        }
    }

    /// A folder the player chose for their worlds — a OneDrive, Dropbox or
    /// iCloud folder, so the same worlds turn up on every computer pointed
    /// at it. Nil means the default, beside the game's other files. See
    /// `WorldCatalog.directoryURL`.
    static var worldsFolder: String? {
        get { defaults.string(forKey: "blockhaven.worldsFolder") }
        set { defaults.set(newValue, forKey: "blockhaven.worldsFolder") }
    }

    /// The last version the updater downloaded and started installing. If
    /// the game comes back still older than it, the install did not take,
    /// and the updater does not try the same one again on every launch.
    static var lastUpdateAttempt: String? {
        get { defaults.string(forKey: "blockhaven.lastUpdateAttempt") }
        set { defaults.set(newValue, forKey: "blockhaven.lastUpdateAttempt") }
    }
}

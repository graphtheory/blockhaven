import Foundation

/// Which language the game speaks, toggled on the start menu.
enum Language: String, CaseIterable {
    case english
    case swedish

    /// The name on the language toggle, each in its own language — the one
    /// label that must never be translated, or the player who can't read
    /// the current language can't find the way back out of it.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .swedish: return "Svenska"
        }
    }

    /// The other one. Two languages make "switch" unambiguous; a third
    /// would turn this into a cycle and the toggle into a row.
    var toggled: Language {
        self == .english ? .swedish : .english
    }

    /// Reads "sv", "swedish", "svenska", "en"… — the forgiving spellings a
    /// BLOCKHAVEN_LANGUAGE override might use.
    init?(spelledOut name: String) {
        switch name.lowercased() {
        case "en", "eng", "english": self = .english
        case "sv", "swe", "swedish", "svenska": self = .swedish
        default: return nil
        }
    }
}

/// Picks the wording for the current language.
///
/// Every player-visible string sits at its call site as an English/Swedish
/// pair — `L10n.t("Resume", "Fortsätt")` — rather than in a central table,
/// so the words stay next to the screen they belong to and adding a string
/// is one line, not three. Strings are resolved at draw time, which is
/// what lets the start-menu toggle repaint the whole UI by doing nothing
/// more than setting `needsDisplay`.
enum L10n {
    static func t(_ english: String, _ swedish: String) -> String {
        GameSettings.language == .swedish ? swedish : english
    }
}

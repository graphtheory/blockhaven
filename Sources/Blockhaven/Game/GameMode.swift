import Foundation

/// Which set of rules the world is played under, chosen once at launch.
///
/// Everything that differs between the two modes is expressed here as a
/// named rule rather than as `if mode == .creative` scattered through the
/// game loop, so adding a third mode later means filling in a column.
enum GameMode: String, CaseIterable {
    /// Mine for what you build with, and the world can kill you.
    case survival
    /// An unlimited block palette and no way to die.
    case creative

    var displayName: String {
        switch self {
        case .survival: return L10n.t("Survival", "Överlevnad")
        case .creative: return L10n.t("Creative", "Kreativt")
        }
    }

    var tagline: String {
        switch self {
        case .survival: return L10n.t("Gather, craft and stay alive",
                                      "Samla, tillverka och håll dig vid liv")
        case .creative: return L10n.t("Every block, unlimited, and you can fly",
                                      "Alla block, obegränsat, och du kan flyga")
        }
    }

    /// Longer blurb for the start screen.
    var details: [String] {
        switch self {
        case .survival:
            return [
                L10n.t("Health, hunger and drowning",
                       "Hälsa, hunger och drunkning"),
                L10n.t("Blocks take time to mine, and the right tool matters",
                       "Block tar tid att bryta, och rätt verktyg spelar roll"),
                L10n.t("Tools wear out \u{2014} a wooden one does not last long",
                       "Verktyg slits ut \u{2014} ett i trä håller inte länge"),
                L10n.t("Breaking a block drops it into your inventory",
                       "När du bryter ett block hamnar det i ditt förråd"),
                L10n.t("Start with a wooden sword and a few wooden tools",
                       "Du börjar med ett träsvärd och några träverktyg"),
                L10n.t("Build a chest to keep what you make",
                       "Bygg en kista för att spara det du tillverkar"),
                L10n.t("Fizzlers hunt in the dark \u{2014} light your house",
                       "Fräsare jagar i mörkret \u{2014} lys upp huset"),
            ]
        case .creative:
            return [
                L10n.t("No health, hunger or fall damage",
                       "Ingen hälsa, ingen hunger, inga fallskador"),
                L10n.t("Blocks break almost the instant you click",
                       "Block går sönder nästan direkt när du klickar"),
                L10n.t("Every block type, on a shelf beside your inventory",
                       "Alla sorters block, på en hylla bredvid ditt förråd"),
                L10n.t("F picks up whatever block you are looking at",
                       "F plockar upp blocket du tittar på"),
                L10n.t("Double-tap space to fly",
                       "Tryck två gånger på mellanslag för att flyga"),
            ]
        }
    }

    /// How long mining a block takes: nil lets hardness and tool decide, a
    /// value is a flat time per block regardless of both. Creative is a
    /// hair over zero rather than literally instant so the renderer always
    /// has a few frames to reveal what's behind a block before it vanishes.
    var fixedMiningTime: Double? {
        switch self {
        case .survival: return nil
        case .creative: return 0.05
        }
    }

    /// Placing a block takes one off the stack.
    var consumesPlacedBlocks: Bool { self == .survival }

    /// Broken blocks drop into the inventory.
    var collectsDrops: Bool { self == .survival }

    /// Tools wear out and break. Creative's never do: the palette hands
    /// out another of everything, so a worn pickaxe there would be an
    /// errand rather than a cost.
    var wearsTools: Bool { self == .survival }

    /// Health, hunger, air and fall damage are simulated.
    var hasSurvivalStats: Bool { self == .survival }

    /// Flight can be toggled by double-tapping space.
    var allowsFlight: Bool { self == .creative }

    /// Fizzlers spawn and hunt. Creative is for building in peace.
    var spawnsHostileMobs: Bool { self == .survival }

    /// Pigs, cows and sheep spawn. True in both modes — nothing about them
    /// can hurt you, and a creative world with nothing alive in it is a
    /// lonely place to build.
    var spawnsPassiveMobs: Bool { true }
}

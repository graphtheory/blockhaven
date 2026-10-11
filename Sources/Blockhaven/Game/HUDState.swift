import Foundation

/// Everything the HUD draws in one frame, built by `GameSession.hudState`
/// and handed to whichever front end is drawing it.
struct HUDState {
    var hotbar: [ItemStack?] = Array(repeating: nil, count: Inventory.hotbarSize)
    var selectedSlot = 0
    var health = PlayerStats.maxHealth
    var hunger = PlayerStats.maxHunger
    var air = PlayerStats.maxAir
    var isSubmerged = false
    var isInLava = false
    /// Worn, not held — drawn as its own icon above the hearts rather
    /// than sitting in a hotbar slot, since it never does.
    var equippedChestplate: ItemType?
    /// Creative has nothing to lose, so it hides the health, hunger and
    /// air rows entirely and leaves just the hotbar.
    var showSurvivalBars = true
    /// Creative's one-time nudge says something different from
    /// survival's: the palette is the thing a new player has to be
    /// told about, and "gather materials" is not the advice.
    var isCreative = false
    var showDamageFlash = false
    var itemName: String?
    /// A line that appears for a moment and goes away: "It follows you
    /// now", "Staying here". Drawn where the item name is, a little
    /// higher, because that is where the eye already goes for a
    /// one-line answer to "what just happened".
    var toast: String?
    var debugText: String?
    /// Non-nil only while the compass is the selected hotbar item.
    /// Radians, screen-relative — see `Compass.needleAngle`. Distance
    /// is flat, in blocks.
    var compassBearing: CGFloat?
    var compassDistance: CGFloat?
    /// True while an unclaimed grave, not home, is what the needle is
    /// actually pointing at.
    var compassTargetsGrave = false
    /// How black the screen is, 0…1 — the dip a night's sleep passes
    /// through. Drawn over everything else, including the hotbar,
    /// because the point of it is that the player sees nothing for a
    /// moment while the sun moves.
    var fadeToBlack: CGFloat = 0
}

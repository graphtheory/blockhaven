import Foundation

/// Health, hunger, and the drowning clock — the survival numbers the HUD
/// draws. All measured in half-units, matching how the original counts hearts
/// and drumsticks (20 = ten full icons).
struct PlayerStats {
    static let maxHealth = 20
    static let maxHunger = 20
    static let maxAir = 20

    private(set) var health = PlayerStats.maxHealth
    private(set) var hunger = PlayerStats.maxHunger
    private(set) var air = PlayerStats.maxAir
    /// How much air the lungs — or the suit — hold. A space suit on the
    /// Moon holds six breaths' worth of the home world's.
    var airCapacity = PlayerStats.maxAir
    static let suitAirCapacity = PlayerStats.maxAir * 6

    /// The one thing worn rather than held — set only by `equip`, not by
    /// anything in `update`, because it changes on a right-click, not on a
    /// clock.
    private(set) var equippedChestplate: ItemType?

    /// Accumulated exhaustion; every full point costs a half-drumstick.
    private var exhaustion: Double = 0
    private var regenTimer: Double = 0
    private var starveTimer: Double = 0
    private var drownTimer: Double = 0
    private var burnTimer: Double = 0

    var isDead: Bool { health <= 0 }

    /// `mitigable` is required rather than defaulted, the same as
    /// `isInLava` below: starving and drowning cost exactly what they cost
    /// no matter what is worn, and a default that silently let a chestplate
    /// blunt them too would be a balance change nobody chose to make.
    mutating func takeDamage(_ amount: Int, mitigable: Bool) {
        guard amount > 0 else { return }
        let reduction = mitigable ? (equippedChestplate?.armorReduction ?? 0) : 0
        let reduced = reduction > 0
            ? max(1, Int((Double(amount) * (1 - reduction)).rounded(.down)))
            : amount
        health = max(0, health - reduced)
    }

    /// Swaps whatever is worn for `item`, returning what came off so the
    /// caller can hand it back to the inventory slot the new piece came
    /// from — the same swap a bucket already does with itself, one level
    /// up from an item that changes what it is into an item that changes
    /// what's worn.
    @discardableResult
    mutating func equip(_ item: ItemType?) -> ItemType? {
        let previous = equippedChestplate
        equippedChestplate = item
        return previous
    }

    mutating func heal(_ amount: Int) {
        health = min(PlayerStats.maxHealth, health + amount)
    }

    mutating func feed(_ amount: Int) {
        hunger = min(PlayerStats.maxHunger, hunger + amount)
    }

    mutating func reset() {
        health = PlayerStats.maxHealth
        hunger = PlayerStats.maxHunger
        air = airCapacity
        exhaustion = 0
        regenTimer = 0
        starveTimer = 0
        drownTimer = 0
        burnTimer = 0
    }

    /// Puts a saved body back. The timers deliberately start fresh: a save
    /// records where you stood, not that you were three seconds into
    /// drowning. Health never restores to zero — loading into a corpse
    /// would respawn you on the first frame and throw away the position
    /// that was just loaded.
    mutating func restore(health: Int, hunger: Int, air: Int, equippedChestplate: ItemType?) {
        reset()
        self.health = min(PlayerStats.maxHealth, max(1, health))
        self.hunger = min(PlayerStats.maxHunger, max(0, hunger))
        self.air = min(PlayerStats.suitAirCapacity, max(0, air))
        self.equippedChestplate = equippedChestplate
    }

    /// One frame of survival bookkeeping: movement burns hunger, a full
    /// belly regenerates health, an empty one starves, being underwater
    /// drains air and then drowns you, and touching lava burns you outright.
    mutating func update(
        dt: Double, distanceMoved: Double, isSprinting: Bool, isSubmerged: Bool, isInLava: Bool
    ) {
        air = min(air, airCapacity)
        exhaustion += distanceMoved * (isSprinting ? 0.10 : 0.03)
        while exhaustion >= 4.0 {
            exhaustion -= 4.0
            hunger = max(0, hunger - 1)
        }

        if hunger >= 18, health < PlayerStats.maxHealth {
            regenTimer += dt
            if regenTimer >= 4.0 {
                regenTimer = 0
                heal(1)
                exhaustion += 1.5 // regenerating costs food
            }
        } else {
            regenTimer = 0
        }

        if hunger == 0 {
            starveTimer += dt
            if starveTimer >= 4.0 {
                starveTimer = 0
                takeDamage(1, mitigable: false)
            }
        } else {
            starveTimer = 0
        }

        if isSubmerged {
            drownTimer += dt
            if drownTimer >= 1.0 {
                drownTimer = 0
                if air > 0 {
                    air -= 1
                } else {
                    takeDamage(2, mitigable: false)
                }
            }
        } else {
            drownTimer = 0
            air = airCapacity
        }

        // No grace period, unlike drowning: there is no air to spend
        // first, lava simply costs health from the first frame it is
        // touched, the same as the original's own — a mistake down here is
        // immediate rather than a countdown you can still turn back from.
        // Mitigable, unlike starving and drowning just above: a burn is a
        // hit the same way an arrow or a blast is, and a chestplate blunts
        // all three the same way.
        if isInLava {
            burnTimer += dt
            if burnTimer >= 0.4 {
                burnTimer = 0
                takeDamage(2, mitigable: true)
            }
        } else {
            burnTimer = 0
        }
    }
}

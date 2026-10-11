import Foundation

/// Which animal this is. Everything that differs between the seven lives
/// here as a named property, the same way `GameMode` keeps its rules.
///
/// `String`-backed so a tamed animal's kind can be written to a save file —
/// the raw value is the case name, the same convention `ItemType` uses.
enum AnimalKind: String, CaseIterable {
    /// Low and round.
    case pig
    /// The biggest of them.
    case cow
    /// In between, and woolly.
    case sheep
    /// The small one, which flaps instead of falling.
    case chicken
    /// The first of the swimmers, and the odd one out on land.
    case axolotl
    /// The shoal fish. Never alone; that is the whole point of it.
    case cod
    /// The deep-water one, which jets rather than glides.
    case squid
    /// The one you can keep. Wanders like the rest until it is fed, and
    /// then follows you about — the first animal here with any interest in
    /// the player beyond being hit by one.
    case wolf

    /// Collision box: square in plan, like the original's own animal boxes,
    /// and wide enough to cover the length of the body the renderer builds
    /// — a box narrower than the model is a box a swing aimed at the
    /// animal misses. Still under a block across, so they fit through gaps.
    var halfWidth: CGFloat {
        switch self {
        case .pig: return 0.40
        case .cow: return 0.45
        case .sheep: return 0.43
        case .chicken: return 0.28
        case .axolotl: return 0.35
        case .cod: return 0.24
        case .squid: return 0.40
        // Lean and dog-sized: narrower than a sheep, and it has to fit
        // through the doorways it will follow you through.
        case .wolf: return 0.35
        }
    }

    var height: CGFloat {
        switch self {
        case .pig: return 0.9
        case .cow: return 1.3
        case .sheep: return 1.2
        case .chicken: return 0.7
        case .axolotl: return 0.45
        case .cod: return 0.30
        case .squid: return 0.75
        case .wolf: return 0.85
        }
    }

    /// Half-hearts, on the same scale as `PlayerStats`.
    var maxHealth: Int {
        switch self {
        case .pig: return 10
        case .cow: return 10
        case .sheep: return 8
        case .chicken: return 4
        case .axolotl: return 6
        case .cod: return 3
        case .squid: return 5
        // Tougher than the livestock. A pet that dies to one bad fall
        // is a pet a kid loses once and never tames again.
        case .wolf: return 16
        }
    }

    /// Ambling pace. All of them are well under the player's walk, so they
    /// can always be caught up with — and the swimmers, which have no
    /// business being on land at all, barely move there.
    var walkSpeed: CGFloat {
        switch self {
        case .pig: return 1.5
        case .cow: return 1.3
        case .sheep: return 1.4
        case .chicken: return 1.35
        case .axolotl: return 0.45
        case .cod: return 0.30
        case .squid: return 0.35
        // The quickest thing on four legs here, and it has to be: a pet
        // slower than the player is a pet you spend the game waiting for.
        // Still under the player's 4.3 walk, so it trails rather than
        // barges, and its follow speed below is what closes a gap.
        case .wolf: return 2.2
        }
    }

    /// True for the kinds that spawn in water and swim rather than walk.
    /// Everything the aquatic branch of `Animal` does hangs off this.
    ///
    /// A switch rather than `self == .axolotl`, which is what this was when
    /// there was one swimmer: that spelling compiles perfectly happily for
    /// a second water mob and then gives it gravity, a land spawn and a
    /// quadruped's body, all without a word of complaint.
    var isAquatic: Bool {
        switch self {
        case .axolotl, .cod, .squid: return true
        case .pig, .cow, .sheep, .chicken, .wolf: return false
        }
    }

    /// Which biomes this kind spawns in on land — nil for the swimmers,
    /// which are already gated by water depth and never ask this. Before
    /// this every land kind rolled everywhere alike, so a desert and a
    /// snowfield held exactly the same herd a plain did: biome decided
    /// what the ground looked like and nothing about what lived on it.
    /// Livestock keep to the grass they'd actually graze; the wolf ranges
    /// wider, the one predator here, the way a forest's or a mountain's
    /// edge is where the original's own wolves are found.
    var habitatBiomes: Set<WorldGenerator.Biome> {
        switch self {
        case .pig, .cow, .sheep, .chicken: return [.plains, .forest]
        case .wolf: return [.forest, .mountains, .snowy]
        case .axolotl, .cod, .squid: return []
        }
    }

    /// Pace under water, where the swimmers are actually at home — well
    /// over their hopeless flopping speed on land, still under the
    /// player's swim.
    var swimSpeed: CGFloat {
        switch self {
        case .axolotl: return 1.5
        case .cod: return 2.0
        case .squid: return 1.1
        default: return walkSpeed
        }
    }

    /// True for the kinds that keep station on their own sort. Only the
    /// cod does, and it is most of what makes a lake read as inhabited
    /// rather than as four animals that happen to be wet.
    var shoals: Bool { self == .cod }

    /// True for the kinds that swim in bursts rather than at a steady
    /// glide. Only the squid, which has no fins to hold a speed with.
    var jets: Bool { self == .squid }

    /// The fastest a bird may fall. A chicken cannot fly, but it cannot
    /// drop like a stone either: beating its wings caps the descent, which
    /// is the one rule that makes a chicken read as a chicken the moment it
    /// walks off a ledge. Nil for everything else, which falls properly.
    var glideFallSpeed: CGFloat? {
        self == .chicken ? -2.6 : nil
    }

    /// How deep a column of water has to be before a spawn of this kind
    /// will take it. Two is the shallowest a body fits in with a cell to
    /// spare; the squid asks for real depth, which is what keeps it out of
    /// the ponds and makes swimming out over the sea floor worth doing.
    var minimumWaterDepth: Int {
        switch self {
        case .squid: return 5
        default: return 2
        }
    }

    /// How many arrive together. Animals turning up one at a time, minutes
    /// apart, is what made a field read as scenery; a herd that walked in
    /// together reads as a herd. The shoal is the extreme of it — a single
    /// cod is a bug, not a fish.
    var groupSize: ClosedRange<Int> {
        switch self {
        case .pig, .cow: return 2...3
        case .sheep: return 2...4
        case .chicken: return 3...4
        case .axolotl: return 1...2
        case .cod: return 4...6
        case .squid: return 1...2
        // Twos and threes. A wolf alone reads as lost; a pack of six is
        // a wolf problem rather than a pet.
        case .wolf: return 2...3
        }
    }

    /// The name the harness knows this kind by — `BLOCKHAVEN_SNAPSHOT_ANIMAL`
    /// and the check transcripts. Deliberately not localised and
    /// deliberately not `displayName`: these are command-line tokens, and a
    /// Swedish machine must not need a different command line.
    var identifier: String {
        switch self {
        case .pig: return "pig"
        case .cow: return "cow"
        case .sheep: return "sheep"
        case .chicken: return "chicken"
        case .axolotl: return "axolotl"
        case .cod: return "cod"
        case .squid: return "squid"
        case .wolf: return "wolf"
        }
    }

    /// How many of this one kind may be alive at once, inside its habitat's
    /// budget rather than beside it.
    ///
    /// This is the same argument the land and water budgets already make,
    /// one level down. A shoal is six fish; against a shared water budget
    /// the first two shoals would fill it, and the axolotl the budget was
    /// widened for would never be seen again — which is exactly the
    /// crowd-out the two budgets exist to prevent, with the roles swapped.
    var maximumAlive: Int {
        switch self {
        case .pig, .cow, .sheep, .chicken: return 6
        case .axolotl: return 4
        case .cod: return 8
        case .squid: return 3
        case .wolf: return 4
        }
    }

    /// True for the kinds a player can keep. Only the wolf, and everything
    /// taming does hangs off this rather than off `== .wolf`, so a second
    /// pet later is a property and not a hunt through the file.
    var isTameable: Bool { self == .wolf }

    /// How close a tamed animal tries to stay. Inside this it stops and
    /// mills about; outside it comes after you.
    ///
    /// Three blocks rather than one: a pet that heels exactly is a pet
    /// permanently standing where you want to put a block, and one that
    /// shoves you off ledges. Three is close enough to feel kept.
    static let followDistance: CGFloat = 3.0

    /// Beyond this it gives up walking and simply reappears beside you.
    ///
    /// The original's rule and the original's distance, and both are load-bearing.
    /// There is no pathfinding here: a pet walks straight at you, hops a
    /// one-block step and veers round what it cannot hop, and that is the
    /// whole of it. Two-block terrain beats it, and measured, that is not
    /// rare — a wolf fourteen blocks off across ordinary ground got stuck
    /// under a two-block rise and was still there ten seconds later.
    ///
    /// Twelve blocks is what turns that from "the dog is gone" into "the
    /// dog caught up". Proper voxel pathfinding would be the better answer
    /// and is a great deal more than this needs: a pet is a promise, and
    /// the teleport is the cheapest way to keep it.
    static let recallDistance: CGFloat = 12.0

    /// How much quicker a tamed animal moves while catching up. Applied
    /// only when it is out of `followDistance`, so a pet that has fallen
    /// behind sprints and a pet at your heel ambles.
    static let followSprint: CGFloat = 1.9

    /// How often a spawn of this kind comes out in the rare colour. A kid
    /// who has found four pink axolotls and then a cyan one has found
    /// something; the same goes for the one cod in eight that is tropical.
    var rareMorphChance: Double {
        switch self {
        case .axolotl: return 0.1
        case .cod: return 0.125
        default: return 0
        }
    }
}

/// Which colour an animal came out. Everything but the axolotl is always
/// `.common`, so this costs the other three nothing but a cache key.
enum AnimalMorph: Hashable {
    case common
    /// One axolotl in ten: cyan instead of pink.
    case rare
}

/// One passive animal: position, physics and an idle/flee state machine.
///
/// Pure simulation over the voxel volume with no scene-graph dependency,
/// the same split as `Fizzler` and `PlayerController` — the renderer reads
/// `position`, `facing` and the hurt flag once a frame and moves an entity
/// to match. A wild animal notices nothing but a hit; a tamed one also
/// notices its owner, and a tamed wolf notices a threat.
struct Animal {
    static let gravity: CGFloat = 26.0
    static let terminalVelocity: CGFloat = -55.0
    static let jumpImpulse: CGFloat = 7.4

    /// How hard a hit shoves it, and how much of that shove is upward.
    static let knockbackSpeed: CGFloat = 6.0
    static let knockbackLift: CGFloat = 4.2
    /// How long the red hurt flash lasts.
    static let hurtFlashDuration: Double = 0.3
    /// How long a hit keeps hold of the horizontal velocity. Without it the
    /// steering blend eats the knockback within a few frames.
    static let knockbackControlDuration: Double = 0.3
    /// How long the body lies there red before the manager clears it, so a
    /// kill reads as a kill rather than as the animal blinking out.
    static let dyingDuration: Double = 0.35

    /// A hit sends it bolting for this long, at this multiple of its walk.
    static let fleeDuration: Double = 1.6
    static let fleeSpeedFactor: CGFloat = 2.2

    /// A tamed wolf closing on a threat holds that heading for this long
    /// before giving up and falling back to following its owner — refreshed
    /// every frame the threat is still in `AnimalManager.defendRadius`, the
    /// same way `fleeDuration` is refreshed by a repeated `spook`, so it
    /// only ever expires once the threat is actually gone.
    static let defendDuration: Double = 1.0
    /// How close a defending wolf closes before it stops advancing and
    /// starts biting — well inside `AnimalKind.followDistance`, which is
    /// how far it loiters from its *owner*, not from something it means to
    /// fight.
    static let biteRange: CGFloat = 1.3
    /// Chip damage, not a duel: a wolf helps, it doesn't replace the sword
    /// in a player's hand. Six bites to bring down a skeleton (12 health),
    /// ten for a fizzler (20) — a real dent over a real fight, not a
    /// one-mob kill switch.
    static let biteDamage = 2
    /// Seconds between bites, tracked by `AnimalManager` rather than here —
    /// see its `biteTimers`.
    static let biteCooldown: Double = 1.0

    // MARK: Swimming

    /// How fast a swimmer eases onto a new heading. Lower than the land
    /// blend, because water has no floor to push off.
    static let swimBlend: CGFloat = 3.0
    /// The gentle rise and fall a hovering swimmer keeps up, as a speed
    /// added to its vertical target, and how many times a second.
    static let bobSpeed: CGFloat = 0.22
    static let bobRate: Double = 0.55
    /// How far ahead a candidate heading is tested for water before it is
    /// taken. Far enough that it turns before its nose is at the bank.
    static let swimLookahead: CGFloat = 1.6
    /// A stranded swimmer's hop, and the seconds between hops.
    static let flopImpulse: CGFloat = 3.4
    static let flopInterval: Double = 0.85
    /// How far a stranded swimmer can smell water, in cells.
    static let waterSearchRadius = 4

    // MARK: Shoaling

    /// How hard each of the three shoal urges pulls, against a wander
    /// heading of length one.
    ///
    /// Cohesion has to beat the wander outright or it does not gather at
    /// all: the wander is a fresh unit heading every few seconds, so
    /// anything under 1 is a fish that drifts apart between rolls and is
    /// nudged back a little in between. Alignment is the weak one on
    /// purpose — it points wherever the group is already going, which keeps
    /// a shoal that has already formed coherent but does nothing whatever
    /// to form one, and at the weight cohesion needs it simply drowns
    /// cohesion out. Separation is strong because a shoal collapsed into
    /// one flickering knot of fish looks worse than no shoal at all, and
    /// only separation prevents it.
    static let shoalCohesion: CGFloat = 2.0
    static let shoalAlignment: CGFloat = 0.6
    static let shoalSeparation: CGFloat = 1.8
    /// Below this the blended heading is treated as no heading, rather than
    /// normalised — `Vector3.normalized` answers +z for a zero vector, and
    /// a shoal all quietly agreeing to swim north is the bug that hides in.
    static let shoalDeadZone: CGFloat = 0.05

    // MARK: Jetting

    /// The squid's stroke: seconds between pulls, and how sharply one
    /// decays. `exp(-decay·t)` is a hard push that coasts, which is what a
    /// squid does; a sine would be a fish's steady beat.
    static let jetPeriod: Double = 2.1
    static let jetDecay: Double = 3.5
    /// What is left of the pace between strokes, so a coasting squid drifts
    /// rather than stopping dead.
    static let jetIdleFraction: CGFloat = 0.2

    enum Activity {
        /// Ambling about or standing still — all an animal does unprompted.
        case idle
        /// Bolting away from whatever just hit it. Payload is seconds left.
        case fleeing(remaining: Double)
        /// Closing on a threat instead of following its owner — only ever
        /// a tamed wolf. Payload is where it's headed and seconds left
        /// before it gives up, the same shape as `fleeing`.
        case defending(target: Vector3, remaining: Double)
    }

    /// What one fish is told about the rest of its shoal.
    ///
    /// Three headings and a count, worked out by `AnimalManager` — which is
    /// the only thing that can see more than one animal — and handed down
    /// flattened, so `Animal` stays a simulation of exactly one animal and
    /// never holds a reference to another. All three are already scaled to
    /// roughly unit length, so the weights above are the whole tuning.
    struct Shoal {
        /// Toward the middle of the neighbours.
        var cohesion = Vector3.zero
        /// The way they are already going, as a fraction of cruising pace,
        /// so a shoal that has stopped exerts no pull to keep going.
        var alignment = Vector3.zero
        /// Away from whoever is too close, and zero when nobody is.
        var separation = Vector3.zero
        /// How many neighbours were in range. Zero means no shoal at all,
        /// and the fish falls back to wandering on its own.
        var count = 0
    }

    let kind: AnimalKind
    /// Fixed at birth off the same seed the wandering runs on, so the same
    /// spawn is the same colour every time the world is loaded.
    let morph: AnimalMorph

    private(set) var position: Vector3
    private(set) var velocity = Vector3.zero
    private(set) var activity = Activity.idle
    /// Yaw in radians, so the renderer can face it where it's heading.
    private(set) var facing: CGFloat = 0
    private(set) var isGrounded = false
    private(set) var health: Int
    /// Seconds left on the hurt flash, counted down by `step`.
    private(set) var hurtTimer: Double = 0
    /// Seconds the knockback still owns the horizontal velocity for.
    private(set) var knockbackTimer: Double = 0
    /// Seconds left of the dying window; only meaningful once dead.
    private(set) var dyingTimer: Double = 0
    /// True while an aquatic animal is actually in the water, so the
    /// renderer can sway a tail instead of walking legs. Always false for
    /// the land animals.
    private(set) var isSwimming = false
    /// True on the frames a bird is beating its wings to break its fall —
    /// which is the only time a chicken's wings are worth animating, and
    /// the only time its descent is capped. Always false for everything
    /// else, and for a dead chicken, which falls like anything else.
    private(set) var isGliding = false
    /// How hard a jetting swimmer is pushing right now, 0…1. The renderer
    /// flares the tentacles on it; nothing else reads it.
    private(set) var jetPulse: CGFloat = 0

    var isDead: Bool { health <= 0 }

    /// Dead and finished lying there — the manager's cue to remove it.
    var isFinished: Bool { isDead && dyingTimer <= 0 }

    /// True while the renderer should be flashing it red. A body stays red
    /// for the whole dying window.
    var isHurt: Bool { hurtTimer > 0 || isDead }

    /// Drives the renderer's walk bob, so a standing animal sits still.
    var horizontalSpeed: CGFloat {
        sqrt(velocity.x * velocity.x + velocity.z * velocity.z)
    }

    /// Where it's currently ambling.
    private var wanderDirection = Vector3.zero
    private var wanderTimer: Double = 0
    /// How long a pet veers after being blocked. Long enough to clear a
    /// corner at its walking speed, short enough that it is not a detour
    /// you can watch it take across an open field.
    static let detourDuration: Double = 0.8

    /// Puts a pet back on the ground beside its owner.
    ///
    /// The one place anything outside this type moves an animal without
    /// physics, which is why it is a named method rather than an open
    /// setter on `position`: a recall is a deliberate teleport and should
    /// read as one at the call site.
    mutating func recall(to place: Vector3) {
        position = place
        velocity = .zero
    }

    /// True once the player has fed it. A tamed animal follows rather than
    /// wanders, and nothing else about it changes — it still takes damage,
    /// still bolts when hit, still falls down holes.
    var isTamed = false

    /// True when a tamed animal has been told to stay put. Right-clicking
    /// toggles it, which is the only control the player has over a pet and
    /// the one that makes it useful: a dog that cannot be left behind is a
    /// dog that follows you into the lava.
    var isSitting = false

    /// Seconds left of being fed and ready to breed — see
    /// `AnimalManager.breed`. Counts down on its own, the same as the hurt
    /// flash, so an animal fed and then ignored quietly stops offering
    /// rather than staying pairable forever.
    private(set) var loveTimer: Double = 0
    /// Seconds left before this animal can be fed into love again, set
    /// once a pairing actually produces a baby. Without it, the two
    /// animals a wheat stack is spent on breed again the instant the next
    /// piece lands, and a population cap that should take a field full of
    /// livestock and an afternoon to reach takes eleven seconds instead.
    private(set) var breedCooldown: Double = 0

    var isInLove: Bool { loveTimer > 0 }
    var canBeFedForBreeding: Bool { breedCooldown <= 0 }

    /// Feeds it into love mode — wheat in a player's hand, the one gesture
    /// `AnimalManager.feedForBreeding` already gated on food and cooldown
    /// before calling this.
    mutating func enterLove() {
        loveTimer = Animal.loveDuration
    }

    /// Spends the love this animal was fed for a pairing that just bred,
    /// and starts the cooldown before it can be fed into love again.
    mutating func consumeLove() {
        loveTimer = 0
        breedCooldown = Animal.breedCooldownDuration
    }

    /// How long a fed animal stays willing to pair, looking for a mate.
    static let loveDuration: Double = 30
    /// How long a bred animal refuses another pairing. the original's own
    /// five minutes, unchanged: long enough that a small pen does not turn
    /// into an instant population cap, short enough that a session that
    /// started a farm sees it grow before it ends.
    static let breedCooldownDuration: Double = 300

    /// How long a following animal keeps veering after walking into
    /// something, and which way round. A wall it cannot hop is a wall it
    /// has to go round, and without this a pet walks into the same cliff
    /// for as long as you care to watch — the hop below only clears one
    /// block, and terrain is full of two.
    private var detourTimer: Double = 0
    private var detourSign: CGFloat = 1

    /// Where the animal is trying to get to, when it is following someone.
    /// Set by the manager each frame, because the animal has no idea the
    /// player exists and this is the one thing it needs to be told.
    var followTarget: Vector3?

    /// The heading a flee burst runs along, fixed at the moment of the hit
    /// so it doesn't curl back toward whatever hit it.
    private var fleeDirection = Vector3.zero
    /// Seconds until a stranded swimmer's next hop.
    private var flopTimer: Double = 0
    /// Where a jetting swimmer is in its stroke, in seconds. Wall-clock
    /// driven like the bob, because a squid pulses whether or not it is
    /// getting anywhere.
    private var jetPhase: Double = 0
    /// Phase of the hovering bob, in radians. Wall-clock driven, unlike the
    /// renderer's walk bob, because a swimmer bobs while it hangs still.
    private var bobPhase: Double = 0
    /// True for the frames on which the water-only movement rule applies:
    /// set by `step` from the position the frame began at, read by the
    /// collision test below. See `step`.
    private var submersionHeld = false
    /// Its own deterministic noise stream, so two animals spawned on the
    /// same frame don't wander in lockstep.
    private var rng: SeededGenerator

    /// `morph` is normally rolled from `seed`; a save passes the one it
    /// already recorded instead, so a reloaded pet doesn't have a chance of
    /// coming back a different colour than the one a player tamed and
    /// named in their head.
    init(kind: AnimalKind, position: Vector3, seed: UInt64, morph: AnimalMorph? = nil) {
        self.kind = kind
        self.position = position
        self.health = kind.maxHealth
        var rng = SeededGenerator(seed: seed)
        self.morph = morph ?? (Double.random(in: 0..<1, using: &rng) < kind.rareMorphChance
            ? .rare : .common)
        self.rng = rng
    }

    /// Advances one frame.
    ///
    /// `shoal` is what the manager worked out about this animal's
    /// neighbours; nil — the default — means it has none, or is not the
    /// sort that keeps station on them, and it wanders on its own.
    mutating func step(dt: Double, world: World, shoal: Shoal? = nil) {
        guard dt > 0 else { return }
        let delta = CGFloat(dt)

        if loveTimer > 0 { loveTimer = max(0, loveTimer - dt) }
        if breedCooldown > 0 { breedCooldown = max(0, breedCooldown - dt) }

        // A swimmer that is already fully under keeps a rule the land
        // animals have no use for: water is the only place it may move
        // into. Decided from the position it starts the frame at, so an
        // animal that somehow ends up half out of the water is free to
        // swim back down rather than being frozen where it stands.
        submersionHeld = kind.isAquatic && submerged(at: position, world: world)
        isSwimming = kind.isAquatic && centreInWater(at: position, world: world)

        if isDead {
            // The dying window: no steering and no wandering, but the
            // killing blow's knockback and gravity still play out.
            dyingTimer = max(0, dyingTimer - dt)
        } else {
            steer(dt: dt, delta: delta, world: world, shoal: shoal)
        }

        // Water holds a swimmer up. Everything else — including a beached
        // axolotl, and including a dead one sinking to the bottom — falls.
        if isSwimming, !isDead {
            isGrounded = false
        } else {
            velocity.y -= Animal.gravity * delta
            velocity.y = max(Animal.terminalVelocity, velocity.y)
        }

        // A chicken beats its wings on the way down. It is not flight —
        // nothing here lifts it — it is a cap on how fast it may fall, and
        // it is the entire difference between a bird walking off a ledge
        // and a brick doing it. A dead one gets no such courtesy.
        isGliding = false
        if let capped = kind.glideFallSpeed, !isDead, !isGrounded, velocity.y < capped {
            velocity.y = capped
            isGliding = true
        }

        let blockedX = !moveAxis(.x, delta: velocity.x * delta, world: world)
        let blockedZ = !moveAxis(.z, delta: velocity.z * delta, world: world)
        _ = moveAxis(.y, delta: velocity.y * delta, world: world)

        // Walked into a wall: hop it, the way the original's mobs climb a step.
        // A swimmer has no step to climb — its wall is the bank, and the
        // whole point is that it stays on this side of it.
        if (blockedX || blockedZ), isGrounded, !isDead, !isSwimming, canStepUp(world: world) {
            velocity.y = Animal.jumpImpulse
            isGrounded = false
        } else if (blockedX || blockedZ), isTamed, !isDead, !isSwimming, detourTimer <= 0 {
            // Blocked by something it cannot hop. Go round it — and flip the
            // side each time, so a pet that picks the wrong way out of a
            // dead end tries the other way rather than grinding along the
            // same wall until the recall rescues it.
            detourTimer = Animal.detourDuration
            detourSign = -detourSign
        }
    }

    /// Takes a melee hit: subtracts health, throws the body along
    /// `knockback`, lights the hurt flash and starts a flee burst.
    mutating func damage(_ amount: Int, knockback: Vector3) {
        guard amount > 0, !isDead else { return }
        health = max(0, health - amount)
        hurtTimer = Animal.hurtFlashDuration
        knockbackTimer = Animal.knockbackControlDuration
        if isDead { dyingTimer = Animal.dyingDuration }

        let push = Vector3(knockback.x, 0, knockback.z)
        if push.length() > 0.0001 {
            let direction = push.normalized()
            velocity.x = direction.x * Animal.knockbackSpeed
            velocity.z = direction.z * Animal.knockbackSpeed
            fleeDirection = direction
        } else {
            // Hit from straight overhead: there is no direction to be
            // shoved in, so it bolts the way it was already facing rather
            // than burning the whole burst standing still.
            fleeDirection = Vector3(sin(facing), 0, cos(facing))
        }
        velocity.y = Animal.knockbackLift
        isGrounded = false
        // A fresh hit restarts the burst from full, so being chased keeps
        // it running rather than letting it settle between blows.
        activity = .fleeing(remaining: Animal.fleeDuration)
    }

    /// Bolts away from a nearby threat — a fizzler closing in, a skeleton
    /// with a line on it — without taking a hit. The same flee burst
    /// `damage` starts, but pointed away from `threat` rather than along a
    /// knockback, and with none of `damage`'s health loss, hurt flash or
    /// vertical shove: nothing has actually touched it, it has only
    /// noticed. Called every frame the threat stays in range, so the burst
    /// keeps re-arming and the direction keeps re-aiming at whichever way
    /// is currently away from it — a herd doesn't outrun a moving threat by
    /// committing to the heading it had when it first noticed.
    mutating func spook(awayFrom threat: Vector3) {
        guard !isDead else { return }
        let away = Vector3(position.x - threat.x, 0, position.z - threat.z)
        fleeDirection = away.length() > 0.0001 ? away.normalized() : Vector3(sin(facing), 0, cos(facing))
        activity = .fleeing(remaining: Animal.fleeDuration)
    }

    /// The tamed answer to `spook`: a wolf that has already given up its
    /// flight response turns to fight instead of merely standing immune to
    /// it. Called every frame `AnimalManager` still sees the threat in
    /// range, refreshing `defendDuration` the same way a repeated `spook`
    /// keeps a flee burst alive — so it only lets go once the threat is
    /// actually gone, not the instant it steps out of range for one frame.
    mutating func defend(against threat: Vector3) {
        guard !isDead, isTamed else { return }
        activity = .defending(target: threat, remaining: Animal.defendDuration)
    }

    /// One frame of the idle/flee machine and the steering it drives, kept
    /// apart from the physics above so the dying window can skip it whole.
    /// Only ever runs while the animal is alive.
    private mutating func steer(dt: Double, delta: CGFloat, world: World, shoal: Shoal?) {
        var desired = Vector3.zero
        var speed = isSwimming ? kind.swimSpeed : kind.walkSpeed

        switch activity {
        case .idle:
            // A pet that has been told to sit does nothing at all, which is
            // the point of telling it.
            if isTamed, isSitting {
                desired = .zero
                break
            }
            // A tamed animal with somewhere to be goes there. Only when it
            // is actually out of range: inside `followDistance` it falls
            // through to the ordinary wander, so a dog at your heel mills
            // about like an animal rather than standing to attention.
            if isTamed, let target = followTarget {
                let gap = Vector3(target.x - position.x, 0, target.z - position.z)
                let distance = gap.length()
                if distance > AnimalKind.followDistance {
                    var heading = Vector3(gap.x / distance, 0, gap.z / distance)
                    // Veering round whatever it just walked into. A quarter
                    // turn, held for a moment, which is enough to clear the
                    // corner of a hill and short enough that it goes back to
                    // making straight for you as soon as it is past.
                    if detourTimer > 0 {
                        detourTimer -= dt
                        let turn = CGFloat.pi / 3 * detourSign
                        heading = Vector3(
                            heading.x * cos(turn) - heading.z * sin(turn),
                            0,
                            heading.x * sin(turn) + heading.z * cos(turn)
                        )
                    }
                    desired = heading
                    speed *= AnimalKind.followSprint
                    break
                }
            }
            desired = isSwimming
                ? swimWanderStep(dt: dt, world: world)
                : (kind.isAquatic ? flopStep(dt: dt, world: world) : wanderStep(dt: dt))
            if isSwimming, kind.shoals, let shoal, shoal.count > 0 {
                desired = shoalStep(desired, shoal: shoal, world: world)
            }
        case .fleeing(let remaining):
            let next = remaining - dt
            activity = next <= 0 ? .idle : .fleeing(remaining: next)
            desired = fleeDirection
            speed *= Animal.fleeSpeedFactor
            // Coming out of a bolt, pick a fresh heading rather than
            // carrying on in a straight line.
            if next <= 0 { wanderTimer = 0 }
        case .defending(let target, let remaining):
            let next = remaining - dt
            let gap = Vector3(target.x - position.x, 0, target.z - position.z)
            let distance = gap.length()
            // Closes all the way to bite range rather than stopping at
            // `followDistance` the way following an owner does — the
            // owner is somewhere to loiter near, a threat is somewhere to
            // actually reach.
            if distance > Animal.biteRange {
                desired = distance > 0.0001 ? Vector3(gap.x / distance, 0, gap.z / distance) : .zero
                speed *= AnimalKind.followSprint
            }
            activity = next <= 0 ? .idle : .defending(target: target, remaining: next)
            if next <= 0 { wanderTimer = 0 }
        }

        // The squid's stroke. It scales the pace rather than the heading,
        // so a coasting squid carries on the way it was pointed instead of
        // wandering off between pulls.
        if kind.jets, isSwimming {
            jetPhase += dt
            let phase = jetPhase.truncatingRemainder(dividingBy: Animal.jetPeriod)
            jetPulse = CGFloat(exp(-Animal.jetDecay * phase / Animal.jetPeriod))
            speed *= Animal.jetIdleFraction + (1 - Animal.jetIdleFraction) * jetPulse
        } else {
            jetPulse = 0
        }

        if desired.x != 0 || desired.z != 0 {
            facing = atan2(desired.x, desired.z)
        }

        if knockbackTimer > 0 {
            knockbackTimer = max(0, knockbackTimer - dt)
        } else if isSwimming {
            // A swimmer steers in all three axes, and keeps a slow rise
            // and fall going even when it is holding still.
            bobPhase += dt * Animal.bobRate * 2 * .pi
            let target = desired * speed
                + Vector3(0, sin(CGFloat(bobPhase)) * Animal.bobSpeed, 0)
            let blend = min(1, Animal.swimBlend * delta)
            velocity.x += (target.x - velocity.x) * blend
            velocity.y += (target.y - velocity.y) * blend
            velocity.z += (target.z - velocity.z) * blend
        } else {
            // Accelerate toward the desired direction rather than snapping,
            // so it doesn't jitter when the heading changes.
            let target = desired * speed
            let blend = min(1, 8 * delta)
            velocity.x += (target.x - velocity.x) * blend
            velocity.z += (target.z - velocity.z) * blend
        }

        if hurtTimer > 0 { hurtTimer = max(0, hurtTimer - dt) }
    }

    /// The swimmer's wander: a fresh heading every couple of seconds,
    /// picked in three dimensions and — this is the part that keeps it off
    /// the beach — only ever one whose destination is still water. Eight
    /// tries, and if none of them are it holds still rather than swimming
    /// at a bank it cannot enter.
    private mutating func swimWanderStep(dt: Double, world: World) -> Vector3 {
        wanderTimer -= dt
        guard wanderTimer <= 0 else { return wanderDirection }
        wanderTimer = 2.0 + Double.random(in: 0..<1, using: &rng) * 3.0
        if Double.random(in: 0..<1, using: &rng) < 0.2 {
            wanderDirection = .zero
            return wanderDirection
        }

        for _ in 0..<8 {
            let angle = Double.random(in: 0..<1, using: &rng) * 2 * .pi
            // Shallow rises and dives: a pond is a few blocks deep, and a
            // steeper heading would spend the whole leg against the bottom.
            let rise = (Double.random(in: 0..<1, using: &rng) - 0.5) * 0.6
            let candidate = Vector3(
                CGFloat(sin(angle)), CGFloat(rise), CGFloat(cos(angle))
            ).normalized()
            let ahead = position + candidate * Animal.swimLookahead
            if submerged(at: ahead, world: world) {
                wanderDirection = candidate
                return candidate
            }
        }
        wanderDirection = .zero
        return wanderDirection
    }

    /// Bends a wander heading toward the shoal — and refuses to, when that
    /// would swim the fish at a bank.
    ///
    /// The three urges are added to the heading `swimWanderStep` already
    /// picked, rather than replacing it, so a fish with one distant
    /// neighbour still mostly wanders and a fish in the middle of a shoal
    /// is mostly carried by it. The water test is the same one the wander
    /// itself passes, and it is deliberately the last word: cohesion is the
    /// one urge that will happily aim a whole shoal at the shore, and the
    /// fallback — the plain wander heading, which was already checked — is
    /// exactly the right thing to do instead.
    private func shoalStep(_ wander: Vector3, shoal: Shoal, world: World) -> Vector3 {
        let social = shoal.cohesion * Animal.shoalCohesion
            + shoal.alignment * Animal.shoalAlignment
            + shoal.separation * Animal.shoalSeparation
        let combined = wander + social
        guard combined.length() > Animal.shoalDeadZone else { return wander }
        let heading = combined.normalized()
        guard submerged(at: position + heading * Animal.swimLookahead, world: world) else {
            return wander
        }
        return heading
    }

    /// Beached: hop feebly, and hop toward water if there is any within a
    /// few cells. With none in reach it flops about at random, which is at
    /// least the right kind of hopeless.
    private mutating func flopStep(dt: Double, world: World) -> Vector3 {
        flopTimer -= dt
        if flopTimer <= 0 {
            flopTimer = Animal.flopInterval
            if isGrounded {
                velocity.y = Animal.flopImpulse
                isGrounded = false
            }
        }

        wanderTimer -= dt
        guard wanderTimer <= 0 else { return wanderDirection }
        wanderTimer = 0.5
        wanderDirection = waterBearing(world: world) ?? {
            let angle = Double.random(in: 0..<1, using: &rng) * 2 * .pi
            return Vector3(CGFloat(sin(angle)), 0, CGFloat(cos(angle)))
        }()
        return wanderDirection
    }

    /// A horizontal heading toward the nearest water cell within
    /// `waterSearchRadius`, or nil when there is none to make for.
    private func waterBearing(world: World) -> Vector3? {
        let radius = Animal.waterSearchRadius
        let cx = Int(floor(position.x)), cy = Int(floor(position.y)), cz = Int(floor(position.z))
        var best: Vector3?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for dy in -2...2 {
            for dz in -radius...radius {
                for dx in -radius...radius
                where world.isWater(worldX: cx + dx, y: cy + dy, worldZ: cz + dz) {
                    let to = Vector3(
                        CGFloat(cx + dx) + 0.5 - position.x,
                        0,
                        CGFloat(cz + dz) + 0.5 - position.z
                    )
                    // Water directly overhead or underfoot has no heading
                    // to offer, so it is skipped rather than recorded: a
                    // zero distance banked as the best would be a distance
                    // nothing else could beat, and the search would answer
                    // "no water anywhere" while standing on a lake.
                    let distance = to.length()
                    guard distance > 0.0001, distance < bestDistance else { continue }
                    bestDistance = distance
                    best = to.normalized()
                }
            }
        }
        return best
    }

    /// Picks a new heading every few seconds and holds it. Nearly half the
    /// time it just stands there, which is what makes a field of animals
    /// read as calm rather than as a stampede.
    private mutating func wanderStep(dt: Double) -> Vector3 {
        wanderTimer -= dt
        guard wanderTimer <= 0 else { return wanderDirection }
        wanderTimer = 3.0 + Double.random(in: 0..<1, using: &rng) * 4.0
        if Double.random(in: 0..<1, using: &rng) < 0.45 {
            wanderDirection = .zero
        } else {
            let angle = Double.random(in: 0..<1, using: &rng) * 2 * .pi
            wanderDirection = Vector3(CGFloat(sin(angle)), 0, CGFloat(cos(angle)))
        }
        return wanderDirection
    }

    // MARK: - Collision

    private enum Axis { case x, y, z }

    /// Moves along one axis, backing off to the last free position on a
    /// hit. Returns true when the full step was taken.
    @discardableResult
    private mutating func moveAxis(_ axis: Axis, delta: CGFloat, world: World) -> Bool {
        guard delta != 0 else { return true }
        let start = value(of: axis)
        let target = start + delta

        setValue(target, of: axis)
        guard blocks(at: position, world: world) else {
            if axis == .y, delta < 0 { isGrounded = false }
            return true
        }

        var free = start
        var blocked = target
        for _ in 0..<14 {
            let mid = (free + blocked) / 2
            setValue(mid, of: axis)
            if blocks(at: position, world: world) { blocked = mid } else { free = mid }
        }
        setValue(free, of: axis)

        switch axis {
        case .x: velocity.x = 0
        case .z: velocity.z = 0
        case .y:
            isGrounded = delta < 0
            velocity.y = 0
        }
        return false
    }

    private func value(of axis: Axis) -> CGFloat {
        switch axis {
        case .x: return position.x
        case .y: return position.y
        case .z: return position.z
        }
    }

    private mutating func setValue(_ value: CGFloat, of axis: Axis) {
        switch axis {
        case .x: position.x = value
        case .y: position.y = value
        case .z: position.z = value
        }
    }

    /// True when there's headroom to hop up one block from here.
    private func canStepUp(world: World) -> Bool {
        var lifted = position
        lifted.y += 1.05
        return !collides(at: lifted, world: world)
    }

    /// What a move is allowed to end in. Terrain for everyone; for a
    /// swimmer that started the frame fully under, leaving the water counts
    /// as hitting a wall too — which is the one rule that keeps an axolotl
    /// out of the air and out of the ground at the same time, since a cell
    /// can only be water if it is neither.
    private func blocks(at feet: Vector3, world: World) -> Bool {
        if submersionHeld { return !submerged(at: feet, world: world) }
        return collides(at: feet, world: world)
    }

    /// True when every cell the body box touches holds water.
    func submerged(at feet: Vector3, world: World) -> Bool {
        forEachCell(at: feet) { x, y, z in world.isWater(worldX: x, y: y, worldZ: z) }
    }

    /// True when the cell at the middle of the body holds water — a looser
    /// test than `submerged`, and the one that decides whether it swims.
    private func centreInWater(at feet: Vector3, world: World) -> Bool {
        world.isWater(
            worldX: Int(floor(feet.x)),
            y: Int(floor(feet.y + kind.height / 2)),
            worldZ: Int(floor(feet.z))
        )
    }

    /// Runs `test` over every cell the body box overlaps, answering false
    /// as soon as one fails. The cell span is the one `collides` walks.
    private func forEachCell(at feet: Vector3, _ test: (Int, Int, Int) -> Bool) -> Bool {
        let halfWidth = kind.halfWidth
        let x0 = Int(floor(feet.x - halfWidth))
        let x1 = Int(ceil(feet.x + halfWidth)) - 1
        let y0 = Int(floor(feet.y))
        let y1 = Int(ceil(feet.y + kind.height)) - 1
        let z0 = Int(floor(feet.z - halfWidth))
        let z1 = Int(ceil(feet.z + halfWidth)) - 1
        guard x1 >= x0, y1 >= y0, z1 >= z0 else { return false }

        for y in y0...y1 {
            for z in z0...z1 {
                for x in x0...x1 where !test(x, y, z) { return false }
            }
        }
        return true
    }

    private func collides(at feet: Vector3, world: World) -> Bool {
        let halfWidth = kind.halfWidth
        let x0 = Int(floor(feet.x - halfWidth))
        let x1 = Int(ceil(feet.x + halfWidth)) - 1
        let y0 = Int(floor(feet.y))
        let y1 = Int(ceil(feet.y + kind.height)) - 1
        let z0 = Int(floor(feet.z - halfWidth))
        let z1 = Int(ceil(feet.z + halfWidth)) - 1
        guard x1 >= x0, y1 >= y0, z1 >= z0 else { return false }

        for y in y0...y1 {
            for z in z0...z1 {
                for x in x0...x1 where world.obstructsMob(worldX: x, y: y, worldZ: z) {
                    return true
                }
            }
        }
        return false
    }

    /// True when this animal's bounding box overlaps the given block cell.
    /// A dead animal does not occupy space or trigger plates.
    func overlaps(blockX x: Int, y: Int, z: Int) -> Bool {
        guard !isDead else { return false }
        return OccupancyQuery.overlaps(
            position: position,
            halfWidth: kind.halfWidth,
            height: kind.height,
            blockX: x, y: y, z: z
        )
    }
}

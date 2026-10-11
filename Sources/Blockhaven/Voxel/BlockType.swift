import Foundation

/// Which tool class breaks a block fastest. Blocks that `requiresTool`
/// drop nothing unless mined with at least their `minimumTier`.
enum ToolClass: UInt8 {
    case none, pickaxe, axe, shovel, sword
}

/// Material tier, shared by tools and by the blocks that demand them.
/// Higher mines faster and unlocks harder blocks.
enum ToolTier: Int, Comparable {
    case hand = 0, wood = 1, stone = 2, iron = 3, diamond = 4

    static func < (l: ToolTier, r: ToolTier) -> Bool { l.rawValue < r.rawValue }

    /// Multiplier on mining speed when the tool matches the block's class.
    var speedMultiplier: Double {
        switch self {
        case .hand: return 1
        case .wood: return 2
        case .stone: return 4
        case .iron: return 6
        case .diamond: return 8
        }
    }
}

/// One of the four horizontal directions a shaped block can be turned to.
///
/// A cell holds nothing but a `BlockType` raw value — there is no
/// metadata channel — so orientation has to be baked into the case, and
/// this is the alphabet the cases are spelled with. The raw values are the
/// order every run of shaped cases is laid out in, which is what lets
/// `stairFacing` and friends be a subtraction rather than a switch.
enum BlockFacing: UInt8, CaseIterable {
    case north = 0   // -Z
    case south       // +Z
    case east        // +X
    case west        // -X

    var dx: Int {
        switch self {
        case .east: return 1
        case .west: return -1
        default: return 0
        }
    }

    var dz: Int {
        switch self {
        case .south: return 1
        case .north: return -1
        default: return 0
        }
    }

    var opposite: BlockFacing {
        switch self {
        case .north: return .south
        case .south: return .north
        case .east: return .west
        case .west: return .east
        }
    }

    /// A quarter turn anticlockwise seen from above — where an open door
    /// swings to. Which way round is arbitrary; that it is the *same* way
    /// round everywhere is not, because closing a door has to put it back.
    var turnedLeft: BlockFacing {
        switch self {
        case .north: return .west
        case .west: return .south
        case .south: return .east
        case .east: return .north
        }
    }
}

/// An axis-aligned box inside one cell, in 0…1 block-local coordinates.
/// Both the collision tables and the shaped-block mesher speak in these.
struct BlockBox: Equatable {
    var minX: CGFloat, minY: CGFloat, minZ: CGFloat
    var maxX: CGFloat, maxY: CGFloat, maxZ: CGFloat

    init(_ minX: CGFloat, _ minY: CGFloat, _ minZ: CGFloat,
         _ maxX: CGFloat, _ maxY: CGFloat, _ maxZ: CGFloat) {
        self.minX = minX; self.minY = minY; self.minZ = minZ
        self.maxX = maxX; self.maxY = maxY; self.maxZ = maxZ
    }

    static let full = BlockBox(0, 0, 0, 1, 1, 1)

    /// A slab against one horizontal edge of the cell, `thickness` deep.
    static func edge(_ facing: BlockFacing, thickness: CGFloat) -> BlockBox {
        switch facing {
        case .north: return BlockBox(0, 0, 0, 1, 1, thickness)
        case .south: return BlockBox(0, 0, 1 - thickness, 1, 1, 1)
        case .east: return BlockBox(1 - thickness, 0, 0, 1, 1, 1)
        case .west: return BlockBox(0, 0, 0, thickness, 1, 1)
        }
    }

    /// Half the cell, on `facing`'s side or the far side of it, between two
    /// heights. The two halves of a staircase are both this.
    static func half(
        _ facing: BlockFacing, toward: Bool, yMin: CGFloat, yMax: CGFloat
    ) -> BlockBox {
        let side = toward ? facing : facing.opposite
        switch side {
        case .north: return BlockBox(0, yMin, 0, 1, yMax, 0.5)
        case .south: return BlockBox(0, yMin, 0.5, 1, yMax, 1)
        case .east: return BlockBox(0.5, yMin, 0, 1, yMax, 1)
        case .west: return BlockBox(0, yMin, 0, 0.5, yMax, 1)
        }
    }
}

/// Which half of a two-cell block a case is.
enum DoorPart: UInt8 { case lower, upper }
enum BedPart: UInt8 { case foot, head }

/// Every block that can occupy a cell in the world grid.
///
/// **Raw values are append-only.** Old saves index blocks by raw value, and
/// a raw an older build does not know decodes to "nothing there" on purpose
/// — so a case may be added at the end, and never moved or removed.
enum BlockType: UInt8, CaseIterable {
    case air = 0
    case grass
    case dirt
    case stone
    case cobblestone
    case sand
    case sandstone
    case gravel
    case log
    case planks
    case leaves
    case glass
    case bedrock
    case coalOre
    case ironOre
    case goldOre
    case diamondOre
    case snow
    case water
    case craftingTable
    case brick
    case obsidian

    // MARK: Shaped blocks
    //
    // Everything from here down is a *shaped* block: it does not fill its
    // cell, and the mesher, the collision tables and `isOpaque` all key off
    // that. Each run is laid out facing-major in `BlockFacing.rawValue`
    // order (north, south, east, west), which is what lets the accessors
    // below be arithmetic instead of a thirty-arm switch. Nothing here may
    // be reordered — see the note on the enum.

    /// Bottom half-slab plus the upper quarter against the `facing` edge:
    /// the stairs ascend *toward* their facing.
    case oakStairsNorth, oakStairsSouth, oakStairsEast, oakStairsWest
    case cobbleStairsNorth, cobbleStairsSouth, cobbleStairsEast, cobbleStairsWest

    /// A thin panel against the `facing` edge of the cell. Open swings it a
    /// quarter turn to the adjacent edge and makes it passable.
    case oakDoorLowerNorth, oakDoorLowerSouth, oakDoorLowerEast, oakDoorLowerWest
    case oakDoorUpperNorth, oakDoorUpperSouth, oakDoorUpperEast, oakDoorUpperWest
    case oakDoorLowerNorthOpen, oakDoorLowerSouthOpen, oakDoorLowerEastOpen, oakDoorLowerWestOpen
    case oakDoorUpperNorthOpen, oakDoorUpperSouthOpen, oakDoorUpperEastOpen, oakDoorUpperWestOpen

    /// One case only: which arms a pane grows is worked out at mesh time
    /// from its neighbours, so connectivity costs no raw values at all.
    case glassPane

    /// Two cells, 9/16 high. `facing` points from the foot to the head.
    case bedFootNorth, bedFootSouth, bedFootEast, bedFootWest
    case bedHeadNorth, bedHeadSouth, bedHeadEast, bedHeadWest

    // MARK: Full cubes, added after the shaped run
    //
    // The two other trees and the thing that grows in a desert. These are
    // ordinary cubes and belong up with the others by every measure except
    // the one that decides: raw values are append-only, and putting them
    // where they read best would move every shaped block's raw and silently
    // turn every staircase in every existing save into a door. So they go
    // at the end, and `isShaped` reads two ranges instead of one.
    case birchLog, birchLeaves
    case spruceLog, spruceLeaves
    case cactus

    // MARK: Cross plants
    //
    // Two thin slabs crossed in the middle of the cell, drawn from a mostly
    // transparent tile. Nothing you can stand on, nothing that stops you,
    // and gone in one hit.
    case tallGrass, poppy, dandelion, cornflower, deadBush

    // MARK: Torch
    //
    // A thin post standing on the cell floor, and the first thing in this
    // world that makes its own light. Shaped, like the plants, but emphatically
    // not one of them: see the bounds on `isPlant` below, which this case is
    // the reason for.
    case torch

    // MARK: TNT
    //
    // An ordinary full cube until something lights it. The fuse lives in
    // `FuseManager`, not in the block — a block is a byte and cannot count.
    case tnt

    // MARK: Rails
    //
    // A flat plate on the floor of its cell, and the only family here whose
    // *shape* is a statement about its neighbours rather than about itself:
    // a rail is which two sides of the cell it connects. Straights, the four
    // corners, the four ascents, and the powered pair that pushes a cart
    // along instead of just carrying it.
    //
    // The ordering inside the run matters to nothing but `railShape`, which
    // reads it as a table. The run as a whole must stay contiguous, because
    // `isRail` is two comparisons against its ends.
    case railNorthSouth, railEastWest
    case railCurveNorthEast, railCurveNorthWest
    case railCurveSouthEast, railCurveSouthWest
    case railSlopeNorth, railSlopeSouth, railSlopeEast, railSlopeWest
    case boosterNorthSouth, boosterEastWest

    // MARK: The pyramid's blocks
    //
    // Two ordinary full cubes, appended for the Great Pyramid on the demo
    // site: the solid gold of its capstone and the carved sandstone lining
    // its treasure chamber. Ordinary cubes in every respect — they are
    // listed here rather than up with the others only because raw values
    // are append-only (see the note on the trees above).
    case goldBlock
    case sandstoneCarved

    // MARK: The sunken city's blocks
    //
    // Two more cubes, for Atlantis: the sea-green stone the city is built
    // from, and the lamp that lights it — the second thing in this world
    // that makes its own light, and the first that does it twenty blocks
    // under the sea, where a torch has no floor it could stand on that is
    // not already wet.
    case seaStone
    case seaLantern

    // MARK: The treasure block
    //
    // Solid diamond, appended for the same reason the gold was: treasure
    // the demo's landmarks can be tipped and crowned with. Faintly
    // luminous, like the gold — see `lightEmission` for why treasure
    // glows here when the original's does not.
    case diamondBlock

    // MARK: The radiant lamps
    //
    // Stained glass with a light sealed inside: transparent like glass,
    // bright as a torch, in four colours. The light they flood is the
    // same scalar light everything floods — this engine's light has a
    // level but not a colour — so the colour lives in the glowing frame
    // and sparkle of the face itself, which at lamp brightness is what
    // you see anyway. Crafted by staining a sea lantern with something
    // that colour: a poppy, a dandelion, a cactus, a cornflower.
    case radiantRed
    case radiantYellow
    case radiantGreen
    case radiantCyan

    // MARK: Glow Crystal
    //
    // Dark rock veined with trapped light — the mineral the lamps only
    // imitate. An opaque cube as bright as a torch, so it works as
    // paving, ceiling, or a lamp you can stand on. Crafted by cooking
    // torchlight into stone.
    case glowCrystal

    // MARK: The pearl lamp
    //
    // A cube that is all glow: white-hot at the heart of each face,
    // magenta at the rim, torch-bright. Where the radiants are glass
    // with a light inside, this is the light itself with a surface —
    // solid, opaque, and the pinkest thing in the game. Crafted by
    // staining a sea lantern with a poppy and a cornflower at once,
    // red and blue making pink.
    case pearlLight

    // MARK: The painted columns
    //
    // Two cubes that stack into an Egyptian column: a fluted sandstone
    // shaft, and the painted capital that crowns it — gold, red and blue
    // bands under a ring of green lotus leaves, the way the temple
    // painters actually did it. One block each rather than a shaped
    // column, because a colonnade is a rhythm of verticals and the
    // rhythm reads at cube resolution; the paint is what carries it.
    case sandstonePillar
    case pillarCapital

    // MARK: The sky city's blocks
    //
    // Four cubes for the city that floats over the demo site's southern
    // valley. Lime plaster and the same plaster crossed with dark beams
    // make the half-timbered houses; the cloud is white weather with a
    // walkable top, because in a game of cubes even the sky should be
    // standable-on; and the striped canvas is what an airship's balloon
    // is sewn from.
    case plaster
    case timberFrame
    case cloud
    case balloonCanvas

    // MARK: The chest
    //
    // The first block in this world with an inside. Everything else here
    // is a byte and nothing but a byte; a chest is a byte plus twenty-seven
    // slots kept beside the world in `ChestStore`, keyed by this cell.
    // Appended last, like everything else, because raw values are
    // append-only — see the note at the top of the enum.
    case chest

    // MARK: The furnace
    //
    // The second block with an inside, and the first *process*: what it
    // holds is not just slots but a clock, kept beside the world in
    // `FurnaceStore` the same way a chest's contents are. Two cases rather
    // than one, on the door/rail pattern — `furnace` and `furnaceLit` are
    // the same block cold and burning, and the world's own `setBlock`
    // swaps between them as fuel catches and runs out, so whether a
    // furnace is working is a fact about the world a player reads by
    // looking, not a number in a menu.
    case furnace, furnaceLit

    // MARK: The signal
    //
    // Everything above reacts to the player. This is the one thing in the
    // game that reacts to *itself*: a lever's on/off is a fact a neighbour
    // can read, wire carries that fact outward one cell at a time, and a
    // door or a stick of TNT at the far end answers to it exactly as if a
    // player had swung it or lit it — see `SignalNetwork`. Two blocks, on
    // the door/furnace pattern of one case per state rather than a hidden
    // flag: `leverOff`/`leverOn` and `wireOff`/`wireOn` are what a player
    // reads to know what the machine they are looking at is doing, with no
    // screen anywhere in the loop.
    case leverOff, leverOn
    case wireOff, wireOn

    // MARK: Farmland and wheat
    //
    // The first thing in this world that grows because time passed, not
    // because a player placed it: tilled soil, and a crop that climbs
    // through four stages sitting on top of it — see `CropTick`. A cross
    // plant like the tail of the enum above, but appended down here
    // because raw values are append-only. Ordering inside the run matters
    // to nothing but growth, which reads it as a ladder: breaking or
    // advancing a stage is stepping one raw value at a time toward
    // `wheatStage3`, the one worth harvesting.
    case farmland
    case wheatStage0, wheatStage1, wheatStage2, wheatStage3

    // MARK: The hopper
    //
    // The first block that moves an item without a player's hand on it: a
    // funnel that pulls one item a second from whatever sits above it —
    // a chest's stocked slot, a furnace's finished output — and hands it
    // to whatever sits below, the same way a player's own hand would. See
    // `HopperStore`. An ordinary cube rather than a new shaped family: a
    // hopper's whole gameplay is what passes through it, not a state
    // worth reading off its own block the way a furnace's fire is.
    case hopper

    // MARK: The pressure plate
    //
    // The signal network's second source, after the lever — but this one
    // is thrown by weight, not by a click. See `SignalNetwork.plateCells`.
    // On/off is still read off the block itself, the same as a lever or a
    // door: `pressurePlateOff`/`pressurePlateOn` are two cases rather than
    // a hidden flag, so a player standing over one sees the same thing the
    // network is acting on.
    case pressurePlateOff, pressurePlateOn

    // MARK: The sapling
    //
    // Wood is the one material a player can only ever find, never grow —
    // every other staple in this game has a renewable loop (wheat climbs
    // four stages on farmland, an animal breeds another animal) except the
    // planks the very first crafting table is built from. A sapling closes
    // that loop: planted, it stands as scenery like any other cross plant,
    // then — its own clock, kept the same place a crop's is, in
    // `SaplingStore` — becomes a real tree, built by the exact function
    // that plants a wild one. Three species rather than one generic case,
    // matching the three logs and three leaves already in the game: an oak
    // sapling should not be able to grow a spruce.
    case sapling, birchSapling, spruceSapling

    // MARK: The detector rail
    //
    // The signal network's third source, and the first thrown by neither a
    // hand nor a foot: a cart parked over one turns it on, the same
    // pressure-plate idea one step further along a track. Two cases, not
    // four — an axis each, the same shape a booster has — because unlike a
    // plate it needs no on/off pair of its own: the cart sitting on top of
    // it already says so to anyone looking, so which detector cells are
    // currently live is kept off-block, in `SignalNetwork.activeDetectors`.
    // Not contiguous with the rail run above — raw values are append-only —
    // so `isRail` and `railEnds` both fold it in with an explicit `||`/case
    // rather than a range check, the same way `isSapling` folds into
    // `isPlant`.
    case detectorNorthSouth, detectorEastWest

    // MARK: Lava
    //
    // The first thing underground that can kill you just for touching it,
    // and the reason a torch stops being merely convenient once a shaft
    // goes deep enough to find some. Generated the same way an ore vein
    // is — `inVein`, clustered rather than sprinkled — in the lightless
    // lower band the deepest ores already live in, so the risk and the
    // reward of digging that far down are the same trip. Glows on its own
    // the way a torch does, which is the only warning a player gets before
    // rounding a corner into it: no block anywhere says "lava ahead",
    // the light does. See `WaterFlow.spread` for what happens where a
    // poured stream finds one.
    case lava

    // MARK: The signal torch
    //
    // The network's fourth source, and the first one that is also a
    // consumer: lit by default, it goes dark the instant a powered cell
    // touches it, and feeds power out to any wire touching it exactly
    // while it is lit — so it hands back the *opposite* of whatever it is
    // reading. Nothing before this could invert a signal, hold one for
    // longer than its switch was held, or refer to its own output, which
    // between them are the entire difference between a network that can
    // only ever mirror a switch and one that can remember, delay or
    // oscillate. A plate wired straight to a door only holds it open while
    // a foot is still on the plate; a plate wired through one of these
    // holds the door open, dark, exactly as long as the plate is pressed
    // and not a frame longer — which sounds identical until a player wires
    // the torch's own output back around to its own input and gets a
    // clock nobody had to write, or wires two of them to each other and
    // gets a latch that remembers which one fired last. See
    // `SignalNetwork.updateTorches` for the delay that keeps a self-wired
    // loop oscillating in real time instead of collapsing in one frame.
    case signalTorchOff, signalTorchOn

    // MARK: The signal relay
    //
    // Wire alone gives out after fifteen cells — plenty for one door or one
    // dispenser, nowhere near enough for the ports, factories and settlements
    // the goal doc asks for, and there was never a way past that wall except
    // building closer together. A relay sits in the wire like any other
    // traversable cell but resets how far a signal has travelled the instant
    // it's crossed, exactly the way a real repeater refreshes signal back
    // to full strength — see `SignalNetwork.reach` for where that reset
    // actually happens. One relay every fifteen cells turns a network capped
    // at "most of a room" into one with no real ceiling at all, and it costs
    // every existing consumer nothing to benefit: a door, a stick of TNT, a
    // hopper and a booster a hundred cells from their lever don't know the
    // difference between one relay and being close by.
    case signalRelayOff, signalRelayOn

    // MARK: The daylight sensor
    //
    // A celestial sensor that reads solar elevation: outputs power proportional
    // to sun height when open to sky; unpowered at night or under solid cover.
    case daylightSensor = 121

    // MARK: The signal lamp
    //
    // An opaque cube of signal-veined glass that illuminates brightly
    // (light level 15) when powered by a signal network and goes dark when unpowered.
    case signalLamp = 122
    case signalLampLit = 123

    // MARK: The ice block
    //
    // A frozen translucent cube formed when water is exposed to sub-freezing
    // biomes or alpine altitudes open to the sky. Thaws back into water when
    // bathed in thermal radiance.
    case ice = 124

    // MARK: - Shaped-block predicates

    /// True for every case that does not fill its cell. The mesher's
    /// dispatch, the collision boxes and `isOpaque` all hang off this.
    ///
    /// Two ranges rather than one comparison, because the cubes added after
    /// the beds sit between the two shaped runs — see the note on those
    /// cases. Still two comparisons and no lookup, and the hot paths go
    /// through `shapedByRawValue` regardless.
    var isShaped: Bool {
        (rawValue >= BlockType.oakStairsNorth.rawValue
            && rawValue <= BlockType.bedHeadWest.rawValue)
            || (rawValue >= BlockType.tallGrass.rawValue
                && rawValue <= BlockType.torch.rawValue)
            || isRail
            || isLever || isWire
            || isCrop
            || isPressurePlate
            || isSapling
            || isSignalTorch
            || isSignalRelay
    }

    /// True for a block a mason's line may fill a whole box with at once.
    /// Most of what `isShaped` excludes stays excluded for the right
    /// reason — a rail's own shape depends on which neighbours exist yet,
    /// a lever or a crop needs the network or the growth clock told about
    /// it one cell at a time, and the small set of blocks that carry their
    /// own store entry (a chest's contents, a furnace's fire, a hopper's
    /// cooldown, a crafting table's grid) stay a one-at-a-time placement: a
    /// wall of a thousand chests is not a wall anyone meant to place, it is
    /// a typo.
    ///
    /// Wire and a relay are the one exception, because they were never on
    /// that list for the reason the others are: `SignalNetwork` never
    /// registers either one anywhere — it finds them by scanning the world
    /// during `recompute`, the same walk whether a run of them arrived one
    /// click at a time or from a single fill. A lever, a plate and a
    /// detector are switches meant to be thrown one at a time, so bulk
    /// placement stays excluded even though it's mechanically possible —
    /// nothing is gained by planting fifty identical hand-thrown switches
    /// in one gesture. Wire, a relay and a torch are the opposite: none of
    /// them is meaningfully "thrown," so a whole wall of any of them is
    /// exactly the monumental wiring a mason's line exists for. Wire and a
    /// relay need nothing but to already be sitting in the world, which a
    /// fill leaves them doing exactly as well as a hand did; a torch still
    /// needs its own `*Placed`/`*Removed` call the way a fill makes it,
    /// same as the single-cell placement path already does.
    var isBulkFillable: Bool {
        if isWire || isSignalRelay || isSignalTorch { return true }
        return !isShaped && self != .chest && self != .furnace && self != .furnaceLit
            && self != .craftingTable && self != .hopper && self != .daylightSensor
    }

    /// True for the switch a player throws by hand.
    var isLever: Bool { self == .leverOff || self == .leverOn }
    /// True for the switch weight throws instead.
    var isPressurePlate: Bool { self == .pressurePlateOff || self == .pressurePlateOn }
    /// True for the lamp in either state — the one the network switches
    /// rather than the player.
    var isSignalLamp: Bool { self == .signalLamp || self == .signalLampLit }

    /// True for the switch nothing throws — it throws itself, the instant
    /// nothing powered is touching it.
    var isSignalTorch: Bool { self == .signalTorchOff || self == .signalTorchOn }
    /// True for the cell that resets how far a signal has travelled rather
    /// than carrying it any differently than plain wire does.
    var isSignalRelay: Bool { self == .signalRelayOff || self == .signalRelayOn }
    /// True for any of the four wheat growth stages.
    var isCrop: Bool {
        rawValue >= BlockType.wheatStage0.rawValue && rawValue <= BlockType.wheatStage3.rawValue
    }
    /// True for the plate that only ever carries what a lever tells it to.
    var isWire: Bool { self == .wireOff || self == .wireOn }

    /// True for any of the three saplings, whichever tree it grows into.
    var isSapling: Bool {
        rawValue >= BlockType.sapling.rawValue && rawValue <= BlockType.spruceSapling.rawValue
    }

    /// True for the three leaves — the one thing a hand closing over them
    /// might come away with a sapling from. See `GameViewController`'s
    /// sapling-drop roll, the one place this is asked.
    var isLeaf: Bool { self == .leaves || self == .birchLeaves || self == .spruceLeaves }

    /// True for every rail, powered or not, flat or sloped — plus the
    /// detector rail, appended long after this run and folded in with an
    /// explicit `||` rather than widening the range, the same way `isPlant`
    /// folds in `isSapling`.
    var isRail: Bool {
        (rawValue >= BlockType.railNorthSouth.rawValue
            && rawValue <= BlockType.boosterEastWest.rawValue)
            || isDetectorRail
    }

    /// True for either axis of the detector rail.
    var isDetectorRail: Bool { self == .detectorNorthSouth || self == .detectorEastWest }

    /// True for the two that push a cart along rather than just carrying it.
    var isBooster: Bool {
        self == .boosterNorthSouth || self == .boosterEastWest
    }

    /// True for the four that climb. A cart on one of these trades height
    /// for speed in both directions, which is the whole of what makes a
    /// track a roller coaster rather than a tram line.
    var isRailSlope: Bool {
        rawValue >= BlockType.railSlopeNorth.rawValue
            && rawValue <= BlockType.railSlopeWest.rawValue
    }

    /// The uphill direction of a sloped rail, or nil for a flat one.
    var railRise: BlockFacing? {
        switch self {
        case .railSlopeNorth: return .north
        case .railSlopeSouth: return .south
        case .railSlopeEast: return .east
        case .railSlopeWest: return .west
        default: return nil
        }
    }

    /// The two sides of the cell this rail joins.
    ///
    /// Everything the cart does is a question about this and nothing else,
    /// which is why the shape is stored in the block rather than worked out
    /// from the neighbours each time a cart rolls over it: a track is read
    /// far more often than it is built.
    var railEnds: (BlockFacing, BlockFacing)? {
        switch self {
        case .railNorthSouth, .boosterNorthSouth, .detectorNorthSouth: return (.north, .south)
        case .railEastWest, .boosterEastWest, .detectorEastWest: return (.east, .west)
        case .railCurveNorthEast: return (.north, .east)
        case .railCurveNorthWest: return (.north, .west)
        case .railCurveSouthEast: return (.south, .east)
        case .railCurveSouthWest: return (.south, .west)
        // A slope runs along its rise: it climbs toward `railRise` and
        // descends the other way.
        case .railSlopeNorth: return (.north, .south)
        case .railSlopeSouth: return (.south, .north)
        case .railSlopeEast: return (.east, .west)
        case .railSlopeWest: return (.west, .east)
        default: return nil
        }
    }

    /// True for the cross plants: grass, the flowers, a dead bush.
    ///
    /// Everything they do differently from the other shaped blocks hangs
    /// off this — no collision, no hardness to speak of, and no tool that
    /// helps.
    ///
    /// Bounded at both ends, and it has to be. This read `rawValue >=
    /// tallGrass` while the plants were the tail of the enum, which made
    /// every case appended after them a plant by default: the torch would
    /// have arrived with no collision, no hardness, a cross-shaped mesh and
    /// a habit of falling off its own floor, and nothing would have said so.
    /// An open-ended predicate on an append-only enum is a trap that springs
    /// on whoever appends next.
    var isPlant: Bool {
        (rawValue >= BlockType.tallGrass.rawValue
            && rawValue <= BlockType.deadBush.rawValue)
            || isCrop
            || isSapling
    }

    /// True for delicate non-structural scenery (plants, flowers, saplings,
    /// crops, signal wire, rails, levers, pressure plates, signal
    /// torches, and signal relays). Falling granular blocks fall through
    /// and displace them rather than resting on top of them.
    var isDelicateScenery: Bool {
        isWire || isRail || isLever || isSignalTorch || isSignalRelay || isPressurePlate || isPlant
    }

    /// How brightly this block lights its surroundings, 0…15 in the same
    /// units the propagation uses. Zero for everything that is not a lamp.
    ///
    /// 14 rather than the original's exact number is deliberate: it puts the
    /// last visible step of a torch's pool at 14 blocks, which is a little
    /// under a chunk, so a torch never lights a cell the mesher would have
    /// to reach two chunks away to shade.
    var lightEmission: UInt8 {
        switch self {
        case .torch: return 14
        // Dimmer than a plain torch on purpose: a corridor lit by these
        // should still read as "wired," not as lighting, at a glance.
        case .signalTorchOn: return 9
        // Bright enough that a pool of it is what a player sees first,
        // often before they see the edge of it — the light is the warning.
        case .lava: return 14
        // As bright as a torch and no brighter, for the same reach reason
        // — see the note above. That it is a full opaque cube is what
        // makes it the underwater lamp: it emits from its faces, so
        // unlike the torch it needs no dry floor to stand on.
        case .seaLantern: return 14
        // Treasure gleams. the original's gold and diamond do not, but its
        // treasure rooms are lit by the finder's own torch — this game's
        // treasure sits at the top of a drowned trident and under a
        // desert, and a hoard that shows itself in the dark is the whole
        // difference between finding it and walking past it. Well short
        // of a torch, so it reads as a glint rather than a lamp.
        case .goldBlock: return 6
        case .diamondBlock: return 9
        // Full lamps, like the lantern they are stained from.
        case .radiantRed, .radiantYellow, .radiantGreen, .radiantCyan: return 14
        case .glowCrystal: return 14
        case .pearlLight: return 14
        // The treasure ores glow in the raw, dimmer than the refined
        // block: enough to betray a vein across a dark cave, not enough
        // to light the digging. Coal and iron stay dark — the glow marks
        // what is worth the detour.
        case .goldOre: return 5
        case .diamondOre: return 7
        // Embers, not a lamp: enough to find a workshop by, well short of
        // what a torch throws. Only while burning — `furnace` (cold) emits
        // nothing at all.
        case .furnaceLit: return 9
        case .signalLampLit: return 15
        default: return 0
        }
    }

    /// True where light passes. Air, water, glass and every shaped block let
    /// it through; a full opaque cube stops it.
    ///
    /// Deliberately *not* `!isOpaque`: leaves are opaque to the mesher, on
    /// purpose, so that a canopy does not generate a face per leaf. Light
    /// treating them as solid would leave a black shell under every tree.
    var transmitsLight: Bool {
        switch self {
        case .leaves, .birchLeaves, .spruceLeaves: return true
        default: return isShaped || !isOpaque
        }
    }

    /// A plant needs something under it. Nothing grows on air, on water or
    /// on another plant, and a plant whose floor is mined should not be
    /// left hanging — which is what `World.setBlock` uses this for.
    static func plantCanRootOn(_ ground: BlockType) -> Bool {
        switch ground {
        case .grass, .dirt, .sand, .snow, .gravel, .farmland: return true
        default: return false
        }
    }

    /// Stricter than `plantCanRootOn`: a wheat seed roots only in tilled
    /// ground, which is the entire reason to till in the first place — a
    /// seed that took on any patch of dirt would make the hoe pointless.
    static func cropCanRootOn(_ ground: BlockType) -> Bool { ground == .farmland }

    var isStairs: Bool {
        rawValue >= BlockType.oakStairsNorth.rawValue
            && rawValue <= BlockType.cobbleStairsWest.rawValue
    }

    var isDoor: Bool {
        rawValue >= BlockType.oakDoorLowerNorth.rawValue
            && rawValue <= BlockType.oakDoorUpperWestOpen.rawValue
    }

    var isBed: Bool {
        rawValue >= BlockType.bedFootNorth.rawValue
            && rawValue <= BlockType.bedHeadWest.rawValue
    }

    var isPane: Bool { self == .glassPane }

    /// The direction a shaped block is turned to, or nil for anything that
    /// has no orientation.
    var facing: BlockFacing? {
        let base: UInt8
        if isStairs { base = BlockType.oakStairsNorth.rawValue }
        else if isDoor { base = BlockType.oakDoorLowerNorth.rawValue }
        else if isBed { base = BlockType.bedFootNorth.rawValue }
        else { return nil }
        return BlockFacing(rawValue: (rawValue - base) % 4)
    }

    var stairFacing: BlockFacing? { isStairs ? facing : nil }
    var doorFacing: BlockFacing? { isDoor ? facing : nil }
    var bedFacing: BlockFacing? { isBed ? facing : nil }

    /// Which full block a staircase is cut from — its texture, its hardness
    /// and the tool that mines it all come from here.
    var stairMaterial: BlockType? {
        guard isStairs else { return nil }
        return rawValue < BlockType.cobbleStairsNorth.rawValue ? .planks : .cobblestone
    }

    var doorPart: DoorPart? {
        guard isDoor else { return nil }
        // lower/upper alternate every four cases, closed run then open run.
        let offset = (rawValue - BlockType.oakDoorLowerNorth.rawValue) % 8
        return offset < 4 ? .lower : .upper
    }

    var doorIsOpen: Bool {
        isDoor && rawValue >= BlockType.oakDoorLowerNorthOpen.rawValue
    }

    var bedPart: BedPart? {
        guard isBed else { return nil }
        return rawValue < BlockType.bedHeadNorth.rawValue ? .foot : .head
    }

    // MARK: - Shaped-block constructors

    static func oakStairs(_ facing: BlockFacing) -> BlockType {
        BlockType(rawValue: oakStairsNorth.rawValue + facing.rawValue)!
    }

    static func cobbleStairs(_ facing: BlockFacing) -> BlockType {
        BlockType(rawValue: cobbleStairsNorth.rawValue + facing.rawValue)!
    }

    static func oakDoor(_ part: DoorPart, facing: BlockFacing, open: Bool) -> BlockType {
        let base = oakDoorLowerNorth.rawValue
            + (open ? 8 : 0) + (part == .upper ? 4 : 0)
        return BlockType(rawValue: base + facing.rawValue)!
    }

    static func bed(_ part: BedPart, facing: BlockFacing) -> BlockType {
        let base = bedFootNorth.rawValue + (part == .head ? 4 : 0)
        return BlockType(rawValue: base + facing.rawValue)!
    }

    /// The same door with its open flag flipped, keeping part and facing.
    var doorToggled: BlockType? {
        guard isDoor, let part = doorPart, let facing = doorFacing else { return nil }
        return BlockType.oakDoor(part, facing: facing, open: !doorIsOpen)
    }

    /// Blocks the player and stops movement. Water is passable (you swim),
    /// and so is a door standing open.
    var isSolid: Bool {
        switch self {
        case .air, .water, .lava, .torch: return false
        default: return (isPlant || isPressurePlate) ? false : !doorIsOpen
        }
    }

    /// True if this block is subject to granular gravity when unsupported.
    var hasGravity: Bool {
        self == .sand || self == .gravel
    }

    /// Alias for granular materials.
    var isGranular: Bool {
        hasGravity
    }

    /// Whether an entity's simple box-vs-block collision should treat this
    /// cell as an obstacle. `isSolid` alone overstates that for a rail, a
    /// lever, wire, a signal torch or a signal relay — every one of them is
    /// "solid" in the sense that governs light and placement, but each
    /// carries an empty `collisionBoxes` because it is scenery on the
    /// floor, not a wall. The player's own collision already asks
    /// `collisionBoxes` rather than `isSolid` for exactly this reason; this
    /// is that same distinction collapsed to the single bool a mob's coarse
    /// per-cell collision test needs.
    var obstructsMovement: Bool { isSolid && !collisionBoxes.isEmpty }

    /// True for water and lava. Fluids are transparent to ordinary picking
    /// and mining, but can be scooped with a bucket.
    var isFluid: Bool {
        self == .water || self == .lava
    }

    /// Is there something *here* — as opposed to something that stops you
    /// walking. The crosshair picks by this, and a placement asks it of the
    /// cell it is about to write to.
    ///
    /// The two questions were the same one until doors: an open door does
    /// not block movement, but it is still a block sitting in that cell, so
    /// it has to be aimable at (or it could never be closed or mined again)
    /// and it has to refuse a block placed into it (or it would be silently
    /// overwritten, orphaning its other half). Air, water and lava are the only
    /// cells that are genuinely empty — you place into fluids on purpose,
    /// and you aim through them, both exactly as the original does.
    var occupiesCell: Bool {
        switch self {
        case .air, .water, .lava: return false
        default: return true
        }
    }

    /// Fully hides the neighbouring face behind it. Only genuinely
    /// see-through blocks are excluded — leaves use a fully opaque texture
    /// (the original's "fast" leaves), so treating them as occluders saves the
    /// enormous number of internal faces a dense canopy would otherwise
    /// generate.
    ///
    /// Every shaped block is excluded, without exception and without a case
    /// of its own: a block that leaves most of its cell empty cannot hide
    /// the face behind it, and the buried-face classifier has to be able to
    /// flood *through* the gap round a staircase or a pane the way it
    /// floods through air. Getting this wrong on one case is a face culled
    /// that should not be and a chunk half of whose surface is filed as
    /// buried, so it is derived from `isShaped` rather than enumerated.
    var isOpaque: Bool {
        switch self {
        case .air, .water, .glass, .ice, .daylightSensor: return false
        // The radiant lamps are stained glass with a light inside: you see
        // through them, faces behind them draw, and their own glow floods
        // out — `transmitsLight` follows from this being false.
        case .radiantRed, .radiantYellow, .radiantGreen, .radiantCyan: return false
        default: return !isShaped
        }
    }

    /// `isOpaque` as a flat table, indexed by raw value.
    ///
    /// Ambient occlusion asks the question three times per vertex, twelve
    /// times per face, and the buried-face classifier asks it once per cell
    /// of a padded volume; going through the switch each time was
    /// measurable.
    static let opaqueByRawValue: [Bool] = {
        var table = [Bool](repeating: true, count: 256)
        for raw in 0..<256 {
            table[raw] = BlockType(rawValue: UInt8(raw))?.isOpaque ?? false
        }
        return table
    }()

    /// `lightEmission` as a flat table of 0…1 fractions, indexed by raw
    /// value. The mesher floors a face's torch light at the face's own
    /// block's emission — the face of a lamp is the source, not a wall
    /// near one, and without this a pearl lamp rendered one step dimmer
    /// than the light it was flooding everywhere else.
    ///
    /// A full-strength emitter maps to exactly 1.0 rather than 14/15:
    /// the saturated torch byte is the shader's signal that the face is
    /// itself a lamp and should keep its daylight look at any hour. No
    /// neighbouring cell can reach that byte — the brightest a wall next
    /// to a lamp reads is the lamp's 14, which is 238 of 255.
    static let emissionByRawValue: [Float] = {
        var table = [Float](repeating: 0, count: 256)
        for raw in 0..<256 {
            let emission = BlockType(rawValue: UInt8(raw))?.lightEmission ?? 0
            table[raw] = emission >= 14 ? 1.0 : Float(emission) / 15
        }
        return table
    }()

    /// `isShaped` as a flat table, indexed by raw value — the branch the
    /// mesher and the collision test take once per cell to decide between
    /// the cube fast path and the shaped one. Unknown raws are not shaped,
    /// which keeps a save from a newer build on the cube path rather than
    /// indexing a geometry table that has no entry for it.
    static let shapedByRawValue: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for raw in 0..<256 {
            table[raw] = BlockType(rawValue: UInt8(raw))?.isShaped ?? false
        }
        return table
    }()

    /// Rendered in the alpha-blended pass rather than the opaque one.
    var isTranslucent: Bool {
        switch self {
        case .water, .glass, .glassPane, .ice,
             .radiantRed, .radiantYellow, .radiantGreen, .radiantCyan:
            return true
        default:
            return false
        }
    }

    // MARK: - Collision

    /// The boxes a player's collision test has to clear, in 0…1 cell-local
    /// coordinates. A full cube is one box covering the cell, which is what
    /// every unshaped block returns and what the fast path assumes without
    /// ever asking; only `shapedByRawValue` cells reach this.
    ///
    /// An open door returns *no* boxes — it is passable, which is the whole
    /// point of opening it.
    var collisionBoxes: [BlockBox] {
        guard isShaped else { return isSolid ? [.full] : [] }
        // A plant is scenery. You walk through it, exactly as you walk
        // through the original's grass, and the crosshair can still pick it
        // because that is `occupiesCell`'s question and not this one.
        if isPlant { return [] }
        // A rail is a plate on the floor. You walk over it, not into it.
        if isRail { return [] }
        // A torch is scenery too: you walk through the cell it stands in.
        // Anything else and a corridor lit down one side becomes a corridor
        // you keep catching your shoulder on.
        if self == .torch { return [] }
        // A lever is a switch, not a wall, and wire is a plate on the
        // floor exactly like a rail — both scenery, for the same reasons.
        // A pressure plate needs this even more than wire does: the whole
        // point is standing *on* it, which a collision box would stop.
        if isLever || isWire || isPressurePlate || isSignalTorch || isSignalRelay { return [] }
        if isStairs, let facing = stairFacing {
            return [
                BlockBox(0, 0, 0, 1, 0.5, 1),
                BlockBox.half(facing, toward: true, yMin: 0.5, yMax: 1),
            ]
        }
        if isDoor {
            guard !doorIsOpen, let facing = doorFacing else { return [] }
            return [.edge(facing, thickness: BlockType.doorThickness)]
        }
        if isBed { return [BlockBox(0, 0, 0, 1, BlockType.bedHeight, 1)] }
        if isPane {
            // A pane's shape is not in its cell — it is grown toward
            // whatever stands around it — so the best a table indexed by
            // raw value can give is the pane with nothing to hold on to,
            // which is the flat panel the mesher draws for that case. The
            // player asks `ShapedBlocks.paneBoxes` with the connections the
            // world actually has, so what stops them is always what they
            // can see. A fixed full cross here instead would stop them with
            // an invisible bar across every pane in a fence.
            return ShapedBlocks.paneBoxes(connections: [])
        }
        return [.full]
    }

    /// How deep a door panel sits into its cell.
    static let doorThickness: CGFloat = 3.0 / 16
    /// How tall a bed stands.
    static let bedHeight: CGFloat = 9.0 / 16
    /// Half the thickness of a pane's post and arms, as an inset from the
    /// cell edge — so the pane spans `paneHalf`…`1 - paneHalf`.
    static let paneHalf: CGFloat = 7.0 / 16

    /// `collisionBoxes` as a flat table. Only shaped raws are ever indexed
    /// — the cube path answers before it gets here — so the unshaped rows
    /// are left empty rather than filled with a box nothing reads.
    static let collisionBoxesByRawValue: [[BlockBox]] = {
        var table = [[BlockBox]](repeating: [], count: 256)
        for raw in 0..<256 {
            guard let type = BlockType(rawValue: UInt8(raw)), type.isShaped else { continue }
            table[raw] = type.collisionBoxes
        }
        return table
    }()

    /// Seconds to break bare-handed at tier 0, before tool multipliers.
    /// `.infinity` means indestructible.
    var hardness: Double {
        if isShaped {
            if isPlant { return 0 }  // one hit, like the original's
            if self == .torch { return 0 }
            // Quick to pick up, because building a track is mostly
            // rebuilding the last three you got wrong.
            if isRail { return 0.7 }
            if isStairs { return stairMaterial?.hardness ?? 2.4 }
            if isDoor { return 2.4 }
            if isBed { return 0.9 }
            // A switch and the wire it feeds are both quick to pick back
            // up, the same reasoning as a rail: a circuit is rebuilt far
            // more often than it is broken on purpose.
            if isLever { return 0.5 }
            if isWire { return 0.3 }
            if isPressurePlate { return 0.5 }
            if isSignalTorch { return 0 }
            if isSignalRelay { return 0.3 }
            return 0.4  // panes, and any shaped family added without an answer
        }
        switch self {
        case .air, .water, .lava: return 0
        case .daylightSensor: return 0.6
        case .signalLamp, .signalLampLit: return 0.4
        case .bedrock: return .infinity
        case .grass, .dirt, .sand, .gravel, .snow, .farmland: return 0.6
        case .leaves, .birchLeaves, .spruceLeaves: return 0.35
        case .glass: return 0.4
        case .ice: return 0.5
        case .cactus: return 0.4
        // Instant, as the original's is. A block you are about to blow up is
        // not a block anyone should have to chew through first.
        case .tnt: return 0
        case .log, .planks, .craftingTable, .chest, .birchLog, .spruceLog: return 2.4
        case .stone, .cobblestone, .sandstone, .sandstoneCarved, .brick, .seaStone,
             .sandstonePillar, .pillarCapital: return 6.0
        // Softer than stone on purpose: plaster and beams are house
        // fabric, and a house should be quicker to remodel than a quarry.
        case .plaster: return 1.5
        case .timberFrame: return 2.0
        // A cloud puts up almost no argument, and canvas is cloth.
        case .cloud: return 0.3
        case .balloonCanvas: return 0.8
        case .coalOre, .ironOre, .goldOre, .diamondOre: return 9.0
        case .obsidian: return 45.0
        // Soft, as the original's is: gold is a metal for looking at, not for
        // building out of.
        case .goldBlock: return 3.0
        case .diamondBlock: return 9.0
        // A lamp is glass with a light in it, and breaks like the glass.
        case .seaLantern, .radiantRed, .radiantYellow, .radiantGreen, .radiantCyan,
             .pearlLight:
            return 0.4
        // Crumbly, as the original's is — a mineral you scoop rather than mine.
        case .glowCrystal: return 0.6
        // Quarried stone, whichever way its fire happens to be sitting.
        case .furnace, .furnaceLit: return 3.5
        // Sheet iron, quicker to take back down than the furnace it feeds.
        case .hopper: return 3.0
        // Unreachable: every unshaped case past `obsidian` is answered
        // above. The arm exists because Swift cannot be told a switch
        // covers a prefix of an enum.
        default: return 1.0
        }
    }

    /// Which tool class mines this fastest.
    var toolClass: ToolClass {
        if isPlant { return .none }
        if isStairs { return stairMaterial?.toolClass ?? .axe }
        if isDoor || isBed { return .axe }
        if isPane { return .none }
        switch self {
        case .grass, .dirt, .sand, .gravel, .snow, .cloud, .farmland: return .shovel
        case .log, .planks, .craftingTable, .chest, .birchLog, .spruceLog, .timberFrame, .daylightSensor: return .axe
        case .stone, .cobblestone, .sandstone, .sandstoneCarved, .brick, .obsidian,
             .coalOre, .ironOre, .goldOre, .diamondOre, .goldBlock, .diamondBlock,
             .seaStone, .sandstonePillar, .pillarCapital, .plaster,
             .furnace, .furnaceLit, .hopper, .ice: return .pickaxe
        default: return .none
        }
    }

    /// The lowest tool tier that yields a drop. Below it the block still
    /// breaks, but gives nothing — mining stone with fists, the classic way.
    var minimumTier: ToolTier {
        // A staircase demands exactly what the block it was cut from
        // demands — cobblestone stairs are stone, and bare hands break them
        // without a drop, the same as the cobblestone they came from. The
        // other shaped blocks are wood, wool and glass, all of which are
        // `.hand` anyway, so they fall through with everything else.
        if isStairs { return stairMaterial?.minimumTier ?? .hand }
        switch self {
        case .stone, .cobblestone, .coalOre, .sandstone, .sandstoneCarved, .brick,
             .seaStone, .sandstonePillar, .pillarCapital, .furnace, .furnaceLit, .hopper: return .wood
        case .ironOre: return .stone
        case .goldOre, .diamondOre, .goldBlock, .diamondBlock: return .iron
        case .obsidian: return .diamond
        default: return .hand
        }
    }

    /// True when a drop requires `minimumTier` — otherwise the block drops
    /// regardless of what broke it.
    var requiresTool: Bool {
        minimumTier != .hand
    }

    /// What breaking this block yields.
    /// A shaped block always drops the one item it was placed from,
    /// whichever way it happens to be turned — you get your stairs back,
    /// not "east-facing stairs".
    var drop: ItemType? {
        if isStairs { return stairMaterial == .cobblestone ? .cobbleStairs : .oakStairs }
        if isDoor { return .oakDoor }
        if isBed { return .bed }
        if isPane { return .glassPane }
        switch self {
        case .air, .water, .lava, .bedrock, .ice: return nil
        case .grass: return .dirt
        // Tilled ground gives up the dirt it was cut from — there is no
        // "farmland" item to speak of, the same way stairs give up cobble
        // rather than a stack of themselves half broken.
        case .farmland: return .dirt
        case .stone: return .cobblestone
        // Ripe, it is worth harvesting; anything short of that hands back
        // only the seed it grew from — the plant has nothing else in it
        // yet. The other three stages fall to the default below, which
        // already answers `.wheatSeeds` for every stage via `blockItem`.
        case .wheatStage3: return .wheat
        // Matches the original's mostly-nothing leaf drop, for all three trees.
        case .leaves, .birchLeaves, .spruceLeaves: return nil
        case .coalOre: return .coal
        case .ironOre: return .rawIron
        case .goldOre: return .rawGold
        case .diamondOre: return .diamond
        case .snow: return nil
        // Whichever state it broke in, it comes back as the block you can
        // place — nobody stocks a bag with "lit furnace".
        case .furnace, .furnaceLit: return .furnace
        // A hand closing over a tuft of grass comes up with a seed, not
        // the tuft — the only way this game hands one out, and the reason
        // every meadow doubles as a seed bank. `pickItem` still answers
        // `.tallGrass` first (see `blockItem`), so middle-click keeps
        // picking the decoration, not the seed.
        case .tallGrass: return .wheatSeeds
        default: return ItemType.blockItem(for: self)
        }
    }

    /// What "pick block" puts in your hand: the block itself wherever an
    /// item places it, and only otherwise what breaking it would yield.
    ///
    /// The two differ exactly where mining transforms something — stone
    /// gives cobblestone, grass gives dirt, leaves give nothing. Pointing
    /// at a stone wall and asking for more of it should not hand over
    /// cobblestone, so this is not `drop`; and stairs have no `blockItem`
    /// at all, so it is not `blockItem` either.
    var pickItem: ItemType? {
        ItemType.blockItem(for: self) ?? drop
    }

    /// Which atlas tile each face samples.
    ///
    /// Shaped blocks are drawn part by part and the mesher picks their tiles
    /// itself, so what they answer here is only the sane fallback anything
    /// else — an icon, a particle, a debug cube — would want.
    func tile(for face: FaceKind) -> AtlasTile {
        if isShaped {
            if isPlant { return plantTile }
            if self == .torch { return .torch }
            if isRail {
                if isBooster { return .railBooster }
                if isDetectorRail { return .railDetector }
                if let ends = railEnds, ends.0 != ends.1.opposite { return .railCurve }
                return .railStraight
            }
            if isStairs { return (stairMaterial ?? .planks).tile(for: face) }
            if isDoor { return doorPart == .upper ? .doorTop : .doorBottom }
            if isLever { return self == .leverOn ? .leverOn : .leverOff }
            if isWire { return self == .wireOn ? .wireOn : .wireOff }
            if isPressurePlate { return self == .pressurePlateOn ? .pressurePlateOn : .pressurePlateOff }
            if isSignalTorch { return self == .signalTorchOn ? .signalTorchOn : .signalTorchOff }
            if isSignalRelay { return self == .signalRelayOn ? .signalRelayOn : .signalRelayOff }
            if isBed {
                switch face {
                case .top: return bedPart == .head ? .bedPillow : .bedBlanket
                case .bottom: return .planks
                case .side: return .bedSide
                }
            }
            return .glass  // panes, and anything shaped added without an answer
        }
        switch self {
        case .air: return .stone
        case .grass:
            switch face {
            case .top: return .grassTop
            case .bottom: return .dirt
            case .side: return .grassSide
            }
        case .dirt: return .dirt
        case .stone: return .stone
        case .cobblestone: return .cobblestone
        case .sand: return .sand
        case .sandstone:
            switch face {
            case .top: return .sandstoneTop
            case .bottom: return .sandstoneTop
            case .side: return .sandstoneSide
            }
        case .gravel: return .gravel
        case .tnt:
            switch face {
            case .top, .bottom: return .tntTop
            case .side: return .tntSide
            }
        case .log:
            switch face {
            case .top, .bottom: return .logTop
            case .side: return .logSide
            }
        case .planks: return .planks
        case .leaves: return .leaves
        case .glass: return .glass
        case .bedrock: return .bedrock
        case .coalOre: return .coalOre
        case .ironOre: return .ironOre
        case .goldOre: return .goldOre
        case .diamondOre: return .diamondOre
        case .snow: return .snow
        case .water: return .water
        case .lava: return .lava
        case .craftingTable:
            switch face {
            case .top: return .craftingTableTop
            case .bottom: return .planks
            case .side: return .craftingTableSide
            }
        case .chest:
            // The latch is on every side rather than on a chosen front.
            // A chest that faces one way needs placement to know which way
            // the player was standing and the mesher to know which face it
            // is drawing; a chest with four fronts is readable from
            // wherever a child happens to be standing, which is the thing
            // that matters here.
            switch face {
            case .top: return .chestTop
            case .bottom: return .planks
            case .side: return .chestFront
            }
        case .furnace:
            switch face {
            case .top, .bottom: return .cobblestone
            case .side: return .furnaceFront
            }
        case .furnaceLit:
            switch face {
            case .top, .bottom: return .cobblestone
            case .side: return .furnaceFrontLit
            }
        case .hopper:
            switch face {
            case .top: return .hopperTop
            case .bottom, .side: return .hopperSide
            }
        case .brick: return .brick
        case .obsidian: return .obsidian
        case .birchLog:
            switch face {
            case .top, .bottom: return .birchLogTop
            case .side: return .birchLogSide
            }
        case .birchLeaves: return .birchLeaves
        case .spruceLog:
            switch face {
            case .top, .bottom: return .spruceLogTop
            case .side: return .spruceLogSide
            }
        case .spruceLeaves: return .spruceLeaves
        case .cactus:
            switch face {
            case .top, .bottom: return .cactusTop
            case .side: return .cactusSide
            }
        case .goldBlock: return .goldBlock
        case .sandstoneCarved:
            switch face {
            // Plain sandstone above and below: the carvings are reliefs on
            // the faces you stand in front of, not a pattern to tile a
            // floor with.
            case .top, .bottom: return .sandstoneTop
            case .side: return .sandstoneCarved
            }
        case .seaStone: return .seaStone
        case .seaLantern: return .seaLantern
        case .diamondBlock: return .diamondBlock
        case .radiantRed: return .radiantRed
        case .radiantYellow: return .radiantYellow
        case .radiantGreen: return .radiantGreen
        case .radiantCyan: return .radiantCyan
        case .glowCrystal: return .glowCrystal
        case .pearlLight: return .pearlLight
        case .sandstonePillar:
            switch face {
            // Plain sandstone ends, so a toppled or built-in shaft still
            // meets the masonry around it without a seam of fluting.
            case .top, .bottom: return .sandstoneTop
            case .side: return .sandstonePillar
            }
        case .pillarCapital:
            switch face {
            case .top, .bottom: return .sandstoneTop
            case .side: return .pillarCapital
            }
        case .plaster: return .plaster
        case .timberFrame:
            switch face {
            // Beams belong on the faces you stand in front of; a floor or
            // soffit of this is just plaster.
            case .top, .bottom: return .plaster
            case .side: return .timberFrame
            }
        case .cloud: return .cloud
        case .balloonCanvas: return .balloonCanvas
        case .farmland:
            switch face {
            case .top: return .farmlandTop
            case .bottom, .side: return .dirt
            }
        case .daylightSensor:
            switch face {
            case .top: return .craftingTableTop
            case .bottom, .side: return .planks
            }
        case .signalLamp:
            return .glowCrystal
        case .signalLampLit:
            return .radiantYellow
        case .ice:
            return .water
        // Unreachable — see the note in `hardness`.
        default: return .stone
        }
    }

    /// The one tile a cross plant draws every face from.
    var plantTile: AtlasTile {
        switch self {
        case .poppy: return .poppy
        case .dandelion: return .dandelion
        case .cornflower: return .cornflower
        case .deadBush: return .deadBush
        case .wheatStage0: return .wheatStage0
        case .wheatStage1: return .wheatStage1
        case .wheatStage2: return .wheatStage2
        case .wheatStage3: return .wheatStage3
        case .sapling: return .sapling
        case .birchSapling: return .birchSapling
        case .spruceSapling: return .spruceSapling
        default: return .tallGrass
        }
    }

    var displayName: String {
        if isShaped {
            switch self {
            case .tallGrass: return L10n.t("Grass", "Gräs")
            case .poppy: return L10n.t("Poppy", "Vallmo")
            case .dandelion: return L10n.t("Dandelion", "Maskros")
            case .cornflower: return L10n.t("Cornflower", "Blåklint")
            case .deadBush: return L10n.t("Dead Bush", "Torr buske")
            case .wheatStage0, .wheatStage1, .wheatStage2, .wheatStage3:
                return L10n.t("Wheat", "Vete")
            case .torch: return L10n.t("Torch", "Fackla")
            case .boosterNorthSouth, .boosterEastWest:
                return L10n.t("Powered Rail", "Drivskena")
            case .detectorNorthSouth, .detectorEastWest:
                return L10n.t("Detector Rail", "Detektorskena")
            default: break
            }
            if isStairs {
                return stairMaterial == .cobblestone
                    ? L10n.t("Cobblestone Stairs", "Kullerstenstrappa")
                    : L10n.t("Oak Stairs", "Ektrappa")
            }
            if isRail { return L10n.t("Rail", "Räls") }
            if isDoor { return L10n.t("Oak Door", "Ekdörr") }
            if isBed { return L10n.t("Bed", "Säng") }
            if isLever { return L10n.t("Lever", "Spak") }
            if isWire { return L10n.t("Copper Wire", "Koppartråd") }
            if isPressurePlate { return L10n.t("Pressure Plate", "Tryckplatta") }
            if isSignalTorch { return L10n.t("Signal Torch", "Signalfackla") }
            if isSignalRelay { return L10n.t("Signal Relay", "Signalrelä") }
            if self == .sapling { return L10n.t("Oak Sapling", "Ekplanta") }
            if self == .birchSapling { return L10n.t("Birch Sapling", "Björkplanta") }
            if self == .spruceSapling { return L10n.t("Spruce Sapling", "Granplanta") }
            return L10n.t("Glass Pane", "Glasruta")
        }
        switch self {
        case .air: return L10n.t("Air", "Luft")
        case .grass: return L10n.t("Grass Block", "Gräsblock")
        case .dirt: return L10n.t("Dirt", "Jord")
        case .farmland: return L10n.t("Farmland", "Åkermark")
        case .hopper: return L10n.t("Hopper", "Tratt")
        case .daylightSensor: return L10n.t("Daylight Sensor", "Dagsljussensor")
        case .signalLamp: return L10n.t("Signal Lamp", "Signallampa")
        case .signalLampLit: return L10n.t("Signal Lamp (Lit)", "Signallampa (tänd)")
        case .stone: return L10n.t("Stone", "Sten")
        case .cobblestone: return L10n.t("Cobblestone", "Kullersten")
        case .sand: return L10n.t("Sand", "Sand")
        case .sandstone: return L10n.t("Sandstone", "Sandsten")
        case .tnt: return L10n.t("Blasting Charge", "Sprängladdning")
        case .gravel: return L10n.t("Gravel", "Grus")
        case .log: return L10n.t("Oak Log", "Ekstock")
        case .planks: return L10n.t("Oak Planks", "Ekplankor")
        case .leaves: return L10n.t("Oak Leaves", "Eklöv")
        case .glass: return L10n.t("Glass", "Glas")
        case .bedrock: return L10n.t("Bedrock", "Berggrund")
        case .coalOre: return L10n.t("Coal Ore", "Kolmalm")
        case .ironOre: return L10n.t("Iron Ore", "Järnmalm")
        case .goldOre: return L10n.t("Gold Ore", "Guldmalm")
        case .diamondOre: return L10n.t("Diamond Ore", "Diamantmalm")
        case .snow: return L10n.t("Snow Block", "Snöblock")
        case .water: return L10n.t("Water", "Vatten")
        case .lava: return L10n.t("Lava", "Lava")
        case .craftingTable: return L10n.t("Crafting Table", "Arbetsbänk")
        case .chest: return L10n.t("Chest", "Kista")
        case .brick: return L10n.t("Bricks", "Tegel")
        case .obsidian: return L10n.t("Obsidian", "Obsidian")
        case .birchLog: return L10n.t("Birch Log", "Björkstock")
        case .birchLeaves: return L10n.t("Birch Leaves", "Björklöv")
        case .spruceLog: return L10n.t("Spruce Log", "Granstock")
        case .spruceLeaves: return L10n.t("Spruce Leaves", "Granbarr")
        case .cactus: return L10n.t("Cactus", "Kaktus")
        case .goldBlock: return L10n.t("Gold Block", "Guldblock")
        case .sandstoneCarved: return L10n.t("Carved Sandstone", "Ristad sandsten")
        case .seaStone: return L10n.t("Sea Stone", "Havssten")
        case .seaLantern: return L10n.t("Sea Lantern", "Havslykta")
        case .diamondBlock: return L10n.t("Diamond Block", "Diamantblock")
        case .radiantRed: return L10n.t("Radiant Red", "Strålande röd")
        case .radiantYellow: return L10n.t("Radiant Yellow", "Strålande gul")
        case .radiantGreen: return L10n.t("Radiant Green", "Strålande grön")
        case .radiantCyan: return L10n.t("Radiant Cyan", "Strålande cyan")
        case .glowCrystal: return L10n.t("Glow Crystal", "Glödkristall")
        case .pearlLight: return L10n.t("Pearl Lamp", "Pärllampa")
        case .sandstonePillar: return L10n.t("Sandstone Pillar", "Sandstenspelare")
        case .pillarCapital: return L10n.t("Painted Capital", "Målat kapitäl")
        case .plaster: return L10n.t("Plaster", "Puts")
        case .timberFrame: return L10n.t("Timber Frame", "Korsvirke")
        case .cloud: return L10n.t("Cloud", "Moln")
        case .balloonCanvas: return L10n.t("Balloon Canvas", "Ballongduk")
        case .furnace, .furnaceLit: return L10n.t("Furnace", "Ugn")
        case .ice: return L10n.t("Ice", "Is")
        // Unreachable — see the note in `hardness`.
        default: return "Block"
        }
    }

    /// Right-clicking these does something instead of placing the held
    /// item: the crafting table opens a UI, a door swings, a bed is slept
    /// in.
    var isInteractive: Bool {
        self == .craftingTable || self == .chest || isDoor || isBed || isLever
    }

    /// Looks a block up by its Swift case name, for the scripted-edit hooks
    /// the snapshot harness and the self-checks drive worlds with.
    static func named(_ name: String) -> BlockType? { byName[name] }

    private static let byName: [String: BlockType] = Dictionary(
        uniqueKeysWithValues: BlockType.allCases.map { (String(describing: $0), $0) }
    )
}

/// Which of a cube's six faces a quad represents — most blocks texture
/// every face alike, but grass, logs and sandstone want distinct top,
/// side, and bottom images.
enum FaceKind: Int, Hashable {
    case top = 0, side = 1, bottom = 2

    init(normalY: Int) {
        if normalY > 0 { self = .top }
        else if normalY < 0 { self = .bottom }
        else { self = .side }
    }
}

import Foundation

/// Everything that can sit in an inventory slot. Block items place their
/// `placedBlock` on right-click; tools and materials do not.
enum ItemType: String, CaseIterable, Hashable {
    // Block items
    case grass, dirt, stone, cobblestone, sand, sandstone, gravel
    case log, planks, leaves, glass, coalOreBlock, ironOreBlock
    case snow, craftingTable, chest, brick, obsidian, furnace
    case birchLog, birchLeaves, spruceLog, spruceLeaves, cactus
    case goldBlock, sandstoneCarved
    // Saved worlds store an item by its raw value, so a renamed case keeps
    // the name it was first saved under.
    case seaStone = "prismarine", seaLantern, diamondBlock
    case radiantRed, radiantYellow, radiantGreen, radiantCyan
    case glowCrystal = "glowstone", pearlLight
    case sandstonePillar, pillarCapital
    case plaster, timberFrame, cloud, balloonCanvas

    // Plants. Block items like the rest, but drawn as their own flat
    // sprite rather than as a cube — an isometric box of a poppy is a box.
    case tallGrass, poppy, dandelion, cornflower, deadBush

    // The sapling: a plant like the rest, but the one that grows into
    // something with no bag slot of its own — see `SaplingStore`. Three
    // cases rather than one, matching the three logs and leaves already in
    // the game, because which one a player is holding decides which tree
    // comes up.
    case sapling, birchSapling, spruceSapling

    // Shaped blocks. One item each, whatever way the block ends up turned:
    // `placedBlock` stays nil for these because which case they place
    // depends on where the player is standing, so they go through the
    // placement path rather than the straight item→block mapping.
    case oakStairs, cobbleStairs, oakDoor, glassPane, bed

    // The torch goes through the placement path too — it needs a floor
    // under it, which the straight item→block mapping has no way to check.
    case torch
    // TNT is an ordinary cube and places like one, but it has a `case` here
    // rather than a `blockItem` mapping because it is not in `BlockType`'s
    // cube run — see the note on its raw value.
    case tnt

    // Track, and the thing that runs on it. Rails resolve their own shape
    // from their neighbours, so one item covers all twelve cases — the same
    // arrangement stairs and doors already use, one level further along.
    case rail
    case poweredRail
    // The network's third source, riding the rail family rather than the
    // signal one: a cart parked over it throws it, the same idea a
    // pressure plate already is, one step further along a track. No
    // `placedBlock` either, for the same reason rail has none — its axis
    // is chosen from where the player is facing, through `ShapedPlacement`.
    case detectorRail
    case minecart

    // The signal: a switch, and the wire it feeds. One item each, like the
    // rail — `placedBlock` always answers with the off case, and the world
    // turns it on the moment it is thrown or wired up.
    case lever
    case wire
    // A second source the network can flood from, thrown by weight
    // instead of by hand — `placedBlock` answers with the off case, the
    // same as the lever, and standing on it is what turns it on.
    case pressurePlate
    // The network's fourth source, and its first consumer that is also a
    // source: it starts lit, the same resting state an unpowered one always
    // settles back to, so `placedBlock` answers with the *on* case for once
    // rather than the off one every other switch here starts from.
    case signalTorch
    // Plain wire like `pressurePlate`'s own placement — `placedBlock`
    // answers with the off case, and current passing through is what lights
    // it. The one thing it does that wire itself cannot: resets how far
    // that current has travelled, so a network isn't capped at fifteen
    // cells from its switch forever.
    case signalRelay

    // The hopper: a block item like the furnace, one state, no placement
    // path of its own to speak of.
    case hopper

    // The two blocks that read and answer the sky. Both are block items
    // like the furnace: one placeable state each, and the lit lamp is a
    // state the world puts it in rather than a thing you can hold — so
    // `blockItem` folds `signalLampLit` back to this, the same way it
    // folds `furnaceLit` back to `furnace`.
    case daylightSensor
    case signalLamp = "redstoneLamp"

    // Materials
    case stick, coal, rawIron, rawGold, diamond, ironIngot, goldIngot
    case gunpowder, wool
    case feather, inkSac

    // Food
    case porkchop, beef, mutton
    case chicken, rawCod
    // What the furnace turns each of the above into — see `FurnaceRecipe`.
    case cookedPorkchop, cookedBeef, cookedMutton, cookedChicken, cookedCod
    // What a stand of tall grass gives up, and what growing it out on
    // farmland gives back — the only food this game grows rather than
    // hunts.
    case wheatSeeds, wheat

    // Tools
    case woodenPickaxe, stonePickaxe, ironPickaxe, diamondPickaxe
    case woodenAxe, stoneAxe, ironAxe
    case woodenShovel, stoneShovel, ironShovel
    case woodenSword, stoneSword, ironSword, diamondSword
    // Not a mining tool — nothing in `ToolClass` speeds up for it — but it
    // belongs beside them rather than among materials: its one use is
    // turning grass or dirt into farmland, the same "point it and act"
    // gesture as every other tool here.
    case hoe

    // Armor. Only two tiers, not the tool ladder's four — wood and stone
    // are not things anyone straps to their chest, and the reduction they
    // would buy over bare skin is not worth the two extra items. Worn
    // rather than held, so unlike every other item on this list it does
    // not occupy the hotbar's one selected slot: see
    // `PlayerStats.equippedChestplate`.
    case ironChestplate, diamondChestplate

    // The bucket: empty and full are two different items rather than one
    // item with a hidden flag, the same reason a door or a furnace is two
    // blocks — what it is carrying has to be readable from the slot it
    // sits in, not from a number nothing on screen shows. Filling and
    // emptying are handled directly in `GameViewController`, not through
    // `placedBlock`: placing a normal item consumes it, but a bucket
    // empties into the water it just placed rather than disappearing.
    case bucket, waterBucket, lavaBucket

    // Points at home — the bed last slept in, or world spawn if there is
    // none — rather than at anything it places or mines. What it draws is
    // decided per-frame in `GameViewController`/`HUDView` from `Compass`,
    // not carried on the item itself: unlike the bucket, there is nothing
    // about *this particular compass* that differs from any other one in
    // the stack, so it stacks like an ordinary item instead of splitting
    // into two cases.
    case compass

    // Marks two corners rather than placing anything itself — the block
    // that actually fills the box between them is whatever the next
    // ordinary placement swings, the same "aim and act" gesture as every
    // other placed item, just multiplied by the box instead of spent on
    // one cell. See `RegionFill`.
    case masonLine

    // A mason's line one step further along: instead of marking a box to
    // fill with one material, it marks a box to *copy* — whatever stood
    // there, in whatever materials it actually used — and every later
    // right-click stamps that shape down again somewhere else, still
    // billed per block against the same inventory a hand-built copy would
    // cost. One captured shape survives repeat stamps; breaking anything
    // while holding it and already carrying a shape clears that shape
    // instead, ready to capture a different one. See `RegionFill.Blueprint`.
    case blueprint

    // The survival storyline's hardware and harvest — see
    // `specs/survival-storyline.md`. Appended, like every case: a saved
    // slot is its raw value.
    case radio, signalCore, rawMeteor, meteorIngot
    case launchPad, rocket, spaceSuit, fuelCell, airMaker
    case ice, moonDust, moonRock, moonBrick, prismGlass
    case lampBloomSeeds, silverReedSeeds, silverReed, silverThatch

    /// The block this item places, if any.
    var placedBlock: BlockType? {
        switch self {
        case .grass: return .grass
        case .dirt: return .dirt
        case .stone: return .stone
        case .cobblestone: return .cobblestone
        case .sand: return .sand
        case .sandstone: return .sandstone
        case .gravel: return .gravel
        case .log: return .log
        case .planks: return .planks
        case .leaves: return .leaves
        case .glass: return .glass
        case .coalOreBlock: return .coalOre
        case .ironOreBlock: return .ironOre
        case .snow: return .snow
        case .craftingTable: return .craftingTable
        case .chest: return .chest
        case .brick: return .brick
        case .obsidian: return .obsidian
        case .furnace: return .furnace
        case .hopper: return .hopper
        case .birchLog: return .birchLog
        case .birchLeaves: return .birchLeaves
        case .spruceLog: return .spruceLog
        case .spruceLeaves: return .spruceLeaves
        case .cactus: return .cactus
        case .goldBlock: return .goldBlock
        case .sandstoneCarved: return .sandstoneCarved
        case .seaStone: return .seaStone
        case .seaLantern: return .seaLantern
        case .diamondBlock: return .diamondBlock
        case .radiantRed: return .radiantRed
        case .radiantYellow: return .radiantYellow
        case .radiantGreen: return .radiantGreen
        case .radiantCyan: return .radiantCyan
        case .glowCrystal: return .glowCrystal
        case .pearlLight: return .pearlLight
        case .sandstonePillar: return .sandstonePillar
        case .pillarCapital: return .pillarCapital
        case .plaster: return .plaster
        case .timberFrame: return .timberFrame
        case .cloud: return .cloud
        case .balloonCanvas: return .balloonCanvas
        case .tallGrass: return .tallGrass
        case .poppy: return .poppy
        case .dandelion: return .dandelion
        case .cornflower: return .cornflower
        case .deadBush: return .deadBush
        case .torch: return .torch
        case .tnt: return .tnt
        case .lever: return .leverOff
        case .wire: return .wireOff
        case .pressurePlate: return .pressurePlateOff
        case .signalTorch: return .signalTorchOn
        case .signalRelay: return .signalRelayOff
        case .daylightSensor: return .daylightSensor
        case .signalLamp: return .signalLamp
        case .sapling: return .sapling
        case .birchSapling: return .birchSapling
        case .spruceSapling: return .spruceSapling
        case .wheatSeeds: return .wheatStage0
        case .radio: return .radio
        case .launchPad: return .padCore
        case .airMaker: return .airMaker
        case .ice: return .ice
        case .moonDust: return .moonDust
        case .moonRock: return .moonRock
        case .moonBrick: return .moonBrick
        case .prismGlass: return .prismGlass
        case .silverThatch: return .silverThatch
        case .lampBloomSeeds: return .lampBloomStage0
        case .silverReedSeeds: return .silverReedStage0
        default: return nil
        }
    }

    /// The inverse mapping, for block drops.
    static func blockItem(for block: BlockType) -> ItemType? {
        if block.isRail {
            if block.isBooster { return .poweredRail }
            if block.isDetectorRail { return .detectorRail }
            return .rail
        }
        switch block {
        case .grass: return .grass
        case .dirt: return .dirt
        case .stone: return .stone
        case .cobblestone: return .cobblestone
        case .sand: return .sand
        case .sandstone: return .sandstone
        case .gravel: return .gravel
        case .log: return .log
        case .planks: return .planks
        case .leaves: return .leaves
        case .glass: return .glass
        case .coalOre: return .coalOreBlock
        case .ironOre: return .ironOreBlock
        case .snow: return .snow
        case .craftingTable: return .craftingTable
        case .chest: return .chest
        case .brick: return .brick
        case .obsidian: return .obsidian
        case .furnace, .furnaceLit: return .furnace
        case .hopper: return .hopper
        case .birchLog: return .birchLog
        case .birchLeaves: return .birchLeaves
        case .spruceLog: return .spruceLog
        case .spruceLeaves: return .spruceLeaves
        case .cactus: return .cactus
        case .goldBlock: return .goldBlock
        case .sandstoneCarved: return .sandstoneCarved
        case .seaStone: return .seaStone
        case .seaLantern: return .seaLantern
        case .diamondBlock: return .diamondBlock
        case .radiantRed: return .radiantRed
        case .radiantYellow: return .radiantYellow
        case .radiantGreen: return .radiantGreen
        case .radiantCyan: return .radiantCyan
        case .glowCrystal: return .glowCrystal
        case .pearlLight: return .pearlLight
        case .sandstonePillar: return .sandstonePillar
        case .pillarCapital: return .pillarCapital
        case .plaster: return .plaster
        case .timberFrame: return .timberFrame
        case .cloud: return .cloud
        case .balloonCanvas: return .balloonCanvas
        case .tallGrass: return .tallGrass
        case .poppy: return .poppy
        case .dandelion: return .dandelion
        case .cornflower: return .cornflower
        case .deadBush: return .deadBush
        case .torch: return .torch
        case .tnt: return .tnt
        case .leverOff, .leverOn: return .lever
        case .wireOff, .wireOn: return .wire
        case .pressurePlateOff, .pressurePlateOn: return .pressurePlate
        case .signalTorchOff, .signalTorchOn: return .signalTorch
        case .signalRelayOff, .signalRelayOn: return .signalRelay
        case .daylightSensor: return .daylightSensor
        case .signalLamp, .signalLampLit: return .signalLamp
        case .sapling: return .sapling
        case .birchSapling: return .birchSapling
        case .spruceSapling: return .spruceSapling
        case .wheatStage0, .wheatStage1, .wheatStage2, .wheatStage3: return .wheatSeeds
        case .radio, .radioLit: return .radio
        case .padCore: return .launchPad
        case .rocketEngine, .rocketTank, .rocketCabin: return .rocket
        case .airMaker: return .airMaker
        case .ice: return .ice
        case .moonDust: return .moonDust
        case .moonRock: return .moonRock
        case .moonBrick: return .moonBrick
        case .prismGlass: return .prismGlass
        case .silverThatch: return .silverThatch
        case .lampBloomStage0, .lampBloomStage1, .lampBloomStage2, .lampBloomStage3: return .lampBloomSeeds
        case .silverReedStage0, .silverReedStage1, .silverReedStage2, .silverReedStage3: return .silverReedSeeds
        default: return nil
        }
    }

    /// True for the cross plants, which are block items that must not be
    /// drawn as cubes.
    var isPlant: Bool { placedBlock?.isPlant == true }

    var maxStack: Int {
        // A bucket has no `toolClass` — filling ground isn't mining — but
        // it doesn't stack for the same reason a tool doesn't: what one
        // holds (nothing, or water) is a fact about that one item, and a
        // stack of them would have to hold it for all of them at once.
        // A chestplate is the same shape of exception: there is only ever
        // one of it worn at a time.
        toolClass == nil && self != .bucket && self != .waterBucket && self != .lavaBucket && !isArmor ? 64 : 1
    }

    /// True for the two chestplates — the only items worn rather than held.
    var isArmor: Bool {
        self == .ironChestplate || self == .diamondChestplate || self == .spaceSuit
    }

    /// Fraction of incoming mitigable damage a worn chestplate cuts, or
    /// zero bare-chested. Iron and diamond, not the full four-tier ladder:
    /// see the case's own doc comment for why wood and stone stop short of
    /// armor. Deliberately smaller than `toolTier`'s reuse elsewhere — this
    /// is its own ladder of two, not read from `ToolTier`, because nothing
    /// here needs the ordering or the wood/stone/hand rungs, only the
    /// number.
    var armorReduction: Double {
        switch self {
        case .ironChestplate: return 0.20
        case .diamondChestplate: return 0.40
        // Built for air, not for a fight.
        case .spaceSuit: return 0.10
        default: return 0
        }
    }

    /// Non-nil for tools: which block class this speeds up.
    var toolClass: ToolClass? {
        switch self {
        case .woodenPickaxe, .stonePickaxe, .ironPickaxe, .diamondPickaxe: return .pickaxe
        case .woodenAxe, .stoneAxe, .ironAxe: return .axe
        case .woodenShovel, .stoneShovel, .ironShovel: return .shovel
        case .woodenSword, .stoneSword, .ironSword, .diamondSword: return .sword
        default: return nil
        }
    }

    var toolTier: ToolTier {
        switch self {
        case .woodenPickaxe, .woodenAxe, .woodenShovel, .woodenSword: return .wood
        case .stonePickaxe, .stoneAxe, .stoneShovel, .stoneSword: return .stone
        case .ironPickaxe, .ironAxe, .ironShovel, .ironSword: return .iron
        case .diamondPickaxe, .diamondSword: return .diamond
        default: return .hand
        }
    }

    /// How many uses a tool has in it before it breaks, or nil for
    /// anything that is not a tool.
    ///
    /// The original's own numbers, because they are the ones tuned against a
    /// day of play: a wooden pickaxe is most of a first tunnel, stone is
    /// an afternoon, iron is a project, and diamond outlasts what anyone
    /// sets out to build with it. The point of the ladder is that the
    /// first tool you make is not the last one you need.
    var durability: Int? {
        guard toolClass != nil else { return nil }
        switch toolTier {
        case .hand: return nil
        case .wood: return 59
        case .stone: return 131
        case .iron: return 250
        case .diamond: return 1561
        }
    }

    /// Half-drumsticks eating one restores, or nil for anything that isn't
    /// food. Raw is a real meal, cooked is a better one — the furnace pays
    /// back the time and fuel it costs with roughly double the raw value,
    /// same ratio the original's own smoker uses.
    var foodValue: Int? {
        switch self {
        case .porkchop: return 4
        case .beef: return 4
        case .mutton: return 3
        case .chicken: return 3
        case .rawCod: return 2
        case .cookedPorkchop: return 8
        case .cookedBeef: return 8
        case .cookedMutton: return 6
        case .cookedChicken: return 6
        case .cookedCod: return 5
        case .wheat: return 2
        default: return nil
        }
    }

    var displayName: String {
        if let block = placedBlock, !block.isCrop { return block.displayName }
        switch self {
        case .oakStairs: return L10n.t("Oak Stairs", "Ektrappa")
        case .cobbleStairs: return L10n.t("Cobblestone Stairs", "Kullerstenstrappa")
        case .oakDoor: return L10n.t("Oak Door", "Ekdörr")
        case .glassPane: return L10n.t("Glass Pane", "Glasruta")
        case .bed: return L10n.t("Bed", "Säng")
        case .stick: return L10n.t("Stick", "Pinne")
        case .coal: return L10n.t("Coal", "Kol")
        case .rawIron: return L10n.t("Raw Iron", "Råjärn")
        case .rawGold: return L10n.t("Raw Gold", "Råguld")
        case .diamond: return L10n.t("Diamond", "Diamant")
        case .ironIngot: return L10n.t("Iron Ingot", "Järntacka")
        case .goldIngot: return L10n.t("Gold Ingot", "Guldtacka")
        case .gunpowder: return L10n.t("Gunpowder", "Krut")
        case .wool: return L10n.t("Wool", "Ull")
        case .porkchop: return L10n.t("Porkchop", "Fläskkotlett")
        case .beef: return L10n.t("Beef", "Nötkött")
        case .mutton: return L10n.t("Mutton", "Fårkött")
        case .chicken: return L10n.t("Chicken", "Kyckling")
        case .rawCod: return L10n.t("Raw Cod", "Rå torsk")
        case .cookedPorkchop: return L10n.t("Cooked Porkchop", "Stekt fläskkotlett")
        case .cookedBeef: return L10n.t("Steak", "Biff")
        case .cookedMutton: return L10n.t("Cooked Mutton", "Stekt fårkött")
        case .cookedChicken: return L10n.t("Cooked Chicken", "Stekt kyckling")
        case .cookedCod: return L10n.t("Cooked Cod", "Stekt torsk")
        case .wheatSeeds: return L10n.t("Wheat Seeds", "Vetefrön")
        case .wheat: return L10n.t("Wheat", "Vete")
        case .hoe: return L10n.t("Hoe", "Hacka")
        case .ironChestplate: return L10n.t("Iron Chestplate", "Järnbröstplåt")
        case .diamondChestplate: return L10n.t("Diamond Chestplate", "Diamantbröstplåt")
        case .bucket: return L10n.t("Bucket", "Hink")
        case .waterBucket: return L10n.t("Water Bucket", "Hink med vatten")
        case .lavaBucket: return L10n.t("Lava Bucket", "Lavahink")
        case .compass: return L10n.t("Compass", "Kompass")
        case .masonLine: return L10n.t("Mason's Line", "Murarlina")
        case .blueprint: return L10n.t("Blueprint", "Ritning")
        case .signalCore: return L10n.t("Signal Core", "Signalkärna")
        case .rawMeteor: return L10n.t("Raw Meteor", "Rå meteor")
        case .meteorIngot: return L10n.t("Meteor Ingot", "Meteortacka")
        case .rocket: return L10n.t("Rocket", "Raket")
        case .spaceSuit: return L10n.t("Space Suit", "Rymddräkt")
        case .fuelCell: return L10n.t("Fuel Cell", "Bränslecell")
        case .silverReed: return L10n.t("Silver Reed", "Silvervass")
        case .lampBloomSeeds: return L10n.t("Lamp Bloom Seeds", "Lampblomsfrön")
        case .silverReedSeeds: return L10n.t("Silver Reed Seeds", "Silvervassfrön")
        case .pressurePlate: return L10n.t("Pressure Plate", "Tryckplatta")
        case .rail: return L10n.t("Rail", "Räls")
        case .poweredRail: return L10n.t("Powered Rail", "Drivskena")
        case .detectorRail: return L10n.t("Detector Rail", "Detektorskena")
        case .minecart: return L10n.t("Minecart", "Vagn")
        case .feather: return L10n.t("Feather", "Fjäder")
        case .inkSac: return L10n.t("Ink Sac", "Bläckpåse")
        case .woodenPickaxe: return L10n.t("Wooden Pickaxe", "Trähacka")
        case .stonePickaxe: return L10n.t("Stone Pickaxe", "Stenhacka")
        case .ironPickaxe: return L10n.t("Iron Pickaxe", "Järnhacka")
        case .diamondPickaxe: return L10n.t("Diamond Pickaxe", "Diamanthacka")
        case .woodenAxe: return L10n.t("Wooden Axe", "Träyxa")
        case .stoneAxe: return L10n.t("Stone Axe", "Stenyxa")
        case .ironAxe: return L10n.t("Iron Axe", "Järnyxa")
        case .woodenShovel: return L10n.t("Wooden Shovel", "Träspade")
        case .stoneShovel: return L10n.t("Stone Shovel", "Stenspade")
        case .ironShovel: return L10n.t("Iron Shovel", "Järnspade")
        case .woodenSword: return L10n.t("Wooden Sword", "Träsvärd")
        case .stoneSword: return L10n.t("Stone Sword", "Stensvärd")
        case .ironSword: return L10n.t("Iron Sword", "Järnsvärd")
        case .diamondSword: return L10n.t("Diamond Sword", "Diamantsvärd")
        default: return rawValue.capitalized
        }
    }
}

/// A slot's contents: a type plus how many. Empty slots are `nil`, never a
/// zero-count stack — `Inventory` maintains that invariant.
struct ItemStack: Equatable {
    var type: ItemType
    var count: Int
    /// Uses a tool has already spent. Always zero for everything else —
    /// tools are the only thing here that does not stack, which is what
    /// makes one number per slot enough to describe the wear on it.
    var wear: Int = 0

    init(_ type: ItemType, count: Int = 1, wear: Int = 0) {
        self.type = type
        self.count = max(1, count)
        self.wear = max(0, wear)
    }

    var maxStack: Int { type.maxStack }
    var isFull: Bool { count >= maxStack }

    /// Uses left, or nil for anything that cannot wear out.
    var usesLeft: Int? {
        type.durability.map { max(0, $0 - wear) }
    }

    /// 0…1 of the tool's life remaining — what the bar under a worn tool's
    /// icon is long. Nil when there is no bar to draw, which is both
    /// everything that is not a tool and a tool nobody has used yet: an
    /// untouched pickaxe showing a full green bar would put a gauge on
    /// every slot in the game to say nothing has happened.
    var wearFraction: CGFloat? {
        guard let durability = type.durability, wear > 0 else { return nil }
        return CGFloat(max(0, durability - wear)) / CGFloat(durability)
    }

    /// Spends one use. Returns false when that was the last one and the
    /// tool is now scrap — the caller empties the slot.
    mutating func wearOne() -> Bool {
        guard let durability = type.durability else { return true }
        wear += 1
        return wear < durability
    }

    /// Merges `other` into this stack, returning whatever didn't fit.
    mutating func merging(_ other: ItemStack) -> ItemStack? {
        guard other.type == type, !isFull else { return other }
        let space = maxStack - count
        let moved = min(space, other.count)
        count += moved
        let remainder = other.count - moved
        return remainder > 0 ? ItemStack(other.type, count: remainder) : nil
    }
}

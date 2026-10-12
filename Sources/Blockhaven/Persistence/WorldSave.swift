import Foundation

/// One saved world, exactly as it goes to disk.
///
/// Terrain is a pure function of the seed, so nothing the generator can
/// produce is stored: the file is the seed plus the diff the player made
/// against it. That keeps a long-played world in the tens of kilobytes,
/// and loading it is the same code path as walking back into a chunk you
/// edited — the journal is handed to `World` before any chunk generates.
///
/// Everything read back is treated as suspect. An unreadable file, a
/// version this build doesn't know, or a block or item whose name means
/// nothing here resolves to "not there" rather than to a crash: losing a
/// world to a bad save is the worst thing this game could do.
struct WorldSave: Codable, Sendable {
    /// Bumped when the meaning of a field changes. A file written by any
    /// other version is ignored rather than guessed at.
    ///
    /// Deliberately *not* bumped for `name` and `lastPlayed`. Those are
    /// additions, not changes: a file without them means exactly what it
    /// always meant, and `init(from:)` below fills them in. Bumping would
    /// have thrown away every world written before this build — the one
    /// outcome the whole file is written to avoid.
    static let currentVersion = 1

    var version = WorldSave.currentVersion
    var seed: UInt64
    var mode: GameMode
    /// What the player calls this world. Shown on the Continue card and in
    /// the world list; it never has to be unique, because the file name is.
    var name: String
    /// When this world was last saved, in epoch seconds. Sorts the world
    /// list and decides which world Continue opens.
    var lastPlayed: Double
    var chunks: [ChunkEdits]
    var playerX: Double
    var playerY: Double
    var playerZ: Double
    var yaw: Double
    var pitch: Double
    var selectedSlot: Int
    var slots: [SavedSlot]
    var health: Int
    var hunger: Int
    var air: Int
    var timeOfDay: Double
    /// How many times `timeOfDay` has wrapped back to dawn — the day
    /// counter `SkyController.isRaining` needs and `timeOfDay` itself
    /// cannot carry, since it resets every single day on its own. Optional
    /// for the same reason `chests`/`furnaces` are: a file written before
    /// weather existed still means exactly what it always meant, and reads
    /// back as day zero.
    var weatherDayIndex: Int?
    /// The bed the player last slept in, or nil if they never have. Three
    /// separate optionals rather than a struct so a file written by a build
    /// that had no beds is still exactly a v1 file: absent keys, read with
    /// `decodeIfPresent`, and the version stays where it is.
    var bedSpawnX: Int?
    var bedSpawnY: Int?
    var bedSpawnZ: Int?
    /// What is inside every chest in the world. Optional and absent when
    /// there are none, for the same reason the bed is three optionals: a
    /// file written before chests existed means exactly what it always
    /// meant, so the version does not move.
    var chests: [SavedChest]?
    /// Every furnace's fire: what state, if any, means "a save from before
    /// furnaces existed still means exactly what it always meant" — same
    /// reasoning as `chests`.
    var furnaces: [SavedFurnace]?
    /// Every hopper's facing and buffered item. Absent in a file written
    /// before conveyors existed, which then reload exactly as they did
    /// before — same reasoning as `chests` and `furnaces`.
    var hoppers: [SavedHopper]?
    /// Every cart on the rails, exactly where it stopped. A cart is not
    /// part of the block journal — it rides *on* a rail rather than being
    /// one — so without this a coaster a player spent an evening building
    /// loses every cart on it the moment they quit, which is not a
    /// railway, just an elaborate wall.
    var minecarts: [SavedMinecart]?
    /// What's worn, by raw item name — absent for bare-chested and for
    /// every file written before armor existed, which mean the same thing
    /// on load. `equippedChestplate` below is the decoded, forgiving
    /// version of this, the same split `chests`/`chestStore` uses.
    var equippedChestplateRaw: String?
    /// Every tamed animal, exactly where it stood. Wild ones are not here —
    /// they are ambient population the spawner keeps topped up wherever the
    /// player happens to be, the same as a fresh world starts with none —
    /// but a pet is the one animal a player fed on purpose, and a save that
    /// forgot it would be breaking the promise taming makes to keep it.
    /// Optional and absent for a file written before this existed, the same
    /// reason `minecarts` is.
    var animals: [SavedAnimal]?
    /// The single grave a save from before a second one could ever be
    /// owed at once — kept only so a file written by that build still
    /// decodes, and folded into `pendingGraves` below the moment anything
    /// reads it. New files never write these.
    var lastGraveX: Int?
    var lastGraveY: Int?
    var lastGraveZ: Int?
    /// Every grave the player hasn't finished emptying, oldest first.
    /// Without this a second death before walking the first grave back
    /// would erase the only reason the compass had to point at it —
    /// nothing else in the world marks where it stands.
    var pendingGraves: [SavedGraveKey]?

    /// Which of the save's two places this file's top level describes.
    /// Absent in every save written before the Moon existed, which is
    /// exactly what `home` means.
    var destination: Destination?
    /// The storyline's journal. It belongs to the player, so it is written
    /// beside the inventory rather than inside either world.
    var story: StoryState?
    /// The other place, asleep: everything about it but the player, who is
    /// here. Empty until the first launch. An array because a struct cannot
    /// hold an optional copy of itself directly; it never holds more than
    /// one.
    var elsewhere: [WorldSave]?

    /// One chunk of the edit journal as two parallel arrays: `blocks[i]`
    /// is what sits at packed local index `indices[i]`. A dictionary keyed
    /// by a stringified index would cost several times the bytes for the
    /// same content, and a journal is the one part of this file that grows
    /// without limit.
    struct ChunkEdits: Codable, Sendable {
        var x: Int
        var z: Int
        var indices: [Int]
        var blocks: [UInt8]
    }

    /// A non-empty inventory slot. Empty slots are simply absent.
    ///
    /// `wear` is how many uses a tool has spent. Optional and absent for
    /// everything that cannot wear out, which is almost every slot ever
    /// written — and absent from every file written before tools wore out
    /// at all, which is why it is an optional rather than a field with a
    /// default and a version bump.
    struct SavedSlot: Codable, Sendable {
        var slot: Int
        var item: String
        var count: Int
        var wear: Int?
    }

    /// One chest: where it stands, and what is in it. The cell is stored
    /// rather than derived, because a chest's contents live beside the
    /// block journal and not in it — a byte in a chunk cannot hold
    /// twenty-seven stacks.
    struct SavedChest: Codable, Sendable {
        var x: Int
        var y: Int
        var z: Int
        var slots: [SavedSlot]
    }

    /// One hopper's two invisible facts: which way it points, and the one
    /// item it may be holding mid-transfer.
    ///
    /// Neither is recoverable from the block journal. A hopper is one byte
    /// in a chunk like any other block, so a reloaded world used to give
    /// every hopper a `nil` facing and fall back to scanning its neighbours
    /// for the first container it could find — which is how a conveyor a
    /// player aimed west came back feeding a chest to the east.
    struct SavedHopper: Codable, Sendable {
        var x: Int
        var y: Int
        var z: Int
        /// `BlockFacing.rawValue`, absent for a hopper that just drops into
        /// whatever is under it.
        var facing: Int?
        var itemType: String?
        var itemCount: Int?
        var itemWear: Int?
    }

    /// One grave's cell — its contents live in `chests` like any other
    /// chest; this just says which cells are still owed to the player.
    struct SavedGraveKey: Codable, Sendable {
        var x: Int
        var y: Int
        var z: Int
    }

    /// One furnace's fire, frozen at save time. `oreType`/`fuelType`/
    /// `outputType` are the raw item names, absent rather than empty-string
    /// when that slot has nothing in it — Codable's `nil` for a `String?`
    /// is one byte cheaper than a sentinel and needs no reserved word.
    struct SavedFurnace: Codable, Sendable {
        var x: Int
        var y: Int
        var z: Int
        var oreType: String?
        var oreCount: Int
        var fuelType: String?
        var fuelCount: Int
        var burnRemaining: Double
        var progress: Double
        var outputType: String?
        var outputCount: Int
    }

    /// One cart, frozen mid-ride if it was moving. `heading` is a
    /// `BlockFacing` raw value rather than the enum itself — Codable would
    /// happily encode the enum directly, but every other direction in this
    /// file is a plain number for the same reason chunk blocks are: so a
    /// future rename of a case can't silently change what old saves mean.
    struct SavedMinecart: Codable, Sendable {
        var x: Double
        var y: Double
        var z: Double
        var heading: Int
        var speed: Double
        /// What it was hauling, if anything — optional for the same reason
        /// `weatherDayIndex` is: a file written before a cart could carry
        /// cargo at all still means exactly what it always meant, decoding
        /// with no cargo rather than failing.
        var cargoType: String?
        var cargoCount: Int?
        var cargoWear: Int?
    }

    /// One tamed animal, frozen where it stood. `morph` is carried
    /// explicitly rather than re-rolled on load — see `Animal.init`'s own
    /// `morph` parameter — so a rare-coloured pet doesn't have a one-in-ten
    /// chance of coming back ordinary. `kind`/`isRareMorph` absent or
    /// unreadable drops that one animal rather than failing the rest, the
    /// same forgiveness every other saved list in this file shows.
    struct SavedAnimal: Codable, Sendable {
        var kind: String
        var x: Double
        var y: Double
        var z: Double
        var isSitting: Bool
        var isRareMorph: Bool
    }

    /// Spelled out rather than synthesised, so the hand-written decoder
    /// below has something stable to key off.
    enum CodingKeys: String, CodingKey {
        case version, seed, mode, name, lastPlayed, chunks
        case playerX, playerY, playerZ, yaw, pitch
        case selectedSlot, slots, health, hunger, air, timeOfDay
        case weatherDayIndex
        case bedSpawnX, bedSpawnY, bedSpawnZ
        case lastGraveX, lastGraveY, lastGraveZ
        case pendingGraves
        case destination, story, elsewhere
        case chests, furnaces, hoppers, minecarts, animals
        case equippedChestplateRaw = "equippedChestplate"
    }

    /// What a world is called when its file doesn't say — which is every
    /// world written before this build.
    static let legacyName = "My World"

    /// Hand-written because the synthesised decoder treats a missing key as
    /// a failure even where the property has a default. Adding `name` to a
    /// synthesised `Codable` would have made every save already on disk
    /// undecodable, which this file's whole design exists to prevent.
    ///
    /// So: everything v1 wrote is still required, and the two fields this
    /// build added are read only if they are there. A `lastPlayed` of zero
    /// means "the file didn't say" and `load` substitutes the file's own
    /// modification date, which is the honest answer for a legacy world.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        seed = try container.decode(UInt64.self, forKey: .seed)
        mode = try container.decode(GameMode.self, forKey: .mode)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? WorldSave.legacyName
        lastPlayed = try container.decodeIfPresent(Double.self, forKey: .lastPlayed) ?? 0
        chunks = try container.decode([ChunkEdits].self, forKey: .chunks)
        playerX = try container.decode(Double.self, forKey: .playerX)
        playerY = try container.decode(Double.self, forKey: .playerY)
        playerZ = try container.decode(Double.self, forKey: .playerZ)
        yaw = try container.decode(Double.self, forKey: .yaw)
        pitch = try container.decode(Double.self, forKey: .pitch)
        selectedSlot = try container.decode(Int.self, forKey: .selectedSlot)
        slots = try container.decode([SavedSlot].self, forKey: .slots)
        health = try container.decode(Int.self, forKey: .health)
        hunger = try container.decode(Int.self, forKey: .hunger)
        air = try container.decode(Int.self, forKey: .air)
        timeOfDay = try container.decode(Double.self, forKey: .timeOfDay)
        weatherDayIndex = try container.decodeIfPresent(Int.self, forKey: .weatherDayIndex)
        bedSpawnX = try container.decodeIfPresent(Int.self, forKey: .bedSpawnX)
        bedSpawnY = try container.decodeIfPresent(Int.self, forKey: .bedSpawnY)
        bedSpawnZ = try container.decodeIfPresent(Int.self, forKey: .bedSpawnZ)
        lastGraveX = try container.decodeIfPresent(Int.self, forKey: .lastGraveX)
        lastGraveY = try container.decodeIfPresent(Int.self, forKey: .lastGraveY)
        lastGraveZ = try container.decodeIfPresent(Int.self, forKey: .lastGraveZ)
        pendingGraves = try container.decodeIfPresent([SavedGraveKey].self, forKey: .pendingGraves)
        chests = try container.decodeIfPresent([SavedChest].self, forKey: .chests)
        furnaces = try container.decodeIfPresent([SavedFurnace].self, forKey: .furnaces)
        hoppers = try container.decodeIfPresent([SavedHopper].self, forKey: .hoppers)
        minecarts = try container.decodeIfPresent([SavedMinecart].self, forKey: .minecarts)
        animals = try container.decodeIfPresent([SavedAnimal].self, forKey: .animals)
        equippedChestplateRaw = try container.decodeIfPresent(String.self, forKey: .equippedChestplateRaw)
        // A journal this build cannot read is a journal lost, not a world
        // lost: the story starts over and the world keeps everything else.
        destination = try? container.decodeIfPresent(Destination.self, forKey: .destination)
        story = try? container.decodeIfPresent(StoryState.self, forKey: .story)
        elsewhere = try? container.decodeIfPresent([WorldSave].self, forKey: .elsewhere)
    }

    /// The saved respawn bed, and only when all three coordinates made it
    /// back — two thirds of a position is not a place.
    var bedSpawn: BedSpawn? {
        get {
            guard let x = bedSpawnX, let y = bedSpawnY, let z = bedSpawnZ else { return nil }
            return BedSpawn(x: x, y: y, z: z)
        }
        set {
            bedSpawnX = newValue?.x
            bedSpawnY = newValue?.y
            bedSpawnZ = newValue?.z
        }
    }

    /// Every grave the player still hasn't emptied. A file with the new
    /// array wins outright; one written before a second grave could exist
    /// at once falls back to its single `lastGraveX/Y/Z` triple, so an old
    /// save still remembers the one grave it always knew about.
    var pendingGraveKeys: [ChestStore.Key] {
        get {
            if let pendingGraves { return pendingGraves.map { ChestStore.Key($0.x, $0.y, $0.z) } }
            guard let x = lastGraveX, let y = lastGraveY, let z = lastGraveZ else { return [] }
            return [ChestStore.Key(x, y, z)]
        }
        set {
            pendingGraves = newValue.isEmpty ? nil : newValue.map { SavedGraveKey(x: $0.x, y: $0.y, z: $0.z) }
        }
    }
}

extension WorldSave.SavedSlot {
    /// Wear, kept inside what the item could actually have spent. A file
    /// claiming 900 uses off a wooden pickaxe — hand-edited, or written by
    /// a build whose durabilities were different — must come back as a
    /// worn-out-but-present tool rather than as one with negative life.
    func clampedWear(for type: ItemType) -> Int {
        guard let durability = type.durability, let wear else { return 0 }
        return min(max(0, wear), durability - 1)
    }
}

/// `GameMode` is already a `String` enum, so this is all `Codable` needs.
/// Decoding a mode this build doesn't have throws, which `load` turns into
/// "there is no save" — better than playing someone's world under rules
/// this version has to invent.
extension GameMode: Codable {}

// MARK: - Capture

extension WorldSave {
    /// Snapshots live state. Everything here is a plain value by the time
    /// the initialiser returns, so the result can be encoded and written
    /// on another thread while the game carries on.
    init(
        seed: UInt64,
        mode: GameMode,
        name: String,
        lastPlayed: Double,
        edits: [ChunkCoord: [Int: BlockType]],
        position: Vector3,
        yaw: CGFloat,
        pitch: CGFloat,
        inventory: Inventory,
        stats: PlayerStats,
        timeOfDay: Double,
        weatherDayIndex: Int = 0,
        bedSpawn: BedSpawn? = nil,
        pendingGraves: [ChestStore.Key] = [],
        chests: ChestStore? = nil,
        furnaces: FurnaceStore? = nil,
        hoppers: HopperStore? = nil,
        minecarts: MinecartManager? = nil,
        animals: AnimalManager? = nil
    ) {
        self.seed = seed
        self.mode = mode
        self.name = name
        self.lastPlayed = lastPlayed
        // Sorted so replaying the same session twice writes the same bytes,
        // which makes a diff of two saves readable.
        self.chunks = edits.keys.sorted { ($0.x, $0.z) < ($1.x, $1.z) }.compactMap { coord in
            guard let entries = edits[coord], !entries.isEmpty else { return nil }
            let indices = entries.keys.sorted()
            return ChunkEdits(
                x: coord.x,
                z: coord.z,
                indices: indices,
                blocks: indices.map { entries[$0]?.rawValue ?? BlockType.air.rawValue }
            )
        }
        self.playerX = Double(position.x)
        self.playerY = Double(position.y)
        self.playerZ = Double(position.z)
        self.yaw = Double(yaw)
        self.pitch = Double(pitch)
        self.selectedSlot = inventory.selectedHotbarSlot
        self.slots = inventory.slots.enumerated().compactMap { index, stack in
            guard let stack else { return nil }
            return SavedSlot(
                slot: index, item: stack.type.rawValue, count: stack.count,
                wear: stack.wear > 0 ? stack.wear : nil
            )
        }
        self.health = stats.health
        self.hunger = stats.hunger
        self.air = stats.air
        self.equippedChestplateRaw = stats.equippedChestplate?.rawValue
        self.timeOfDay = timeOfDay
        self.weatherDayIndex = weatherDayIndex
        self.bedSpawnX = bedSpawn?.x
        self.bedSpawnY = bedSpawn?.y
        self.bedSpawnZ = bedSpawn?.z
        self.pendingGraves = pendingGraves.isEmpty
            ? nil : pendingGraves.map { SavedGraveKey(x: $0.x, y: $0.y, z: $0.z) }
        // Sorted by cell for the same reason the chunk journal is: two
        // runs that did the same things should write the same bytes.
        let stored = (chests?.chests ?? [:])
            .filter { !$0.value.isEmpty }
            .sorted { ($0.key.x, $0.key.y, $0.key.z) < ($1.key.x, $1.key.y, $1.key.z) }
        self.chests = stored.isEmpty ? nil : stored.map { key, chest in
            SavedChest(
                x: key.x, y: key.y, z: key.z,
                slots: chest.slots.enumerated().compactMap { index, stack in
                    guard let stack else { return nil }
                    return SavedSlot(
                        slot: index, item: stack.type.rawValue, count: stack.count,
                        wear: stack.wear > 0 ? stack.wear : nil
                    )
                }
            )
        }
        // Sorted by cell for the same reason the chests are.
        let storedFurnaces = (furnaces?.furnaces ?? [:])
            .sorted { ($0.key.x, $0.key.y, $0.key.z) < ($1.key.x, $1.key.y, $1.key.z) }
        self.furnaces = storedFurnaces.isEmpty ? nil : storedFurnaces.map { key, state in
            SavedFurnace(
                x: key.x, y: key.y, z: key.z,
                oreType: state.oreType?.rawValue, oreCount: state.oreCount,
                fuelType: state.fuelType?.rawValue, fuelCount: state.fuelCount,
                burnRemaining: state.burnRemaining, progress: state.progress,
                outputType: state.outputType?.rawValue, outputCount: state.outputCount
            )
        }
        // Every hopper the store knows about, whether or not it is holding
        // anything: the facing is worth saving on its own. Sorted by cell
        // for the same reason the chests are.
        let storedHoppers = (hoppers?.allKeys ?? [])
            .sorted { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) }
        self.hoppers = storedHoppers.isEmpty ? nil : storedHoppers.map { key in
            let held = hoppers?.item(at: key)
            return SavedHopper(
                x: key.x, y: key.y, z: key.z,
                facing: hoppers?.facing(at: key).map { Int($0.rawValue) },
                itemType: held?.type.rawValue,
                itemCount: held?.count,
                itemWear: held?.wear
            )
        }
        // Sorted by id, which is itself assignment order — the same "two
        // runs that did the same things write the same bytes" reasoning as
        // the chests and the furnaces, just keyed by the one thing a cart
        // has instead of a cell.
        let storedCarts = (minecarts?.carts ?? [:]).sorted { $0.key < $1.key }
        self.minecarts = storedCarts.isEmpty ? nil : storedCarts.map { _, cart in
            SavedMinecart(
                x: Double(cart.position.x), y: Double(cart.position.y), z: Double(cart.position.z),
                heading: Int(cart.heading.rawValue), speed: Double(cart.speed),
                cargoType: cart.cargo?.type.rawValue,
                cargoCount: cart.cargo?.count,
                cargoWear: cart.cargo.flatMap { $0.wear > 0 ? $0.wear : nil }
            )
        }
        // Sorted by id, the same reason the carts are. Only the tamed ones:
        // a wild herd is ambient and the spawner replaces it for free, but
        // nothing else in the game will ever put this exact pet back.
        let storedAnimals = (animals?.animals ?? [:])
            .filter { $0.value.isTamed }
            .sorted { $0.key < $1.key }
        self.animals = storedAnimals.isEmpty ? nil : storedAnimals.map { _, animal in
            SavedAnimal(
                kind: animal.kind.rawValue,
                x: Double(animal.position.x), y: Double(animal.position.y), z: Double(animal.position.z),
                isSitting: animal.isSitting,
                isRareMorph: animal.morph == .rare
            )
        }
    }
}

// MARK: - Restore

extension WorldSave {
    /// The journal in the shape `World.init(seed:edits:)` takes it. A block
    /// this build has no case for — a save from a version with more block
    /// types — is dropped, which leaves the terrain the seed describes
    /// there instead of a hole.
    var editJournal: [ChunkCoord: [Int: BlockType]] {
        var journal: [ChunkCoord: [Int: BlockType]] = [:]
        for chunk in chunks {
            var entries: [Int: BlockType] = [:]
            for (index, raw) in zip(chunk.indices, chunk.blocks) {
                guard index >= 0, index < Chunk.blockCount, let block = BlockType(rawValue: raw) else { continue }
                entries[index] = block
            }
            guard !entries.isEmpty else { continue }
            journal[ChunkCoord(x: chunk.x, z: chunk.z)] = entries
        }
        return journal
    }

    var playerPosition: Vector3 {
        Vector3(CGFloat(playerX), CGFloat(playerY), CGFloat(playerZ))
    }

    /// Every slot the inventory has, in order — an unknown item, or one
    /// filed against a slot number this build doesn't have, drops out and
    /// leaves the slot empty.
    var inventorySlots: [ItemStack?] {
        var restored = [ItemStack?](repeating: nil, count: Inventory.totalSize)
        for saved in slots {
            guard restored.indices.contains(saved.slot), let type = ItemType(rawValue: saved.item) else { continue }
            restored[saved.slot] = ItemStack(
                type, count: min(max(1, saved.count), type.maxStack), wear: saved.clampedWear(for: type)
            )
        }
        return restored
    }

    /// What's worn, decoded — an unknown or missing raw name comes back as
    /// bare-chested rather than a crash, the same forgiveness
    /// `inventorySlots` shows an unreadable slot.
    var equippedChestplate: ItemType? {
        equippedChestplateRaw.flatMap { ItemType(rawValue: $0) }
    }
}

extension WorldSave {
    /// The chests, put back where they stood. An item this build has no
    /// case for drops out and leaves its slot empty — the same forgiveness
    /// `inventorySlots` shows, and for the same reason.
    var chestStore: ChestStore {
        let store = ChestStore()
        for saved in chests ?? [] {
            var restored = [ItemStack?](repeating: nil, count: Chest.size)
            for slot in saved.slots {
                guard restored.indices.contains(slot.slot),
                      let type = ItemType(rawValue: slot.item) else { continue }
                restored[slot.slot] = ItemStack(
                    type, count: min(max(1, slot.count), type.maxStack), wear: slot.clampedWear(for: type)
                )
            }
            let chest = store.chest(at: ChestStore.Key(saved.x, saved.y, saved.z))
            for (index, stack) in restored.enumerated() { chest[index] = stack }
        }
        return store
    }

    /// The furnaces, put back where they stood, fires exactly as far along
    /// as they were. An item this build has no case for drops out of that
    /// slot rather than failing the whole furnace — the same forgiveness
    /// `chestStore` shows.
    var furnaceStore: FurnaceStore {
        let store = FurnaceStore()
        for saved in furnaces ?? [] {
            var state = FurnaceState()
            state.oreType = saved.oreType.flatMap(ItemType.init(rawValue:))
            state.oreCount = state.oreType == nil ? 0 : max(0, saved.oreCount)
            state.fuelType = saved.fuelType.flatMap(ItemType.init(rawValue:))
            state.fuelCount = state.fuelType == nil ? 0 : max(0, saved.fuelCount)
            state.outputType = saved.outputType.flatMap(ItemType.init(rawValue:))
            state.outputCount = state.outputType == nil ? 0 : max(0, saved.outputCount)
            // Burning without anything left in the ore slot to cook is not
            // a state `tick` can ever produce, so a hand-edited or corrupt
            // file claiming it is gets the fire out rather than a furnace
            // that glows for ore it does not have.
            state.burnRemaining = state.oreType == nil ? 0 : max(0, saved.burnRemaining)
            state.progress = state.oreType == nil ? 0 : max(0, min(FurnaceRecipe.smeltSeconds, saved.progress))
            guard !state.isEmpty else { continue }
            store.set(state, at: FurnaceStore.Key(saved.x, saved.y, saved.z))
        }
        return store
    }

    /// The hoppers, pointing where they were pointed and still holding
    /// whatever they were mid-transfer.
    ///
    /// A facing this build has no case for is dropped rather than failing
    /// the whole hopper — the same forgiveness `chestStore` shows — which
    /// leaves that one hopper auto-discovering its target as it did before
    /// facings existed.
    var hopperStore: HopperStore {
        let store = HopperStore()
        for saved in hoppers ?? [] {
            let key = HopperStore.Key(saved.x, saved.y, saved.z)
            let facing = saved.facing
                .flatMap { UInt8(exactly: $0) }
                .flatMap(BlockFacing.init(rawValue:))
            store.hopperPlaced(at: key, facing: facing)
            if let raw = saved.itemType,
               let type = ItemType(rawValue: raw),
               let count = saved.itemCount, count > 0 {
                store.setItem(ItemStack(type, count: count, wear: saved.itemWear ?? 0), at: key)
            }
        }
        return store
    }

    /// The carts, put back exactly where and how fast they were — mid-hill
    /// speed included, so a coaster reloads still rolling rather than
    /// having quietly stopped everywhere overnight. A heading this build
    /// has no case for (a future direction, or a hand-edited file) drops
    /// that one cart rather than failing the rest of the railway.
    var restoredMinecarts: [Minecart] {
        (minecarts ?? []).compactMap { saved in
            guard let rawHeading = UInt8(exactly: saved.heading),
                  let heading = BlockFacing(rawValue: rawHeading) else { return nil }
            var cart = Minecart(
                position: Vector3(CGFloat(saved.x), CGFloat(saved.y), CGFloat(saved.z)),
                heading: heading
            )
            cart.speed = CGFloat(saved.speed)
            // An item this build has no case for drops the cargo rather
            // than failing the whole cart — the same forgiveness
            // `inventorySlots` shows a slot it cannot place.
            if let cargoType = saved.cargoType, let type = ItemType(rawValue: cargoType) {
                let count = min(max(1, saved.cargoCount ?? 1), type.maxStack)
                let wear: Int
                if let durability = type.durability, let cargoWear = saved.cargoWear {
                    wear = min(max(0, cargoWear), durability - 1)
                } else {
                    wear = 0
                }
                cart.cargo = ItemStack(type, count: count, wear: wear)
            }
            return cart
        }
    }

    /// The tamed animals, put back where they stood. A kind this build has
    /// no case for drops that one pet rather than failing the rest — the
    /// same forgiveness `restoredMinecarts` shows a heading it doesn't
    /// know. The seed only matters for wander noise on an untamed animal;
    /// a restored one is already following, so any deterministic value
    /// does.
    var restoredAnimals: [Animal] {
        (animals ?? []).compactMap { saved in
            guard let kind = AnimalKind(rawValue: saved.kind) else { return nil }
            var animal = Animal(
                kind: kind,
                position: Vector3(CGFloat(saved.x), CGFloat(saved.y), CGFloat(saved.z)),
                seed: UInt64(bitPattern: Int64(saved.x)) &* 0x2545F4914F6CDD1D
                    &+ UInt64(bitPattern: Int64(saved.z)),
                morph: saved.isRareMorph ? .rare : .common
            )
            animal.isTamed = true
            animal.isSitting = saved.isSitting
            return animal
        }
    }
}

// MARK: - Disk

extension WorldSave {
    /// The executable is unbundled, so there is no bundle identifier to
    /// name a directory after. A literal is fine: the only property that
    /// matters is that it's the same one next launch.
    ///
    /// `BLOCKHAVEN_SAVE_DIR=<path>` replaces it wholesale — not just the
    /// world file but the whole directory, so `saves/`, the legacy backup
    /// and anything added later all move together. That is what lets a test
    /// exercise the real save code, migration included, without the real
    /// world being anywhere near the run: there is exactly one place the
    /// game can be pointed at, so pointing it elsewhere is total.
    ///
    /// The override has to be an absolute path, and an empty one is a
    /// mistake rather than an absence. This is the only mechanism keeping a
    /// test run away from the world someone is playing, so it is not allowed
    /// to fail open: a script whose path variable came out empty — an unset
    /// shell variable, a failed `mkdir`, a typo'd expansion — used to export
    /// `BLOCKHAVEN_SAVE_DIR=`, look isolated, and write straight into the
    /// real save directory. A relative path fails the same way, against
    /// whatever working directory the run happened to have. Both stop the
    /// process here instead.
    ///
    /// Resolved once. A run that changed this halfway through would write
    /// one world into two directories, and the value is read on every save.
    static let directoryURL: URL = {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["BLOCKHAVEN_SAVE_DIR"] {
            let path = (override as NSString).expandingTildeInPath
            guard isAbsolutePath(path) else {
                StandardError.write(Data("""
                    [save] BLOCKHAVEN_SAVE_DIR must be an absolute path — got "\(override)".
                    [save] Refusing to start: an unset or relative value would have written to \
                    the real save directory.

                    """.utf8))
                // EX_CONFIG. Loud, immediate, and nowhere near anyone's world.
                exit(78)
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Blockhaven", isDirectory: true)
    }()

    /// The single slot every build before this one saved to.
    ///
    /// Nothing writes here any more — `WorldCatalog` copies it into
    /// `saves/` once and then leaves it alone forever. It stays on disk as
    /// the backup of last resort for the one world that predates the
    /// catalogue.
    static var legacyFileURL: URL { directoryURL.appendingPathComponent("world.json") }

    /// Reads the save location, and so runs the check above, at a moment of
    /// the caller's choosing. Called at launch: a bad `BLOCKHAVEN_SAVE_DIR`
    /// should stop the process before a frame is drawn rather than at the
    /// first save half an hour in — and on a run with saving switched off
    /// nothing else would ever look.
    static func checkSaveLocation() {
        _ = directoryURL
    }

    /// `BLOCKHAVEN_NO_SAVE=1` leaves the disk alone for a whole run —
    /// nothing loaded, nothing written — so a test can't overwrite a world
    /// someone is actually playing.
    static let isEnabled = ProcessInfo.processInfo.environment["BLOCKHAVEN_NO_SAVE"] != "1"

    /// Every world writes to its own file, so the URL is never a default:
    /// a save that guessed where it belonged could put one world on top of
    /// another.
    func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Without this the key order varies run to run, so two saves of an
        // identical world wouldn't be identical files — which makes any
        // "did this change?" question about a save unanswerable.
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)

        // Write beside the target and swap it in, so a crash or a full disk
        // mid-write leaves the previous save whole rather than truncated.
        let temp = directory.appendingPathComponent(url.lastPathComponent + ".tmp")
        try data.write(to: temp)
        if FileManager.default.fileExists(atPath: url.path) {
            try replaceFile(at: url, with: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: url)
        }
    }

    /// Reads the save, or `nil` for anything that isn't one this build can
    /// play: missing, unreadable, malformed, or written by another version.
    ///
    /// A file that carried no `lastPlayed` — every world written before
    /// this build — is dated by the file itself, which is the closest thing
    /// to the truth anyone has.
    static func load(from url: URL) -> WorldSave? {
        guard let data = try? Data(contentsOf: url),
              var save = try? JSONDecoder().decode(WorldSave.self, from: data),
              save.version == WorldSave.currentVersion,
              save.hasUsableNumbers else { return nil }
        if save.lastPlayed <= 0 { save.lastPlayed = modificationTime(of: url) }
        return save
    }

    /// The file's own modification date in epoch seconds, or zero if the
    /// filesystem won't say.
    static func modificationTime(of url: URL) -> Double {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attributes?[.modificationDate] as? Date else { return 0 }
        return date.timeIntervalSince1970
    }

    /// A hand-edited or half-written file can decode cleanly and still be
    /// nonsense. A non-finite coordinate would drop the player out of the
    /// world entirely, and a merely enormous one traps the `Int(floor(x))`
    /// that turns a position into a chunk — so both are rejected here,
    /// where the answer can still be "there is no save".
    private var hasUsableNumbers: Bool {
        [playerX, playerY, playerZ].allSatisfy { $0.isFinite && abs($0) <= WorldSave.coordinateLimit }
            && yaw.isFinite && pitch.isFinite && timeOfDay.isFinite && lastPlayed.isFinite
    }

    /// Far beyond anywhere anyone can walk, and far short of where the
    /// conversion to `Int` gets interesting.
    private static let coordinateLimit: Double = 1e7
}

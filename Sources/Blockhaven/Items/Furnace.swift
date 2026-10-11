import Foundation

/// What a furnace turns things into, and what it burns to do it.
///
/// The whole point of a furnace over the crafting grid it replaces is that
/// it costs time and fuel rather than nothing — so this is two small
/// tables, not a menu: what smelts, and what burns. Ore in, an ingot out
/// (or raw meat in, a cooked cut out — the same fire and the same clock),
/// and a lump of coal or wood standing in the fire while it happens.
enum FurnaceRecipe {
    /// Seconds one item takes to smelt, once its fuel is lit.
    static let smeltSeconds: Double = 3.0

    /// What one unit of ore — or raw food — becomes, or nil for anything a
    /// furnace has nothing to say about.
    static func output(for ore: ItemType) -> ItemType? {
        switch ore {
        case .rawIron: return .ironIngot
        case .rawGold: return .goldIngot
        case .porkchop: return .cookedPorkchop
        case .beef: return .cookedBeef
        case .mutton: return .cookedMutton
        case .chicken: return .cookedChicken
        case .rawCod: return .cookedCod
        default: return nil
        }
    }

    /// Seconds of burn one unit of fuel is worth, or nil for anything that
    /// will not catch. Coal is the dense fuel — five smelts a lump, the
    /// same ratio the original's own furnace uses; planks and logs are what a
    /// first furnace runs on before coal is easy to find, and burn for
    /// less because wood is the thing every early trip already carries.
    static func burnSeconds(for fuel: ItemType) -> Double? {
        switch fuel {
        case .coal: return smeltSeconds * 5
        case .log, .birchLog, .spruceLog: return smeltSeconds * 2
        case .planks: return smeltSeconds
        case .lavaBucket: return smeltSeconds * 100
        default: return nil
        }
    }
}

/// One furnace's fire: an ore slot, a fuel slot, an output slot and the
/// clock burning between them.
///
/// A block is a byte and cannot hold any of this — the same reason a
/// chest's contents live in `ChestStore` rather than in the world array —
/// so a furnace's state lives here, keyed by cell, beside it.
struct FurnaceState: Equatable {
    var oreType: ItemType?
    var oreCount = 0
    var fuelType: ItemType?
    var fuelCount = 0
    /// Seconds left in the fuel currently alight. Zero means the fire is
    /// out, whatever is still waiting in the fuel slot.
    var burnRemaining: Double = 0
    /// Seconds the ore on top of the fire has been cooking, toward
    /// `FurnaceRecipe.smeltSeconds`.
    var progress: Double = 0
    var outputType: ItemType?
    var outputCount = 0

    var isBurning: Bool { burnRemaining > 0 }
    var isEmpty: Bool { oreType == nil && fuelType == nil && outputType == nil }

    private static let outputCapacity = 64

    /// Whether one more smelted item would fit in the output slot.
    private func hasRoom(for output: ItemType) -> Bool {
        outputType == nil || (outputType == output && outputCount < FurnaceState.outputCapacity)
    }

    /// One frame of the fire: catches new fuel if the ore waiting on it
    /// could use it, burns down what is already lit, and banks a smelted
    /// item every `smeltSeconds`. Returns whether `isBurning` changed, which
    /// is the caller's cue to swap the block between `furnace` and
    /// `furnaceLit` — the only way this state is ever seen from outside.
    mutating func tick(dt: Double) -> Bool {
        let wasBurning = isBurning

        if !isBurning,
           let ore = oreType, oreCount > 0,
           let output = FurnaceRecipe.output(for: ore), hasRoom(for: output),
           let fuel = fuelType, fuelCount > 0,
           let seconds = FurnaceRecipe.burnSeconds(for: fuel) {
            burnRemaining = seconds
            if fuel == .lavaBucket {
                fuelType = .bucket
                fuelCount = 1
            } else {
                fuelCount -= 1
                if fuelCount == 0 { fuelType = nil }
            }
        }

        guard isBurning else {
            progress = 0
            return wasBurning != isBurning
        }

        // Fuel that outlasts its ore keeps burning rather than being
        // wasted mid-lump, but nothing cooks until there is ore over it
        // again — the fire does not advance `progress` on nothing.
        guard let ore = oreType, oreCount > 0,
              let output = FurnaceRecipe.output(for: ore), hasRoom(for: output) else {
            burnRemaining = max(0, burnRemaining - dt)
            return wasBurning != isBurning
        }

        burnRemaining = max(0, burnRemaining - dt)
        progress += dt
        // Epsilon rather than a bare `>=`: `burnRemaining` and `progress`
        // both accumulate as a sum of the same per-frame `dt`, and a lump
        // of coal is defined as exactly `smeltSeconds * 5` for exactly
        // that reason — so the fire and the fifth smelt are meant to land
        // on the same frame. Summed in double, `15.0` and `5 * 3.0` do not
        // always come out bit-identical, and without slack the last smelt
        // in a lump could lose a whole item to the fire going out `2.9e-14`
        // seconds early.
        if progress >= FurnaceRecipe.smeltSeconds - 1e-9 {
            progress -= FurnaceRecipe.smeltSeconds
            oreCount -= 1
            if oreCount == 0 { oreType = nil }
            if outputType == output {
                outputCount += 1
            } else {
                outputType = output
                outputCount = 1
            }
        }
        return wasBurning != isBurning
    }
}

/// Every furnace in a world, by where it stands — the chest's own
/// arrangement (`ChestStore`), for the same reason: a furnace is one cell,
/// chunks come and go under the streamer, and its fire should not go out
/// just because its chunk did.
final class FurnaceStore {
    struct Key: Hashable {
        var x: Int
        var y: Int
        var z: Int

        init(_ x: Int, _ y: Int, _ z: Int) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    private(set) var furnaces: [Key: FurnaceState] = [:]

    /// The furnace at a cell, or a cold empty one if there isn't a state
    /// recorded yet — which is what a freshly placed furnace is.
    func state(at key: Key) -> FurnaceState { furnaces[key] ?? FurnaceState() }

    /// Writes a furnace's state back, or drops the entry entirely once it
    /// has nothing left in it — an empty, cold furnace is indistinguishable
    /// from one nobody ever touched, so there is nothing worth keeping.
    func set(_ state: FurnaceState, at key: Key) {
        if state.isEmpty {
            furnaces.removeValue(forKey: key)
        } else {
            furnaces[key] = state
        }
    }

    @discardableResult
    func remove(at key: Key) -> FurnaceState? {
        furnaces.removeValue(forKey: key)
    }

    var isEmpty: Bool { furnaces.isEmpty }

    /// Drops every furnace no longer standing where it says it is — the
    /// same sweep `ChestStore.prune` runs, and needed for the same reason:
    /// an explosion takes whole cells out without asking this store first.
    func prune(where blockIsGone: (Key) -> Bool) {
        for key in furnaces.keys where blockIsGone(key) {
            furnaces.removeValue(forKey: key)
        }
    }
}

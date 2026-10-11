import Foundation

/// The one signal primitive in the game: a lever's on/off, carried through
/// touching wire, and read by whatever sits at the far end of it.
///
/// Everything else in this world reacts to the player. This is the one
/// thing that reacts to *itself* — and deliberately the smallest version of
/// that idea rather than a new layer of blocks: no new consumer exists for
/// it, only a second way to trigger two that already do. A door opens
/// exactly as it would for a swung hand, through `ShapedPlacement`'s own
/// toggle; a stick of TNT ignites exactly as it would for a torch, through
/// `FuseManager.light`, which already refuses a cell that stopped being
/// TNT — so a network that fires the same charge twice in one frame costs
/// nothing. The two consumers were chosen because they were already there:
/// a switch that opens a gate and a switch that fires a charge are most of
/// what a first circuit is ever built to do, and both come from rules this
/// game already had.
///
/// Recomputed on the events that can change it — a lever thrown, a wire or
/// a lever placed or broken — never once a frame. A network only ever
/// costs as much as an *on* lever can reach, so recomputing the whole thing
/// is free while nothing in the world is wired up, and bounded everywhere
/// else by `maxReach`.
/// Represents the celestial sky state for environmental checks and daylight sensing.
struct Sky {
    var timeOfDay: Double
    var isRaining: Bool

    init(timeOfDay: Double = 0.25, isRaining: Bool = false) {
        self.timeOfDay = timeOfDay
        self.isRaining = isRaining
    }

    var dayFraction: Double {
        get { timeOfDay }
        set { timeOfDay = newValue }
    }

    var isNight: Bool {
        SkyClock.isNight(at: timeOfDay)
    }
}

final class SignalNetwork {
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

    /// Every lever's cell, so a toggle or an edit can find the sources
    /// without scanning the loaded world for them.
    private(set) var leverCells: Set<Key> = []
    /// Every pressure plate's cell — the network's second source. A plate
    /// is never toggled directly the way a lever is; something outside
    /// this type (`GameViewController`, every frame, cheaply) flips the
    /// block between `pressurePlateOff`/`pressurePlateOn` as feet arrive
    /// and leave, and `recompute` reads whichever state is there exactly
    /// the way it already reads a lever's.
    private(set) var plateCells: Set<Key> = []
    /// Every detector rail's cell — the network's third source, and the
    /// first one thrown by neither a hand nor a foot: a cart parked over
    /// one is what turns it on. Unlike a plate it has no on/off block pair
    /// to read back — a cart sitting on top of it already says so to
    /// anyone looking — so which detector cells are currently live is kept
    /// here instead, in `activeDetectors`.
    private(set) var detectorCells: Set<Key> = []
    /// Which detector cells a cart was actually parked on as of the last
    /// `updateDetectors` poll. `recompute` reads this exactly the way it
    /// reads a lever's or a plate's own block state.
    private var activeDetectors: Set<Key> = []
    /// Every signal torch's cell — the network's fourth source, and the
    /// first that is also one of the things a source feeds: lit by
    /// default, it goes dark the instant `isPowered` finds a powered
    /// neighbour and relights the instant it stops. `recompute` reads its
    /// on/off the same as any other source; `updateTorches` is what
    /// decides which one it currently is. See `torchCooldown` for why a
    /// torch does not simply re-evaluate every frame.
    private(set) var torchCells: Set<Key> = []
    /// Seconds left before a torch is allowed to flip again, keyed by
    /// cell — set only on an actual flip, never just for being checked.
    /// Without this, a torch wired to loop back on itself would flip,
    /// notice its own new state next frame, flip back, and so on with no
    /// floor: a clock that oscillates once per frame is not a clock a
    /// player can build anything from, it is a flicker. This is the one
    /// number that turns that into a visible, usable oscillation instead —
    /// see `updateTorches`.
    private var torchCooldown: [Key: Double] = [:]
    /// How long a torch holds a flip before it is allowed to flip again.
    static let torchDelay: Double = 0.4
    /// Wire currently lit, so a wire that stops being reached is turned
    /// back off rather than left glowing forever.
    private var litWire: Set<Key> = []
    /// Doors currently held open by power — the one consumer that has to
    /// be put back rather than just fired once.
    private var poweredDoors: Set<Key> = []
    /// Boosters the network is currently holding inert — the other
    /// reversible consumer. See `World.boosterIsActive` for why a booster
    /// is switched off here rather than in the block itself.
    private var suppressedBoosters: Set<Key> = []
    /// Every lever or wire cell currently carrying power, kept around
    /// after `recompute` returns so a fourth consumer can ask "am I
    /// touching power right now" between recomputes instead of needing to
    /// be one of the things `recompute` already knows how to drive. A
    /// hopper is exactly that: nothing here fires it or holds it open the
    /// way a door or a booster is, `isPowered` is read, not pushed.
    private(set) var poweredCells: Set<Key> = []

    /// Every daylight sensor's cell.
    private(set) var daylightSensorCells: Set<Key> = []
    private var activeDaylightSensors: Set<Key> = []
    private var sensorPower: [Key: Int] = [:]

    /// Every signal lamp's cell.
    private(set) var lampCells: Set<Key> = []

    /// How far a signal reaches through wire before it gives out. Fifteen
    /// is the original's own signal dust; there is no reason to pick a
    /// different number when that one already reads as "most of a room".
    static let maxReach = 15

    func leverPlaced(at key: Key) { leverCells.insert(key) }
    func leverRemoved(at key: Key) { leverCells.remove(key) }
    func platePlaced(at key: Key) { plateCells.insert(key) }
    func plateRemoved(at key: Key) { plateCells.remove(key) }
    func detectorPlaced(at key: Key) { detectorCells.insert(key) }
    func detectorRemoved(at key: Key) { detectorCells.remove(key); activeDetectors.remove(key) }
    func torchPlaced(at key: Key) { torchCells.insert(key) }
    func torchRemoved(at key: Key) { torchCells.remove(key); torchCooldown.removeValue(forKey: key) }
    func daylightSensorPlaced(at key: Key) { daylightSensorCells.insert(key) }
    func daylightSensorRemoved(at key: Key) {
        daylightSensorCells.remove(key)
        activeDaylightSensors.remove(key)
        sensorPower.removeValue(forKey: key)
    }
    func lampPlaced(at key: Key) { lampCells.insert(key) }
    func lampRemoved(at key: Key) { lampCells.remove(key) }

    private static let neighborOffsets: [(Int, Int, Int)] = [
        (1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1),
    ]

    private static func neighbors(of key: Key) -> [Key] {
        neighborOffsets.map { Key(key.x + $0.0, key.y + $0.1, key.z + $0.2) }
    }

    static func daylightPower(timeOfDay: Double) -> Int {
        let angle = (timeOfDay - 0.25) * 2.0 * .pi
        let elevation = max(0.0, cos(angle))
        return Int(round(elevation * 15.0))
    }

    func isSensorOpenToSky(at key: Key, world: World) -> Bool {
        world.isSkyOpen(worldX: key.x, y: key.y, worldZ: key.z)
    }

    func daylightSensorPower(at key: Key, world: World, timeOfDay: Double) -> Int {
        guard isSensorOpenToSky(at: key, world: world) else { return 0 }
        return SignalNetwork.daylightPower(timeOfDay: timeOfDay)
    }

    @discardableResult
    func updateDaylightSensors(world: World, timeOfDay: Double, fuses: FuseManager = FuseManager()) -> Bool {
        guard !daylightSensorCells.isEmpty else { return false }
        var nextPower: [Key: Int] = [:]
        for key in daylightSensorCells {
            let power = daylightSensorPower(at: key, world: world, timeOfDay: timeOfDay)
            nextPower[key] = power
        }
        guard nextPower != sensorPower else { return false }
        sensorPower = nextPower
        activeDaylightSensors = Set(nextPower.filter { $0.value > 0 }.keys)
        recompute(world: world, fuses: fuses)
        return true
    }

    @discardableResult
    func updateDaylightSensors(world: World, fuses: FuseManager = FuseManager(), sky: Sky) -> Bool {
        updateDaylightSensors(world: world, timeOfDay: sky.timeOfDay, fuses: fuses)
    }

    @discardableResult
    func updateDaylightSensors(world: World, sky: Sky, fuses: FuseManager = FuseManager()) -> Bool {
        updateDaylightSensors(world: world, timeOfDay: sky.timeOfDay, fuses: fuses)
    }

    @discardableResult
    func updateDaylightSensors(world: World, fuses: FuseManager = FuseManager(), sky: SkyClock) -> Bool {
        updateDaylightSensors(world: world, timeOfDay: sky.timeOfDay, fuses: fuses)
    }

    @discardableResult
    func updateDaylightSensors(world: World, sky: SkyClock, fuses: FuseManager = FuseManager()) -> Bool {
        updateDaylightSensors(world: world, timeOfDay: sky.timeOfDay, fuses: fuses)
    }

    /// Every cell a lever at `start` reaches through wire, plus the lever
    /// cell itself — regardless of whether that lever is currently on.
    /// Used twice: once over every lever, to know which boosters a player
    /// has actually wired up at all, and once over only the *on* ones, to
    /// know which of those wired cells are currently carrying power.
    ///
    /// Depth is carried per cell rather than per BFS layer, the one thing
    /// that changes once a relay can appear in the middle of a run: a plain
    /// wire cell hands its neighbours one more than whatever depth got it
    /// there, same as before, but a relay hands its neighbours a fresh
    /// count starting from zero regardless of how much reach it took to
    /// reach the relay itself — the same reset a real repeater gives
    /// signal. Without a relay anywhere in reach this produces exactly
    /// the old layer-by-layer cutoff at `maxReach`.
    private static func reach(from start: Key, world: World, maxReach: Int = SignalNetwork.maxReach) -> Set<Key> {
        var visited: Set<Key> = [start]
        var frontier: [(cell: Key, depth: Int)] = [(start, 0)]
        while !frontier.isEmpty {
            var next: [(cell: Key, depth: Int)] = []
            for (cell, depth) in frontier {
                let isRelay = world.block(worldX: cell.x, y: cell.y, worldZ: cell.z).isSignalRelay
                let base = isRelay ? 0 : depth
                guard base < maxReach else { continue }
                for neighbor in neighbors(of: cell) {
                    guard !visited.contains(neighbor) else { continue }
                    let block = world.block(worldX: neighbor.x, y: neighbor.y, worldZ: neighbor.z)
                    guard block.isWire || block.isSignalRelay else { continue }
                    visited.insert(neighbor)
                    next.append((neighbor, base + 1))
                }
            }
            frontier = next
        }
        return visited
    }

    /// Recomputes the whole network: floods outward from every lever and
    /// every plate, lit or not, lights the wire an *on* one reaches, and
    /// applies what that means to whatever is standing at the end of it.
    func recompute(world: World, fuses: FuseManager) {
        var wiredCells: Set<Key> = []      // reachable from any source, on or off
        var powered: Set<Key> = []         // reachable from an *on* source

        for source in leverCells.union(plateCells).union(detectorCells).union(torchCells).union(daylightSensorCells) {
            let isSensor = daylightSensorCells.contains(source)
            let wiredReached = SignalNetwork.reach(from: source, world: world, maxReach: SignalNetwork.maxReach)
            wiredCells.formUnion(wiredReached)

            let power = isSensor ? (sensorPower[source] ?? 0) : SignalNetwork.maxReach
            let block = world.block(worldX: source.x, y: source.y, worldZ: source.z)
            let on = block == .leverOn || block == .pressurePlateOn || block == .signalTorchOn
                || activeDetectors.contains(source) || (isSensor && activeDaylightSensors.contains(source) && power > 0)
            if on {
                let poweredReached = (isSensor && power < SignalNetwork.maxReach)
                    ? SignalNetwork.reach(from: source, world: world, maxReach: power)
                    : wiredReached
                powered.formUnion(poweredReached)
            }
        }
        let poweredWire = powered.filter {
            let block = world.block(worldX: $0.x, y: $0.y, worldZ: $0.z)
            return block.isWire || block.isSignalRelay
        }

        // Light the wire carrying signal; dim what stopped. A relay is lit
        // and dimmed by the same rule, since it is wire for every purpose
        // but how far it lets a signal travel.
        for key in poweredWire {
            switch world.block(worldX: key.x, y: key.y, worldZ: key.z) {
            case .wireOff: world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: .wireOn)
            case .signalRelayOff: world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: .signalRelayOn)
            default: break
            }
        }
        for key in litWire.subtracting(poweredWire) {
            switch world.block(worldX: key.x, y: key.y, worldZ: key.z) {
            case .wireOn: world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: .wireOff)
            case .signalRelayOn: world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: .signalRelayOff)
            default: break
            }
        }
        litWire = poweredWire

        // TNT touching a powered cell goes off — one-shot, and safe to
        // revisit: `FuseManager.light` refuses a cell that is no longer
        // TNT, so a network recomputed twice in a frame cannot double-fire.
        for cell in powered {
            for neighbor in SignalNetwork.neighbors(of: cell) {
                guard world.block(worldX: neighbor.x, y: neighbor.y, worldZ: neighbor.z) == .tnt else { continue }
                fuses.light(atX: neighbor.x, y: neighbor.y, z: neighbor.z, in: world, fuse: FuseManager.litFuse)
            }
        }

        // Doors touching a powered cell are forced open; ones that lost
        // power close again.
        var stillOpen: Set<Key> = []
        for cell in powered {
            for neighbor in SignalNetwork.neighbors(of: cell) {
                let block = world.block(worldX: neighbor.x, y: neighbor.y, worldZ: neighbor.z)
                guard block.isDoor else { continue }
                let key = Key(neighbor.x, neighbor.y, neighbor.z)
                stillOpen.insert(key)
                guard !block.doorIsOpen else { continue }
                if let edits = ShapedPlacement.doorToggleEdits(at: (neighbor.x, neighbor.y, neighbor.z), world: world) {
                    ShapedPlacement.apply(edits, to: world)
                }
            }
        }
        for key in poweredDoors.subtracting(stillOpen) {
            let block = world.block(worldX: key.x, y: key.y, worldZ: key.z)
            guard block.isDoor, block.doorIsOpen else { continue }
            if let edits = ShapedPlacement.doorToggleEdits(at: (key.x, key.y, key.z), world: world) {
                ShapedPlacement.apply(edits, to: world)
            }
        }
        poweredDoors = stillOpen

        // Boosters touching a wired cell follow the signal; every other
        // booster in the world was never in this loop at all and keeps
        // pushing exactly as it always has. One that is wired but unlit
        // is held inert; the instant power reaches it, it launches again.
        var stillWired: Set<Key> = []
        for cell in wiredCells {
            for neighbor in SignalNetwork.neighbors(of: cell) {
                guard world.block(worldX: neighbor.x, y: neighbor.y, worldZ: neighbor.z).isBooster else { continue }
                let key = Key(neighbor.x, neighbor.y, neighbor.z)
                stillWired.insert(key)
            }
        }
        let poweredBoosters = Set(powered.flatMap { cell in
            SignalNetwork.neighbors(of: cell).filter {
                world.block(worldX: $0.x, y: $0.y, worldZ: $0.z).isBooster
            }.map { Key($0.x, $0.y, $0.z) }
        })
        for key in stillWired {
            world.setBoosterSuppressed(!poweredBoosters.contains(key), worldX: key.x, y: key.y, worldZ: key.z)
        }
        for key in suppressedBoosters.subtracting(stillWired) {
            world.setBoosterSuppressed(false, worldX: key.x, y: key.y, worldZ: key.z)
        }
        suppressedBoosters = stillWired.subtracting(poweredBoosters)

        poweredCells = powered

        for key in lampCells {
            let block = world.block(worldX: key.x, y: key.y, worldZ: key.z)
            let shouldBeLit = isPowered(at: key)
            if shouldBeLit && block == .signalLamp {
                world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: .signalLampLit, remesh: true)
            } else if !shouldBeLit && block == .signalLampLit {
                world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: .signalLamp, remesh: true)
            }
        }
    }

    /// Checks every known plate against `occupied`, flips any whose
    /// pressed state disagrees with what it should be, and recomputes the
    /// network if anything actually changed. `occupied` is the caller's
    /// answer to "is something standing in this cell" — cheap and cheap to
    /// call every frame, since it is only ever asked about the handful of
    /// cells a player has actually laid a plate on, never the whole world.
    /// The expensive part, `recompute`'s flood fill, still only runs on a
    /// real transition, the same discipline every other consumer keeps.
    @discardableResult
    func updatePlates(world: World, fuses: FuseManager, occupied: (Key) -> Bool) -> Bool {
        var changed = false
        for key in plateCells {
            let isOn = world.block(worldX: key.x, y: key.y, worldZ: key.z) == .pressurePlateOn
            let shouldBeOn = occupied(key)
            guard isOn != shouldBeOn else { continue }
            world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: shouldBeOn ? .pressurePlateOn : .pressurePlateOff)
            changed = true
        }
        if changed { recompute(world: world, fuses: fuses) }
        return changed
    }

    @discardableResult
    func updatePlates(world: World, fuses: FuseManager, occupancy: (Key) -> Bool, _ dummy: Void = ()) -> Bool {
        updatePlates(world: world, fuses: fuses, occupied: occupancy)
    }

    /// Checks every detector rail against `occupied` — the caller's answer
    /// to "is a cart parked here" — and recomputes if that disagreed with
    /// what was live last frame. The same poll-and-diff discipline
    /// `updatePlates` uses, except there is no block to flip: a cart
    /// sitting on the rail is already the visible tell, so only the
    /// bookkeeping here changes, never the world.
    @discardableResult
    func updateDetectors(world: World, fuses: FuseManager, occupied: (Key) -> Bool) -> Bool {
        var next: Set<Key> = []
        for key in detectorCells where occupied(key) {
            next.insert(key)
        }
        guard next != activeDetectors else { return false }
        activeDetectors = next
        recompute(world: world, fuses: fuses)
        return true
    }

    /// Whether `key` is reached by an *on* source other than the torch
    /// standing at `key` itself.
    ///
    /// A torch is the one source that also reads the network, and its own
    /// light reaches every side of it, not just the side a player thinks of
    /// as the output — so a torch wired to both a switch and a door would,
    /// read against the ordinary `poweredCells`, see its own glow on the
    /// output wire and read itself as externally powered. Excluding the
    /// torch at `key` from the flood is what keeps "lever through a torch
    /// to a door" a stable inversion instead of a torch that lights for one
    /// frame and immediately convinces itself to go back out. A torch two
    /// cells away is not excluded, which is exactly what lets one torch's
    /// output legitimately decide another's input — the entire reason a
    /// ring of them can tick at all.
    private func isPowered(reaching key: Key, excluding: Key, world: World) -> Bool {
        for source in leverCells.union(plateCells).union(detectorCells).union(torchCells).union(daylightSensorCells) where source != excluding {
            let isSensor = daylightSensorCells.contains(source)
            let block = world.block(worldX: source.x, y: source.y, worldZ: source.z)
            let power = isSensor ? (sensorPower[source] ?? 0) : SignalNetwork.maxReach
            let on = block == .leverOn || block == .pressurePlateOn || block == .signalTorchOn
                || activeDetectors.contains(source) || (isSensor && activeDaylightSensors.contains(source) && power > 0)
            guard on else { continue }
            let reached = SignalNetwork.reach(from: source, world: world, maxReach: power)
            if SignalNetwork.neighbors(of: key).contains(where: { reached.contains($0) }) { return true }
        }
        return false
    }

    /// Checks every signal torch against every *other* source's current
    /// power, and flips any whose light disagrees with that — dark where
    /// something else reaches it, lit everywhere else. Every torch due for
    /// a check this poll is decided against the same pre-poll block state
    /// before any of them are written, and only one `recompute` runs after
    /// all the writes, so a ring of torches steps forward exactly one link
    /// per poll rather than racing itself around the loop in a single
    /// frame — and a torch that just flipped is skipped until its cooldown
    /// clears, which is the only thing standing between a ring and a
    /// signal that laps itself infinitely inside one frame instead of
    /// ticking.
    @discardableResult
    func updateTorches(world: World, fuses: FuseManager, dt: Double) -> Bool {
        guard !torchCells.isEmpty else { return false }
        var eligible: [Key] = []
        for key in torchCells {
            let remaining = (torchCooldown[key] ?? 0) - dt
            if remaining > 0 {
                torchCooldown[key] = remaining
            } else {
                eligible.append(key)
            }
        }
        guard !eligible.isEmpty else { return false }
        var decisions: [(Key, Bool)] = []
        for key in eligible {
            let shouldBeLit = !isPowered(reaching: key, excluding: key, world: world)
            let isLit = world.block(worldX: key.x, y: key.y, worldZ: key.z) == .signalTorchOn
            guard shouldBeLit != isLit else { continue }
            decisions.append((key, shouldBeLit))
        }
        guard !decisions.isEmpty else { return false }
        for (key, lit) in decisions {
            world.setBlock(worldX: key.x, y: key.y, worldZ: key.z, to: lit ? .signalTorchOn : .signalTorchOff)
            torchCooldown[key] = SignalNetwork.torchDelay
        }
        recompute(world: world, fuses: fuses)
        return true
    }

    /// True when a powered lever or wire cell sits directly against `key` —
    /// the same adjacency rule doors, TNT and boosters already answer to,
    /// just asked from outside `recompute` instead of acted on inside it.
    func isPowered(at key: Key) -> Bool {
        SignalNetwork.neighbors(of: key).contains { poweredCells.contains(Key($0.x, $0.y, $0.z)) }
    }

    /// Drops bookkeeping for cells that left the world outright — an
    /// explosion takes whole cells at once, the same reason `ChestStore`
    /// and `FurnaceStore` each get their own sweep. Three sets, not one
    /// predicate: a lever gone, a wire gone and a door gone are three
    /// different questions, and a blast can answer any of them without
    /// touching the other two.
    func prune(world: World) {
        leverCells = leverCells.filter { world.block(worldX: $0.x, y: $0.y, worldZ: $0.z).isLever }
        plateCells = plateCells.filter { world.block(worldX: $0.x, y: $0.y, worldZ: $0.z).isPressurePlate }
        detectorCells = detectorCells.filter { world.block(worldX: $0.x, y: $0.y, worldZ: $0.z).isDetectorRail }
        activeDetectors = activeDetectors.intersection(detectorCells)
        torchCells = torchCells.filter { world.block(worldX: $0.x, y: $0.y, worldZ: $0.z).isSignalTorch }
        torchCooldown = torchCooldown.filter { torchCells.contains($0.key) }
        litWire = litWire.filter {
            let block = world.block(worldX: $0.x, y: $0.y, worldZ: $0.z)
            return block.isWire || block.isSignalRelay
        }
        poweredDoors = poweredDoors.filter { world.block(worldX: $0.x, y: $0.y, worldZ: $0.z).isDoor }
        daylightSensorCells = daylightSensorCells.filter { world.block(worldX: $0.x, y: $0.y, worldZ: $0.z) == .daylightSensor }
        activeDaylightSensors = activeDaylightSensors.intersection(daylightSensorCells)
        sensorPower = sensorPower.filter { daylightSensorCells.contains($0.key) }
        lampCells = lampCells.filter {
            let b = world.block(worldX: $0.x, y: $0.y, worldZ: $0.z)
            return b == .signalLamp || b == .signalLampLit
        }
        // A booster a blast destroyed outright has to clear its flag in
        // `World` too, or a fresh booster someone places on that same cell
        // later would read as inert from the moment it lands.
        for key in suppressedBoosters
            where !world.block(worldX: key.x, y: key.y, worldZ: key.z).isBooster {
            world.setBoosterSuppressed(false, worldX: key.x, y: key.y, worldZ: key.z)
        }
        suppressedBoosters = suppressedBoosters.filter { world.block(worldX: $0.x, y: $0.y, worldZ: $0.z).isBooster }
    }
}

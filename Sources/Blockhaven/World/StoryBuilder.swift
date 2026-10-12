import Foundation

/// Builds the places the storyline needs: the survey station, the three
/// sites that keep the old network's pieces, the landing pad on the Moon
/// and the Sleeping Garden.
///
/// Everything goes in through `World.setBlock`, the same edit journal a
/// player's own building uses. That is what lets a world saved before the
/// story existed grow these places the next time it opens, and what keeps
/// them in the save afterwards without the generator having to know about
/// them. Sites are chosen away from any chunk that already holds an edit,
/// so a station never lands in the middle of somebody's house.
enum StoryBuilder {
    // MARK: - Ground

    /// The generated surface at a column — the top solid block, as the seed
    /// made it.
    static func ground(_ world: World, _ x: Int, _ z: Int) -> Int {
        world.generator.surfaceHeight(x: x, z: z)
    }

    /// True when no chunk under this square has been edited by anyone.
    static func untouched(_ world: World, x: Int, z: Int, radius: Int) -> Bool {
        for dz in stride(from: -radius, through: radius, by: max(1, radius)) {
            for dx in stride(from: -radius, through: radius, by: max(1, radius)) {
                let coord = World.chunkCoord(forWorldX: x + dx, worldZ: z + dz)
                if world.editJournal[coord] != nil { return false }
            }
        }
        return true
    }

    /// The tallest and lowest ground under a square.
    static func relief(_ world: World, x: Int, z: Int, radius: Int) -> (low: Int, high: Int) {
        var low = Int.max, high = Int.min
        for dz in -radius...radius {
            for dx in -radius...radius {
                let h = ground(world, x + dx, z + dz)
                low = min(low, h)
                high = max(high, h)
            }
        }
        return (low, high)
    }

    /// Candidate columns on rings around a centre, nearest ring first, in
    /// an order fixed by the seed — so the same world always picks the same
    /// places.
    static func candidates(
        around centre: (x: Int, z: Int), from minRadius: Int, to maxRadius: Int, salt: UInt64, seed: UInt64
    ) -> [(x: Int, z: Int)] {
        var out: [(x: Int, z: Int)] = []
        var radius = minRadius
        while radius <= maxRadius {
            let spokes = max(8, radius / 6)
            let turn = latticeHash(radius, Int(salt & 0xFFFF), seed: seed &+ salt) * 2 * .pi
            for spoke in 0..<spokes {
                let angle = turn + Double(spoke) / Double(spokes) * 2 * .pi
                out.append((centre.x + Int((cos(angle) * Double(radius)).rounded()),
                            centre.z + Int((sin(angle) * Double(radius)).rounded())))
            }
            radius += 12
        }
        return out
    }

    /// Makes a square of ground level at `y`: fills what is below it,
    /// clears what is above it, and lays `top` as the surface.
    static func level(_ world: World, x: Int, z: Int, radius: Int, y: Int, top: BlockType, fill: BlockType,
                      clearance: Int = 8) {
        for dz in -radius...radius {
            for dx in -radius...radius {
                let cx = x + dx, cz = z + dz
                let h = ground(world, cx, cz)
                if h < y {
                    for fy in (h + 1)..<y { world.setBlock(worldX: cx, y: fy, worldZ: cz, to: fill) }
                }
                world.setBlock(worldX: cx, y: y, worldZ: cz, to: top)
                let clearTo = max(h, y) + clearance
                for cy in (y + 1)...clearTo { world.setBlock(worldX: cx, y: cy, worldZ: cz, to: .air) }
            }
        }
    }

    static func put(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ block: BlockType) {
        world.setBlock(worldX: x, y: y, worldZ: z, to: block)
    }

    static func box(_ world: World, _ x0: Int, _ y0: Int, _ z0: Int, _ x1: Int, _ y1: Int, _ z1: Int,
                    _ block: BlockType) {
        for y in min(y0, y1)...max(y0, y1) {
            for z in min(z0, z1)...max(z0, z1) {
                for x in min(x0, x1)...max(x0, x1) { put(world, x, y, z, block) }
            }
        }
    }

    /// A handful of meteor ore lying in a shallow scorch, the one place on
    /// the home world the expedition's special metal comes from.
    static func meteorScatter(_ world: World, near x: Int, _ z: Int) {
        let offsets = [(0, 0), (1, 0), (0, 1), (-1, 0), (1, 1), (-1, -1), (2, 1)]
        for (dx, dz) in offsets {
            let h = ground(world, x + dx, z + dz)
            put(world, x + dx, h, z + dz, .meteorOre)
            put(world, x + dx, h - 1, z + dz, .meteorOre)
        }
    }

    // MARK: - Chapter 1: the survey station

    struct Station {
        var radio: StoryCell
        var chest: StoryCell
    }

    /// A short walk from spawn, on dry, fairly flat ground nobody has built
    /// on. Falls back to spawn's own ring at the edge of its reach rather
    /// than having no station at all.
    static func stationSite(_ world: World, spawn: (x: Int, z: Int)) -> (x: Int, z: Int) {
        let all = candidates(around: spawn, from: 36, to: 156, salt: 11, seed: world.seed)
        for site in all {
            let h = ground(world, site.x, site.z)
            guard h > WorldGenerator.seaLevel + 1 else { continue }
            let biome = world.generator.biome(x: site.x, z: site.z)
            guard biome != .ocean, biome != .beach else { continue }
            let r = relief(world, x: site.x, z: site.z, radius: 3)
            guard r.high - r.low <= 3, r.low > WorldGenerator.seaLevel else { continue }
            guard untouched(world, x: site.x, z: site.z, radius: 6) else { continue }
            return site
        }
        return all.last ?? (spawn.x + 40, spawn.z)
    }

    /// A roofless stone room: a broken radio on the north wall, the Moon
    /// carved beside it with the blinking point marked, a chest, and a
    /// mast with a red light to find it by.
    static func buildStation(_ world: World, at site: (x: Int, z: Int)) -> Station {
        let x = site.x, z = site.z
        let y = ground(world, x, z)
        level(world, x: x, z: z, radius: 4, y: y, top: .cobblestone, fill: .dirt)
        // Walls, broken along the top, with a doorway to the south.
        for dz in -3...3 {
            for dx in -3...3 where abs(dx) == 3 || abs(dz) == 3 {
                let height = 1 + Int(latticeHash(x + dx, z + dz, seed: world.seed &+ 5001) * 3.0)
                for dy in 1...height {
                    if dz == 3, dx == 0, dy <= 2 { continue }
                    put(world, x + dx, y + dy, z + dz, dx == 3 && dz == -3 ? .stone : .cobblestone)
                }
            }
        }
        // The north wall stands whole: it carries the map.
        for dx in -3...3 { for dy in 1...3 { put(world, x + dx, y + dy, z - 3, .cobblestone) } }
        for dx in -1...1 { for dy in 2...3 { put(world, x + dx, y + dy, z - 3, .sandstoneCarved) } }
        put(world, x + 1, y + 3, z - 3, .radiantYellow)
        let radio = StoryCell(x, y + 1, z - 2)
        put(world, radio.x, radio.y, radio.z, .radio)
        put(world, x + 1, y + 1, z - 2, .plaque)
        let chest = StoryCell(x - 2, y + 1, z - 2)
        put(world, chest.x, chest.y, chest.z, .chest)
        // The mast: seen over the trees before the walls are.
        for dy in 1...9 { put(world, x + 3, y + dy, z - 3, .cobblestone) }
        put(world, x + 3, y + 10, z - 3, .radiantRed)
        meteorScatter(world, near: x + 7, z + 6)
        return Station(radio: radio, chest: chest)
    }

    // MARK: - Chapter 2: the three sites

    /// The spire: a stone shaft on high ground with steps winding round
    /// it, a beacon on top, and the navigation radio beside the beacon.
    static func buildSpire(_ world: World, near centre: (x: Int, z: Int)) -> StoryCell {
        var best: (x: Int, z: Int)?
        var bestHeight = Int.min
        for site in candidates(around: centre, from: 110, to: 230, salt: 21, seed: world.seed) {
            let h = ground(world, site.x, site.z)
            guard h > WorldGenerator.seaLevel + 2, h < WorldGenerator.highestSurface - 40 else { continue }
            let biome = world.generator.biome(x: site.x, z: site.z)
            guard biome != .ocean, biome != .beach else { continue }
            guard untouched(world, x: site.x, z: site.z, radius: 4) else { continue }
            if h > bestHeight { bestHeight = h; best = site }
        }
        let site = best ?? (centre.x + 140, centre.z)
        let x = site.x, z = site.z
        let base = ground(world, x, z)
        level(world, x: x, z: z, radius: 3, y: base, top: .cobblestone, fill: .cobblestone, clearance: 6)
        let rise = 26
        box(world, x - 1, base + 1, z - 1, x + 1, base + rise, z + 1, .stone)
        // Steps up the outside: one block higher per step, round and round.
        var ring: [(Int, Int)] = []
        for dx in -2...2 { ring.append((dx, -2)) }
        for dz in -1...2 { ring.append((2, dz)) }
        for dx in stride(from: 1, through: -2, by: -1) { ring.append((dx, 2)) }
        for dz in stride(from: 1, through: -1, by: -1) { ring.append((-2, dz)) }
        for step in 0..<rise {
            let (dx, dz) = ring[step % ring.count]
            put(world, x + dx, base + 1 + step, z + dz, .cobblestone)
            put(world, x + dx, base + 2 + step, z + dz, .air)
            put(world, x + dx, base + 3 + step, z + dz, .air)
        }
        let top = base + rise
        box(world, x - 2, top, z - 2, x + 2, top, z + 2, .stone)
        put(world, x, top + 1, z, .seaLantern)
        put(world, x, top + 2, z, .seaLantern)
        let radio = StoryCell(x + 1, top + 1, z - 1)
        put(world, radio.x, radio.y, radio.z, .radio)
        put(world, x - 1, top + 1, z - 1, .plaque)
        meteorScatter(world, near: x + 6, z + 5)
        return radio
    }

    /// The vault: a sealed obsidian room deep under a lit cairn, reached by
    /// a stair winding down a stone shaft. The cabin radio waits inside.
    static func buildVault(_ world: World, near centre: (x: Int, z: Int)) -> StoryCell {
        var chosen: (x: Int, z: Int)?
        for site in candidates(around: centre, from: 90, to: 210, salt: 31, seed: world.seed) {
            let h = ground(world, site.x, site.z)
            guard h > WorldGenerator.seaLevel + 1, h < WorldGenerator.highestSurface - 10 else { continue }
            let biome = world.generator.biome(x: site.x, z: site.z)
            guard biome != .ocean, biome != .beach else { continue }
            guard untouched(world, x: site.x, z: site.z, radius: 4) else { continue }
            chosen = site
            break
        }
        let site = chosen ?? (centre.x - 120, centre.z)
        let x = site.x, z = site.z
        let surface = ground(world, x, z)
        level(world, x: x, z: z, radius: 3, y: surface, top: .cobblestone, fill: .cobblestone, clearance: 5)
        // The cairn: a lit pillar on each corner of the shaft.
        for (dx, dz) in [(-2, -2), (2, -2), (-2, 2), (2, 2)] {
            put(world, x + dx, surface + 1, z + dz, .cobblestone)
            put(world, x + dx, surface + 2, z + dz, .seaLantern)
        }
        let floor = max(10, surface - 22)
        // The shaft: stone walls, a hollow core, and a stair round the
        // inside of the walls descending one block a step.
        let shaftBottom = floor + 4
        for y in shaftBottom...surface {
            for dz in -2...2 {
                for dx in -2...2 {
                    let wall = abs(dx) == 2 || abs(dz) == 2
                    put(world, x + dx, y, z + dz, wall ? .stone : .air)
                }
            }
        }
        let ring: [(Int, Int)] = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)]
        var step = 0
        var y = surface - 1
        while y >= shaftBottom {
            let (dx, dz) = ring[step % ring.count]
            put(world, x + dx, y, z + dz, .cobblestone)
            if step % 6 == 0 { put(world, x, y, z, .torch) }
            y -= 1
            step += 1
        }
        // The vault itself: obsidian, whole, with the shaft landing on its
        // roof.
        box(world, x - 3, floor - 1, z - 3, x + 3, floor + 3, z + 3, .obsidian)
        box(world, x - 2, floor, z - 2, x + 2, floor + 2, z + 2, .air)
        put(world, x - 2, floor, z + 2, .torch)
        put(world, x + 2, floor, z + 2, .torch)
        let radio = StoryCell(x, floor, z - 2)
        put(world, radio.x, radio.y, radio.z, .radio)
        put(world, x + 1, floor, z - 2, .plaque)
        meteorScatter(world, near: x + 7, z - 6)
        return radio
    }

    /// The wreck: an old hull lying on a deep seabed, with a raft and a lamp
    /// floating over it. Where there is no sea deep enough nearby, a
    /// flooded well instead — the same dive, the same clock.
    static func buildWreck(_ world: World, near centre: (x: Int, z: Int)) -> StoryCell {
        var chosen: (x: Int, z: Int)?
        var deepest = 7
        for site in candidates(around: centre, from: 60, to: 420, salt: 41, seed: world.seed) {
            let h = ground(world, site.x, site.z)
            let depth = WorldGenerator.seaLevel - h
            guard depth > deepest else { continue }
            guard untouched(world, x: site.x, z: site.z, radius: 4) else { continue }
            deepest = depth
            chosen = site
            if depth >= 12 { break }
        }
        if let site = chosen {
            let x = site.x, z = site.z
            let bed = ground(world, x, z)
            // Flatten the seabed under the hull; water above stays water.
            for dz in -3...3 {
                for dx in -5...5 {
                    let h = ground(world, x + dx, z + dz)
                    for fy in min(h, bed)...bed { put(world, x + dx, fy, z + dz, .sand) }
                    if h > bed { for cy in (bed + 1)...h { put(world, x + dx, cy, z + dz, .water) } }
                }
            }
            // The hull: planks round a boat-shaped floor, broken along the
            // gunwale.
            for dz in -2...2 {
                for dx in -4...4 {
                    let edge = abs(dz) == 2 || abs(dx) == 4
                    let tapered = abs(dx) == 4 && abs(dz) == 2
                    guard !tapered else { continue }
                    put(world, x + dx, bed + 1, z + dz, .planks)
                    if edge, latticeHash(x + dx, z + dz, seed: world.seed &+ 5101) < 0.7 {
                        put(world, x + dx, bed + 2, z + dz, .planks)
                    }
                }
            }
            put(world, x, bed + 2, z, .log)
            put(world, x, bed + 3, z, .log)
            let radio = StoryCell(x + 2, bed + 2, z)
            put(world, radio.x, radio.y, radio.z, .radio)
            put(world, x - 2, bed + 2, z, .plaque)
            put(world, x - 2, bed + 2, z + 1, .seaLantern)
            // The marker: a raft with a lamp on it, floating right above.
            box(world, x - 1, WorldGenerator.seaLevel, z - 1, x + 1, WorldGenerator.seaLevel, z + 1, .planks)
            put(world, x, WorldGenerator.seaLevel + 1, z, .seaLantern)
            return radio
        }
        // No sea: a flooded well beside the station.
        let x = centre.x + 12, z = centre.z + 10
        let top = ground(world, x, z)
        let bottom = max(8, top - 12)
        for y in bottom...top {
            for dz in -2...2 {
                for dx in -2...2 {
                    let wall = abs(dx) == 2 || abs(dz) == 2
                    put(world, x + dx, y, z + dz, wall ? .stone : .water)
                }
            }
        }
        box(world, x - 2, bottom - 1, z - 2, x + 2, bottom - 1, z + 2, .stone)
        for (dx, dz) in [(-2, -2), (2, -2), (-2, 2), (2, 2)] { put(world, x + dx, top + 1, z + dz, .seaLantern) }
        let radio = StoryCell(x, bottom, z)
        put(world, radio.x, radio.y, radio.z, .radio)
        put(world, x + 1, bottom, z, .plaque)
        return radio
    }

    // MARK: - Chapter 3: the rocket

    /// The three blocks of a rocket stacked on a pad.
    static func rocketCells(onPad pad: StoryCell) -> [StoryCell] {
        [StoryCell(pad.x, pad.y + 1, pad.z), StoryCell(pad.x, pad.y + 2, pad.z), StoryCell(pad.x, pad.y + 3, pad.z)]
    }

    static func placeRocket(_ world: World, onPad pad: StoryCell) {
        let cells = rocketCells(onPad: pad)
        put(world, cells[0].x, cells[0].y, cells[0].z, .rocketEngine)
        put(world, cells[1].x, cells[1].y, cells[1].z, .rocketTank)
        put(world, cells[2].x, cells[2].y, cells[2].z, .rocketCabin)
    }

    /// The pad under a rocket block, if it stands on one.
    static func pad(under cell: StoryCell, in world: World) -> StoryCell? {
        for dy in 1...3 {
            let y = cell.y - dy
            let block = world.block(worldX: cell.x, y: y, worldZ: cell.z)
            if block == .padCore { return StoryCell(cell.x, y, cell.z) }
            if !block.isRocket { return nil }
        }
        return nil
    }

    // MARK: - The Moon

    /// Where the garden stands, east of the landing.
    static let gardenCentre = (x: 48, z: 0)

    /// The landing crater's floor at the origin: a ring of brick round a
    /// pad, the rocket on it, and a chest with a few spare parts.
    static func buildMoonLanding(_ world: World) -> StoryCell {
        let y = ground(world, 0, 0)
        level(world, x: 0, z: 0, radius: 4, y: y, top: .moonDust, fill: .moonRock)
        box(world, -2, y, -2, 2, y, 2, .moonBrick)
        let pad = StoryCell(0, y, 0)
        put(world, 0, y, 0, .padCore)
        placeRocket(world, onPad: pad)
        // A path of brick toward the garden, so the first walk has a line.
        for x in 3...(gardenCentre.x - 11) {
            let h = ground(world, x, 0)
            put(world, x, h, 0, .moonBrick)
        }
        // The cold shelf: a shaded bowl of ice south-west of the pad.
        let iceX = -18, iceZ = 16
        let bowl = ground(world, iceX, iceZ) - 3
        for dz in -4...4 {
            for dx in -4...4 where dx * dx + dz * dz <= 18 {
                let h = ground(world, iceX + dx, iceZ + dz)
                for cy in bowl...max(h, bowl) { put(world, iceX + dx, cy, iceZ + dz, .air) }
                put(world, iceX + dx, bowl - 1, iceZ + dz, .ice)
                put(world, iceX + dx, bowl - 2, iceZ + dz, .ice)
            }
        }
        return pad
    }

    /// The Sleeping Garden: a buried brick complex with a corridor, a dark
    /// light hall, a dry reservoir, an empty nursery, and a sealed seed
    /// vault — and, on the ridge behind it, the buried sun collector whose
    /// wire to the lamps is broken.
    static func buildGarden(_ world: World) -> GardenPlan {
        let cx = gardenCentre.x, cz = gardenCentre.z
        let gy = ground(world, cx, cz)
        let x0 = cx - 10, x1 = cx + 10, z0 = cz - 10, z1 = cz + 10
        let roof = gy + 5
        // The ground the garden and its ridge sit on.
        for z in (z0 - 16)...(z1 + 2) {
            for x in (x0 - 2)...(x1 + 2) {
                let h = ground(world, x, z)
                if h < gy { for fy in (h + 1)...gy { put(world, x, fy, z, .moonRock) } }
                put(world, x, gy, z, .moonDust)
                if h > gy { for cy in (gy + 1)...(h + 1) { put(world, x, cy, z, .air) } }
            }
        }
        // The shell, hollow, roofed, floored with brick.
        box(world, x0, gy, z0, x1, roof, z1, .moonBrick)
        box(world, x0 + 1, gy + 1, z0 + 1, x1 - 1, roof - 1, z1 - 1, .air)
        // Partitions: a corridor down the middle (z -2…2), four rooms off it.
        for x in (x0 + 1)...(x1 - 1) {
            for y in (gy + 1)...(roof - 1) {
                put(world, x, y, cz - 3, .moonBrick)
                put(world, x, y, cz + 3, .moonBrick)
            }
        }
        for z in [Array((z0 + 1)...(cz - 4)), Array((cz + 4)...(z1 - 1))].joined() {
            for y in (gy + 1)...(roof - 1) { put(world, cx, y, z, .moonBrick) }
        }
        // Windows of prism glass along the south and east walls, so the
        // seed chambers and the empty halls can be seen before the way in
        // is found — glass keeps air in as well as brick does.
        for x in stride(from: x0 + 2, through: x1 - 2, by: 3) {
            for y in (gy + 2)...(gy + 3) { put(world, x, y, z1, .prismGlass) }
        }
        for z in stride(from: z0 + 2, through: z1 - 2, by: 3) where abs(z - cz) > 1 {
            for y in (gy + 2)...(gy + 3) { put(world, x1, y, z, .prismGlass) }
        }
        // The front door, west, and the doorways off the corridor.
        for y in (gy + 1)...(gy + 2) {
            put(world, x0, y, cz, .air)
            put(world, cx - 5, y, cz - 3, .air)   // light hall
            put(world, cx - 5, y, cz + 3, .air)   // reservoir hall
            put(world, cx + 5, y, cz - 3, .air)   // nursery
        }
        // The seed vault's door: the one thing nothing breaks.
        let seal = [StoryCell(cx + 5, gy + 1, cz + 3), StoryCell(cx + 5, gy + 2, cz + 3)]
        for cell in seal { put(world, cell.x, cell.y, cell.z, .gardenSeal) }
        // The panel beside the front door, and lamps along the corridor's
        // walls so the way in is not pitch dark.
        let panel = StoryCell(x0 + 1, gy + 2, cz - 2)
        put(world, panel.x, panel.y, panel.z, .plaque)
        for x in stride(from: x0 + 3, through: x1 - 3, by: 6) {
            put(world, x, gy + 3, cz - 2, .glowCrystal)
        }
        // A chest of what the garden kept for whoever came: wire, relays,
        // buckets, a hoe and light.
        let supply = StoryCell(x0 + 2, gy + 1, cz + 2)
        put(world, supply.x, supply.y, supply.z, .chest)

        // The light hall (north-west): two lamps in the roof, dark.
        let lamps = [StoryCell(cx - 7, roof, cz - 7), StoryCell(cx - 3, roof, cz - 7)]
        for lamp in lamps { put(world, lamp.x, lamp.y, lamp.z, .signalLamp) }

        // The ridge behind the garden: rock up to the roof's height, so wire
        // laid on it runs straight onto the roof. Prism glass shows in its
        // face.
        let ridgeZ0 = z0 - 14, ridgeZ1 = z0 - 1
        for z in ridgeZ0...ridgeZ1 {
            for x in (x0 - 2)...(x1 + 2) {
                for y in (gy + 1)...roof {
                    let seam = (y == gy + 3 || y == gy + 4) && (z == ridgeZ0 || x == x0 - 2 || x == x1 + 2)
                        && latticeHash(x, z &+ y, seed: world.seed &+ 5201) < 0.5
                    put(world, x, y, z, seam ? .prismGlass : (y == roof ? .moonDust : .moonRock))
                }
            }
        }
        // The collector: three sun sensors on the ridge, buried under a
        // drift of dust.
        let collectorZ = ridgeZ0 + 4
        let collector = StoryCell(cx - 3, roof + 1, collectorZ)
        for dx in -1...1 {
            put(world, collector.x + dx, roof + 1, collectorZ, .daylightSensor)
            put(world, collector.x + dx, roof + 2, collectorZ, .moonDust)
            put(world, collector.x + dx, roof + 3, collectorZ, .moonDust)
        }
        // The wire from the collector to the lamps, along the ridge and over
        // the roof — broken in the middle, where a slab of ridge slid.
        var wire: [StoryCell] = []
        for z in (collectorZ + 1)...lamps[1].z { wire.append(StoryCell(collector.x, roof + 1, z)) }
        for x in stride(from: lamps[1].x - 1, through: lamps[0].x, by: -1) { wire.append(StoryCell(x, roof + 1, lamps[1].z)) }
        let gapStart = collectorZ + 4, gapEnd = collectorZ + 7
        for cell in wire where !(cell.x == collector.x && cell.z >= gapStart && cell.z <= gapEnd) {
            put(world, cell.x, cell.y, cell.z, .wireOff)
        }

        // The reservoir hall (south-west): a dry channel in the floor.
        let reservoir = (0..<6).map { StoryCell(cx - 8 + $0, gy, cz + 6) }
        for cell in reservoir {
            put(world, cell.x, cell.y, cell.z, .air)
            put(world, cell.x, cell.y - 1, cell.z, .moonBrick)
            put(world, cell.x, cell.y, cell.z + 1, .moonBrick)
            put(world, cell.x, cell.y, cell.z - 1, .moonBrick)
        }
        put(world, cx - 9, gy + 3, cz + 7, .glowCrystal)

        // The nursery (north-east): bare brick, a hole in the roof, and the
        // doorway open to the corridor. It is the player's to seal.
        let nurseryMin = StoryCell(cx + 1, gy + 1, z0 + 1)
        let nurseryMax = StoryCell(x1 - 1, roof - 1, cz - 4)
        put(world, cx + 5, roof, cz - 6, .air)

        // The seed vault (south-east): green-lit seed chambers on the walls
        // and the lever that wakes everything.
        for x in stride(from: cx + 2, through: x1 - 2, by: 2) {
            put(world, x, gy + 3, z1 - 1, .radiantGreen)
        }
        let lever = StoryCell(cx + 7, gy + 1, z1 - 2)
        put(world, lever.x, lever.y, lever.z, .leverOff)
        let vaultChest = StoryCell(cx + 3, gy + 1, z1 - 2)
        put(world, vaultChest.x, vaultChest.y, vaultChest.z, .chest)

        // The shutters: the corridor roof over the middle, brick until the
        // garden wakes.
        var shutters: [StoryCell] = []
        for z in (cz - 2)...(cz + 2) {
            for x in (cx - 3)...(cx + 3) { shutters.append(StoryCell(x, roof, z)) }
        }

        // The beacon mast on the roof: the light seen from home.
        for y in (roof + 1)...(roof + 5) { put(world, cx, y, cz, .moonBrick) }
        put(world, cx, roof + 6, cz, .radioLit)

        return GardenPlan(
            panel: panel, lamps: lamps, reservoir: reservoir,
            nurseryMin: nurseryMin, nurseryMax: nurseryMax,
            seal: seal, lever: lever, shutters: shutters,
            collector: collector, vaultChest: vaultChest
        )
    }

    /// Where the garden's supply chest stands — one cell in from the front
    /// door, beside the panel.
    static func gardenSupplyChest(_ plan: GardenPlan) -> StoryCell {
        StoryCell(plan.panel.x + 1, plan.panel.y - 1, plan.panel.z + 4)
    }
}

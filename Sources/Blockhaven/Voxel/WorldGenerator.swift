import Foundation

/// One block to be written at a world coordinate.
///
/// A named struct rather than the tuple this used to be, because these now
/// cross a thread boundary: decoration is worked out on the generation
/// queue and applied on the game loop, and `Sendable` is the compiler's
/// word that the hand-off is sound.
struct BlockPlacement: Sendable {
    let x: Int
    let y: Int
    let z: Int
    let block: BlockType
}

/// Deterministic terrain: a chunk's contents depend only on its coordinate
/// and the world seed, so chunks can be generated in any order, on any
/// thread, and always agree at their seams.
struct WorldGenerator {
    let seed: UInt64
    static let seaLevel = 62

    /// The highest the ground may come, and the two heights above which
    /// decoration stops.
    ///
    /// Absolute numbers, deliberately, where they used to be written as
    /// `Chunk.height - 14` and friends. Terrain is a pure function of the
    /// seed and a save stores only a seed and a diff, so *any* change to
    /// this function rewrites the landscape under every world anyone has
    /// built in. Deriving these from the world's ceiling made raising that
    /// ceiling — something done for a tall building, with no intention of
    /// touching terrain — quietly lift every clamped mountain top by
    /// sixty-four blocks and start planting trees where none had grown.
    ///
    /// These are the values they held when `Chunk.height` was 128. They
    /// stay there. A future world that genuinely wants taller mountains
    /// changes them on purpose and accepts what that means for old saves.
    static let highestSurface = 114
    static let highestSnowCap = 126
    static let highestTree = 112

    private let continentNoise: ValueNoise
    private let hillNoise: ValueNoise
    private let temperatureNoise: ValueNoise
    private let caveNoise: ValueNoise
    private let caveNoise2: ValueNoise

    init(seed: UInt64) {
        self.seed = seed
        continentNoise = ValueNoise(seed: seed &+ 1)
        hillNoise = ValueNoise(seed: seed &+ 2)
        temperatureNoise = ValueNoise(seed: seed &+ 3)
        caveNoise = ValueNoise(seed: seed &+ 4)
        caveNoise2 = ValueNoise(seed: seed &+ 5)
    }

    enum Biome {
        case ocean, beach, plains, forest, desert, mountains, snowy
    }

    /// The only two biomes trees ever generate in — see `treePositions`'s
    /// own density table. `World.spawnPosition` leans on this directly
    /// rather than guessing at "not desert, not snowy" from the outside.
    static let treeBiomes: Set<Biome> = [.plains, .forest]

    /// Surface height at a world column, built from three layers:
    ///
    /// - `continent` decides land versus sea over a few hundred blocks.
    /// - `hills` is fine relief everywhere.
    /// - `mountains` is masked to where the continent is already high, so
    ///   peaks gather into ranges instead of speckling the whole map.
    ///
    /// The frequencies matter as much as the amplitudes: too low and the
    /// terrain is a flat plain, because nothing changes within the few
    /// hundred blocks the player can actually see.
    func surfaceHeight(x: Int, z: Int) -> Int {
        let fx = Double(x), fz = Double(z)
        let continent = continentNoise.sample(fx * 0.0115, fz * 0.0115)
        let hills = hillNoise.sample(fx * 0.045, fz * 0.045)

        let mountainMask = max(0, continent - 0.12) / 0.88
        let ridge = hillNoise.sample(fx * 0.019 + 137, fz * 0.019 + 137)
        let mountains = max(0, ridge) * mountainMask * 36

        let height = Double(WorldGenerator.seaLevel)
            + continent * 22
            + hills * 6
            + mountains
        return max(1, min(WorldGenerator.highestSurface, Int(height.rounded())))
    }

    func temperature(x: Int, z: Int) -> Double {
        temperatureNoise.sample(Double(x) * 0.0045, Double(z) * 0.0045)
    }

    func biome(x: Int, z: Int) -> Biome {
        let height = surfaceHeight(x: x, z: z)
        let temp = temperature(x: x, z: z)
        if height < WorldGenerator.seaLevel - 1 { return .ocean }
        if height <= WorldGenerator.seaLevel + 1 { return .beach }
        if height > WorldGenerator.seaLevel + 30 { return temp < -0.15 ? .snowy : .mountains }
        if temp > 0.34 { return .desert }
        if temp < -0.3 { return .snowy }
        return temp > 0.05 ? .forest : .plains
    }

    /// How close to zero a cave field has to be for that field to call the
    /// cell hollow. Both fields are held to the same figure, and it is one
    /// of the numbers that decides the shape of the landscape — see the
    /// note on `highestSurface` about what changing it costs.
    private static let caveThreshold = 0.085

    /// True where a cave carves out this cell. Two independent noise fields
    /// are thresholded near zero and intersected, which yields winding
    /// tunnels rather than the swiss-cheese blobs a single field gives.
    ///
    /// No upper bound on `y` beyond the floor guard: every caller already
    /// stops at the column's own surface height, which is at most
    /// `highestSurface`, so a fixed ceiling here did not protect anything —
    /// it just quietly emptied a mountain's whole peak of caves, since
    /// `seaLevel + 12` sat forty-some blocks below where a mountaintop
    /// actually is. A cave that reaches a cliff face and opens onto it is
    /// the discovery, not a bug to guard against.
    private func isCave(x: Int, y: Int, z: Int) -> Bool {
        guard y > 4 else { return false }
        let fx = Double(x) * 0.028, fy = Double(y) * 0.055, fz = Double(z) * 0.028
        // Sample the 2D noise on two different planes to fake 3D cheaply.
        //
        // The second plane is only reached where the first has already said
        // "hollow", which is about a quarter of the cells asked. Both
        // fields are pure functions of the seed and the point, so an
        // intersection computed this way is the same intersection — but the
        // three cells in four that are plainly solid now cost one noise
        // sample rather than two. This is the single most expensive thing
        // in world generation and it is most of a chunk's cost.
        let a = caveNoise.sample(fx, fz + fy * 3.1)
        guard abs(a) < WorldGenerator.caveThreshold else { return false }
        let b = caveNoise2.sample(fx + fy * 2.7, fz)
        return abs(b) < WorldGenerator.caveThreshold
    }

    /// True where a rare, wide chamber claims this cell — reuses `inVein`'s
    /// own one-candidate-per-cell shape rather than a bespoke roll, at a
    /// scale meant to be walked into rather than squeezed through. Ordinary
    /// caves are a corridor a player digs their own way through; a cavern
    /// is the one underground find that isn't a resource — the room itself
    /// is the discovery, the same job a ruin does on the surface. Confined
    /// to the band ore already lives in, so breaking into one is also
    /// breaking into an open wall of whatever that depth was already
    /// hiding, ore or lava both.
    private func isCavern(x: Int, y: Int, z: Int) -> Bool {
        guard y > 8, y < 50 else { return false }
        return inVein(x: x, y: y, z: z, cellSize: 48, chance: 0.18, radius: 9, seedOffset: 1000)
    }

    /// True where `(x, y, z)` falls inside a vein: the world is divided
    /// into a coarse grid of `cellSize`-wide cubes, each of which either
    /// has no vein at all (probability `1 - chance`) or has exactly one,
    /// centred at a point hashed from the cell's own coordinates. A cell
    /// is judged in isolation — no neighbour is consulted — so a vein
    /// never straddles a cell boundary; the grid is coarse enough next to
    /// `radius` that the seam this leaves is not worth the extra hashing
    /// a neighbour check would cost.
    ///
    /// This is what turns ore from a fact about one block into a fact
    /// about a pocket of them: the old version rolled every cell on its
    /// own, so finding a piece of coal said nothing about whether there
    /// was more next to it. A vein makes "dig around this" a real
    /// question with a real answer, which is the entire difference
    /// between mining and repeatedly checking a number.
    private func inVein(x: Int, y: Int, z: Int, cellSize: Int, chance: Double, radius: Double, seedOffset: UInt64) -> Bool {
        let veinSeed = seed &+ seedOffset
        let cellX = WorldGenerator.floorDivide(x, by: cellSize)
        let cellY = WorldGenerator.floorDivide(y, by: cellSize)
        let cellZ = WorldGenerator.floorDivide(z, by: cellSize)
        guard latticeHash(cellX &* 92821 &+ cellY, cellZ &* 689287 &+ cellY &* 31, seed: veinSeed) < chance else {
            return false
        }
        let cx = Double(cellX * cellSize) + latticeHash(cellX, cellZ &* 13 &+ cellY, seed: veinSeed &+ 1) * Double(cellSize)
        let cy = Double(cellY * cellSize) + latticeHash(cellY, cellX &* 7 &+ cellZ, seed: veinSeed &+ 2) * Double(cellSize)
        let cz = Double(cellZ * cellSize) + latticeHash(cellZ, cellY &* 5 &+ cellX, seed: veinSeed &+ 3) * Double(cellSize)
        let dx = Double(x) - cx, dy = Double(y) - cy, dz = Double(z) - cz
        return dx * dx + dy * dy + dz * dz < radius * radius
    }

    /// Ore placement: veins gated on depth bands that mirror the original's
    /// own distribution — coal high and common, diamond deep and rare.
    /// Radii and chances are picked so each type's overall share of its
    /// depth band lands close to what the old flat roll gave it; what
    /// changes is that share now arrives in pockets of several blocks
    /// each rather than as single blocks scattered independently.
    private func ore(x: Int, y: Int, z: Int) -> BlockType? {
        if y < 16, inVein(x: x, y: y, z: z, cellSize: 12, chance: 0.22, radius: 1.3, seedOffset: 80) {
            return .diamondOre
        }
        if y < 32, inVein(x: x, y: y, z: z, cellSize: 10, chance: 0.30, radius: 1.5, seedOffset: 84) {
            return .goldOre
        }
        if y < 48, inVein(x: x, y: y, z: z, cellSize: 8, chance: 0.35, radius: 1.8, seedOffset: 88) {
            return .ironOre
        }
        if y < 88, inVein(x: x, y: y, z: z, cellSize: 8, chance: 0.5, radius: 2.2, seedOffset: 92) {
            return .coalOre
        }
        return nil
    }

    /// Fills a freshly-allocated chunk with terrain, water, ores and caves.
    /// Trees are a separate pass because they cross chunk borders.
    func generate(_ chunk: Chunk) {
        for lz in 0..<Chunk.depth {
            for lx in 0..<Chunk.width {
                let wx = chunk.originX + lx
                let wz = chunk.originZ + lz
                let height = surfaceHeight(x: wx, z: wz)
                let columnBiome = biome(x: wx, z: wz)

                for y in 0...height {
                    var type: BlockType

                    if y <= 1 {
                        type = .bedrock
                    } else if y <= 4 && latticeHash(wx, wz &* 31 &+ y, seed: seed &+ 9) < Double(5 - y) * 0.28 {
                        type = .bedrock
                    } else if y == height {
                        type = surfaceBlock(for: columnBiome, height: height)
                    } else if y > height - 4 {
                        type = subsurfaceBlock(for: columnBiome)
                    } else {
                        type = ore(x: wx, y: y, z: wz) ?? .stone
                    }

                    // Caves cut everything but bedrock, and never open the
                    // seabed into an air pocket under the ocean. A cavern is
                    // the same cut with a different shape, tried second so
                    // the cell isCave already claimed skips the extra hash.
                    if type != .bedrock, isCave(x: wx, y: y, z: wz) || isCavern(x: wx, y: y, z: wz) {
                        if height >= WorldGenerator.seaLevel || y < height - 2 {
                            type = .air
                            // The lower band a cave can reach — the same
                            // depth the deepest ore already lives at —
                            // sometimes fills with lava instead of standing
                            // open. `inVein` rather than a bare roll per
                            // cell, so a pocket is a lake with an edge
                            // rather than single glowing cells sprinkled
                            // through the dark: the risk and the reward of
                            // digging this deep are the same trip.
                            if y < 16, inVein(
                                x: wx, y: y, z: wz, cellSize: 14, chance: 0.5, radius: 3.5, seedOffset: 900
                            ) {
                                type = .lava
                            }
                        }
                    }

                    chunk.setBlock(localX: lx, y: y, localZ: lz, to: type)
                }

                // Fill everything from the surface up to sea level with water.
                if height < WorldGenerator.seaLevel {
                    for y in (height + 1)...WorldGenerator.seaLevel {
                        chunk.setBlock(localX: lx, y: y, localZ: lz, to: .water)
                    }
                }
            }
        }
    }

    private func surfaceBlock(for biome: Biome, height: Int) -> BlockType {
        switch biome {
        case .ocean: return .sand
        case .beach: return .sand
        case .desert: return .sand
        case .snowy: return .snow
        case .mountains: return height > WorldGenerator.seaLevel + 42 ? .stone : .grass
        case .plains, .forest: return .grass
        }
    }

    private func subsurfaceBlock(for biome: Biome) -> BlockType {
        switch biome {
        case .ocean, .beach: return .sand
        case .desert: return .sandstone
        case .mountains: return .stone
        case .snowy, .plains, .forest: return .dirt
        }
    }

    // MARK: - Trees

    /// Every block this chunk's trees put into the world, in world
    /// coordinates — trunk and canopy together, canopies included where
    /// they spill into a neighbour.
    ///
    /// Pure: it reads nothing but the seed and the chunk's coordinate, so
    /// `World` runs it on the generation queue alongside the terrain fill
    /// rather than on the frame the chunk arrives. That matters because it
    /// is the expensive half of planting a tree — a biome (and so a
    /// surface height) for all 256 columns, plus a 7×7 local-maximum roll
    /// around every candidate trunk.
    func decorationBlocks(in chunk: Chunk) -> [BlockPlacement] {
        // Ground cover first, trees second. Both write to the cell just
        // above the surface, and the caller applies these in order, so this
        // is what lets a trunk stand where a tuft of grass was rolled
        // rather than sprouting out of one.
        var placements = groundCover(in: chunk)
        for tree in treePositions(in: chunk) {
            placements.append(contentsOf: treeBlocks(
                atX: tree.x, groundY: tree.y, z: tree.z, species: tree.species
            ))
        }
        // Ruins last, so a ruin never generates hidden under a canopy that
        // happened to land on the same ground.
        placements.append(contentsOf: ruinBlocks(in: chunk))
        // Vaults live deep underground, nowhere near a surface canopy or a
        // ruin's own footprint, so order relative to either doesn't matter
        // — they're appended last purely to keep this list read top to
        // bottom in the same order the file does.
        placements.append(contentsOf: vaultBlocks(in: chunk))
        // Spires stand back on the surface, tall enough to reach into a
        // neighbour's canopy — appended after it for the same reason a ruin
        // is: so the shaft is what a tree loses to, not the other way round.
        placements.append(contentsOf: spireBlocks(in: chunk))
        // Wrecks sit on the ocean floor, nowhere near a canopy, a ruin's
        // footprint or a spire's — appended last purely to keep this list
        // read top to bottom in the same order the file does.
        placements.append(contentsOf: wreckBlocks(in: chunk))
        return placements
    }

    /// How much farther a landmark's own haul has ramped at this anchor —
    /// the same distance-from-spawn curve `FizzlerManager.dangerScale`
    /// already uses to spawn more danger and cost more per hit, reused
    /// here so a chest five hundred blocks out is not identical to one at
    /// the doorstep. Every one of `rollRuinLoot`, `rollVaultLoot`,
    /// `rollSpireLoot` and `rollWreckLoot` shared this gap until now: risk
    /// scaled with distance and reward never answered it, so "danger" only
    /// ever meant a worse trip, never a better one at the far end of it.
    ///
    /// Distance from the origin stands in for distance from spawn:
    /// `World.spawnPosition()` always lands within a couple hundred blocks
    /// of (0, 0), well inside the ramp's own five-hundred-block span, and
    /// generation code has no access to the resolved runtime spawn point
    /// `FizzlerManager` reads directly off `World`.
    ///
    /// Three-dimensional for the same reason `dangerScale` itself is: a
    /// vault's whole anchor is a real point in space, not a column resolved
    /// against the surface, so a shell sitting almost directly under spawn
    /// horizontally was rolling doorstep loot regardless of how many blocks
    /// of stone actually stood between the chest and daylight. `anchorY`
    /// defaults to `seaLevel` for ruin/spire/wreck, whose anchors are
    /// columns rather than points and already sit at the surface, so this
    /// changes nothing for them.
    /// Not `private` — same reason `FizzlerManager.dangerScale` and
    /// `SkeletonManager.shotDamage` aren't: a check needs to point straight
    /// at the ramp itself rather than infer it from noisy random rolls.
    func lootScale(anchorX: Int, anchorY: Int = WorldGenerator.seaLevel, anchorZ: Int) -> Double {
        let dx = Double(anchorX), dy = Double(anchorY - WorldGenerator.seaLevel), dz = Double(anchorZ)
        let distance = (dx * dx + dy * dy + dz * dz).squareRoot()
        return FizzlerManager.dangerScale(distanceFromSpawn: CGFloat(distance))
    }

    // MARK: - Ruins
    //
    // The one thing in a freshly generated world worth walking toward on
    // purpose rather than past. A player cannot mine or build their way to
    // curiosity; the terrain has to put something out there that was not
    // explained to them. This is the smallest version of that idea: no new
    // block format, no structure file — three or four broken pillars from
    // the pyramid's own palette, one of them capped in gold or diamond
    // exactly where `lightEmission` already makes those blocks glint in
    // the dark, and a chest beside them a player can actually carry away
    // regardless of what tool they showed up with. A ruin at night is
    // found by its glow before it is found by its shape, which is the
    // difference between a landmark and a waypoint marker: nothing on the
    // map says it is there.
    //
    /// One region cell, in blocks. Chosen as an exact multiple of the
    /// chunk width so a region's bounds always land on chunk bounds too —
    /// which is what lets a candidate be resolved once per chunk rather
    /// than swept from a neighbourhood of them.
    private static let ruinRegionSize = Chunk.width * 3

    /// The one candidate site a region offers, or nil if this region rolled
    /// against having one at all. Roughly one region in five does, which
    /// over a `48`-block region is on the close order of the original's own
    /// stronghold spacing — rare enough that finding one is worth
    /// mentioning, common enough that a half hour of walking finds one.
    func ruinAnchor(regionX: Int, regionZ: Int) -> (x: Int, z: Int)? {
        guard latticeHash(regionX, regionZ, seed: seed &+ 771) < 0.22 else { return nil }
        let localX = Int(latticeHash(regionX, regionZ, seed: seed &+ 772) * Double(WorldGenerator.ruinRegionSize))
        let localZ = Int(latticeHash(regionX, regionZ, seed: seed &+ 773) * Double(WorldGenerator.ruinRegionSize))
        return (regionX * WorldGenerator.ruinRegionSize + localX, regionZ * WorldGenerator.ruinRegionSize + localZ)
    }

    /// The farthest a pillar or a piece of rubble ever sits from its
    /// ruin's anchor — the offsets in `ruin(atX:z:)` never reach past 2.
    private static let ruinFootprint = 2

    /// Every ruin anchor that could possibly reach a column in this chunk:
    /// its own region's, plus the eight surrounding it. A safe superset
    /// rather than an exact one — a region is 48 blocks on a side and a
    /// ruin never reaches more than two cells from its anchor, so the
    /// extra regions checked almost never have their anchor land close
    /// enough to matter, and the one case they exist for is a ruin whose
    /// anchor fell just across the region line from a column this chunk
    /// is about to plant grass on.
    private func nearbyRuinAnchors(for chunk: Chunk) -> [(x: Int, z: Int)] {
        nearbyRuinAnchors(x: chunk.originX, z: chunk.originZ)
    }

    /// Every ruin anchor that could possibly reach a raw coordinate — the
    /// same neighbourhood `nearbyRuinAnchors(for:)` sweeps for a chunk, but
    /// callable from a bare position. What lets a chest's contents be
    /// recomputed from where it stands rather than remembered from when it
    /// was placed.
    private func nearbyRuinAnchors(x: Int, z: Int) -> [(x: Int, z: Int)] {
        let regionX = WorldGenerator.floorDivide(x, by: WorldGenerator.ruinRegionSize)
        let regionZ = WorldGenerator.floorDivide(z, by: WorldGenerator.ruinRegionSize)
        var anchors: [(x: Int, z: Int)] = []
        for dz in -1...1 {
            for dx in -1...1 {
                if let anchor = ruinAnchor(regionX: regionX + dx, regionZ: regionZ + dz) {
                    anchors.append(anchor)
                }
            }
        }
        return anchors
    }

    /// True where a ruin has already claimed the ground — the pillars and
    /// the rubble both replace it, so nothing ground cover plants there
    /// would have anything real to root in. Checked against the anchor
    /// rather than against the ruin's actual blocks, because ground cover
    /// for a neighbouring chunk runs before that ruin's own chunk has
    /// necessarily generated at all: a placement list has nothing to
    /// check yet, but an anchor's position is pure arithmetic on the seed.
    ///
    /// `margin` widens the claim past the ruin's own footprint for a
    /// caller whose own structure isn't a single cell either — see
    /// `spireSiteIsValid`, the one other landmark built entirely on dry
    /// land, where a shaft's own half-width has to clear the ruin's
    /// rubble, not just its anchor point.
    func columnIsClaimedByRuin(
        _ x: Int, _ z: Int, anchors: [(x: Int, z: Int)], margin: Int = WorldGenerator.ruinFootprint
    ) -> Bool {
        anchors.contains {
            abs($0.x - x) <= margin && abs($0.z - z) <= margin
        }
    }

    /// Rounds toward negative infinity rather than zero, the same reason
    /// `World.floorDivide` exists: a region west or south of the origin
    /// has to resolve to the region actually under it, not to the one a
    /// truncating divide would round it toward.
    private static func floorDivide(_ value: Int, by divisor: Int) -> Int {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    /// This chunk's ruin, if the region it sits in rolled one and the roll
    /// landed inside this chunk specifically rather than one of the other
    /// eight chunks sharing the region.
    private func ruinBlocks(in chunk: Chunk) -> [BlockPlacement] {
        let regionX = WorldGenerator.floorDivide(chunk.originX, by: WorldGenerator.ruinRegionSize)
        let regionZ = WorldGenerator.floorDivide(chunk.originZ, by: WorldGenerator.ruinRegionSize)
        guard let anchor = ruinAnchor(regionX: regionX, regionZ: regionZ) else { return [] }
        guard anchor.x >= chunk.originX, anchor.x < chunk.originX + Chunk.width,
              anchor.z >= chunk.originZ, anchor.z < chunk.originZ + Chunk.depth
        else { return [] }
        guard ruinSiteIsValid(atX: anchor.x, z: anchor.z) else { return [] }
        return ruin(atX: anchor.x, z: anchor.z)
    }

    /// Not at sea, not so high the snow line makes a ruin unreachable, and
    /// not over a cave mouth the terrain pass already hollowed — the same
    /// three guards the ground cover pass uses, for the same reasons. Nor
    /// inside another ruin's own footprint: nothing coordinates two
    /// independent per-region rolls, so a ruin near one edge of its region
    /// and a second ruin near the matching edge of the region next door
    /// occasionally land close enough for their rubble to interpenetrate
    /// — the same class of collision `spireSiteIsValid` already guards
    /// against between a spire and a ruin, just between two ruins instead.
    /// Shared between actually placing a ruin and recomputing whether one
    /// stands at a given anchor later, so the two can never disagree about
    /// which anchors a ruin actually generated at.
    func ruinSiteIsValid(atX x: Int, z: Int) -> Bool {
        let height = surfaceHeight(x: x, z: z)
        guard height > WorldGenerator.seaLevel + 1, height < WorldGenerator.highestSnowCap else { return false }
        let siteBiome = biome(x: x, z: z)
        guard siteBiome != .ocean, siteBiome != .beach else { return false }
        guard !isCave(x: x, y: height, z: z) else { return false }
        guard !ruinYieldsToNeighbor(atX: x, z: z) else { return false }
        return true
    }

    /// True where a nearer-to-canonical neighbouring region also rolled a
    /// ruin close enough to overlap this one. Both ruins run the identical
    /// check against each other, so the outcome has to be decided by
    /// something both sides agree on without either having to have gone
    /// first — the region coordinate itself, lexicographically, is that
    /// tiebreak: whichever region sorts first keeps its ruin, the other
    /// yields. `2 * ruinFootprint`, not just one, because it's the sum of
    /// both ruins' rubble reaching toward each other that has to clear.
    private func ruinYieldsToNeighbor(atX x: Int, z: Int) -> Bool {
        let regionX = WorldGenerator.floorDivide(x, by: WorldGenerator.ruinRegionSize)
        let regionZ = WorldGenerator.floorDivide(z, by: WorldGenerator.ruinRegionSize)
        for dz in -1...1 {
            for dx in -1...1 {
                guard dx != 0 || dz != 0 else { continue }
                guard (regionX, regionZ) > (regionX + dx, regionZ + dz) else { continue }
                guard let other = ruinAnchor(regionX: regionX + dx, regionZ: regionZ + dz) else { continue }
                guard abs(other.x - x) <= WorldGenerator.ruinFootprint * 2,
                      abs(other.z - z) <= WorldGenerator.ruinFootprint * 2
                else { continue }
                return true
            }
        }
        return false
    }

    /// Fixed relative to the anchor, distinct from every pillar and rubble
    /// offset `ruin(atX:z:)` uses, so the chest never lands on top of
    /// either.
    private static let ruinChestOffset = (x: -1, z: 0)

    /// Where a ruin's loot chest stands, if the ground under it isn't
    /// ocean or beach — the same guard every other piece of a ruin's
    /// footprint checks against its own exact column, since the anchor's
    /// own biome check two blocks doesn't reach this far either.
    private func ruinChestPosition(atX x: Int, z: Int) -> (x: Int, y: Int, z: Int)? {
        let chestX = x + WorldGenerator.ruinChestOffset.x
        let chestZ = z + WorldGenerator.ruinChestOffset.z
        let chestBiome = biome(x: chestX, z: chestZ)
        guard chestBiome != .ocean, chestBiome != .beach else { return nil }
        return (chestX, surfaceHeight(x: chestX, z: chestZ), chestZ)
    }

    /// What a player's bag gains the first time they open the chest beside
    /// a ruin's treasure pillar — a handful of stacks rolled from a small
    /// pool, deterministic from the anchor and the world seed the same way
    /// the treasure cap's own material is chosen. Nil for every chest that
    /// isn't one of these: nothing about a hand-placed chest's position
    /// agrees with this arithmetic by chance.
    ///
    /// The pool leans toward iron gear on purpose: the cap beside it is
    /// gold or diamond block, both of which need an iron pickaxe to break,
    /// so the ruin that shows a player treasure they cannot yet take is
    /// also, sometimes, the ruin that hands them the tool to come back for
    /// it.
    func ruinLoot(atX x: Int, y: Int, z: Int) -> [(item: ItemType, count: Int)]? {
        for anchor in nearbyRuinAnchors(x: x, z: z) {
            guard ruinSiteIsValid(atX: anchor.x, z: anchor.z) else { continue }
            guard let site = ruinChestPosition(atX: anchor.x, z: anchor.z) else { continue }
            guard site.x == x, site.y == y, site.z == z else { continue }
            return rollRuinLoot(anchorX: anchor.x, anchorZ: anchor.z)
        }
        return nil
    }

    private static let ruinLootPool: [(item: ItemType, minCount: Int, maxCount: Int)] = [
        (.ironIngot, 1, 3),
        (.goldIngot, 1, 2),
        (.diamond, 1, 1),
        (.coal, 2, 4),
        (.torch, 3, 6),
        (.cookedBeef, 1, 2),
        (.cookedChicken, 1, 2),
        (.ironPickaxe, 1, 1),
        (.ironSword, 1, 1),
    ]

    private func rollRuinLoot(anchorX: Int, anchorZ: Int) -> [(item: ItemType, count: Int)] {
        let pool = WorldGenerator.ruinLootPool
        let baseSlots = 2 + Int(latticeHash(anchorX, anchorZ, seed: seed &+ 900) * 3)
        let slotCount = max(1, Int((Double(baseSlots) * lootScale(anchorX: anchorX, anchorZ: anchorZ)).rounded()))
        var rolled: [(item: ItemType, count: Int)] = []
        for slot in 0..<slotCount {
            let offset = UInt64(slot) &* 2
            let entry = pool[
                min(
                    Int(latticeHash(anchorX, anchorZ, seed: seed &+ 901 &+ offset) * Double(pool.count)),
                    pool.count - 1
                )
            ]
            let span = entry.maxCount - entry.minCount + 1
            let count = entry.minCount
                + Int(latticeHash(anchorX, anchorZ, seed: seed &+ 902 &+ offset) * Double(span))
            rolled.append((entry.item, count))
        }
        return rolled
    }

    /// Three or four broken pillars in a loose scatter, heights rolled
    /// independently so the silhouette reads as fallen rather than built —
    /// a colonnade still standing would be architecture, not a ruin. One
    /// pillar, chosen per site, is capped in treasure instead of a
    /// capital; the rest keep the capital the standing columns wear
    /// elsewhere, so the one that matters has to be picked out from
    /// pillars that otherwise look exactly like it.
    ///
    /// Each pillar samples its *own* ground rather than the site's, the
    /// same reasoning `treePositions` never has to face because a trunk is
    /// one column: on anything but dead-flat terrain, a ring of pillars a
    /// couple of blocks apart planted at one shared height either floats
    /// or buries itself the moment the ground so much as tilts.
    private func ruin(atX x: Int, z: Int) -> [BlockPlacement] {
        var blocks: [BlockPlacement] = []
        let offsets = [(0, 0), (2, 1), (-2, 2), (1, -2)]
        let treasureIndex = Int(latticeHash(x, z, seed: seed &+ 774) * Double(offsets.count))
        let treasureIsGold = latticeHash(x, z, seed: seed &+ 775) < 0.5

        for (index, offset) in offsets.enumerated() {
            let px = x + offset.0, pz = z + offset.1
            // The anchor's own biome check doesn't reach this far — an
            // offset two blocks out can cross onto sand or below the tide
            // line even when the site itself is planted well inland.
            let pillarBiome = biome(x: px, z: pz)
            guard pillarBiome != .ocean, pillarBiome != .beach else { continue }
            let base = surfaceHeight(x: px, z: pz)
            let pillarHeight = 1 + Int(latticeHash(px, pz, seed: seed &+ 776) * 4)
            for dy in 0..<pillarHeight {
                blocks.append(BlockPlacement(x: px, y: base + dy, z: pz, block: .sandstonePillar))
            }
            let cap: BlockType = index == treasureIndex
                ? (treasureIsGold ? .goldBlock : .diamondBlock)
                : .pillarCapital
            blocks.append(BlockPlacement(x: px, y: base + pillarHeight, z: pz, block: cap))
        }

        // The one thing here a player can take home regardless of what
        // tool they're carrying — the treasure cap needs iron and reads
        // from across the site, but not everyone finding a ruin has iron
        // yet.
        if let chestSite = ruinChestPosition(atX: x, z: z) {
            blocks.append(BlockPlacement(x: chestSite.x, y: chestSite.y, z: chestSite.z, block: .chest))
        }

        // Rubble scattered round the base — sandstone the collapse left
        // lying rather than standing. `columnIsClaimedByRuin` already kept
        // ground cover off every one of these columns and the pillars'
        // both, so there is nothing left over here to clear away.
        for (dx, dz) in [(1, 1), (-1, -1), (1, -1), (-1, 1), (0, 2), (2, 0), (-2, -1)] {
            guard latticeHash(x + dx, z + dz, seed: seed &+ 777) < 0.6 else { continue }
            let rubbleBiome = biome(x: x + dx, z: z + dz)
            guard rubbleBiome != .ocean, rubbleBiome != .beach else { continue }
            let rubbleY = surfaceHeight(x: x + dx, z: z + dz)
            blocks.append(BlockPlacement(x: x + dx, y: rubbleY, z: z + dz, block: .sandstoneCarved))
        }

        // A door and the lever that opens it — the network's own two
        // consumers, found already wired rather than built by hand for the
        // first time. Gates nothing: the lever isn't reached by anything
        // but this one door, and the chest is its own separate pillar with
        // nothing standing in front of it, so nobody has to understand a
        // lever to leave with what a ruin already promises. Whoever tries
        // it anyway gets to watch a door no one told them how to open
        // swing on its own.
        let doorOffset = (dx: 0, dz: -2)
        let doorX = x + doorOffset.dx, doorZ = z + doorOffset.dz
        let doorBiome = biome(x: doorX, z: doorZ)
        if doorBiome != .ocean, doorBiome != .beach {
            let doorBase = surfaceHeight(x: doorX, z: doorZ)
            let facing: BlockFacing = latticeHash(x, z, seed: seed &+ 778) < 0.5 ? .north : .east
            blocks.append(BlockPlacement(
                x: doorX, y: doorBase, z: doorZ, block: .oakDoor(.lower, facing: facing, open: false)
            ))
            blocks.append(BlockPlacement(
                x: doorX, y: doorBase + 1, z: doorZ, block: .oakDoor(.upper, facing: facing, open: false)
            ))
        }
        // One cell closer to the anchor than the door, so it reads as
        // belonging to it without ever sharing a column — own biome guard,
        // same as every other piece of this ruin's footprint.
        let leverZ = z - 1
        let leverBiome = biome(x: x, z: leverZ)
        if leverBiome != .ocean, leverBiome != .beach {
            blocks.append(BlockPlacement(x: x, y: surfaceHeight(x: x, z: leverZ), z: leverZ, block: .leverOff))
        }
        return blocks
    }

    // MARK: - Vaults
    //
    // A ruin is found by luck and opened by anyone who gets there; nothing
    // in the game has ever asked a player to have the *right gear* to reach
    // something, only enough patience. Obsidian has been the one block
    // whose minimum tier costs real minutes rather than a lost drop since
    // the day water first met lava — 45.0 hardness against a wooden
    // pickaxe's penalised 0.4 speed is two minutes a block bare stone
    // never asks for — and nothing was ever built to actually spend that.
    // This is the smallest version that does: a small sealed room, deep in
    // the same band diamond and lava already share, its entire shell
    // forced to obsidian regardless of what the cave pass carved through
    // that space first — so there is no soft wall to dig around, only the
    // one hard one every face of the room presents. No new block, no new
    // item, no new mechanic: the first place in the world where showing up
    // with a diamond pickaxe is minutes faster than showing up without
    // one, on a wall built entirely out of a rule the game already had.
    /// One region cell, in blocks — far coarser than a ruin's, so a vault
    /// is the rarer of the two landmarks by a wide margin.
    private static let vaultRegionSize = Chunk.width * 8

    /// The one candidate site a region offers, y included: a vault's depth
    /// matters as much as its column, so the anchor is a real point in
    /// space rather than a column resolved against the surface the way a
    /// ruin's is.
    private func vaultAnchor(regionX: Int, regionZ: Int) -> (x: Int, y: Int, z: Int)? {
        guard latticeHash(regionX, regionZ, seed: seed &+ 950) < 0.12 else { return nil }
        let localX = Int(latticeHash(regionX, regionZ, seed: seed &+ 951) * Double(WorldGenerator.vaultRegionSize))
        let localZ = Int(latticeHash(regionX, regionZ, seed: seed &+ 952) * Double(WorldGenerator.vaultRegionSize))
        // 6...15: the same deep band ore and lava already share, and
        // comfortably clear of the probabilistic bedrock band at y <= 4.
        let y = 6 + Int(latticeHash(regionX, regionZ, seed: seed &+ 953) * 10)
        return (
            regionX * WorldGenerator.vaultRegionSize + localX, y,
            regionZ * WorldGenerator.vaultRegionSize + localZ
        )
    }

    /// Every vault anchor that could possibly reach a raw coordinate — the
    /// same 3×3 region sweep `nearbyRuinAnchors` runs, needed for the same
    /// reason: a vault's shell can land just across a region line from the
    /// chunk asking about it.
    private func nearbyVaultAnchors(x: Int, z: Int) -> [(x: Int, y: Int, z: Int)] {
        let regionX = WorldGenerator.floorDivide(x, by: WorldGenerator.vaultRegionSize)
        let regionZ = WorldGenerator.floorDivide(z, by: WorldGenerator.vaultRegionSize)
        var anchors: [(x: Int, y: Int, z: Int)] = []
        for dz in -1...1 {
            for dx in -1...1 {
                if let anchor = vaultAnchor(regionX: regionX + dx, regionZ: regionZ + dz) {
                    anchors.append(anchor)
                }
            }
        }
        return anchors
    }

    /// This chunk's vault, if the region it sits in rolled one and the
    /// roll landed inside this chunk specifically.
    private func vaultBlocks(in chunk: Chunk) -> [BlockPlacement] {
        let regionX = WorldGenerator.floorDivide(chunk.originX, by: WorldGenerator.vaultRegionSize)
        let regionZ = WorldGenerator.floorDivide(chunk.originZ, by: WorldGenerator.vaultRegionSize)
        guard let anchor = vaultAnchor(regionX: regionX, regionZ: regionZ) else { return [] }
        guard anchor.x >= chunk.originX, anchor.x < chunk.originX + Chunk.width,
              anchor.z >= chunk.originZ, anchor.z < chunk.originZ + Chunk.depth
        else { return [] }
        return vault(atX: anchor.x, y: anchor.y, z: anchor.z)
    }

    /// A 3×4×3 box of obsidian around one hollow: the chest itself at the
    /// centre, one cell of headroom above it. Every other cell in the box
    /// is forced to obsidian — forced, not merely placed over stone,
    /// because the cave pass runs first and a vault that only sealed
    /// whatever wasn't already air would occasionally hand a player a
    /// door for free.
    private func vault(atX x: Int, y: Int, z: Int) -> [BlockPlacement] {
        var blocks: [BlockPlacement] = []
        for dy in -1...2 {
            for dz in -1...1 {
                for dx in -1...1 {
                    let block: BlockType
                    if dx == 0, dz == 0, dy == 0 {
                        block = .chest
                    } else if dx == 0, dz == 0, dy == 1 {
                        block = .air
                    } else {
                        block = .obsidian
                    }
                    blocks.append(BlockPlacement(x: x + dx, y: y + dy, z: z + dz, block: block))
                }
            }
        }
        return blocks
    }

    // Raw materials only, deliberately: diamond ore itself needs no more
    // than an iron pickaxe, so a pool of finished diamond tools would let
    // a patient wooden pickaxe — 0.4 speed against 45.0 hardness is slow,
    // not impassable — walk straight past the iron tier those tools
    // normally cost, rather than merely saving the trip. A denser haul of
    // the same materials ruins already hand out keeps the reward matched
    // to what the wall actually asks for: minutes of digging, not a
    // skipped tier.
    private static let vaultLootPool: [(item: ItemType, minCount: Int, maxCount: Int)] = [
        (.diamond, 3, 6),
        (.goldIngot, 3, 5),
        (.ironIngot, 3, 5),
    ]

    /// What a player's bag gains the first time they reach a vault's
    /// chest — rolled deterministically from the anchor, the same scheme
    /// `rollRuinLoot` uses, but a denser haul befitting the wall it sits
    /// behind.
    func vaultLoot(atX x: Int, y: Int, z: Int) -> [(item: ItemType, count: Int)]? {
        for anchor in nearbyVaultAnchors(x: x, z: z) {
            guard anchor.x == x, anchor.y == y, anchor.z == z else { continue }
            return rollVaultLoot(anchorX: anchor.x, anchorY: anchor.y, anchorZ: anchor.z)
        }
        return nil
    }

    private func rollVaultLoot(anchorX: Int, anchorY: Int, anchorZ: Int) -> [(item: ItemType, count: Int)] {
        let pool = WorldGenerator.vaultLootPool
        let baseSlots = 3 + Int(latticeHash(anchorX, anchorZ, seed: seed &+ 960) * 2)
        let slotCount = max(
            1,
            Int((Double(baseSlots) * lootScale(anchorX: anchorX, anchorY: anchorY, anchorZ: anchorZ)).rounded())
        )
        var rolled: [(item: ItemType, count: Int)] = []
        for slot in 0..<slotCount {
            let offset = UInt64(slot) &* 2
            let entry = pool[
                min(
                    Int(latticeHash(anchorX, anchorZ, seed: seed &+ 961 &+ offset) * Double(pool.count)),
                    pool.count - 1
                )
            ]
            let span = entry.maxCount - entry.minCount + 1
            let count = entry.minCount
                + Int(latticeHash(anchorX, anchorZ, seed: seed &+ 962 &+ offset) * Double(span))
            rolled.append((entry.item, count))
        }
        return rolled
    }

    // MARK: - Spires
    //
    // Every landmark so far is found by luck, up close: a ruin by walking
    // over it, a vault by digging into it, a cavern by breaking through to
    // it. Nothing in the world has ever pulled a player from far away — the
    // "worth traveling toward" half of curiosity, not just the "worth
    // stopping for" half. A spire is the smallest version of that: a plain
    // stone shaft, the same block a mountain already is, rising far above
    // whatever ground it stands on and capped in a light a `seaLantern`
    // already knows how to cast. No new block, no new item — height and an
    // existing light source are the whole trick, the same two things that
    // make a real lighthouse work. It does not wait for an actual mountain
    // to stand on: this generator's own peaks barely clear the hills around
    // them (checked directly — the tallest point over several thousand
    // blocks around spawn on the default seed lands in the high 90s, a
    // handful of blocks past the `.mountains` cutoff), so gating a rare
    // landmark on one would have meant almost nobody ever finds one. The
    // shaft supplies its own height regardless of what it grows out of.
    /// One region cell, in blocks — coarser than even a vault's, since the
    /// whole point is a landmark rare enough that reaching one means having
    /// actually gone somewhere.
    private static let spireRegionSize = Chunk.width * 20

    /// The one candidate site a region offers, or nil if it rolled against
    /// having one — a coarse region and a middling chance together land
    /// spires roughly every few regions, sparse enough to be a destination.
    private func spireAnchor(regionX: Int, regionZ: Int) -> (x: Int, z: Int)? {
        guard latticeHash(regionX, regionZ, seed: seed &+ 1100) < 0.35 else { return nil }
        let localX = Int(latticeHash(regionX, regionZ, seed: seed &+ 1101) * Double(WorldGenerator.spireRegionSize))
        let localZ = Int(latticeHash(regionX, regionZ, seed: seed &+ 1102) * Double(WorldGenerator.spireRegionSize))
        return (regionX * WorldGenerator.spireRegionSize + localX, regionZ * WorldGenerator.spireRegionSize + localZ)
    }

    /// Every spire anchor that could possibly reach a raw coordinate — the
    /// same 3×3 region sweep `nearbyRuinAnchors` runs, for the same reason.
    private func nearbySpireAnchors(x: Int, z: Int) -> [(x: Int, z: Int)] {
        let regionX = WorldGenerator.floorDivide(x, by: WorldGenerator.spireRegionSize)
        let regionZ = WorldGenerator.floorDivide(z, by: WorldGenerator.spireRegionSize)
        var anchors: [(x: Int, z: Int)] = []
        for dz in -1...1 {
            for dx in -1...1 {
                if let anchor = spireAnchor(regionX: regionX + dx, regionZ: regionZ + dz) {
                    anchors.append(anchor)
                }
            }
        }
        return anchors
    }

    /// Dry land clear of the tide line, not a cave mouth the terrain pass
    /// already hollowed at the surface — the same two guards
    /// `ruinSiteIsValid` checks, plus a floor a few blocks above sea level
    /// so a shaft never starts out ankle-deep in the shallows. Shared
    /// between placing a spire and recomputing whether one stands at a
    /// given anchor later, the same reason `ruinSiteIsValid` is shared, so
    /// the two can never disagree.
    ///
    /// A ruin and a spire are the only two landmarks that ever stand on
    /// the same dry ground, and nothing coordinated their two independent
    /// rolls — a spire's region is a hundred times a ruin's, but nothing
    /// stopped one from landing close enough to a ruin's rubble that the
    /// shaft would have risen straight out of someone else's chest.
    /// `columnIsClaimedByRuin` already exists for exactly this claim,
    /// against ground cover; a spire is not a single cell either, so it
    /// gets the same margin widened by its own half-width.
    func spireSiteIsValid(atX x: Int, z: Int) -> Bool {
        let siteBiome = biome(x: x, z: z)
        guard siteBiome != .ocean, siteBiome != .beach else { return false }
        let height = surfaceHeight(x: x, z: z)
        guard height > WorldGenerator.seaLevel + 4, height < WorldGenerator.highestSnowCap else { return false }
        guard !isCave(x: x, y: height, z: z) else { return false }
        let ruinAnchors = nearbyRuinAnchors(x: x, z: z)
        guard !columnIsClaimedByRuin(x, z, anchors: ruinAnchors, margin: WorldGenerator.ruinFootprint + 1)
        else { return false }
        return true
    }

    /// How far the shaft rises above its own base — 45 to 65 blocks, tall
    /// enough that even a modest peak clears every ordinary hill around it.
    /// A pure function of the anchor so the loot lookup and the builder
    /// never have to agree on it by coincidence.
    private func spireRise(atX x: Int, z: Int) -> Int {
        45 + Int(latticeHash(x, z, seed: seed &+ 1103) * 21)
    }

    /// This chunk's spire, if the region it sits in rolled one and the roll
    /// landed inside this chunk specifically.
    private func spireBlocks(in chunk: Chunk) -> [BlockPlacement] {
        let regionX = WorldGenerator.floorDivide(chunk.originX, by: WorldGenerator.spireRegionSize)
        let regionZ = WorldGenerator.floorDivide(chunk.originZ, by: WorldGenerator.spireRegionSize)
        guard let anchor = spireAnchor(regionX: regionX, regionZ: regionZ) else { return [] }
        guard anchor.x >= chunk.originX, anchor.x < chunk.originX + Chunk.width,
              anchor.z >= chunk.originZ, anchor.z < chunk.originZ + Chunk.depth
        else { return [] }
        guard spireSiteIsValid(atX: anchor.x, z: anchor.z) else { return [] }
        return spire(atX: anchor.x, z: anchor.z)
    }

    /// Fixed relative to the anchor, distinct from the beacon at the centre
    /// of the platform, so the chest never lands under the light.
    private static let spireChestOffset = (x: 1, z: 0)

    /// A solid 3×3 shaft of stone from the ground to `spireRise` above it,
    /// capped with a lit block at the centre of the top and a chest beside
    /// it — the same "one thing anyone can carry off" a ruin's own chest
    /// promises, just paid for in a climb instead of a walk.
    private func spire(atX x: Int, z: Int) -> [BlockPlacement] {
        var blocks: [BlockPlacement] = []
        let base = surfaceHeight(x: x, z: z)
        let top = base + spireRise(atX: x, z: z)

        for dy in 0...(top - base) {
            for dz in -1...1 {
                for dx in -1...1 {
                    blocks.append(BlockPlacement(x: x + dx, y: base + dy, z: z + dz, block: .stone))
                }
            }
        }
        blocks.append(BlockPlacement(x: x, y: top + 1, z: z, block: .seaLantern))
        blocks.append(BlockPlacement(
            x: x + WorldGenerator.spireChestOffset.x, y: top + 1, z: z + WorldGenerator.spireChestOffset.z,
            block: .chest
        ))
        return blocks
    }

    // A denser haul than a ruin's, and no finished tools — the climb costs
    // no gear at all, only time and nerve, so nothing here should let it
    // skip a tier either.
    private static let spireLootPool: [(item: ItemType, minCount: Int, maxCount: Int)] = [
        (.goldIngot, 2, 4),
        (.diamond, 1, 2),
        (.ironIngot, 2, 4),
        (.torch, 4, 8),
    ]

    /// What a player's bag gains the first time they reach a spire's chest
    /// — rolled deterministically from the anchor, the same scheme
    /// `rollRuinLoot` and `rollVaultLoot` both use.
    func spireLoot(atX x: Int, y: Int, z: Int) -> [(item: ItemType, count: Int)]? {
        for anchor in nearbySpireAnchors(x: x, z: z) {
            guard spireSiteIsValid(atX: anchor.x, z: anchor.z) else { continue }
            let top = surfaceHeight(x: anchor.x, z: anchor.z) + spireRise(atX: anchor.x, z: anchor.z)
            guard x == anchor.x + WorldGenerator.spireChestOffset.x, y == top + 1,
                  z == anchor.z + WorldGenerator.spireChestOffset.z
            else { continue }
            return rollSpireLoot(anchorX: anchor.x, anchorZ: anchor.z)
        }
        return nil
    }

    private func rollSpireLoot(anchorX: Int, anchorZ: Int) -> [(item: ItemType, count: Int)] {
        let pool = WorldGenerator.spireLootPool
        let baseSlots = 2 + Int(latticeHash(anchorX, anchorZ, seed: seed &+ 1110) * 3)
        let slotCount = max(1, Int((Double(baseSlots) * lootScale(anchorX: anchorX, anchorZ: anchorZ)).rounded()))
        var rolled: [(item: ItemType, count: Int)] = []
        for slot in 0..<slotCount {
            let offset = UInt64(slot) &* 2
            let entry = pool[
                min(
                    Int(latticeHash(anchorX, anchorZ, seed: seed &+ 1111 &+ offset) * Double(pool.count)),
                    pool.count - 1
                )
            ]
            let span = entry.maxCount - entry.minCount + 1
            let count = entry.minCount
                + Int(latticeHash(anchorX, anchorZ, seed: seed &+ 1112 &+ offset) * Double(span))
            rolled.append((entry.item, count))
        }
        return rolled
    }

    // MARK: - Wrecks
    //
    // Every landmark so far costs patience (ruin, spire) or gear (vault) —
    // whatever the cost, it's paid before the player ever sees the chest,
    // and nothing left ticks while they decide what to do. A wreck costs
    // something that keeps counting down in real time instead: air.
    // `PlayerStats.maxAir` already gives a diver twenty seconds before it
    // starts costing health, and a deep-enough ocean floor is the one
    // place in the game that clock was always relevant and never asked
    // anything of. This just puts a reason to spend it there — a chest on
    // the sea bed, twelve-plus blocks under (checked directly against this
    // generator's own oceans: the deepest trenches within a couple
    // thousand blocks of spawn on the default seed bottom out only a
    // little past this), reachable on one held breath or by draining a
    // path first with buckets the way a patient player already can. No
    // new block, no new mechanic, and no gear shortcut past it either —
    // `PlayerStats` mitigates fall, blast, arrow and lava through a
    // chestplate on purpose, never drowning, so a diamond chestplate does
    // nothing here that patience and planning don't already do for free.
    /// One region cell, in blocks — rarer than a ruin, since a wreck also
    /// has to land somewhere deep enough to matter.
    private static let wreckRegionSize = Chunk.width * 6

    /// The one candidate site a region offers, or nil if it rolled against
    /// having one at all.
    private func wreckAnchor(regionX: Int, regionZ: Int) -> (x: Int, z: Int)? {
        guard latticeHash(regionX, regionZ, seed: seed &+ 1200) < 0.2 else { return nil }
        let localX = Int(latticeHash(regionX, regionZ, seed: seed &+ 1201) * Double(WorldGenerator.wreckRegionSize))
        let localZ = Int(latticeHash(regionX, regionZ, seed: seed &+ 1202) * Double(WorldGenerator.wreckRegionSize))
        return (regionX * WorldGenerator.wreckRegionSize + localX, regionZ * WorldGenerator.wreckRegionSize + localZ)
    }

    /// Every wreck anchor that could possibly reach a raw coordinate — the
    /// same 3×3 region sweep every other landmark runs, for the same
    /// reason.
    private func nearbyWreckAnchors(x: Int, z: Int) -> [(x: Int, z: Int)] {
        let regionX = WorldGenerator.floorDivide(x, by: WorldGenerator.wreckRegionSize)
        let regionZ = WorldGenerator.floorDivide(z, by: WorldGenerator.wreckRegionSize)
        var anchors: [(x: Int, z: Int)] = []
        for dz in -1...1 {
            for dx in -1...1 {
                if let anchor = wreckAnchor(regionX: regionX + dx, regionZ: regionZ + dz) {
                    anchors.append(anchor)
                }
            }
        }
        return anchors
    }

    /// Ocean floor, deep enough that reaching it and back is a genuine
    /// question against a held breath, and not a cave mouth the terrain
    /// pass already hollowed at the seabed. Shared between placing a wreck
    /// and recomputing whether one stands at a given anchor later, so the
    /// two can never disagree.
    private func wreckSiteIsValid(atX x: Int, z: Int) -> Bool {
        guard biome(x: x, z: z) == .ocean else { return false }
        let height = surfaceHeight(x: x, z: z)
        guard WorldGenerator.seaLevel - height >= 12 else { return false }
        guard !isCave(x: x, y: height, z: z) else { return false }
        return true
    }

    /// This chunk's wreck, if the region it sits in rolled one, the roll
    /// landed inside this chunk, and the seabed under it is actually deep
    /// enough to be worth diving for.
    private func wreckBlocks(in chunk: Chunk) -> [BlockPlacement] {
        let regionX = WorldGenerator.floorDivide(chunk.originX, by: WorldGenerator.wreckRegionSize)
        let regionZ = WorldGenerator.floorDivide(chunk.originZ, by: WorldGenerator.wreckRegionSize)
        guard let anchor = wreckAnchor(regionX: regionX, regionZ: regionZ) else { return [] }
        guard anchor.x >= chunk.originX, anchor.x < chunk.originX + Chunk.width,
              anchor.z >= chunk.originZ, anchor.z < chunk.originZ + Chunk.depth
        else { return [] }
        guard wreckSiteIsValid(atX: anchor.x, z: anchor.z) else { return [] }
        return wreck(atX: anchor.x, z: anchor.z)
    }

    /// A scatter of planks standing in for a broken hull — no structure
    /// file, the same trick a ruin's own rubble uses.
    private static let wreckPlankOffsets: [(x: Int, z: Int)] = [
        (1, 1), (-2, 0), (1, -2), (2, 2),
    ]

    private func wreck(atX x: Int, z: Int) -> [BlockPlacement] {
        var blocks: [BlockPlacement] = []
        blocks.append(BlockPlacement(x: x, y: surfaceHeight(x: x, z: z), z: z, block: .chest))
        for offset in WorldGenerator.wreckPlankOffsets {
            let px = x + offset.x, pz = z + offset.z
            blocks.append(BlockPlacement(x: px, y: surfaceHeight(x: px, z: pz), z: pz, block: .planks))
        }
        return blocks
    }

    // A modest haul and nothing finished: the depth costs no gear at all,
    // only air and nerve, the same framing a spire's climb uses.
    private static let wreckLootPool: [(item: ItemType, minCount: Int, maxCount: Int)] = [
        (.ironIngot, 2, 4),
        (.goldIngot, 1, 3),
        (.diamond, 1, 2),
        (.cookedCod, 2, 4),
    ]

    /// What a player's bag gains the first time they reach a wreck's chest
    /// — rolled deterministically from the anchor, the same scheme every
    /// other landmark's loot uses.
    func wreckLoot(atX x: Int, y: Int, z: Int) -> [(item: ItemType, count: Int)]? {
        for anchor in nearbyWreckAnchors(x: x, z: z) {
            guard wreckSiteIsValid(atX: anchor.x, z: anchor.z) else { continue }
            guard x == anchor.x, y == surfaceHeight(x: anchor.x, z: anchor.z), z == anchor.z else { continue }
            return rollWreckLoot(anchorX: anchor.x, anchorZ: anchor.z)
        }
        return nil
    }

    private func rollWreckLoot(anchorX: Int, anchorZ: Int) -> [(item: ItemType, count: Int)] {
        let pool = WorldGenerator.wreckLootPool
        let baseSlots = 2 + Int(latticeHash(anchorX, anchorZ, seed: seed &+ 1210) * 3)
        let slotCount = max(1, Int((Double(baseSlots) * lootScale(anchorX: anchorX, anchorZ: anchorZ)).rounded()))
        var rolled: [(item: ItemType, count: Int)] = []
        for slot in 0..<slotCount {
            let offset = UInt64(slot) &* 2
            let entry = pool[
                min(
                    Int(latticeHash(anchorX, anchorZ, seed: seed &+ 1211 &+ offset) * Double(pool.count)),
                    pool.count - 1
                )
            ]
            let span = entry.maxCount - entry.minCount + 1
            let count = entry.minCount
                + Int(latticeHash(anchorX, anchorZ, seed: seed &+ 1212 &+ offset) * Double(span))
            rolled.append((entry.item, count))
        }
        return rolled
    }

    /// Which tree grows here. Three species over seven biomes, rolled per
    /// trunk rather than per biome so a forest is mixed — a wood in which
    /// every tree is the same tree reads as wallpaper.
    enum TreeSpecies {
        case oak, birch, spruce
    }

    /// The plants scattered over the surface of one chunk: grass and
    /// flowers where things grow, cactus and dead bush where they don't.
    ///
    /// One roll per column against a per-biome density, off the shared
    /// lattice hash — so this is stateless, agrees with itself across chunk
    /// seams, and costs one hash per column rather than a neighbourhood
    /// sweep like the trees.
    private func groundCover(in chunk: Chunk) -> [BlockPlacement] {
        var placements: [BlockPlacement] = []
        let ruinAnchors = nearbyRuinAnchors(for: chunk)
        for lz in 0..<Chunk.depth {
            for lx in 0..<Chunk.width {
                let wx = chunk.originX + lx
                let wz = chunk.originZ + lz
                let height = surfaceHeight(x: wx, z: wz)
                // Nothing grows in the sea, and nothing grows on a roof of
                // stone the terrain pass laid over a cave.
                guard height > WorldGenerator.seaLevel, height < WorldGenerator.highestSnowCap else { continue }
                guard !isCave(x: wx, y: height, z: wz) else { continue }
                // Nor on a column a ruin is about to stand a pillar on —
                // that ruin's own chunk may not even have generated yet,
                // so there is no block here to check, only an anchor to
                // stay clear of.
                guard !columnIsClaimedByRuin(wx, wz, anchors: ruinAnchors) else { continue }

                let columnBiome = biome(x: wx, z: wz)
                let roll = latticeHash(wx, wz, seed: seed &+ 901)
                guard let plant = plant(for: columnBiome, roll: roll, x: wx, z: wz) else {
                    continue
                }
                guard BlockType.plantCanRootOn(surfaceBlock(for: columnBiome, height: height))
                else { continue }

                // A cactus is a short column rather than one block — one
                // cube of green on the sand reads as a mistake, and it is
                // the height that makes it read as a cactus.
                let stack = plant == .cactus
                    ? 1 + Int(latticeHash(wx, wz, seed: seed &+ 903) * 3)
                    : 1
                for dy in 0..<stack where height + 1 + dy < WorldGenerator.highestSnowCap + 1 {
                    placements.append(
                        BlockPlacement(x: wx, y: height + 1 + dy, z: wz, block: plant)
                    )
                }
            }
        }
        return placements
    }

    /// What, if anything, this column grows.
    ///
    /// The densities are the whole feel of the ground: too low and a
    /// meadow is a bare green plane with the odd sprig in it, too high and
    /// the flowers stop being finds. Grass is common enough to read as
    /// texture from a distance; a flower is roughly one in seventy columns,
    /// which is often enough to meet and rare enough to pick.
    private func plant(
        for biome: Biome, roll: Double, x: Int, z: Int
    ) -> BlockType? {
        switch biome {
        case .plains:
            if roll < 0.17 { return .tallGrass }
            if roll < 0.185 { return flower(x: x, z: z) }
        case .forest:
            if roll < 0.13 { return .tallGrass }
            if roll < 0.142 { return flower(x: x, z: z) }
        case .snowy:
            if roll < 0.045 { return .tallGrass }
        case .mountains:
            if roll < 0.05 { return .tallGrass }
        case .desert:
            if roll < 0.022 { return .cactus }
            if roll < 0.048 { return .deadBush }
        case .beach:
            if roll < 0.006 { return .deadBush }
        case .ocean:
            return nil
        }
        return nil
    }

    /// Which of the three flowers. An independent roll from the one that
    /// decided there is a flower here at all, so the colours are mixed
    /// rather than banded by whatever the density roll happened to be near.
    private func flower(x: Int, z: Int) -> BlockType {
        let roll = latticeHash(x, z, seed: seed &+ 902)
        if roll < 0.42 { return .poppy }
        if roll < 0.78 { return .dandelion }
        return .cornflower
    }

    /// Trees whose trunk lands in this chunk. Canopies may spill into
    /// neighbours, so the caller writes through `World` rather than the
    /// chunk directly — the same tree is produced identically no matter
    /// which chunk generation happens to trigger it.
    private func treePositions(in chunk: Chunk) -> [(x: Int, y: Int, z: Int, species: TreeSpecies)] {
        var trees: [(x: Int, y: Int, z: Int, species: TreeSpecies)] = []
        for lz in 0..<Chunk.depth {
            for lx in 0..<Chunk.width {
                let wx = chunk.originX + lx
                let wz = chunk.originZ + lz
                let columnBiome = biome(x: wx, z: wz)
                let density: Double
                switch columnBiome {
                case .forest: density = 0.040
                case .plains: density = 0.007
                case .snowy: density = 0.016
                // A few pines clinging to the lower slopes, which is what
                // stops a mountain being a bare cone of stone and grass.
                case .mountains: density = 0.008
                default: continue
                }
                guard latticeHash(wx, wz, seed: seed &+ 555) < density else { continue }
                // Keep trunks apart: only the local maximum of a small
                // neighbourhood roll actually sprouts, so canopies have
                // room to read as separate trees rather than one mass.
                let selfRoll = latticeHash(wx, wz, seed: seed &+ 556)
                var isPeak = true
                for dz in -3...3 {
                    for dx in -3...3 where !(dx == 0 && dz == 0) {
                        if latticeHash(wx + dx, wz + dz, seed: seed &+ 555) < density,
                           latticeHash(wx + dx, wz + dz, seed: seed &+ 556) > selfRoll {
                            isPeak = false
                        }
                    }
                }
                guard isPeak else { continue }
                let height = surfaceHeight(x: wx, z: wz)
                guard height > WorldGenerator.seaLevel + 1, height < WorldGenerator.highestTree else { continue }
                guard !isCave(x: wx, y: height, z: wz) else { continue }
                trees.append((wx, height, wz, species(for: columnBiome, x: wx, z: wz)))
            }
        }
        return trees
    }

    /// Which tree stands at this trunk. Rolled per tree off its own lattice
    /// seed, so the mix is stable for a given world and a wood comes out
    /// mixed rather than uniform.
    private func species(for biome: Biome, x: Int, z: Int) -> TreeSpecies {
        let roll = latticeHash(x, z, seed: seed &+ 558)
        switch biome {
        // Oak with a good scatter of birch through it. Birch is the pale
        // one, and a stand of them against the dark oak is most of what
        // makes a wood look like somewhere rather than like ground cover.
        case .forest: return roll < 0.30 ? .birch : .oak
        case .plains: return roll < 0.40 ? .birch : .oak
        // Conifer country: dark, narrow, tall.
        case .snowy, .mountains: return roll < 0.85 ? .spruce : .birch
        default: return .oak
        }
    }

    /// The blocks making up one tree, as absolute world coordinates.
    ///
    /// Not `private`: `SaplingStore` triggers the exact same builder when a
    /// planted sapling matures, through `World.generator`, rather than a
    /// second copy of `broadleaf`/`conifer` living outside this file. Pure
    /// in `x`/`z`/`seed` like the rest of generation, so calling it well
    /// after the chunk it stands in was generated still gets the tree a
    /// sapling planted right here would always have grown into.
    func treeBlocks(
        atX x: Int, groundY: Int, z: Int, species: TreeSpecies
    ) -> [BlockPlacement] {
        switch species {
        case .oak: return broadleaf(atX: x, groundY: groundY, z: z, species: .oak)
        case .birch: return broadleaf(atX: x, groundY: groundY, z: z, species: .birch)
        case .spruce: return conifer(atX: x, groundY: groundY, z: z)
        }
    }

    /// Oak and birch: a straight trunk with a rounded crown on top.
    ///
    /// The same builder for both, because they are the same tree in
    /// different proportions and different colours — birch is taller,
    /// narrower and paler, which is exactly the difference a second
    /// broadleaf wants to be. A second copy of this function that differed
    /// in two constants would be a second place to fix the next canopy bug.
    private func broadleaf(
        atX x: Int, groundY: Int, z: Int, species: TreeSpecies
    ) -> [BlockPlacement] {
        let birch = species == .birch
        let log: BlockType = birch ? .birchLog : .log
        let leaf: BlockType = birch ? .birchLeaves : .leaves

        var blocks: [BlockPlacement] = []
        let vary = Int(latticeHash(x, z, seed: seed &+ 557) * 4)
        let trunkHeight = (birch ? 5 : 4) + vary
        for dy in 1...trunkHeight {
            blocks.append(BlockPlacement(x: x, y: groundY + dy, z: z, block: log))
        }

        // Two wide layers, then a narrow cap — the classic oak silhouette.
        // Birch keeps the shape and loses a block of width, which is what
        // makes a stand of them read as slender.
        let crown = groundY + trunkHeight
        let wide = birch ? 1 : 2
        for (dy, radius) in [(-1, wide), (0, wide), (1, 1), (2, 1)] {
            for dz in -radius...radius {
                for dx in -radius...radius {
                    if dx == 0, dz == 0, dy <= 0 { continue } // trunk owns the core
                    // Trim the corners so the canopy is round, not square.
                    if abs(dx) == radius, abs(dz) == radius, radius > 1 { continue }
                    if dy == 2, abs(dx) + abs(dz) > 1 { continue }
                    blocks.append(BlockPlacement(x: x + dx, y: crown + dy, z: z + dz, block: leaf))
                }
            }
        }
        return blocks
    }

    /// Spruce: a tall bare trunk carrying skirts of needles that narrow to
    /// a point, rather than a ball of leaves on a stick.
    ///
    /// The silhouette is the whole species. A conifer drawn as a broadleaf
    /// with darker leaves is a dark broadleaf; what says "pine" at two
    /// hundred blocks is the outline, so the layers step 2, 2, 1, 1, spike.
    private func conifer(atX x: Int, groundY: Int, z: Int) -> [BlockPlacement] {
        var blocks: [BlockPlacement] = []
        let trunkHeight = 7 + Int(latticeHash(x, z, seed: seed &+ 557) * 5)
        for dy in 1...trunkHeight {
            blocks.append(BlockPlacement(x: x, y: groundY + dy, z: z, block: .spruceLog))
        }

        // Skirts every other block up the top two thirds, each narrower
        // than the one below it. The gaps between them are what let the
        // trunk show through, which is the other half of reading as a pine.
        let firstSkirt = max(2, trunkHeight - 7)
        var radius = 2
        var layer = firstSkirt
        while layer <= trunkHeight {
            let ring = radius
            for dz in -ring...ring {
                for dx in -ring...ring {
                    if dx == 0, dz == 0 { continue }
                    if abs(dx) + abs(dz) > ring + (ring > 1 ? 0 : 1) { continue }
                    blocks.append(BlockPlacement(
                        x: x + dx, y: groundY + layer, z: z + dz, block: .spruceLeaves
                    ))
                }
            }
            // Every second skirt draws in, so the taper is stepped rather
            // than a cone — which is what the block grid can actually say.
            if layer % 2 == 0 { radius = max(1, radius - 1) }
            layer += 2
        }
        // The spike: needles closing over the top of the trunk.
        blocks.append(BlockPlacement(
            x: x, y: groundY + trunkHeight + 1, z: z, block: .spruceLeaves
        ))
        for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            blocks.append(BlockPlacement(
                x: x + dx, y: groundY + trunkHeight, z: z + dz, block: .spruceLeaves
            ))
        }
        return blocks
    }
}

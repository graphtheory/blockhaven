import Foundation

/// The Moon's ground: grey dust over grey rock, rolling gently, pocked
/// with craters. No water, no caves, no trees. Ice sits in the floors of
/// the deeper craters, where the sun never reaches; meteor metal glints
/// in the rims; prism glass runs in seams along the high ground.
///
/// The places the story needs — the landing crater, the cold shelf, the
/// glass ridge and the garden — are not generated here. `StoryBuilder`
/// writes them through the edit journal the first time a rocket lands, the
/// same way a player builds, so this file only ever has to be scenery.
extension WorldGenerator {
    /// The Moon's datum. Below the home world's sea level is meaningless
    /// here; it only has to leave room for craters to bite down into.
    static let lunarBase = 64

    /// One crater per cell at most, and not every cell has one.
    private static let craterCell = 40

    /// The crater, if any, whose bowl reaches this column — as its depth
    /// under the surrounding ground at this point (negative on the rim,
    /// where the thrown-up lip stands proud).
    private func craterRelief(x: Int, z: Int) -> Double {
        let cellX = WorldGenerator.floorDivide(x, by: WorldGenerator.craterCell)
        let cellZ = WorldGenerator.floorDivide(z, by: WorldGenerator.craterCell)
        var relief = 0.0
        for dz in -1...1 {
            for dx in -1...1 {
                let cx = cellX + dx, cz = cellZ + dz
                guard latticeHash(cx, cz, seed: seed &+ 4100) < 0.55 else { continue }
                let centreX = Double(cx * WorldGenerator.craterCell)
                    + latticeHash(cx, cz, seed: seed &+ 4101) * Double(WorldGenerator.craterCell)
                let centreZ = Double(cz * WorldGenerator.craterCell)
                    + latticeHash(cx, cz, seed: seed &+ 4102) * Double(WorldGenerator.craterCell)
                let radius = 5 + latticeHash(cx, cz, seed: seed &+ 4103) * 12
                let ddx = Double(x) - centreX, ddz = Double(z) - centreZ
                let distance = (ddx * ddx + ddz * ddz).squareRoot() / radius
                if distance < 1 {
                    relief = max(relief, (1 - distance * distance) * radius * 0.45)
                } else if distance < 1.35 {
                    // The rim: a lip of thrown-up dust around the bowl.
                    let lip = (1 - abs(distance - 1.12) / 0.23) * radius * 0.12
                    relief = min(relief, -max(0, lip))
                }
            }
        }
        return relief
    }

    func lunarSurfaceHeight(x: Int, z: Int) -> Int {
        let fx = Double(x), fz = Double(z)
        let swell = continentNoise.sample(fx * 0.008, fz * 0.008) * 9
        let roll = hillNoise.sample(fx * 0.03, fz * 0.03) * 4
        let height = Double(WorldGenerator.lunarBase) + swell + roll - craterRelief(x: x, z: z)
        return max(8, min(WorldGenerator.highestSurface, Int(height.rounded())))
    }

    /// Whether this column sits in a crater floor deep enough to stay cold.
    func lunarColdFloor(x: Int, z: Int) -> Bool {
        craterRelief(x: x, z: z) > 4
    }

    func generateLunar(_ chunk: Chunk) {
        for lz in 0..<Chunk.depth {
            for lx in 0..<Chunk.width {
                let wx = chunk.originX + lx
                let wz = chunk.originZ + lz
                let height = lunarSurfaceHeight(x: wx, z: wz)
                let cold = lunarColdFloor(x: wx, z: wz)
                for y in 0...height {
                    let type: BlockType
                    if y <= 1 {
                        type = .bedrock
                    } else if y == height {
                        if cold, latticeHash(wx, wz, seed: seed &+ 4200) < 0.35 {
                            type = .ice
                        } else {
                            type = .moonDust
                        }
                    } else if y > height - 3 {
                        type = .moonDust
                    } else if latticeHash(wx &* 7 &+ y, wz &* 3 &+ y, seed: seed &+ 4300) < 0.012 {
                        type = .meteorOre
                    } else if height > WorldGenerator.lunarBase + 7, y > height - 6,
                              latticeHash(wx &+ y, wz, seed: seed &+ 4400) < 0.08 {
                        type = .prismGlass
                    } else {
                        type = .moonRock
                    }
                    chunk.setBlock(localX: lx, y: y, localZ: lz, to: type)
                }
            }
        }
    }
}

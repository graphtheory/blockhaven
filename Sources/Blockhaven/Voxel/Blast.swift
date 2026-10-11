import Foundation

/// The hole an explosion leaves, and what it sets off on the way.
///
/// Lifted out of `FizzlerManager` when TNT arrived and needed exactly the
/// same crater. Two copies of a sphere-carving loop would have been two
/// places to fix the day somebody adds a block that should survive a
/// blast — and would have meant a fizzler and a stick of dynamite
/// disagreeing about whether obsidian holds, which is the sort of
/// inconsistency a player notices immediately and cannot explain.
enum Blast {
    /// A block this hard or harder shrugs an explosion off. Bedrock is
    /// infinite and obsidian is 45; everything a player can reasonably
    /// build with is below it.
    static let survivesHardness: Double = 8

    struct Result {
        /// How many cells were turned to air.
        var destroyed = 0
        /// TNT the blast reached. Not destroyed — *lit*, by whoever asked
        /// for the blast. This is the chain, and it is deliberately the
        /// caller's business: `Blast` knows how to find them, and the fuse
        /// manager knows what a lit fuse is.
        var ignited: [(x: Int, y: Int, z: Int)] = []
    }

    /// Carves a sphere of air, measured from block centres so the crater is
    /// round rather than a cube with the corners shaved.
    ///
    /// TNT inside the radius is left standing and reported instead. If it
    /// were simply destroyed, a stack of TNT would go off as one blast and
    /// the whole point of stacking it would be lost; if it were detonated
    /// here and now, a stack would recurse straight down the Swift stack
    /// and take the game with it.
    static func carve(at centre: Vector3, radius: CGFloat, in world: World) -> Result {
        var result = Result()
        let reach = Int(ceil(radius))
        let cx = Int(floor(centre.x)), cy = Int(floor(centre.y)), cz = Int(floor(centre.z))

        for dy in -reach...reach {
            for dz in -reach...reach {
                for dx in -reach...reach {
                    let x = cx + dx, y = cy + dy, z = cz + dz
                    guard y >= 0, y < Chunk.height else { continue }

                    let offset = Vector3(
                        CGFloat(x) + 0.5 - centre.x,
                        CGFloat(y) + 0.5 - centre.y,
                        CGFloat(z) + 0.5 - centre.z
                    )
                    guard offset.length() <= radius else { continue }

                    let block = world.block(worldX: x, y: y, worldZ: z)
                    guard block != .air else { continue }
                    if block == .tnt {
                        result.ignited.append((x, y, z))
                        continue
                    }
                    // Bedrock and obsidian shrug it off, as they should.
                    guard block.hardness.isFinite, block.hardness < survivesHardness else { continue }
                    if world.setBlock(worldX: x, y: y, worldZ: z, to: .air) { result.destroyed += 1 }
                }
            }
        }
        return result
    }

    /// Half-hearts to apply at a distance, falling off linearly to nothing
    /// at twice the blast radius, so a near miss still stings.
    static func damage(maximum: Int, at point: Vector3, from centre: Vector3, radius: CGFloat) -> Int {
        let falloff = max(0, 1 - (point - centre).length() / (radius * 2))
        return Int((CGFloat(maximum) * falloff).rounded())
    }
}

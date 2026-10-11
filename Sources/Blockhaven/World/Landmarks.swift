import Foundation

/// The three buildings on the demo site, and the vocabulary they are built
/// from.
///
/// Each landmark lives in its own file as an extension of this enum, and
/// each has the same shape of signature: given the centre of its footprint
/// and the height of the ground under it, put itself there. Nothing else is
/// shared between them, which is the point — three buildings that only
/// agree on where the ground is can be written, changed and read
/// separately.
///
/// The helpers below are the whole toolkit. They are deliberately blunt —
/// boxes, discs, domes, cones and lines — because a voxel landmark is a
/// recognisable silhouette rather than a model, and the silhouette is
/// carried by proportion far more than by detail. Anything fancier than
/// these would be a fourth building's worth of code that only one building
/// used.
///
/// Every write here passes `remesh: false`. These run before the world has
/// generated a single chunk, so there is nothing to remesh yet and asking
/// would queue tens of thousands of rebuilds of chunks that do not exist.
/// The edit journal replays them as the chunks stream in.
enum Landmarks {
    /// The tallest anything may reach. The world is 128 blocks high and the
    /// deck is at 72, so a landmark has this much room and no more — a tower
    /// that runs past the ceiling is silently flattened by `setBlock`'s
    /// bounds check, which reads as a mysteriously decapitated spire.
    static let ceiling = Chunk.height - 6

    // MARK: - Solids

    /// Fills a box, inclusive at both ends.
    static func fill(
        _ world: World,
        x: ClosedRange<Int>, y: ClosedRange<Int>, z: ClosedRange<Int>,
        _ block: BlockType
    ) {
        for yy in y where yy >= 0 && yy <= ceiling {
            for zz in z {
                for xx in x {
                    world.setBlock(worldX: xx, y: yy, worldZ: zz, to: block, remesh: false)
                }
            }
        }
    }

    /// The four walls of a box, leaving the inside hollow. Floors and roofs
    /// are `fill`'s job.
    static func walls(
        _ world: World,
        x: ClosedRange<Int>, y: ClosedRange<Int>, z: ClosedRange<Int>,
        _ block: BlockType
    ) {
        for yy in y where yy >= 0 && yy <= ceiling {
            for zz in z {
                for xx in x {
                    let onEdge = xx == x.lowerBound || xx == x.upperBound
                        || zz == z.lowerBound || zz == z.upperBound
                    guard onEdge else { continue }
                    world.setBlock(worldX: xx, y: yy, worldZ: zz, to: block, remesh: false)
                }
            }
        }
    }

    // MARK: - Round things

    /// A filled circle of blocks at one height.
    ///
    /// The half-block bias is what stops a voxel circle looking like a
    /// plus sign at small radii: a cell counts as inside if its *centre* is
    /// within the radius, not its corner.
    static func disc(
        _ world: World,
        centreX: Int, y: Int, centreZ: Int, radius: Double, _ block: BlockType
    ) {
        guard y >= 0, y <= ceiling else { return }
        let r = Int(radius.rounded(.up))
        for dz in -r...r {
            for dx in -r...r {
                let distance = (Double(dx * dx + dz * dz)).squareRoot()
                guard distance <= radius + 0.35 else { continue }
                world.setBlock(
                    worldX: centreX + dx, y: y, worldZ: centreZ + dz,
                    to: block, remesh: false
                )
            }
        }
    }

    /// The rim of a circle at one height — one block thick, for tower walls
    /// and the drum a dome sits on.
    static func ring(
        _ world: World,
        centreX: Int, y: Int, centreZ: Int, radius: Double, _ block: BlockType
    ) {
        guard y >= 0, y <= ceiling else { return }
        let r = Int(radius.rounded(.up)) + 1
        for dz in -r...r {
            for dx in -r...r {
                let distance = (Double(dx * dx + dz * dz)).squareRoot()
                guard distance <= radius + 0.35, distance >= radius - 0.8 else { continue }
                world.setBlock(
                    worldX: centreX + dx, y: y, worldZ: centreZ + dz,
                    to: block, remesh: false
                )
            }
        }
    }

    /// A hollow vertical tube: `height` courses of `ring`.
    static func cylinder(
        _ world: World,
        centreX: Int, baseY: Int, centreZ: Int, radius: Double, height: Int, _ block: BlockType
    ) {
        for step in 0..<height {
            ring(world, centreX: centreX, y: baseY + step, centreZ: centreZ, radius: radius, block)
        }
    }

    /// A hemisphere shell sitting on `baseY`, open at the bottom.
    ///
    /// A shell rather than a solid, because a dome you can stand under is
    /// the entire reason to build one, and a solid one is a hill.
    static func dome(
        _ world: World,
        centreX: Int, baseY: Int, centreZ: Int, radius: Double, _ block: BlockType
    ) {
        let r = Int(radius.rounded(.up))
        for dy in 0...r {
            for dz in -r...r {
                for dx in -r...r {
                    let distance = Double(dx * dx + dy * dy + dz * dz).squareRoot()
                    // A shell one block thick, measured in the same units as
                    // the radius so it stays one block thick at the top of
                    // the curve as well as at the spring line.
                    guard distance <= radius + 0.35, distance >= radius - 0.9 else { continue }
                    let y = baseY + dy
                    guard y >= 0, y <= ceiling else { continue }
                    world.setBlock(
                        worldX: centreX + dx, y: y, worldZ: centreZ + dz,
                        to: block, remesh: false
                    )
                }
            }
        }
    }

    /// A cone: the spire on top of a round tower. Solid, because at these
    /// radii a hollow one is a ring of single blocks.
    static func cone(
        _ world: World,
        centreX: Int, baseY: Int, centreZ: Int, radius: Double, height: Int, _ block: BlockType
    ) {
        guard height > 0 else { return }
        for step in 0..<height {
            let t = Double(step) / Double(height)
            disc(
                world,
                centreX: centreX, y: baseY + step, centreZ: centreZ,
                radius: radius * (1 - t), block
            )
        }
    }

    /// A square spire — a pyramid that narrows by one ring a course. The
    /// roof of a rectangular tower.
    static func pyramid(
        _ world: World,
        centreX: Int, baseY: Int, centreZ: Int, halfWidth: Int, _ block: BlockType
    ) {
        var half = halfWidth
        var y = baseY
        while half >= 0 {
            fill(
                world,
                x: (centreX - half)...(centreX + half),
                y: y...y,
                z: (centreZ - half)...(centreZ + half),
                block
            )
            half -= 1
            y += 1
        }
    }

    // MARK: - Lines

    /// A straight run of blocks between two points in three dimensions.
    ///
    /// Stepped along whichever axis changes most, so a diagonal comes out as
    /// a connected line rather than a dotted one — which matters for the
    /// Eiffel Tower, where the diagonals *are* the building.
    static func line(
        _ world: World,
        from a: (x: Int, y: Int, z: Int), to b: (x: Int, y: Int, z: Int),
        _ block: BlockType
    ) {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let steps = max(abs(dx), max(abs(dy), abs(dz)))
        guard steps > 0 else {
            if a.y >= 0, a.y <= ceiling {
                world.setBlock(worldX: a.x, y: a.y, worldZ: a.z, to: block, remesh: false)
            }
            return
        }
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let y = a.y + Int((Double(dy) * t).rounded())
            guard y >= 0, y <= ceiling else { continue }
            world.setBlock(
                worldX: a.x + Int((Double(dx) * t).rounded()),
                y: y,
                worldZ: a.z + Int((Double(dz) * t).rounded()),
                to: block, remesh: false
            )
        }
    }

    /// Puts a torch on top of a block, if there is somewhere to put it.
    /// Landmarks are worth looking at after dark.
    static func torch(_ world: World, x: Int, y: Int, z: Int) {
        guard y >= 0, y <= ceiling else { return }
        world.setBlock(worldX: x, y: y, worldZ: z, to: .torch, remesh: false)
    }
}

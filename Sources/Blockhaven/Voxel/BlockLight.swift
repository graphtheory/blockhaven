import Foundation

/// Block light: how far a torch reaches, and what happens to the pool when
/// the torch goes away or something is built in front of it.
///
/// This is the flood fill the original uses, and it is worth saying why rather
/// than recomputing a region from scratch. A full recompute of the 3×3
/// chunks a torch can touch is 48 × 192 × 48 cells — over four hundred
/// thousand — and mining is a write per block held down. The incremental
/// pair below touches only cells whose value actually changes, so breaking
/// a block in the dark costs nothing at all and breaking one next to a
/// torch costs the handful of cells that were lit through it.
///
/// Sky light is *not* here. The sky's contribution is the skyline-and-cover
/// term `ChunkMesher` already bakes from geometry, which needs no
/// propagation because the world has no vertical chunking — a column knows
/// its own skyline. Only lamps need to spread, and only lamps are here.
enum BlockLight {
    /// The brightest a block can be. Emission is given in these units and a
    /// step of one cell costs one level, so a 14 puts the last lit cell 14
    /// blocks out.
    static let maximum: UInt8 = 15

    /// One cell of the frontier. Packed as world coordinates rather than
    /// chunk-plus-local so the walk can cross chunk seams without deciding
    /// anything, which is the whole reason light lives on `World` and not
    /// on `Chunk`.
    struct Node {
        var x: Int
        var y: Int
        var z: Int
        var level: UInt8
    }

    /// The six ways out of a cell.
    static let steps: [(x: Int, y: Int, z: Int)] = [
        (1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1),
    ]
}

extension World {
    /// Lights a chunk for the first time: its own lamps, plus whatever is
    /// already shining at it through the four seams it shares with loaded
    /// neighbours.
    ///
    /// The seam half matters more than it looks. Without it a chunk that
    /// streams in beside a lit cave is black up to the boundary and lit
    /// past it, with a straight vertical edge down the join — and because
    /// chunks arrive in whatever order the queue hands them over, which
    /// side of the seam goes dark is not even stable between runs.
    func seedLight(for chunk: Chunk) {
        guard !chunk.isLit else { return }
        chunk.isLit = true

        // Only up to the chunk's highest block, not to the roof of the
        // world. A lamp is a block, so nothing above `ceiling` can be one,
        // and the cells this skips are air — which emits nothing and would
        // have been skipped a moment later anyway. Most of a chunk is that
        // air: the ground here tops out around y = 70 in a world 192 tall,
        // so this is roughly two thirds of the sweep gone, both here and on
        // every chunk the game streams in while the player walks.
        var frontier: [BlockLight.Node] = []
        let ceiling = chunk.ceiling
        if ceiling >= 0 {
            for y in 0...ceiling {
                for z in 0..<Chunk.depth {
                    for x in 0..<Chunk.width {
                        let emission = chunk.block(localX: x, y: y, localZ: z).lightEmission
                        guard emission > 0 else { continue }
                        chunk.setLight(localX: x, y: y, localZ: z, to: emission)
                        frontier.append(BlockLight.Node(
                            x: chunk.originX + x, y: y, z: chunk.originZ + z, level: emission
                        ))
                    }
                }
            }
        }

        // Light leaning in over the seams. Only the ring one cell outside
        // the chunk is read, because a neighbour's cell two out cannot
        // reach past the one between them without having lit that one too.
        for (dx, dz) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let neighbour = ChunkCoord(x: chunk.coord.x + dx, z: chunk.coord.z + dz)
            guard let source = chunks[neighbour], source.isLit else { continue }
            // The same ceiling, one lamp's reach looser. Every lit cell in
            // the neighbour was lit by a lamp no higher than the
            // neighbour's own highest block, and light climbs at most
            // `maximum` cells above whatever put it there, so there is
            // nothing to read above this.
            let top = min(Chunk.height - 1, source.ceiling + Int(BlockLight.maximum))
            guard top >= 0 else { continue }
            for y in 0...top {
                for step in 0..<Chunk.width {
                    let (sx, sz) = dx != 0
                        ? (dx < 0 ? Chunk.width - 1 : 0, step)
                        : (step, dz < 0 ? Chunk.depth - 1 : 0)
                    let level = source.lightLevel(localX: sx, y: y, localZ: sz)
                    guard level > 1 else { continue }
                    frontier.append(BlockLight.Node(
                        x: source.originX + sx, y: y, z: source.originZ + sz, level: level
                    ))
                }
            }
        }

        guard !frontier.isEmpty else { return }
        spreadLight(from: frontier)
    }

    /// Pushes light outward from a frontier until every cell holds the
    /// brightest value that can reach it.
    ///
    /// Breadth-first with the level carried on the node rather than re-read
    /// from the grid: a cell can be reached by two lamps in the same sweep,
    /// and the grid may already hold the brighter answer by the time the
    /// dimmer node is popped.
    @discardableResult
    func spreadLight(from frontier: [BlockLight.Node]) -> Set<ChunkCoord> {
        var queue = frontier
        var head = 0
        var touched = Set<ChunkCoord>()

        while head < queue.count {
            let node = queue[head]
            head += 1
            guard node.level > 1 else { continue }
            let next = node.level - 1

            for step in BlockLight.steps {
                let x = node.x + step.x, y = node.y + step.y, z = node.z + step.z
                guard y >= 0, y < Chunk.height else { continue }
                let coord = World.chunkCoord(forWorldX: x, worldZ: z)
                guard let chunk = chunks[coord] else { continue }
                let lx = x - chunk.originX, lz = z - chunk.originZ
                guard chunk.block(localX: lx, y: y, localZ: lz).transmitsLight else { continue }
                guard chunk.lightLevel(localX: lx, y: y, localZ: lz) < next else { continue }
                chunk.setLight(localX: lx, y: y, localZ: lz, to: next)
                touched.insert(coord)
                queue.append(BlockLight.Node(x: x, y: y, z: z, level: next))
            }
        }

        for coord in touched { markNeedsRemesh(coord, urgent: true) }
        return touched
    }

    /// Takes light away: the torch is gone, or something opaque was built
    /// where the light used to pass.
    ///
    /// Two sweeps, and both are needed. The first darkens every cell whose
    /// light was strictly dimmer than the cell it came from — that is what
    /// identifies "lit *by this*" without storing where any of it came
    /// from. Cells that are as bright or brighter must have another source,
    /// so they are collected and re-spread in the second sweep, which is
    /// what refills the far side of a pool when one of two torches is
    /// taken out.
    func removeLight(atWorldX x: Int, y: Int, worldZ z: Int) {
        let coord = World.chunkCoord(forWorldX: x, worldZ: z)
        guard let chunk = chunks[coord] else { return }
        let level = chunk.lightLevel(localX: x - chunk.originX, y: y, localZ: z - chunk.originZ)
        guard level > 0 else { return }

        var queue = [BlockLight.Node(x: x, y: y, z: z, level: level)]
        var head = 0
        var relight: [BlockLight.Node] = []
        var touched = Set<ChunkCoord>()
        chunk.setLight(localX: x - chunk.originX, y: y, localZ: z - chunk.originZ, to: 0)
        touched.insert(coord)

        while head < queue.count {
            let node = queue[head]
            head += 1

            for step in BlockLight.steps {
                let nx = node.x + step.x, ny = node.y + step.y, nz = node.z + step.z
                guard ny >= 0, ny < Chunk.height else { continue }
                let neighbourCoord = World.chunkCoord(forWorldX: nx, worldZ: nz)
                guard let neighbour = chunks[neighbourCoord] else { continue }
                let lx = nx - neighbour.originX, lz = nz - neighbour.originZ
                let level = neighbour.lightLevel(localX: lx, y: ny, localZ: lz)
                guard level > 0 else { continue }

                if level < node.level {
                    neighbour.setLight(localX: lx, y: ny, localZ: lz, to: 0)
                    touched.insert(neighbourCoord)
                    queue.append(BlockLight.Node(x: nx, y: ny, z: nz, level: level))
                } else {
                    // As bright or brighter: something else is feeding it,
                    // and it will refill what this sweep emptied.
                    relight.append(BlockLight.Node(x: nx, y: ny, z: nz, level: level))
                }
            }
        }

        // A lamp still standing at the edge of the emptied region has to go
        // back on the frontier too — its own cell was never dimmer than
        // itself, so the walk above would not have collected it.
        for coord in touched { markNeedsRemesh(coord, urgent: true) }
        spreadLight(from: relight)
    }

    /// Called by `setBlock` once the write has landed. Decides which of the
    /// two sweeps this edit needs, if either.
    ///
    /// Order matters: the removal sweep reads the *new* block to decide
    /// whether light still passes, so it has to run after the write, and
    /// the emitter's own light has to be written after the removal sweep or
    /// the sweep would erase the lamp it was just given.
    func updateLight(atWorldX x: Int, y: Int, worldZ z: Int, replacing old: BlockType, with new: BlockType) {
        guard old != new else { return }
        let lostLamp = old.lightEmission > 0 && new.lightEmission == 0
        let blocksLight = old.transmitsLight && !new.transmitsLight

        if lostLamp || blocksLight {
            removeLight(atWorldX: x, y: y, worldZ: z)
        }

        if new.lightEmission > 0 {
            let coord = World.chunkCoord(forWorldX: x, worldZ: z)
            guard let chunk = chunks[coord] else { return }
            chunk.setLight(localX: x - chunk.originX, y: y, localZ: z - chunk.originZ,
                           to: new.lightEmission)
            markNeedsRemesh(coord, urgent: true)
            spreadLight(from: [BlockLight.Node(x: x, y: y, z: z, level: new.lightEmission)])
        } else if !old.transmitsLight && new.transmitsLight {
            // A hole opened in something solid. Nothing was lit inside it,
            // so nothing has to be unwound — but the neighbours may have
            // light to pour in, and only they know how much.
            var frontier: [BlockLight.Node] = []
            for step in BlockLight.steps {
                let nx = x + step.x, ny = y + step.y, nz = z + step.z
                guard ny >= 0, ny < Chunk.height else { continue }
                let coord = World.chunkCoord(forWorldX: nx, worldZ: nz)
                guard let chunk = chunks[coord] else { continue }
                let level = chunk.lightLevel(localX: nx - chunk.originX, y: ny, localZ: nz - chunk.originZ)
                guard level > 1 else { continue }
                frontier.append(BlockLight.Node(x: nx, y: ny, z: nz, level: level))
            }
            if !frontier.isEmpty { spreadLight(from: frontier) }
        }
    }

    /// The light at a world cell, for anything outside the mesher that wants
    /// to ask — the debug readout, a check, a mob deciding it is in the dark.
    func lightLevel(worldX x: Int, y: Int, worldZ z: Int) -> UInt8 {
        guard y >= 0, y < Chunk.height else { return 0 }
        let coord = World.chunkCoord(forWorldX: x, worldZ: z)
        guard let chunk = chunks[coord] else { return 0 }
        return chunk.lightLevel(localX: x - chunk.originX, y: y, localZ: z - chunk.originZ)
    }
}

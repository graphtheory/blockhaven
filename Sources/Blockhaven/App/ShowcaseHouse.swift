import Foundation

/// A small house, built out of the blocks this phase added, for the
/// snapshot harness to photograph.
///
/// `BLOCKHAVEN_SNAPSHOT_EDITS` can place any block anywhere, and a house is
/// a few hundred of them — but a few hundred hand-written coordinates would
/// be a file nobody could read and nobody could move to different ground.
/// This is the same edits, written as loops: a cobblestone-stair roof
/// ridge, plank walls, a real oak door, glass-pane windows, a bed inside
/// and an oak-stair porch, all going down through `World.setBlock` exactly
/// as a player's would.
///
/// `BLOCKHAVEN_SNAPSHOT_HOUSE=1` builds it with the door shut,
/// `=open` with it standing open. The origin and a set of eye positions are
/// printed to stderr, because a gallery script needs absolute camera
/// positions and the house is placed by looking at the terrain.
enum ShowcaseHouse {
    /// Outer footprint, in cells. Odd, so the door and the roof ridge can
    /// both sit on the centre line.
    static let span = 7
    /// How high the walls stand above the floor.
    static let wallHeight = 4

    struct Site {
        /// North-west corner of the outer wall.
        var x: Int
        var z: Int
        /// The last solid cell of the levelled ground the house stands on.
        var groundY: Int
        /// The last solid cell of the plinth — the house's own floor.
        var floorY: Int { groundY + 1 }
    }

    /// Levels a patch of ground near the world's spawn and builds the house
    /// on it. Returns where it went.
    ///
    /// Anchored on spawn rather than on the camera on purpose: a gallery is
    /// several photographs of *one* house, and a site chosen relative to the
    /// eye would move the building every time the camera did.
    @discardableResult
    static func build(in world: World, doorOpen: Bool) -> Site {
        let site = chooseSite(in: world, near: world.spawnPosition())
        levelGround(in: world, site: site)
        buildShell(in: world, site: site, doorOpen: doorOpen)
        buildRoof(in: world, site: site)
        furnish(in: world, site: site)
        report(site)
        return site
    }

    // MARK: - Where

    /// Picks the flattest, driest patch within a short walk of `eye`.
    ///
    /// The ground gets levelled either way, so this is only about how much
    /// of a plateau the levelling has to cut — a house on a hillside sits on
    /// a visible shelf, and a house in a lake sits in a hole with water
    /// walls. Scoring a handful of candidates costs nothing and is the
    /// difference between a photograph and an explanation.
    private static func chooseSite(in world: World, near eye: Vector3) -> Site {
        let eyeX = Int(floor(eye.x)), eyeZ = Int(floor(eye.z))
        var best: (score: Int, site: Site)?

        for dz in stride(from: -18, through: 18, by: 6) {
            for dx in stride(from: -18, through: 18, by: 6) {
                let originX = eyeX + dx, originZ = eyeZ + dz
                var heights: [Int] = []
                var wet = false
                for z in originZ...(originZ + span - 1) {
                    for x in originX...(originX + span - 1) {
                        let top = groundTop(in: world, x: x, z: z)
                        heights.append(top)
                        if world.block(worldX: x, y: top, worldZ: z) == .water { wet = true }
                    }
                }
                guard let low = heights.min(), let high = heights.max() else { continue }
                // Roughness first, then wetness as a heavy penalty, then a
                // small pull back toward the camera so a tie lands nearby.
                let score = (high - low) * 4 + (wet ? 40 : 0) + (abs(dx) + abs(dz)) / 6
                // The *median* height, not the highest: levelling to the top
                // of a terraced slope stands the house on a plinth of fill
                // several blocks tall, with a bare dirt cliff round it. Half
                // cut and half fill leaves a shelf half as deep.
                let level = heights.sorted()[heights.count / 2]
                let site = Site(x: originX, z: originZ, groundY: level)
                if best == nil || score < best!.score { best = (score, site) }
            }
        }
        return best?.site ?? Site(x: eyeX + 6, z: eyeZ + 6,
                                 groundY: groundTop(in: world, x: eyeX + 6, z: eyeZ + 6))
    }

    /// The highest solid cell in a column — the surface you would stand on.
    private static func groundTop(in world: World, x: Int, z: Int) -> Int {
        var top = Chunk.height - 1
        while top > 0, !world.block(worldX: x, y: top, worldZ: z).isSolid { top -= 1 }
        return top
    }

    // MARK: - Ground

    /// Lays a flat grass apron a little wider than the house and clears
    /// everything standing on it, so the walls do not grow through a tree.
    private static func levelGround(in world: World, site: Site) {
        let margin = 4
        for z in (site.z - margin)...(site.z + span - 1 + margin) {
            for x in (site.x - margin)...(site.x + span - 1 + margin) {
                world.setBlock(worldX: x, y: site.groundY, worldZ: z, to: .grass, remesh: false)
                // Two of soil under the turf, so a levelled shelf does not
                // show a stripe of stone at its edge.
                for depth in 1...2 {
                    let y = site.groundY - depth
                    guard y > 0,
                          world.block(worldX: x, y: y, worldZ: z) != .stone else { continue }
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .dirt, remesh: false)
                }
                for y in (site.groundY + 1)...(site.groundY + 14) where y < Chunk.height {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }
    }

    // MARK: - Walls

    private static func buildShell(in world: World, site: Site, doorOpen: Bool) {
        let x0 = site.x, x1 = site.x + span - 1
        let z0 = site.z, z1 = site.z + span - 1
        let floor = site.floorY

        // A cobblestone plinth, one block proud of the ground — which is
        // what gives the porch stairs something to climb.
        for z in z0...z1 {
            for x in x0...x1 {
                world.setBlock(worldX: x, y: floor, worldZ: z, to: .cobblestone, remesh: false)
            }
        }

        // Plank walls round the edge.
        for y in (floor + 1)...(floor + wallHeight) {
            for z in z0...z1 {
                for x in x0...x1 where x == x0 || x == x1 || z == z0 || z == z1 {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .planks, remesh: false)
                }
            }
        }

        // Corner posts of log, so the plank box reads as a building.
        for y in (floor + 1)...(floor + wallHeight) {
            for corner in [(x0, z0), (x1, z0), (x0, z1), (x1, z1)] {
                world.setBlock(worldX: corner.0, y: y, worldZ: corner.1, to: .log, remesh: false)
            }
        }

        // The door, in the middle of the south wall, facing out at whoever
        // is walking up to it.
        let doorX = x0 + span / 2
        world.setBlock(worldX: doorX, y: floor + 1, worldZ: z1,
                       to: .oakDoor(.lower, facing: .south, open: doorOpen), remesh: false)
        world.setBlock(worldX: doorX, y: floor + 2, worldZ: z1,
                       to: .oakDoor(.upper, facing: .south, open: doorOpen), remesh: false)

        // Windows at head height: two either side of the door, two on each
        // long wall, two on the back.
        let eyeY = floor + 2
        for offset in [2, span - 3] {
            world.setBlock(worldX: x0, y: eyeY, worldZ: z0 + offset, to: .glassPane, remesh: false)
            world.setBlock(worldX: x1, y: eyeY, worldZ: z0 + offset, to: .glassPane, remesh: false)
            world.setBlock(worldX: x0 + offset, y: eyeY, worldZ: z0, to: .glassPane, remesh: false)
        }
        world.setBlock(worldX: doorX - 2, y: eyeY, worldZ: z1, to: .glassPane, remesh: false)
        world.setBlock(worldX: doorX + 2, y: eyeY, worldZ: z1, to: .glassPane, remesh: false)

        // The porch: three oak stairs across the doorway, ascending toward
        // the house, so walking in is one smooth auto-step rather than a
        // jump.
        for x in (doorX - 1)...(doorX + 1) {
            world.setBlock(worldX: x, y: floor, worldZ: z1 + 1,
                           to: .oakStairs(.north), remesh: false)
        }
    }

    // MARK: - Roof

    /// A gabled roof of cobblestone stairs, ridge running east-west, with a
    /// block of overhang at each end.
    private static func buildRoof(in world: World, site: Site) {
        let z0 = site.z, z1 = site.z + span - 1
        let ridgeZ = z0 + span / 2
        let eaves = site.floorY + wallHeight + 1   // the first course, on the wall top
        let pitch = span / 2                        // courses from eaves to ridge
        let ridgeY = eaves + pitch

        for x in (site.x - 1)...(site.x + span) {
            world.setBlock(worldX: x, y: ridgeY, worldZ: ridgeZ, to: .cobblestone, remesh: false)
            for step in 1...pitch {
                let y = ridgeY - step
                // North of the ridge the roof climbs southward and vice
                // versa: a stair ascends toward its facing.
                world.setBlock(worldX: x, y: y, worldZ: ridgeZ - step,
                               to: .cobbleStairs(.south), remesh: false)
                world.setBlock(worldX: x, y: y, worldZ: ridgeZ + step,
                               to: .cobbleStairs(.north), remesh: false)
            }
        }

        // The two gable ends: fill the triangle the roof leaves open above
        // the wall, or the house is a tent with its ends cut off.
        for endX in [site.x, site.x + span - 1] {
            // Down from the eaves course to the one under the ridge. The
            // ridge course itself is a single block wide, so there is
            // nothing beside it left to fill.
            for step in stride(from: pitch, through: 1, by: -1) {
                let y = ridgeY - step
                for z in (ridgeZ - step + 1)...(ridgeZ + step - 1) where z >= z0 && z <= z1 {
                    world.setBlock(worldX: endX, y: y, worldZ: z, to: .planks, remesh: false)
                }
            }
        }
    }

    // MARK: - Inside

    private static func furnish(in world: World, site: Site) {
        let floor = site.floorY
        let inside = floor + 1
        let x0 = site.x, z0 = site.z

        // A bed along the west wall, head to the north.
        world.setBlock(worldX: x0 + 1, y: inside, worldZ: z0 + 2,
                       to: .bed(.foot, facing: .north), remesh: false)
        world.setBlock(worldX: x0 + 1, y: inside, worldZ: z0 + 1,
                       to: .bed(.head, facing: .north), remesh: false)

        // A table in the far corner, and a step of stairs by the door to
        // sit on — the two things that make a room look lived in.
        world.setBlock(worldX: x0 + span - 2, y: inside, worldZ: z0 + 1,
                       to: .craftingTable, remesh: false)
        world.setBlock(worldX: x0 + span - 2, y: inside, worldZ: z0 + span - 2,
                       to: .oakStairs(.west), remesh: false)
    }

    // MARK: - Telling the script where it went

    /// Prints the house's own coordinates and a few eye positions worth
    /// photographing it from. A gallery script cannot know where the site
    /// scan landed, so this is how it finds out — run once, read the lines,
    /// write the cameras.
    private static func report(_ site: Site) {
        // No `centreZ` to match: every camera below stands off one end of
        // the house rather than over its middle, so each names its own z.
        let centreX = Double(site.x) + Double(span) / 2
        let standing = Double(site.groundY + 1) + Double(PlayerController.standingEyeHeight)
        let inside = Double(site.floorY + 1) + Double(PlayerController.standingEyeHeight)
        var lines = [
            "[house] origin \(site.x),\(site.z) ground y \(site.groundY) floor y \(site.floorY)",
            String(format: "[house] eye-outside %.1f,%.1f,%.1f",
                   centreX, standing, Double(site.z + span) + 7.5),
            String(format: "[house] eye-porch %.1f,%.1f,%.1f",
                   centreX, standing, Double(site.z + span) + 2.5),
            String(format: "[house] eye-inside %.1f,%.1f,%.1f",
                   Double(site.x + span - 2) + 0.5, inside, Double(site.z + span - 2) + 0.5),
            String(format: "[house] eye-aerial %.1f,%.1f,%.1f",
                   centreX - 11, Double(site.groundY) + 13, Double(site.z + span) + 11),
        ]
        lines.append("")
        StandardError.write(Data(lines.joined(separator: "\n").utf8))
    }
}

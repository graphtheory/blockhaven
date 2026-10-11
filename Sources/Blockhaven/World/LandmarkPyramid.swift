import Foundation

extension Landmarks {
    /// The Great Pyramid of Giza: forty-three courses of solid sandstone on
    /// an eighty-five-block base, a gold cap, and a treasure chamber in the
    /// middle of it with a corridor you can walk in through.
    ///
    /// Over one hundred thousand blocks, and that number is the design
    /// brief rather than a consequence: the pyramid is the demo's proof
    /// that the engine holds a structure of that size without blinking.
    /// The edit journal takes every one of these writes before a single
    /// chunk exists, exactly as it takes the other landmarks' — this is
    /// just far more of them.
    static func greatPyramid(
        originX: Int, groundY: Int, originZ: Int, in world: World
    ) {
        GreatPyramid(originX: originX, groundY: groundY, originZ: originZ, world: world)
            .build()
    }

    /// How far above its ground the pyramid's highest block lands: the
    /// apex capstone plus the beacon torch standing on it.
    ///
    /// Published for the same reason `eiffelHeight` is: `setBlock` drops
    /// anything above the world's ceiling without a word, and only a
    /// builder that says what it was aiming at lets a decapitated pyramid
    /// fail out loud instead of reading as a slightly shorter one.
    static let pyramidTop = GreatPyramid.courses + 1

    /// The corridor, in world coordinates: every cell of the walk from the
    /// sand outside the entrance, through the doorway, to the edge of the
    /// treasure. One flight, flat the whole way — a pyramid you cannot
    /// walk into is a very large paperweight, and this list is what lets
    /// the check walk it with the player's own body rather than assert
    /// that a tunnel-shaped hole exists.
    static func pyramidRoute(
        originX: Int, groundY: Int, originZ: Int
    ) -> [[(x: Int, y: Int, z: Int)]] {
        [(originX - GreatPyramid.baseHalf - 2...originX - 3).map {
            (x: $0, y: groundY + 1, z: originZ)
        }]
    }

    /// Every painted capital on the approach — colonnade, door portico and
    /// pool court — in world coordinates. Published so `DemoCheck` counts
    /// the cells the builder wrote rather than cells it imagined.
    static func pyramidCapitals(
        originX: Int, groundY: Int, originZ: Int
    ) -> [(x: Int, y: Int, z: Int)] {
        GreatPyramid.capitalCells(originX: originX, groundY: groundY, originZ: originZ)
    }

    /// The two obelisks' gold pyramidions, in world coordinates.
    static func pyramidObeliskCaps(
        originX: Int, groundY: Int, originZ: Int
    ) -> [(x: Int, y: Int, z: Int)] {
        let x = originX - 48
        return [-5, 5].map { (x: x, y: groundY + 11, z: originZ + $0) }
    }

    /// The two secret doors: the single carved block in the corridor's
    /// north wall, and the single carved tile in the crypt's ceiling patch.
    /// Each is the one block a finder mines, so each check can mine it too.
    static func pyramidSecretMarkers(
        originX: Int, groundY: Int, originZ: Int
    ) -> [(x: Int, y: Int, z: Int)] {
        [
            (x: originX - 25, y: groundY + 1, z: originZ - 2),
            (x: originX + 5, y: groundY, z: originZ + 5),
        ]
    }
}

/// The builder. A struct rather than a bag of static functions for the
/// same reason `EiffelTower` is one: the origin and the ground thread
/// through every line, and passing them forty times is how coordinates
/// drift.
struct GreatPyramid {
    let originX: Int
    let groundY: Int
    let originZ: Int
    let world: World

    /// Half the base. The real pyramid is 230 m wide and 147 m tall, a
    /// ratio of about 1.6; an 85-block base under 43 courses is twice as
    /// steep — deliberately. The true slope at this scale is a hill you
    /// walk up without noticing, and the silhouette everybody knows is the
    /// one from photographs, which foreshortening has already steepened.
    /// What survives scaling is "each course one block in", and that is
    /// what is built.
    static let baseHalf = 42
    /// One course per block of half-width, so the apex is a single block.
    static let courses = baseHalf + 1

    /// The flattened desert the pyramid stands on. Just wide enough to
    /// catch the base's corners — they reach `baseHalf * √2 ≈ 59.4` from
    /// the centre — because a corner hanging over unflattened hillside is
    /// a corner floating in the air.
    static let apronRadius = 60

    /// The treasure chamber: seventeen blocks square, six tall, dead
    /// centre. Big enough to feel found rather than entered; low enough
    /// that course six, thirty-seven blocks a side, roofs it with plenty
    /// of pyramid still overhead.
    static let chamberHalf = 8
    static let chamberHeight = 6

    /// Courses with a half-width of two or less are gold: a 5×5, a 3×3 and
    /// the capstone, thirty-five blocks. The real capstone was probably
    /// gilded; this one outdoes it because thirty-five blocks of glint is
    /// what reads as "gold cap" from the plaza, and one block is a yellow
    /// pixel.
    private static let goldFromHalf = 2

    func build() {
        apron()
        masonry()
        chamber()
        corridor()
        secretRooms()
        furniture()
        causeway()
        obelisks()
        sphinx()
        poolCourt()
    }

    /// Where every painted capital on the approach stands. Static, and the
    /// single source both for the builder and for `DemoCheck` — a check
    /// that keeps its own copy of the colonnade stops being a check the
    /// first time a column moves.
    ///
    /// Three groups: the colonnade pairs down the causeway, the portico
    /// pair flanking the door itself, and the ring around the pool court.
    static func capitalCells(
        originX: Int, groundY: Int, originZ: Int
    ) -> [(x: Int, y: Int, z: Int)] {
        var cells: [(x: Int, y: Int, z: Int)] = []
        for dx in [-66, -60, -54] {
            for dz in [-4, 4] {
                cells.append((x: originX + dx, y: groundY + 5, z: originZ + dz))
            }
        }
        for dz in [-3, 3] {
            cells.append((x: originX - baseHalf - 1, y: groundY + 5, z: originZ + dz))
        }
        for (dx, dz) in [
            (-56, 7), (-50, 7), (-44, 7), (-56, 17), (-50, 17), (-44, 17),
            (-56, 12), (-44, 12),
        ] {
            cells.append((x: originX + dx, y: groundY + 4, z: originZ + dz))
        }
        return cells
    }

    /// A circle of desert at deck height, the same shape of work as the
    /// site's own `flattenPlot` and sized off the terrain for the same
    /// reason: fill only up to where the ground stops, clear only up to
    /// where it reached.
    private func apron() {
        for dz in -GreatPyramid.apronRadius...GreatPyramid.apronRadius {
            for dx in -GreatPyramid.apronRadius...GreatPyramid.apronRadius {
                guard Double(dx * dx + dz * dz).squareRoot()
                    <= Double(GreatPyramid.apronRadius) else { continue }
                let x = originX + dx, z = originZ + dz
                let surface = world.generator.surfaceHeight(x: x, z: z)

                let floor = max(groundY - 16, min(surface, groundY - 1))
                for y in floor...(groundY - 1) {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .dirt, remesh: false)
                }
                // Sand, not grass: a pyramid stands in a desert, and the
                // apron changing underfoot is what tells you that you have
                // walked somewhere else.
                world.setBlock(worldX: x, y: groundY, worldZ: z, to: .sand, remesh: false)

                let clearTo = min(Landmarks.ceiling, max(groundY, surface + 8))
                guard clearTo > groundY else { continue }
                for y in (groundY + 1)...clearTo {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }
    }

    /// The pyramid itself: one solid square per course, each a block
    /// narrower than the one under it. Solid on purpose — a shell this
    /// size would save writes and cost the one thing the pyramid is for,
    /// which is being a hundred thousand real blocks you can mine a hole
    /// into anywhere and find more pyramid.
    private func masonry() {
        for course in 0..<GreatPyramid.courses {
            let half = GreatPyramid.baseHalf - course
            Landmarks.fill(
                world,
                x: (originX - half)...(originX + half),
                y: (groundY + 1 + course)...(groundY + 1 + course),
                z: (originZ - half)...(originZ + half),
                half <= GreatPyramid.goldFromHalf ? .goldBlock : .sandstone
            )
        }
    }

    /// The treasure chamber: walls lined with carved sandstone first, then
    /// the room cut out of the middle of them. The lining goes down before
    /// the carving because the corridor has to cut a doorway *through* the
    /// lined wall — last write wins, and the order is the doorway.
    private func chamber() {
        let half = GreatPyramid.chamberHalf
        Landmarks.walls(
            world,
            x: (originX - half - 1)...(originX + half + 1),
            y: (groundY + 1)...(groundY + GreatPyramid.chamberHeight),
            z: (originZ - half - 1)...(originZ + half + 1),
            .sandstoneCarved
        )
        Landmarks.fill(
            world,
            x: (originX - half)...(originX + half),
            y: (groundY + 1)...(groundY + GreatPyramid.chamberHeight),
            z: (originZ - half)...(originZ + half),
            .air
        )
    }

    /// The way in: three blocks wide, three tall, straight from the west
    /// face to the chamber at ground level. West because that is where the
    /// rest of the demo is — the real entrance faces north, and a kid
    /// arriving from the plaza will never find a door on the far side of
    /// an eighty-five-block building.
    ///
    /// Flat the whole way, which is not what Giza does either, and is the
    /// point: the corridor exists to be walked by whoever the demo is
    /// being shown to, not to teach Egyptology.
    private func corridor() {
        Landmarks.fill(
            world,
            x: (originX - GreatPyramid.baseHalf)...(originX - GreatPyramid.chamberHalf - 1),
            y: (groundY + 1)...(groundY + 3),
            z: (originZ - 1)...(originZ + 1),
            .air
        )

        // A carved doorframe on the face, following the slope: jambs two
        // blocks out from the opening, a lintel over the top. It replaces
        // face blocks course by course, so each frame cell sits on the
        // course whose face it is.
        for step in 0...2 {
            let x = originX - GreatPyramid.baseHalf + step
            for dz in [-2, 2] {
                world.setBlock(
                    worldX: x, y: groundY + 1 + step, worldZ: originZ + dz,
                    to: .sandstoneCarved, remesh: false
                )
            }
        }
        for dz in -2...2 {
            world.setBlock(
                worldX: originX - GreatPyramid.baseHalf + 3, y: groundY + 4,
                worldZ: originZ + dz,
                to: .sandstoneCarved, remesh: false
            )
        }
    }

    /// What the chamber is for, and the light to see it by.
    private func furniture() {
        // The treasure: a carved plinth, nine blocks of gold, and a single
        // diamond ore on top — something worth the walk, made of things
        // worth mining.
        Landmarks.fill(
            world,
            x: (originX - 1)...(originX + 1), y: (groundY + 1)...(groundY + 1),
            z: (originZ - 1)...(originZ + 1), .sandstoneCarved
        )
        Landmarks.fill(
            world,
            x: (originX - 1)...(originX + 1), y: (groundY + 2)...(groundY + 2),
            z: (originZ - 1)...(originZ + 1), .goldBlock
        )
        world.setBlock(
            worldX: originX, y: groundY + 3, worldZ: originZ,
            to: .diamondBlock, remesh: false
        )

        // Torches on the corners of the gold, because the treasure is the
        // thing the room is arranged around and fourteen blocks of light
        // from the corners of a seventeen-block room leaves the middle —
        // which is here — black.
        for (dx, dz) in [(-1, -1), (-1, 1), (1, -1), (1, 1)] {
            Landmarks.torch(world, x: originX + dx, y: groundY + 3, z: originZ + dz)
        }
        // And in the room's own corners, so the walls read as walls rather
        // than as the edge of the dark.
        let corner = GreatPyramid.chamberHalf
        for (dx, dz) in [(-corner, -corner), (-corner, corner), (corner, -corner), (corner, corner)] {
            Landmarks.torch(world, x: originX + dx, y: groundY + 1, z: originZ + dz)
        }

        // Down the corridor, alternating sides: enough to walk by, spaced
        // wide enough that the doorway still reads as the bright end.
        var side = 1
        for x in stride(from: originX - 38, through: originX - 12, by: 8) {
            Landmarks.torch(world, x: x, y: groundY + 1, z: originZ + side)
            side = -side
        }
        // Flanking the entrance, on the sand outside.
        for dz in [-2, 2] {
            Landmarks.torch(
                world, x: originX - GreatPyramid.baseHalf - 2, y: groundY + 1,
                z: originZ + dz
            )
        }

        // The beacon: one torch on the capstone, for whoever climbs all
        // forty-three courses — and for everyone else, a lit summit after
        // dark, which is how a landmark earns its keep at night.
        Landmarks.torch(world, x: originX, y: groundY + GreatPyramid.courses + 1, z: originZ)
    }

    // MARK: - The approach

    /// One painted column: a carved plinth in the ground, a fluted shaft,
    /// the painted capital, and a torch burning on top — so the whole
    /// approach is an avenue of lights after dark.
    private func column(x: Int, z: Int, capitalY: Int) {
        world.setBlock(worldX: x, y: groundY, worldZ: z, to: .sandstoneCarved, remesh: false)
        for y in (groundY + 1)..<capitalY {
            world.setBlock(worldX: x, y: y, worldZ: z, to: .sandstonePillar, remesh: false)
        }
        world.setBlock(worldX: x, y: capitalY, worldZ: z, to: .pillarCapital, remesh: false)
        Landmarks.torch(world, x: x, y: capitalY + 1, z: z)
    }

    /// The processional way: a five-wide paved causeway with carved
    /// borders, running from the lawn through a pylon gate and down a
    /// double colonnade to the door. This is the reference everybody has
    /// seen — the long straight approach that makes the pyramid arrive
    /// slowly instead of suddenly.
    private func causeway() {
        let doorX = originX - GreatPyramid.baseHalf - 1
        for x in (originX - 70)...doorX {
            for dz in -2...2 {
                world.setBlock(worldX: x, y: groundY, worldZ: originZ + dz,
                               to: .sandstone, remesh: false)
            }
            for dz in [-3, 3] {
                world.setBlock(worldX: x, y: groundY, worldZ: originZ + dz,
                               to: .sandstoneCarved, remesh: false)
            }
        }

        // The pylon gate: two solid towers flanking the way with a carved
        // lintel bridging them, so the causeway begins with a doorway —
        // an approach you *enter*, five blocks before you have entered
        // anything.
        for side in [-1, 1] {
            let near = originZ + 3 * side, far = originZ + 7 * side
            let towerZ = min(near, far)...max(near, far)
            Landmarks.fill(
                world,
                x: (originX - 73)...(originX - 71),
                y: (groundY + 1)...(groundY + 6),
                z: towerZ,
                .sandstone
            )
            Landmarks.fill(
                world,
                x: (originX - 73)...(originX - 71),
                y: (groundY + 7)...(groundY + 7),
                z: towerZ,
                .sandstoneCarved
            )
            Landmarks.torch(world, x: originX - 72, y: groundY + 8, z: originZ + 4 * side)
            Landmarks.torch(world, x: originX - 72, y: groundY + 8, z: originZ + 6 * side)
        }
        Landmarks.fill(
            world,
            x: (originX - 73)...(originX - 71),
            y: (groundY + 6)...(groundY + 7),
            z: (originZ - 2)...(originZ + 2),
            .sandstoneCarved
        )

        // Every column on the approach, from the published list, so the
        // builder and the check can never disagree about where they are.
        for cell in GreatPyramid.capitalCells(
            originX: originX, groundY: groundY, originZ: originZ
        ) {
            column(x: cell.x, z: cell.z, capitalY: cell.y)
        }
    }

    /// Two obelisks flanking the last stretch before the door: a carved
    /// plinth, a slender fluted shaft, and a gold pyramidion that catches
    /// the sun the way the real ones were built to.
    private func obelisks() {
        for side in [-1, 1] {
            let z = originZ + 5 * side
            Landmarks.fill(
                world,
                x: (originX - 49)...(originX - 47),
                y: (groundY + 1)...(groundY + 1),
                z: (z - 1)...(z + 1),
                .sandstoneCarved
            )
            for y in (groundY + 2)...(groundY + 10) {
                world.setBlock(worldX: originX - 48, y: y, worldZ: z,
                               to: .sandstonePillar, remesh: false)
            }
            world.setBlock(worldX: originX - 48, y: groundY + 11, worldZ: z,
                           to: .goldBlock, remesh: false)
        }
    }

    /// The sphinx: couched beside the causeway on a carved platform, paws
    /// stretched toward whoever is walking up, gold nemes flaps on the
    /// head. Blocky on purpose — at this scale a sphinx is a silhouette
    /// with a headdress, and the gold is what says which end thinks.
    private func sphinx() {
        Landmarks.fill(
            world,
            x: (originX - 57)...(originX - 43), y: groundY...groundY,
            z: (originZ - 15)...(originZ - 7), .sandstoneCarved
        )
        // Forepaws, two blocks wide each, reaching west.
        for pawZ in [originZ - 13, originZ - 10] {
            Landmarks.fill(
                world,
                x: (originX - 56)...(originX - 51), y: (groundY + 1)...(groundY + 1),
                z: pawZ...(pawZ + 1), .sandstone
            )
        }
        // The body, its raised haunches, and the shoulders.
        Landmarks.fill(
            world,
            x: (originX - 51)...(originX - 44), y: (groundY + 1)...(groundY + 3),
            z: (originZ - 14)...(originZ - 8), .sandstone
        )
        Landmarks.fill(
            world,
            x: (originX - 48)...(originX - 44), y: (groundY + 4)...(groundY + 4),
            z: (originZ - 14)...(originZ - 8), .sandstone
        )
        Landmarks.fill(
            world,
            x: (originX - 51)...(originX - 50), y: (groundY + 4)...(groundY + 4),
            z: (originZ - 13)...(originZ - 9), .sandstone
        )
        // The head, the gold nemes flaps beside it, and the crown — one
        // gold block front and centre, where a uraeus goes.
        Landmarks.fill(
            world,
            x: (originX - 51)...(originX - 49), y: (groundY + 5)...(groundY + 7),
            z: (originZ - 12)...(originZ - 10), .sandstone
        )
        for flapZ in [originZ - 13, originZ - 9] {
            Landmarks.fill(
                world,
                x: (originX - 51)...(originX - 49), y: (groundY + 5)...(groundY + 6),
                z: flapZ...flapZ, .goldBlock
            )
        }
        Landmarks.fill(
            world,
            x: (originX - 51)...(originX - 49), y: (groundY + 8)...(groundY + 8),
            z: (originZ - 12)...(originZ - 10), .sandstoneCarved
        )
        world.setBlock(worldX: originX - 51, y: groundY + 8, worldZ: originZ - 11,
                       to: .goldBlock, remesh: false)
    }

    /// The pool court: a paved peristyle south of the causeway with a
    /// reflecting pool in the middle — the painted columns standing round
    /// still water, which is the whole reason to paint a column.
    private func poolCourt() {
        Landmarks.fill(
            world,
            x: (originX - 56)...(originX - 44), y: groundY...groundY,
            z: (originZ + 7)...(originZ + 17), .sandstoneCarved
        )
        Landmarks.fill(
            world,
            x: (originX - 53)...(originX - 47), y: (groundY - 1)...(groundY - 1),
            z: (originZ + 10)...(originZ + 14), .sandstone
        )
        Landmarks.fill(
            world,
            x: (originX - 53)...(originX - 47), y: groundY...groundY,
            z: (originZ + 10)...(originZ + 14), .water
        )
        // The columns themselves go up with the rest of the colonnade —
        // `causeway()` builds every published capital, this ring included.
    }

    // MARK: - The secret rooms

    /// Two rooms the chamber does not tell you about.
    ///
    /// Neither is very hidden, deliberately: each is behind exactly one
    /// carved block set where every other block is plain, which is a
    /// secret at the difficulty of "notice one block is different" — the
    /// right difficulty for the person the demo is for.
    private func secretRooms() {
        // The serdab: a treasure room in the thickness of the corridor's
        // north wall. One carved block among the plain sandstone marks
        // the door; mine it and you are in.
        Landmarks.fill(
            world,
            x: (originX - 27)...(originX - 23), y: (groundY + 1)...(groundY + 3),
            z: (originZ - 6)...(originZ - 3), .air
        )
        Landmarks.fill(
            world,
            x: (originX - 27)...(originX - 23), y: groundY...groundY,
            z: (originZ - 6)...(originZ - 3), .sandstoneCarved
        )
        world.setBlock(worldX: originX - 25, y: groundY + 1, worldZ: originZ - 2,
                       to: .sandstoneCarved, remesh: false)
        for dx in [-1, 1] {
            world.setBlock(worldX: originX - 25 + dx, y: groundY + 1, worldZ: originZ - 5,
                           to: .goldBlock, remesh: false)
        }
        world.setBlock(worldX: originX - 25, y: groundY + 1, worldZ: originZ - 5,
                       to: .sandstoneCarved, remesh: false)
        world.setBlock(worldX: originX - 25, y: groundY + 2, worldZ: originZ - 5,
                       to: .diamondOre, remesh: false)
        Landmarks.torch(world, x: originX - 27, y: groundY + 1, z: originZ - 6)
        Landmarks.torch(world, x: originX - 23, y: groundY + 1, z: originZ - 6)

        // The crypt: under the treasure chamber's own sand floor. A patch
        // of the floor is sandstone rather than sand — the tell — and one
        // tile of the patch is carved: mine that tile, drop through, and
        // the pharaoh is below, in gold, with two diamonds at their head.
        // Carved steps under the hole climb back out.
        Landmarks.fill(
            world,
            x: (originX - 2)...(originX + 6), y: (groundY - 4)...(groundY - 1),
            z: originZ...(originZ + 7), .sandstoneCarved
        )
        Landmarks.fill(
            world,
            x: (originX - 2)...(originX + 6), y: groundY...groundY,
            z: originZ...(originZ + 7), .sandstone
        )
        Landmarks.fill(
            world,
            x: (originX - 1)...(originX + 5), y: (groundY - 3)...(groundY - 1),
            z: (originZ + 1)...(originZ + 6), .air
        )
        world.setBlock(worldX: originX + 5, y: groundY, worldZ: originZ + 5,
                       to: .sandstoneCarved, remesh: false)
        // The sarcophagus: a carved base, a gold lid, diamonds at the head.
        Landmarks.fill(
            world,
            x: originX...(originX + 3), y: (groundY - 3)...(groundY - 3),
            z: (originZ + 3)...(originZ + 4), .sandstoneCarved
        )
        Landmarks.fill(
            world,
            x: originX...(originX + 3), y: (groundY - 2)...(groundY - 2),
            z: (originZ + 3)...(originZ + 4), .goldBlock
        )
        for dz in [3, 4] {
            world.setBlock(worldX: originX, y: groundY - 1, worldZ: originZ + dz,
                           to: .diamondBlock, remesh: false)
        }
        // The way back up: two steps rising to just under the hole.
        world.setBlock(worldX: originX + 4, y: groundY - 3, worldZ: originZ + 5,
                       to: .sandstoneCarved, remesh: false)
        world.setBlock(worldX: originX + 5, y: groundY - 3, worldZ: originZ + 5,
                       to: .sandstoneCarved, remesh: false)
        world.setBlock(worldX: originX + 5, y: groundY - 2, worldZ: originZ + 5,
                       to: .sandstoneCarved, remesh: false)
        Landmarks.torch(world, x: originX - 1, y: groundY - 3, z: originZ + 1)
        Landmarks.torch(world, x: originX - 1, y: groundY - 3, z: originZ + 6)
        Landmarks.torch(world, x: originX + 5, y: groundY - 3, z: originZ + 1)
    }
}

import Foundation

extension Landmarks {
    /// Atlantis: a sunken city under glass, twenty blocks down in a sea the
    /// builder dredges for itself.
    ///
    /// The parts, from the shore in: a seaStone lighthouse on the beach
    /// whose only door opens onto a staircase going *down*; a glass tunnel
    /// a hundred blocks long across the seabed; a grand dome seventeen
    /// blocks high with a golden trident at its heart; a garden growing
    /// under its own glass; a hedge-maze of sea-stone with a crypt full of
    /// treasure beneath its centre; and ruined columns scattered across the
    /// sand between them, because a city this old should look like more of
    /// it existed once.
    ///
    /// The dredging is the part the terrain made necessary: this seed's sea
    /// bottoms out around eight blocks deep, which drowns nothing taller
    /// than a shed. The builder excavates a basin a hundred and ten blocks
    /// across down to its own floor and fills the hole with water — journal
    /// writes like every other block here — so the domes stand in twenty
    /// blocks of sea that the map never offered.
    static func atlantis(originX: Int, groundY: Int, originZ: Int, in world: World) {
        Atlantis(originX: originX, groundY: groundY, originZ: originZ, world: world).build()
    }

    /// The walk in, as one route: off the beach, through the lighthouse
    /// door, twenty-one treads down under the shoreline, along the whole
    /// length of the sea tunnel, and up to the foot of the trident. The
    /// check drives a body down every cell of it, which is the only
    /// evidence worth having that a staircase under a beach and a tunnel
    /// under a sea are passable rather than merely present.
    static func atlantisRoute(
        originX: Int, groundY: Int, originZ: Int
    ) -> [[(x: Int, y: Int, z: Int)]] {
        var cells: [(x: Int, y: Int, z: Int)] = []
        let doorX = originX + Atlantis.lighthouseOffset + Atlantis.towerRadius
        let treads = groundY - Atlantis.floorY
        // Off the lawn, through the door, across the tower floor.
        for x in stride(from: doorX + 2, through: Atlantis.stairTopX(originX) + 1, by: -1) {
            cells.append((x, groundY + 1, originZ))
        }
        // Down the stairs, one tread a block.
        for step in 0..<treads {
            cells.append((Atlantis.stairTopX(originX) - step, groundY - step, originZ))
        }
        // Along the tunnel floor and into the dome, stopping at the plinth.
        for x in stride(
            from: Atlantis.stairTopX(originX) - treads, through: originX + 3, by: -1
        ) {
            cells.append((x, Atlantis.floorY + 1, originZ))
        }
        return [cells]
    }

    /// Where the lighthouse beacon sits, so the check can ask that the one
    /// part of the city you can see from the plaza is really there and lit.
    static func atlantisBeacon(originX: Int, originZ: Int) -> (x: Int, y: Int, z: Int) {
        (originX + Atlantis.lighthouseOffset, Atlantis.beaconY, originZ)
    }
}

/// The builder. Origin is the centre of the grand dome; everything else —
/// satellites, tunnel, lighthouse — hangs off it along the axes, which is
/// what keeps a hundred blocks of route derivable by the check instead of
/// copied into it.
struct Atlantis {
    let originX: Int
    /// The ground the lighthouse stands on — the site's deck, since the
    /// tower's plot is inside the flattened circle. Everything above the
    /// water is measured from this; everything below is measured from
    /// `floorY`, and the staircase is exactly the distance between them.
    let groundY: Int
    let originZ: Int
    let world: World

    /// The city's own vertical datum: the dredged basin floor. Chosen, not
    /// measured — the whole point of dredging is that the seabed becomes a
    /// decision instead of terrain.
    static let floorY = 42

    /// The basin: flat at `floorY` out to `basinFlat`, then rising a block
    /// per block until it meets the natural seabed, so the hole reads as a
    /// deep place in the sea rather than as a cliff-walled quarry. The
    /// radius stops two blocks short of the site's flattened plot — a
    /// dredge that reached it would cut a flooded notch into the lawn.
    static let basinRadius = 52
    static let basinFlat = 42

    /// The grand dome, and the two satellites north and south. The grand
    /// dome's crown stops three blocks under the surface: a shape that
    /// glimmers through the waves reads as a discovery, where one poking
    /// out of them reads as a building with wet feet.
    static let grandRadius = 17
    static let gardenRadius = 11
    static let mazeRadius = 13
    static let satelliteOffset = 35

    /// The lighthouse, due east on the beach — the one piece of the city
    /// that admits it exists, and the landmark that tells whoever is on
    /// the plaza which way to walk.
    static let lighthouseOffset = 105
    static let towerRadius = 4
    static let towerTopY = 84
    static let beaconY = towerTopY + 1

    /// The descent: where the stairs start inside the tower, and how many
    /// treads they run. Twenty-one, from the shore down to the tunnel —
    /// each one a block west and a block down, the same geometry the
    /// tower's spiral uses, drawn straight. The top tread is one cell west
    /// of the tower's centre, so the hole in the ground floor is *in* the
    /// lighthouse: the door is the door to the deep.
    var stairTreads: Int { groundY - Atlantis.floorY }
    static func stairTopX(_ originX: Int) -> Int {
        originX + lighthouseOffset - 1
    }

    /// Everything random about the city — the maze, the ruins, the garden's
    /// planting — draws from this one fixed seed, which is what "the same
    /// demo every time" means when a builder wants disorder in it.
    static let citySeed: UInt64 = 0xA71A_0715

    func build() {
        dredgeBasin()
        shells()
        bores()
        furniture()
    }

    // MARK: - The sea

    /// Digs the basin and fills it with sea. Every column inside the circle
    /// is taken down to the basin's own profile wherever the terrain sits
    /// higher, floored with sand, and flooded to one block under sea level.
    /// Terrain already deeper than the profile is left exactly as found —
    /// the basin is a deepening, not a stamp.
    private func dredgeBasin() {
        for dz in -Atlantis.basinRadius...Atlantis.basinRadius {
            for dx in -Atlantis.basinRadius...Atlantis.basinRadius {
                let distance = Double(dx * dx + dz * dz).squareRoot()
                guard distance <= Double(Atlantis.basinRadius) else { continue }
                let x = originX + dx, z = originZ + dz
                let target = Atlantis.floorY
                    + max(0, Int(distance) - Atlantis.basinFlat)
                let surface = world.generator.surfaceHeight(x: x, z: z)
                guard surface > target else { continue }

                world.setBlock(worldX: x, y: target, worldZ: z, to: .sand, remesh: false)
                // To `seaLevel` inclusive, which is where the generator
                // tops its own ocean — a dredged column one block shy of
                // that reads as a square dent in the sea's surface.
                for y in (target + 1)...WorldGenerator.seaLevel {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .water, remesh: false)
                }
                // Anything the terrain held above the waterline — a dune, a
                // tree on a sandbar — goes too, or the sea has hair.
                if surface > WorldGenerator.seaLevel {
                    for y in (WorldGenerator.seaLevel + 1)...(surface + 8) {
                        world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                    }
                }
            }
        }
    }

    // MARK: - Shells

    /// Every enclosing surface, before anything is hollowed: the three
    /// domes, the tunnel, the lighthouse, the crypt. Shells first and bores
    /// second is the whole construction order — a doorway is a bore through
    /// a shell, and it only exists if the shell was there to be cut.
    private func shells() {
        // The domes: glass over a seaStone floor disc.
        for dome in domes() {
            Landmarks.disc(
                world, centreX: dome.x, y: Atlantis.floorY, centreZ: dome.z,
                radius: Double(dome.r), .seaStone
            )
            Landmarks.dome(
                world, centreX: dome.x, baseY: Atlantis.floorY, centreZ: dome.z,
                radius: Double(dome.r), .glass
            )
        }

        // The sea tunnel, east from the grand dome to the foot of the
        // stairs: glass walls and roof on a seaStone floor.
        let stairFoot = Atlantis.stairTopX(originX) - stairTreads
        for x in (originX + Atlantis.grandRadius - 1)...(stairFoot + 1) {
            tunnelRing(x: x, floor: Atlantis.floorY)
        }

        // The stair shaft, seaStone all round: it runs under the beach,
        // and a glass tube buried in sand is a wall of sand. A lantern in
        // the ceiling every sixth tread, or the descent is a walk into
        // the dark and the kid turns round at the third step.
        for step in -1...(stairTreads + 1) {
            let x = Atlantis.stairTopX(originX) - step
            let treadY = groundY - step
            Landmarks.fill(
                world,
                x: x...x, y: (treadY - 1)...(treadY + 5),
                z: (originZ - 2)...(originZ + 2), .seaStone
            )
            if step >= 0, step % 6 == 3 {
                world.setBlock(
                    worldX: x, y: treadY + 5, worldZ: originZ, to: .seaLantern, remesh: false
                )
            }
        }

        // The lighthouse: a platform footed into the beach, a drum of
        // seaStone, and a glass lantern room over it.
        let lx = originX + Atlantis.lighthouseOffset
        for r in 0...(Atlantis.towerRadius + 2) {
            Landmarks.disc(
                world, centreX: lx, y: groundY - r, centreZ: originZ,
                radius: Double(Atlantis.towerRadius + 2 - r), .seaStone
            )
        }
        Landmarks.cylinder(
            world, centreX: lx, baseY: groundY + 1, centreZ: originZ,
            radius: Double(Atlantis.towerRadius),
            height: Atlantis.towerTopY - groundY, .seaStone
        )
        Landmarks.disc(
            world, centreX: lx, y: Atlantis.towerTopY, centreZ: originZ,
            radius: Double(Atlantis.towerRadius) + 0.5, .seaStone
        )
        Landmarks.cylinder(
            world, centreX: lx, baseY: Atlantis.towerTopY + 1, centreZ: originZ,
            radius: Double(Atlantis.towerRadius) - 1, height: 4, .glass
        )
        Landmarks.disc(
            world, centreX: lx, y: Atlantis.towerTopY + 5, centreZ: originZ,
            radius: Double(Atlantis.towerRadius) - 0.5, .seaStone
        )
        // A level apron outside the door. The beach undulates by a block,
        // and a doorstep you have to jump onto is a door the walk check —
        // and a short person — cannot use.
        Landmarks.fill(
            world,
            x: (lx + Atlantis.towerRadius)...(lx + Atlantis.towerRadius + 5),
            y: groundY...groundY,
            z: (originZ - 2)...(originZ + 2), .seaStone
        )
        Landmarks.fill(
            world,
            x: (lx + Atlantis.towerRadius + 1)...(lx + Atlantis.towerRadius + 5),
            y: (groundY + 1)...(groundY + 4),
            z: (originZ - 2)...(originZ + 2), .air
        )

        // The crypt under the maze: an obsidian box whose ceiling is the
        // maze dome's own floor.
        Landmarks.fill(
            world,
            x: (originX - 4)...(originX + 4),
            y: (Atlantis.floorY - 7)...(Atlantis.floorY),
            z: (mazeZ - 4)...(mazeZ + 4), .obsidian
        )
    }

    /// One vertical ring of the sea tunnel at `x`: a 5×5 cross-section,
    /// seaStone underfoot and glass everywhere else, so the walk is a
    /// floor with the whole sea around it. Every eighth ring's centre
    /// floor block is a lantern — a hundred blocks of unlit tube under a
    /// dark sea is a corridor nobody's kid walks twice.
    private func tunnelRing(x: Int, floor: Int) {
        for dz in -2...2 {
            for dy in 0...4 {
                let onEdge = abs(dz) == 2 || dy == 0 || dy == 4
                guard onEdge else { continue }
                let lit = dy == 0 && dz == 0 && x % 8 == 0
                world.setBlock(
                    worldX: x, y: floor + dy, worldZ: originZ + dz,
                    to: lit ? .seaLantern : (dy == 0 ? .seaStone : .glass), remesh: false
                )
            }
        }
    }

    // MARK: - Bores

    /// All the air: dome interiors, the tunnel's bore, the stairwell, the
    /// tower's rooms, the crypt, and every doorway between them — cut last,
    /// so a bore through two shells at once opens both.
    private func bores() {
        for dome in domes() {
            hollow(x: dome.x, z: dome.z, radius: dome.r)
        }

        // The tunnel and the stair shaft, one straight air slot from the
        // inside of the grand dome to the inside of the tower.
        let stairFoot = Atlantis.stairTopX(originX) - stairTreads
        Landmarks.fill(
            world,
            x: (originX + Atlantis.grandRadius - 2)...(stairFoot + 1),
            y: (Atlantis.floorY + 1)...(Atlantis.floorY + 3),
            z: (originZ - 1)...(originZ + 1), .air
        )
        for step in 0..<stairTreads {
            let x = Atlantis.stairTopX(originX) - step
            let treadY = groundY - step
            Landmarks.fill(
                world,
                x: x...x, y: treadY...(treadY + 4),
                z: (originZ - 1)...(originZ + 1), .air
            )
        }

        // The tower: hollow inside, floored at the shore, with a doorway
        // out east toward the plaza and the stair mouth opening west.
        let lx = originX + Atlantis.lighthouseOffset
        for level in 1...(Atlantis.towerTopY - groundY - 1) {
            Landmarks.disc(
                world, centreX: lx, y: groundY + level, centreZ: originZ,
                radius: Double(Atlantis.towerRadius) - 1, .air
            )
        }
        Landmarks.fill(
            world,
            x: (lx + Atlantis.towerRadius)...(lx + Atlantis.towerRadius),
            y: (groundY + 1)...(groundY + 3),
            z: (originZ - 1)...(originZ + 1), .air
        )

        // The two satellite tunnels, north to the garden and south to the
        // maze: short seaStone-floored glass links along z.
        satelliteLink(toZ: gardenZ, radius: Atlantis.gardenRadius)
        satelliteLink(toZ: mazeZ, radius: Atlantis.mazeRadius)

        // The crypt's room. Its doorway is the hole in the maze floor,
        // which is `furniture`'s business, stairs and all.
        Landmarks.fill(
            world,
            x: (originX - 3)...(originX + 3),
            y: (Atlantis.floorY - 6)...(Atlantis.floorY - 1),
            z: (mazeZ - 3)...(mazeZ + 3), .air
        )
    }

    /// A link tunnel along z between the grand dome and a satellite,
    /// shell and bore in one because unlike the sea tunnel it is short
    /// enough to write in a single pass.
    private func satelliteLink(toZ: Int, radius: Int) {
        let sign = toZ > originZ ? 1 : -1
        let from = originZ + sign * (Atlantis.grandRadius - 2)
        let to = toZ - sign * (radius - 2)
        for z in stride(from: from, through: to, by: sign) {
            for dx in -2...2 {
                for dy in 0...4 {
                    let onEdge = abs(dx) == 2 || dy == 0 || dy == 4
                    world.setBlock(
                        worldX: originX + dx, y: Atlantis.floorY + dy, worldZ: z,
                        to: onEdge ? (dy == 0 ? .seaStone : .glass) : .air,
                        remesh: false
                    )
                }
            }
        }
    }

    /// Empties a dome: everything strictly inside the shell becomes air,
    /// including the water the dredge put there first.
    private func hollow(x: Int, z: Int, radius: Int) {
        for dy in 1...radius {
            for dz in -radius...radius {
                for dx in -radius...radius {
                    // Strictly less than the shell's own inner bound — the
                    // exact complement of `Landmarks.dome`'s guard, so no
                    // cell is both carved and shell, and none is neither.
                    // A band of neither is a ring of the dredge's water
                    // hanging inside the glass.
                    let d = Double(dx * dx + dy * dy + dz * dz).squareRoot()
                    guard d < Double(radius) - 0.9 else { continue }
                    world.setBlock(
                        worldX: x + dx, y: Atlantis.floorY + dy, worldZ: z + dz,
                        to: .air, remesh: false
                    )
                }
            }
        }
    }

    // MARK: - Furniture

    private func furniture() {
        var rng = SeededGenerator(seed: Atlantis.citySeed)
        stairs()
        grandDome()
        garden(&rng)
        maze(&rng)
        crypt()
        ruins(&rng)
        beacon()
    }

    /// The staircase itself: three treads wide, each course turned east,
    /// because east is the way you climb back out.
    private func stairs() {
        for step in 0..<stairTreads {
            let x = Atlantis.stairTopX(originX) - step
            let treadY = groundY - step
            for dz in -1...1 {
                world.setBlock(
                    worldX: x, y: treadY, worldZ: originZ + dz,
                    to: .cobbleStairs(.east), remesh: false
                )
            }
        }
    }

    /// The heart of the city: a golden trident on a plinth, pillars with
    /// lanterns round it, under the highest glass in the sea.
    private func grandDome() {
        Landmarks.fill(
            world,
            x: (originX - 1)...(originX + 1),
            y: (Atlantis.floorY + 1)...(Atlantis.floorY + 1),
            z: (originZ - 1)...(originZ + 1), .seaStone
        )
        // The trident: a haft up the middle, a crossbar, three tines off
        // it, the centre one a block taller. Placed cell by cell — at this
        // scale the shape is the whole statue.
        for y in (Atlantis.floorY + 2)...(Atlantis.floorY + 8) {
            world.setBlock(worldX: originX, y: y, worldZ: originZ, to: .goldBlock, remesh: false)
        }
        for dz in -1...1 {
            world.setBlock(
                worldX: originX, y: Atlantis.floorY + 9, worldZ: originZ + dz,
                to: .goldBlock, remesh: false
            )
            world.setBlock(
                worldX: originX, y: Atlantis.floorY + 10, worldZ: originZ + dz,
                to: .goldBlock, remesh: false
            )
        }
        // The middle tine is tipped with diamond, and the diamond glows:
        // at night the top of the trident is a point of light under
        // twenty blocks of dark water, which is the single shiniest thing
        // this city can do.
        world.setBlock(
            worldX: originX, y: Atlantis.floorY + 11, worldZ: originZ,
            to: .diamondBlock, remesh: false
        )

        // Four pillars on the diagonals, lanterns on top, and lanterns at
        // the plinth's corners: the room's light is arranged around the
        // thing it is for.
        for (sx, sz) in [(-1, -1), (-1, 1), (1, -1), (1, 1)] {
            let px = originX + sx * 8, pz = originZ + sz * 8
            for y in (Atlantis.floorY + 1)...(Atlantis.floorY + 4) {
                world.setBlock(worldX: px, y: y, worldZ: pz, to: .seaStone, remesh: false)
            }
            world.setBlock(
                worldX: px, y: Atlantis.floorY + 5, worldZ: pz, to: .seaLantern, remesh: false
            )
            world.setBlock(
                worldX: originX + sx, y: Atlantis.floorY + 2, worldZ: originZ + sz,
                to: sx * sz > 0 ? .seaLantern : .goldBlock, remesh: false
            )
        }
    }

    /// A garden under glass: grass, two trees, and whatever the seed
    /// scatters — the one room in the sea where something is alive.
    private func garden(_ rng: inout SeededGenerator) {
        Landmarks.disc(
            world, centreX: originX, y: Atlantis.floorY, centreZ: gardenZ,
            radius: Double(Atlantis.gardenRadius) - 1.2, .grass
        )
        for (tx, tz) in [(originX - 4, gardenZ - 3), (originX + 4, gardenZ + 3)] {
            for y in (Atlantis.floorY + 1)...(Atlantis.floorY + 4) {
                world.setBlock(worldX: tx, y: y, worldZ: tz, to: .log, remesh: false)
            }
            for dy in 0...2 {
                Landmarks.disc(
                    world, centreX: tx, y: Atlantis.floorY + 4 + dy, centreZ: tz,
                    radius: dy == 1 ? 2.2 : 1.4, .leaves
                )
            }
        }
        // The planting. Nothing here may *read* the world — at build time
        // no chunk exists and every read answers air — so where a flower
        // can go is decided by the same arithmetic that laid the floor:
        // inside the grass disc, not on a trunk, one plant per cell.
        let flowers: [BlockType] = [.poppy, .dandelion, .cornflower, .tallGrass, .tallGrass]
        let trunks = [(originX - 4, gardenZ - 3), (originX + 4, gardenZ + 3)]
        var planted = Set<Int>()
        for _ in 0..<24 {
            let dx = Int(rng.next() % 15) - 7
            let dz = Int(rng.next() % 15) - 7
            let kind = flowers[Int(rng.next() % UInt64(flowers.count))]
            guard dx * dx + dz * dz <= 49 else { continue }
            let x = originX + dx, z = gardenZ + dz
            guard !trunks.contains(where: { $0.0 == x && $0.1 == z }),
                  planted.insert(dx * 64 + dz).inserted else { continue }
            world.setBlock(
                worldX: x, y: Atlantis.floorY + 1, worldZ: z, to: kind, remesh: false
            )
        }
        // One radiant lamp in each corner instead of four white ones: the
        // garden is the city's one living room, and it gets the colour.
        let corners: [(sx: Int, sz: Int, lamp: BlockType)] = [
            (-1, -1, .radiantRed), (-1, 1, .radiantYellow),
            (1, -1, .radiantGreen), (1, 1, .radiantCyan),
        ]
        for corner in corners {
            // A sea lantern in the ground under each pane — a transparent
            // lamp over dark dirt is a picture frame with no picture.
            world.setBlock(
                worldX: originX + corner.sx * 6, y: Atlantis.floorY,
                worldZ: gardenZ + corner.sz * 6,
                to: .seaLantern, remesh: false
            )
            world.setBlock(
                worldX: originX + corner.sx * 6, y: Atlantis.floorY + 1,
                worldZ: gardenZ + corner.sz * 6,
                to: corner.lamp, remesh: false
            )
        }
    }

    /// The maze: a fifteen-block square of two-high seaStone hedges cut
    /// by a depth-first carve, so it is a real maze — every cell reachable,
    /// exactly one route between any two — rather than wiggly decoration.
    /// The way in faces the tunnel from the grand dome; the centre cell is
    /// open floor with a hole in it, and the hole is the way down.
    private func maze(_ rng: inout SeededGenerator) {
        let half = 7
        // The floor first, because the crypt's obsidian box below tops out
        // at exactly this level: without re-laying it the centre of the
        // maze walks on bare obsidian, and a black floor in a sea-green
        // maze reads as a hole, not a path. The crypt carves its own hatch
        // back through this afterwards.
        Landmarks.fill(
            world,
            x: (originX - half)...(originX + half),
            y: Atlantis.floorY...Atlantis.floorY,
            z: (mazeZ - half)...(mazeZ + half), .seaStone
        )
        // Walls everywhere first.
        Landmarks.fill(
            world,
            x: (originX - half)...(originX + half),
            y: (Atlantis.floorY + 1)...(Atlantis.floorY + 2),
            z: (mazeZ - half)...(mazeZ + half), .seaStone
        )

        // Depth-first search over the 7×7 lattice of odd cells, knocking
        // through the wall between each cell and the unvisited neighbour
        // the seed picks. Iterative, with an explicit stack: a maze is not
        // worth a recursion depth.
        var visited = Set<Int>()
        var stack: [(cx: Int, cz: Int)] = [(0, 0)]
        visited.insert(0)
        var carved: [(dx: Int, dz: Int)] = [(0, 0)]
        while let cell = stack.last {
            var options: [(cx: Int, cz: Int)] = []
            for (ox, oz) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                let nx = cell.cx + ox, nz = cell.cz + oz
                guard nx >= 0, nx < 7, nz >= 0, nz < 7,
                      !visited.contains(nx * 7 + nz) else { continue }
                options.append((nx, nz))
            }
            guard !options.isEmpty else {
                stack.removeLast()
                continue
            }
            let next = options[Int(rng.next() % UInt64(options.count))]
            visited.insert(next.cx * 7 + next.cz)
            carved.append((cell.cx + next.cx - 6, cell.cz + next.cz - 6))
            carved.append((next.cx * 2 - 6, next.cz * 2 - 6))
            stack.append(next)
        }
        for cell in carved {
            Landmarks.fill(
                world,
                x: (originX + cell.dx)...(originX + cell.dx),
                y: (Atlantis.floorY + 1)...(Atlantis.floorY + 2),
                z: (mazeZ + cell.dz)...(mazeZ + cell.dz), .air
            )
        }

        // The entrance, cut where the link tunnel arrives, and a lantern
        // over it so the way in reads as a doorway rather than a gap.
        let gate = mazeZ - (originZ < mazeZ ? half : -half)
        Landmarks.fill(
            world,
            x: originX...originX,
            y: (Atlantis.floorY + 1)...(Atlantis.floorY + 2),
            z: min(gate, mazeZ - half + 1)...max(gate, mazeZ - half + 1), .air
        )
        world.setBlock(
            worldX: originX, y: Atlantis.floorY + 3, worldZ: gate, to: .seaLantern,
            remesh: false
        )

        // The centre: a hole in the floor, and the first tread of the way
        // down showing through it.
        world.setBlock(worldX: originX, y: Atlantis.floorY, worldZ: mazeZ, to: .air, remesh: false)
    }

    /// The crypt: the maze's prize. A dog-leg of stairs from the hole in
    /// the floor, gold stacked at the east end, lanterns in the corners —
    /// obsidian everywhere else, because a treasure room should be the one
    /// place in a sea-green city that is black.
    ///
    /// The stair runs all the way to the crypt floor, one tread a block,
    /// turning south when it meets the west wall. That the last tread
    /// lands *on* the floor is not decoration: a flight that stops two
    /// blocks up can be fallen off but not climbed, and a treasure room
    /// that keeps whoever finds it is a trap, not a prize.
    private func crypt() {
        let floorY = Atlantis.floorY - 6
        let treads: [(x: Int, y: Int, z: Int)] = [
            (originX, Atlantis.floorY - 1, mazeZ),
            (originX - 1, Atlantis.floorY - 2, mazeZ),
            (originX - 2, Atlantis.floorY - 3, mazeZ),
            (originX - 3, Atlantis.floorY - 4, mazeZ),
            (originX - 3, Atlantis.floorY - 5, mazeZ + 1),
            (originX - 3, Atlantis.floorY - 6, mazeZ + 2),
        ]
        // Each tread faces the way you walk off it going *up*: toward the
        // tread above, and off the top one, east toward the maze.
        for (index, tread) in treads.enumerated() {
            let above = treads[max(index - 1, 0)]
            let facing: BlockFacing = above.z < tread.z ? .north : .east
            world.setBlock(
                worldX: tread.x, y: tread.y, worldZ: tread.z,
                to: .cobbleStairs(facing), remesh: false
            )
        }
        // Headroom over the top treads, up through the hole in the maze.
        for (step, x) in [originX, originX - 1, originX - 2].enumerated() {
            for y in (Atlantis.floorY - step)...(Atlantis.floorY + 2) {
                world.setBlock(worldX: x, y: y, worldZ: mazeZ, to: .air, remesh: false)
            }
        }

        Landmarks.fill(
            world,
            x: (originX + 1)...(originX + 3), y: floorY...(floorY + 1),
            z: (mazeZ - 1)...(mazeZ + 1), .goldBlock
        )
        for dz in [-1, 0, 1] {
            world.setBlock(
                worldX: originX + 2, y: floorY + 2, worldZ: mazeZ + dz,
                to: dz == 0 ? .diamondBlock : .diamondOre, remesh: false
            )
        }
        for (sx, sz) in [(-1, -1), (-1, 1), (1, -1), (1, 1)] {
            world.setBlock(
                worldX: originX + sx * 3, y: floorY, worldZ: mazeZ + sz * 3,
                to: .seaLantern, remesh: false
            )
        }
    }

    /// The ruins: broken seaStone columns strewn across the basin floor
    /// between the domes, some standing, every third one toppled. Sized and
    /// placed by the seed, skipped where they would land on anything that
    /// is not open sand — a test done by arithmetic against the things this
    /// builder placed, because at build time the world cannot be read (see
    /// the note on the planting).
    private func ruins(_ rng: inout SeededGenerator) {
        for column in 0..<14 {
            let angle = Double(rng.next() % 360) / 360 * 2 * .pi
            let reach = 24 + Double(rng.next() % 14)
            let x = originX + Int((reach * cos(angle)).rounded())
            let z = originZ + Int((reach * sin(angle)).rounded())
            guard openSand(x: x, z: z) else { continue }
            let height = 3 + Int(rng.next() % 4)
            if column % 3 == 2 {
                // Toppled: the same column, lying where it fell.
                let (dx, dz) = abs(x - originX) > abs(z - originZ) ? (0, 1) : (1, 0)
                for step in 0..<height {
                    world.setBlock(
                        worldX: x + dx * step, y: Atlantis.floorY + 1, worldZ: z + dz * step,
                        to: .seaStone, remesh: false
                    )
                }
            } else {
                for step in 0..<height {
                    world.setBlock(
                        worldX: x, y: Atlantis.floorY + 1 + step, worldZ: z,
                        to: .seaStone, remesh: false
                    )
                }
            }
        }
    }

    /// The lantern room's light: a two-by-two of sea lanterns, which is
    /// what makes the tower a lighthouse instead of a tube.
    private func beacon() {
        let lx = originX + Atlantis.lighthouseOffset
        for (dx, dz) in [(0, 0), (-1, 0), (0, -1), (-1, -1)] {
            for dy in 0...1 {
                world.setBlock(
                    worldX: lx + dx, y: Atlantis.beaconY + dy, worldZ: originZ + dz,
                    to: .seaLantern, remesh: false
                )
            }
        }
    }

    // MARK: - Geometry

    private var gardenZ: Int { originZ - Atlantis.satelliteOffset }
    private var mazeZ: Int { originZ + Atlantis.satelliteOffset }

    /// Whether a basin cell is dredged sand with nothing of the city's on
    /// it: on the flat floor, clear of every dome with a block to spare,
    /// clear of the sea tunnel's strip and the links' — where a ruin can
    /// stand without leaning on architecture.
    private func openSand(x: Int, z: Int) -> Bool {
        let dx = x - originX, dz = z - originZ
        guard dx * dx + dz * dz
            <= Atlantis.basinFlat * Atlantis.basinFlat else { return false }
        for dome in domes() {
            let ox = x - dome.x, oz = z - dome.z
            let clear = dome.r + 2
            if ox * ox + oz * oz <= clear * clear { return false }
        }
        // The sea tunnel runs east at this z; the satellite links run north
        // and south at this x. Three blocks of clearance each.
        if abs(dz) <= 3 && dx > 0 { return false }
        if abs(dx) <= 3 { return false }
        return true
    }

    private func domes() -> [(x: Int, z: Int, r: Int)] {
        [
            (originX, originZ, Atlantis.grandRadius),
            (originX, gardenZ, Atlantis.gardenRadius),
            (originX, mazeZ, Atlantis.mazeRadius),
        ]
    }
}

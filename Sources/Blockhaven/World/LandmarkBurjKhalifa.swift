import Foundation

extension Landmarks {
    /// The Burj Khalifa: the one landmark on this site that is allowed to
    /// touch the roof of the world.
    ///
    /// Every other building here stops at `Landmarks.ceiling`, six blocks
    /// short of the top, because six blocks of sky over a spire is what
    /// stops it reading as a thing that ran out of world. The Burj is the
    /// exception on purpose — the whole point of the building is that it
    /// is the tallest there is, so its beacon sits on the highest block
    /// the world can hold, `Chunk.height - 1`. That is why the spire is
    /// written straight through `world.setBlock` instead of through the
    /// helpers in `Landmarks`: the helpers clip at the ceiling, silently,
    /// and a silently clipped Burj Khalifa is just a chimney.
    ///
    /// The shape is the real one and not a box: a three-lobed Y in plan —
    /// a hexagonal core with three wings off it at a hundred and twenty
    /// degrees — and the wings step back as they climb, one wing at a
    /// time, so the setbacks spiral round the tower rather than ringing
    /// it. That spiral is the silhouette. A tower that narrows evenly is
    /// a cone; this one loses a wing tip every third setback and keeps
    /// looking like three buildings leaning on each other, which is what
    /// the photographs show.
    ///
    /// The proportions are compressed, and knowingly. The real tower is
    /// 828 m tall on a plan about 150 m across — a slenderness of five and
    /// a half to one, which at the 127 blocks of height this world can
    /// offer would put the whole base inside a 23-block circle and leave
    /// each wing four blocks wide. Four blocks is not a wing; it is a
    /// wall with a bulge, and there is nowhere in it to put the setbacks
    /// that make the tower recognisable. So the base is opened out to 44
    /// blocks across, a slenderness of just under three, which is stubbier
    /// than Dubai's and the price of a silhouette that still steps.
    ///
    /// You can climb it. A square spiral stair runs up the core from the
    /// lobby to the observation deck at the top of the wings, seventy-four
    /// treads, three wide, walled on both sides — and `DemoCheck` walks it
    /// with the player's own body rather than trusting the arithmetic
    /// here. Above the deck only the spire goes on, which is also true of
    /// the real one.
    static func burjKhalifa(
        originX: Int, groundY: Int, originZ: Int, in world: World,
        cladding: Burj.Cladding = .glassAndSteel
    ) {
        Burj(originX: originX, groundY: groundY, originZ: originZ, world: world,
             cladding: cladding).build()
    }

    /// The absolute height of the beacon: the highest block this world
    /// has. Absolute rather than measured from the deck, because the whole
    /// claim of this building is about the world's roof and not about the
    /// ground it happens to start from.
    static let burjPinnacle = Chunk.height - 1

    /// How far the base reaches from the centre — wing reach plus the
    /// wing's own half-width. Published so the check's scan window can be
    /// sized against the builder's numbers instead of a guess.
    static let burjSpan = Burj.baseReach + Int(Burj.wingHalfWidth.rounded(.up))

    /// The height of the observation deck's floor above the ground the
    /// tower stands on: the top of the wings, where the stair comes out.
    static let burjDeckHeight = Burj.shaftHeight

    /// The climb from the lobby door to the observation deck, as cells for
    /// `DemoCheck`'s body to walk: in at the south wing's door, along the
    /// entrance hall, then every tread of the spiral. One flight, because
    /// it never lands — a spiral stair's landing is the next tread.
    ///
    /// Cell `y` is the tread block itself; the walk's standing band
    /// accepts feet anywhere in that block, which is what a stair's two
    /// half-heights need.
    static func burjStairRoute(
        originX: Int, groundY: Int, originZ: Int
    ) -> [[(x: Int, y: Int, z: Int)]] {
        var route: [(x: Int, y: Int, z: Int)] = []
        // The hall, at lobby level: in at the door on the wing's axis,
        // through the shaft wall, then a few steps east across the lobby
        // floor to the foot of the stair.
        for dz in stride(from: Burj.hallOuter, through: Burj.stairFoot.dz + 1, by: -1) {
            route.append((originX, groundY + 1, originZ + dz))
        }
        for dx in 1...Burj.stairFoot.dx {
            route.append((originX + dx, groundY + 1, originZ + Burj.stairFoot.dz + 1))
        }
        for step in 0...Burj.treads {
            let cell = Burj.stairRing[step % Burj.stairRing.count]
            route.append((originX + cell.dx, groundY + 1 + step, originZ + cell.dz))
        }
        return [route]
    }

    /// The fountain pool south of the podium: its centre, its rim radius
    /// and the y of its water surface.
    static func burjFountain(
        originX: Int, groundY: Int, originZ: Int
    ) -> (x: Int, y: Int, z: Int, radius: Int) {
        (originX, groundY - 1, originZ + Burj.fountainOffset, Burj.fountainRadius)
    }
}

/// The builder. Not private: `Landmarks`' published statics above are
/// this type's own numbers, which is the point of publishing them — the
/// check measures what was built rather than what a check file remembers.
struct Burj {
    let originX: Int
    let groundY: Int
    let originZ: Int
    let world: World

    /// What the tower is made of.
    ///
    /// `.glassAndSteel` is the building: snow mullions, glass between
    /// them, stone floors, cobblestone treads. `.dynamite` is the twin
    /// west of it, where every block the builder would have laid comes
    /// out of the crate instead — one shape, one material, and a
    /// hundred and twenty-seven blocks of it.
    ///
    /// The substitution is at the point of placing rather than in the
    /// shape, on purpose: the two towers are the same code and so the
    /// same building, and the copy cannot drift from the original by
    /// being maintained separately.
    enum Cladding {
        case glassAndSteel
        case dynamite
    }

    var cladding: Cladding = .glassAndSteel

    /// The block that actually goes down.
    ///
    /// Air and water pass through whatever the cladding is: a tower of
    /// dynamite still needs its doorways empty and its fountain wet, and
    /// "purely of dynamite" is a claim about what the thing is built out
    /// of, not about filling in the holes that make it a building. The
    /// ground the apron lays is exempt for the same reason — it is the
    /// hill the tower stands on, not the tower — and calls it straight
    /// through `world.setBlock` rather than through here.
    func paint(_ block: BlockType) -> BlockType {
        guard cladding == .dynamite else { return block }
        switch block {
        case .air, .water: return block
        default: return .tnt
        }
    }

    // MARK: - The numbers the shape is made of

    /// How far a wing reaches from the centre before its first setback.
    static let baseReach = 17
    /// Half the width of a wing. The wing is a capsule — a rectangle this
    /// wide capped with a half-circle of the same radius — because the
    /// real wings end in a round nose and a squared-off one reads as a
    /// slab.
    static let wingHalfWidth = 5.0
    /// What a wing shrinks to and stops at. Three plus the half-width is
    /// eight, which is inside the core's own radius, so by the time a wing
    /// has spent all its setbacks it has dissolved into the shaft — which
    /// is exactly what the tower does at the top of its occupied floors.
    static let minReach = 3

    /// The setbacks: how many, how far apart, and how much each takes.
    /// Twenty-one of them, seven per wing, taking two blocks each: the
    /// wings go from seventeen to three over the height of the shaft.
    static let setbacks = 21
    static let setbackStep = 3
    static let setbackDrop = 2

    /// The height of the wing section — the occupied tower. The
    /// observation deck's floor is its roof.
    static let shaftHeight = 74
    /// The height of the whole body, wings and the tapering core above
    /// them. The spire starts one block higher.
    static let bodyHeight = 88

    static let coreRadiusBase = 9.0
    static let coreRadiusTop = 4.0

    /// The stair shaft, in Chebyshev distance from the centre: a solid
    /// column of lift machinery in the middle, then three cells of
    /// stairway, then a wall. Both walls matter — a spiral stair with a
    /// drop on one side is a hazard, and this world's audience is eight.
    static let shaftColumn = 2
    static let shaftWall = 6

    /// The entrance hall runs from the shaft wall out past the south
    /// wing's nose, which is `baseReach + wingHalfWidth` from the centre.
    static let hallOuter = 24

    static let fountainRadius = 12
    /// Far enough south that the pool clears both the wing's nose at
    /// twenty-two blocks and its own rim: the first cut put the water two
    /// blocks off the tower's door, and the route into the lobby started
    /// with a swim.
    static let fountainOffset = 46

    /// The podium the tower stands on, and the apron of ground that
    /// carries the podium and the pool.
    static let podiumRadius = 30
    static let apronRadius = 62

    /// Where the three wings point. One due south, at the plaza, so the
    /// face the site sees is a wing head-on and not the gap between two —
    /// and so the door is on the side somebody walking up to it is on.
    static let wingDirections: [(x: Double, z: Double)] = [
        (0, 1),
        (-0.8660254, -0.5),
        (0.8660254, -0.5),
    ]

    /// Every cell of the stair's spiral, in the order it climbs: the ring
    /// of the shaft at Chebyshev four, walked clockwise, starting at the
    /// door so the first tread is the one you step onto from the hall.
    static let stairRing: [(dx: Int, dz: Int)] = {
        let r = 4
        var ring: [(dx: Int, dz: Int)] = []
        for dx in (-r)...(r - 1) { ring.append((dx, r)) }        // south side, east
        for dz in stride(from: r, through: -r + 1, by: -1) { ring.append((r, dz)) }
        for dx in stride(from: r, through: -r + 1, by: -1) { ring.append((dx, -r)) }
        for dz in (-r)...(r - 1) { ring.append((-r, dz)) }
        // Rotated so index zero is the south-east corner, where the
        // climb starts.
        //
        // Which corner is not a free choice. A tread's raised half is on
        // the side it faces, so a tread can only be *walked onto* from
        // behind it. The spiral's south side runs east and its east side
        // runs north, and somebody coming in at the south door is walking
        // north: the first tread has to be one of the north-going ones, or
        // they meet its raised half edge-on and stop dead against a
        // half-block wall. Which is exactly what the first cut of this did,
        // and what `DemoCheck`'s body caught.
        //
        // Only the *first* tread is settled here. Which way each of the
        // others faces is settled in `stair()`, by the direction the climb
        // arrives from rather than the one it leaves by — the two differ at
        // every corner, and taking the leaving one there stopped the body
        // dead at the top of the tower. Same bug, one turn later.
        let start = ring.firstIndex { $0.dx == r && $0.dz == r } ?? 0
        return Array(ring[start...] + ring[..<start])
    }()

    /// The tread the climb starts on, and so where the lobby has to
    /// deliver somebody: the corner of the shaft the ring begins at.
    static let stairFoot = stairRing[0]

    /// The last tread's index. The stair climbs one block a tread from the
    /// lobby floor to the observation deck.
    static let treads = shaftHeight - 1

    // MARK: - Build

    func build() {
        apron()
        podium()
        fountain()
        body()
        observationDeck()
        stair()
        spire()
    }

    // MARK: - Ground

    /// Sits the tower in the terrain: dirt up to the podium's level where
    /// the ground falls short, sand on top, and clear air above. The same
    /// idiom the pyramid's apron uses, and for the same reason — a
    /// landmark sited outside the flattened plot has to bring its own
    /// ground or it stands in a hillside.
    private func apron() {
        let r = Burj.apronRadius
        for dz in (-r)...r {
            for dx in (-r)...r {
                let distance = Double(dx * dx + dz * dz).squareRoot()
                guard distance <= Double(r) else { continue }
                let x = originX + dx, z = originZ + dz
                let surface = world.generator.surfaceHeight(x: x, z: z)
                let floor = max(groundY - 16, min(surface, groundY - 1))
                for y in floor...(groundY - 1) {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .dirt, remesh: false)
                }
                world.setBlock(
                    worldX: x, y: groundY, worldZ: z,
                    to: distance > Double(Burj.podiumRadius) ? .grass : .stone,
                    remesh: false
                )
                // Sixteen rather than the plot's eight. The plot is cleared
                // where the generator plants nothing tall; out here the
                // probe found trees whose crowns sit nine and ten blocks
                // over their own ground, and eight left leaves floating
                // over the apron with their trunks cut out from under them.
                let clearTo = min(Landmarks.ceiling, max(groundY, surface + 16))
                guard clearTo > groundY else { continue }
                for y in (groundY + 1)...clearTo {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }
    }

    /// The plaza the tower stands on: stone in, sandstone at the rim, and
    /// a ring of pearl lamps so the base is a place after dark rather than
    /// a dark disc with a lit needle over it.
    private func podium() {
        Landmarks.disc(
            world, centreX: originX, y: groundY, centreZ: originZ,
            radius: Double(Burj.podiumRadius), paint(.stone)
        )
        Landmarks.ring(
            world, centreX: originX, y: groundY, centreZ: originZ,
            radius: Double(Burj.podiumRadius) - 0.5, paint(.sandstone)
        )
        for step in 0..<12 {
            let angle = Double(step) / 12 * 2 * .pi
            let radius = Double(Burj.podiumRadius) - 3
            let x = originX + Int((radius * cos(angle)).rounded())
            let z = originZ + Int((radius * sin(angle)).rounded())
            world.setBlock(worldX: x, y: groundY + 1, worldZ: z,
                           to: paint(.sandstonePillar), remesh: false)
            world.setBlock(worldX: x, y: groundY + 2, worldZ: z,
                           to: paint(.pearlLight), remesh: false)
        }
    }

    /// The pool in front of it. Sunk into the podium's own apron rather
    /// than walled up out of it, with sea lanterns on the bottom — water
    /// is transparent here, so a lamp under it lights the pool itself and
    /// the tower gets something to stand reflected in at night.
    private func fountain() {
        let centreZ = originZ + Burj.fountainOffset
        let r = Burj.fountainRadius
        for dz in (-r - 1)...(r + 1) {
            for dx in (-r - 1)...(r + 1) {
                let distance = Double(dx * dx + dz * dz).squareRoot()
                guard distance <= Double(r) + 1.35 else { continue }
                let x = originX + dx, z = centreZ + dz
                if distance > Double(r) - 0.5 {
                    world.setBlock(worldX: x, y: groundY, worldZ: z,
                                   to: paint(.seaStone), remesh: false)
                    continue
                }
                world.setBlock(worldX: x, y: groundY - 3, worldZ: z,
                               to: paint(.seaStone), remesh: false)
                for y in (groundY - 2)...groundY {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: paint(.water), remesh: false)
                }
            }
        }
        world.setBlock(worldX: originX, y: groundY - 3, worldZ: centreZ,
                       to: paint(.seaLantern), remesh: false)
        for step in 0..<8 {
            let angle = Double(step) / 8 * 2 * .pi
            let radius = Double(r) - 6
            world.setBlock(
                worldX: originX + Int((radius * cos(angle)).rounded()),
                y: groundY - 3,
                worldZ: centreZ + Int((radius * sin(angle)).rounded()),
                to: paint(.seaLantern), remesh: false
            )
        }
    }

    // MARK: - The tower itself

    /// The wings' reach at a height, after however many of their own
    /// setbacks are below it.
    ///
    /// The setbacks are dealt out to the wings in turn — wing zero, one,
    /// two, zero again — which is the whole trick of the silhouette. All
    /// three stepping together would ring the tower with ledges; taking
    /// them one at a time sends the ledges up it in a spiral.
    func wingReach(_ wing: Int, atY y: Int) -> Int {
        let above = y - groundY
        var reach = Burj.baseReach
        for step in 0..<Burj.setbacks where step % 3 == wing {
            if above >= Burj.setbackStep * (step + 1) { reach -= Burj.setbackDrop }
        }
        return max(Burj.minReach, reach)
    }

    /// The core's radius at a height: constant up the occupied tower, then
    /// drawing in above the observation deck toward the spire's foot.
    func coreRadius(atY y: Int) -> Double {
        let above = y - groundY
        guard above > Burj.shaftHeight else { return Burj.coreRadiusBase }
        let t = Double(above - Burj.shaftHeight)
            / Double(Burj.bodyHeight - Burj.shaftHeight)
        return Burj.coreRadiusBase + (Burj.coreRadiusTop - Burj.coreRadiusBase) * min(1, t)
    }

    /// Whether a cell of this course is inside the tower: the core disc,
    /// or any of the three wing capsules off it.
    func inPlan(dx: Int, dz: Int, atY y: Int) -> Bool {
        let px = Double(dx), pz = Double(dz)
        let core = coreRadius(atY: y)
        if (px * px + pz * pz).squareRoot() <= core + 0.35 { return true }
        // Above the deck there are no wings left to draw — only the core
        // goes on, which is what makes the deck a deck.
        guard y - groundY <= Burj.shaftHeight else { return false }
        for wing in 0..<3 {
            let reach = Double(wingReach(wing, atY: y))
            let dir = Burj.wingDirections[wing]
            let along = max(0, min(reach, px * dir.x + pz * dir.z))
            let nx = px - dir.x * along, nz = pz - dir.z * along
            if (nx * nx + nz * nz).squareRoot() <= Burj.wingHalfWidth + 0.35 { return true }
        }
        return false
    }

    /// The curtain wall's block for a cell.
    ///
    /// A tower of plain glass is a ghost at this distance and a tower of
    /// plain white is a chimney, so the skin is both: a snow spandrel on
    /// every fourth course for the floor lines, snow mullions running the
    /// full height, and glass in the slots between them. The mullion test
    /// is done on both diagonals so that it lands as vertical stripes on a
    /// wall facing any direction — the wings point at a hundred and twenty
    /// degrees and almost none of this building's wall is axis-aligned.
    private func skin(x: Int, y: Int, z: Int, roof: Bool) -> BlockType {
        if roof { return .snow }
        if y % 4 == 0 { return .snow }
        let sum = ((x + z) % 3 + 3) % 3
        let difference = ((x - z) % 3 + 3) % 3
        return sum == 0 || difference == 0 ? .snow : .glass
    }

    /// The body: eighty-eight courses of curtain wall, floor plates every
    /// fourth course, and the stair shaft's two walls running up the
    /// middle of it.
    private func body() {
        let reach = Burj.baseReach + Int(Burj.wingHalfWidth.rounded(.up)) + 1
        var below = mask(atY: groundY + 1, reach: reach)
        for y in (groundY + 1)...(groundY + Burj.bodyHeight) {
            let above = mask(atY: y + 1, reach: reach)
            for dz in (-reach)...reach {
                for dx in (-reach)...reach {
                    guard below[at(dx, dz, reach)] else { continue }
                    let x = originX + dx, z = originZ + dz
                    let chebyshev = max(abs(dx), abs(dz))
                    let onEdge = !below[at(dx - 1, dz, reach)] || !below[at(dx + 1, dz, reach)]
                        || !below[at(dx, dz - 1, reach)] || !below[at(dx, dz + 1, reach)]
                    let roof = !above[at(dx, dz, reach)]

                    if onEdge || roof {
                        world.setBlock(worldX: x, y: y, worldZ: z,
                                       to: paint(skin(x: x, y: y, z: z, roof: roof && !onEdge)),
                                       remesh: false)
                        continue
                    }
                    // Inside. The middle of the plan is the shaft — solid
                    // lift core, open stairway, wall — and everything
                    // outside the shaft is office floor on every fourth
                    // course and air between.
                    if y - groundY <= Burj.shaftHeight, chebyshev <= Burj.shaftWall {
                        if chebyshev <= Burj.shaftColumn || chebyshev == Burj.shaftWall {
                            world.setBlock(worldX: x, y: y, worldZ: z,
                                           to: paint(.stone), remesh: false)
                        }
                        continue
                    }
                    if y % 4 == 0 {
                        world.setBlock(worldX: x, y: y, worldZ: z, to: paint(.stone), remesh: false)
                    }
                }
            }
            below = above
        }

        lobby()
        landings()
    }

    /// One course's plan, as a flat array of flags — the plan test is
    /// three capsule distances and a circle, and the body asks it for
    /// every cell and every one of that cell's four neighbours, which is
    /// five times more work than the course has cells.
    private func mask(atY y: Int, reach: Int) -> [Bool] {
        let side = 2 * reach + 3
        var flags = [Bool](repeating: false, count: side * side)
        for dz in (-reach - 1)...(reach + 1) {
            for dx in (-reach - 1)...(reach + 1) {
                flags[at(dx, dz, reach)] = inPlan(dx: dx, dz: dz, atY: y)
            }
        }
        return flags
    }

    private func at(_ dx: Int, _ dz: Int, _ reach: Int) -> Int {
        let side = 2 * reach + 3
        return (dz + reach + 1) * side + (dx + reach + 1)
    }

    /// The way in: a hall driven south out of the shaft, through the
    /// ground floor and out through the south wing's nose. Three blocks
    /// tall, which is the lobby's whole height — the first floor plate is
    /// four courses up.
    private func lobby() {
        for y in (groundY + 1)...(groundY + 3) {
            for dz in Burj.shaftWall...Burj.hallOuter {
                for dx in -1...1 {
                    world.setBlock(worldX: originX + dx, y: y, worldZ: originZ + dz,
                                   to: paint(.air), remesh: false)
                }
            }
            // And across the lobby to the foot of the stair. Cut before
            // the treads are laid, so that where the two overlap the
            // stair wins.
            for dx in -1...Burj.stairFoot.dx {
                world.setBlock(worldX: originX + dx, y: y,
                               worldZ: originZ + Burj.stairFoot.dz + 1,
                               to: paint(.air), remesh: false)
            }
        }
        // Lit, and the lamps double as the doorposts.
        for dx in [-2, 2] {
            world.setBlock(worldX: originX + dx, y: groundY + 1, worldZ: originZ + 21,
                           to: paint(.glowCrystal), remesh: false)
        }
        world.setBlock(worldX: originX, y: groundY + 3, worldZ: originZ + Burj.shaftWall + 2,
                       to: paint(.seaLantern), remesh: false)
    }

    /// A door out of the stairway onto every floor it passes.
    ///
    /// Punched where the stair actually is at that height rather than at a
    /// fixed compass point, because the stair is a spiral: a door in a
    /// fixed wall would be a door onto thin air on three floors out of
    /// four.
    private func landings() {
        for step in 0...Burj.treads {
            let y = groundY + 1 + step
            guard y % 4 == 0 else { continue }
            let cell = Burj.stairRing[step % Burj.stairRing.count]
            // Square out of whichever of the shaft's four walls this tread
            // is against. A corner tread is against two; either will do.
            let alongZ = abs(cell.dz) >= abs(cell.dx)
            let sign = alongZ ? (cell.dz > 0 ? 1 : -1) : (cell.dx > 0 ? 1 : -1)
            for reach in (Burj.shaftWall - 1)...(Burj.shaftWall + 1) {
                for lift in 1...2 {
                    world.setBlock(
                        worldX: originX + (alongZ ? cell.dx : sign * reach),
                        y: y + lift,
                        worldZ: originZ + (alongZ ? sign * reach : cell.dz),
                        to: .air, remesh: false
                    )
                }
            }
        }
    }

    // MARK: - The observation deck

    /// The floor at the top of the wings, thrown two blocks wider than the
    /// core that carries on up through it, with a glass parapet and
    /// lanterns round the edge. "At the Top", and the reason the stair
    /// exists.
    private func observationDeck() {
        let y = groundY + Burj.shaftHeight
        let radius = Burj.coreRadiusBase + 2.5
        Landmarks.disc(world, centreX: originX, y: y - 1, centreZ: originZ,
                       radius: radius - 1, paint(.stone))
        Landmarks.disc(world, centreX: originX, y: y, centreZ: originZ,
                       radius: radius, paint(.snow))
        Landmarks.ring(world, centreX: originX, y: y + 1, centreZ: originZ,
                       radius: radius, paint(.glassPane))
        Landmarks.ring(world, centreX: originX, y: y + 2, centreZ: originZ,
                       radius: radius, paint(.glassPane))
        for step in 0..<8 {
            let angle = Double(step) / 8 * 2 * .pi
            world.setBlock(
                worldX: originX + Int((radius * cos(angle)).rounded()),
                y: y + 1,
                worldZ: originZ + Int((radius * sin(angle)).rounded()),
                to: paint(.seaLantern), remesh: false
            )
        }
    }

    // MARK: - The stair

    /// Seventy-four treads of square spiral up the shaft, three wide, a
    /// block of rise each.
    ///
    /// A block of rise a tread only works because these are stair blocks:
    /// their back half is half a block up, so the climb is two half-steps
    /// and the player's step assist — six tenths of a block — carries
    /// each one. Full blocks at the same rise would be an unclimbable
    /// ladder of one-block walls, which is why the sky city's stair is
    /// built the same way.
    ///
    /// Laid after the floors and the deck so that where they meet, the
    /// treads win: a floor plate over the stairwell is a ceiling somebody
    /// walks into.
    private func stair() {
        let ring = Burj.stairRing
        for step in 0...Burj.treads {
            let y = groundY + 1 + step
            let cell = ring[step % ring.count]
            let next = ring[(step + 1) % ring.count]
            let previous = ring[(step + ring.count - 1) % ring.count]
            // A tread faces the way the climber *arrives*, not the way the
            // flight is about to go. On a straight run those are the same
            // thing and this changes nothing; at a corner they are not, and
            // facing the new direction breaks the climb twice over. The
            // raised half ends up side-on to somebody coming up the old
            // direction, so half their body meets a full block instead of a
            // half one — and the three-block width, which lies across the
            // facing, swings round with it and reaches back over the tread
            // below, putting a stair block on that climber's head.
            //
            // Both go away by facing the arrival. The width then lies across
            // the old direction, where the previous tread is behind rather
            // than beside, and the raised half is on the far side where a
            // tread's raised half belongs.
            //
            // The first tread is the exception: nobody arrives at it along
            // the ring. They arrive from the hall, walking north, which is
            // the way it leaves.
            let facing = step == 0
                ? Burj.facing(from: cell, to: next)
                : Burj.facing(from: previous, to: cell)
            // Three wide, across the direction of travel.
            let across = (dx: facing.dz, dz: facing.dx)
            for side in -1...1 {
                let x = originX + cell.dx + across.dx * side
                let z = originZ + cell.dz + across.dz * side
                world.setBlock(worldX: x, y: y, worldZ: z,
                               to: paint(.cobbleStairs(facing.facing)), remesh: false)
                // Headroom. The turn above is thirty-two blocks up, so
                // three clear blocks never reach it.
                for lift in 1...3 {
                    world.setBlock(worldX: x, y: y + lift, worldZ: z, to: paint(.air), remesh: false)
                }
            }
        }

        // Out onto the deck. The core is still solid at this height, so
        // the last treads arrive inside it and need a way through the
        // wall — carved short of the parapet, which stays whole.
        let top = groundY + 1 + Burj.treads
        let last = ring[Burj.treads % ring.count]
        let length = Double(max(abs(last.dx), abs(last.dz)))
        for reach in 4...10 {
            let scale = Double(reach) / length
            let x = originX + Int((Double(last.dx) * scale).rounded())
            let z = originZ + Int((Double(last.dz) * scale).rounded())
            for lift in 1...3 {
                world.setBlock(worldX: x, y: top + lift, worldZ: z, to: paint(.air), remesh: false)
            }
        }
    }

    /// Which way a tread faces: toward the tread after it, so its raised
    /// back half is the half you step up onto.
    static func facing(
        from cell: (dx: Int, dz: Int), to next: (dx: Int, dz: Int)
    ) -> (dx: Int, dz: Int, facing: BlockFacing) {
        let dx = next.dx - cell.dx, dz = next.dz - cell.dz
        if abs(dx) >= abs(dz) {
            return dx >= 0 ? (1, 0, .east) : (-1, 0, .west)
        }
        return dz >= 0 ? (0, 1, .south) : (0, -1, .north)
    }

    // MARK: - The spire

    /// The needle, from the top of the body to the roof of the world.
    ///
    /// Written straight to `World.setBlock` rather than through
    /// `Landmarks.disc`, because the helpers refuse anything above
    /// `Landmarks.ceiling` and this is the one building that is meant to
    /// go past it. The bound here is the world's own: `Chunk.height - 1`
    /// is the last block a chunk has room for, and `setBlock` drops
    /// anything above it.
    ///
    /// The taper is bent rather than straight — a plain cone from four
    /// blocks to one over thirty-nine courses is a spike, and the real
    /// spire draws in fast at the bottom and then runs almost parallel for
    /// its last hundred metres. Three red beacon courses up it, because a
    /// mast this tall has them and because at night they are the only
    /// thing marking the top of the world.
    private func spire() {
        let base = groundY + Burj.bodyHeight + 1
        let tip = Landmarks.burjPinnacle
        guard tip > base + 2 else { return }
        let mast = tip - 2

        for y in base...mast {
            let t = Double(y - base) / Double(mast - base)
            let radius = 4.5 * pow(1 - t, 1.6)
            let beacon = (y - base) % 12 == 6
            disc(y: y, radius: radius, paint(beacon ? .radiantRed : .snow))
        }
        world.setBlock(worldX: originX, y: tip - 1, worldZ: originZ,
                       to: paint(.glowCrystal), remesh: false)
        world.setBlock(worldX: originX, y: tip, worldZ: originZ,
                       to: paint(.radiantRed), remesh: false)
    }

    /// `Landmarks.disc`, without the ceiling.
    private func disc(y: Int, radius: Double, _ block: BlockType) {
        guard y >= 0, y < Chunk.height else { return }
        let r = Int(radius.rounded(.up))
        for dz in (-r)...r {
            for dx in (-r)...r {
                guard Double(dx * dx + dz * dz).squareRoot() <= radius + 0.35 else { continue }
                world.setBlock(worldX: originX + dx, y: y, worldZ: originZ + dz,
                               to: block, remesh: false)
            }
        }
    }
}

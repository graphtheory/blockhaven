import Foundation

/// The demo world: three landmarks, a railway that visits them, and a
/// coaster on the way round.
///
/// It never saves and never loads. Starting it always gives you the same
/// world in the same state, which is the point — it is somewhere to show
/// somebody what the game does, and a demo you can accidentally blow a hole
/// in and then keep is not that. `GameViewController` builds it with a nil
/// `fileURL`, and that single nil is the whole of "resets when you start
/// it": nothing is written, so there is nothing to come back to.
///
/// Everything here goes through `World.setBlock`, so it lands in the edit
/// journal and replays as chunks stream in. That means the site can be
/// written before a single chunk of terrain exists, which is exactly when
/// this runs — and it is the same path a player's own building takes, so
/// the demo is not a special kind of world, only a world that arrives with
/// some building already done.
enum DemoWorld {
    /// The seed. Fixed, so the demo is the same demo every time. The site
    /// itself is flattened, but the sea, the hills behind it and where the
    /// sun comes up are the terrain's business and should be the same for
    /// everyone who opens it.
    static let seed: UInt64 = 0x0DE_C0_5EED

    /// The height everything is built on. Flat, so the whole site is one
    /// deck rather than three landmarks at three heights joined by ramps.
    ///
    /// Two above sea level and a little *below* the median ground around
    /// it, which is deliberate on both counts. A deck that stands proud of
    /// its surroundings reads as a plinth somebody poured rather than as a
    /// clearing in the land — and, less obviously, every block it stands
    /// proud by is a block off the top of the landmarks, because the world
    /// stops at 128 whatever the deck does. Sitting the site down in the
    /// terrain instead of on it is worth about eight blocks of spire.
    static let deck = 64

    /// Where the player starts: the middle of the plaza.
    static var spawn: Vector3 { Vector3(0.5, CGFloat(deck + 2), 0.5) }

    /// Half the width of the flattened plot. Big enough to contain the
    /// railway's corners — at ±64 in x the far corner of the loop is 90.5
    /// blocks out, and a corner of track sitting on unflattened hillside is
    /// a track that stops.
    private static let plotRadius = 94

    /// Where each landmark stands, as the centre of its own footprint.
    ///
    /// Spread far enough apart that each reads as its own thing from the
    /// plaza, close enough that the railway between them is a ride rather
    /// than a commute, and — the constraint that actually decides these
    /// numbers — clear of the loop, which runs a few blocks outside all
    /// three.
    static let castleSite = (x: 0, z: -44)
    static let basilicaSite = (x: -40, z: 24)
    /// Moved clear of the loop's south-east corner to give the tower a base
    /// 44 blocks across. The real Eiffel Tower is 125 m wide and 330 m
    /// tall; at 120 blocks this is the same ratio, and a narrower one has
    /// legs too thin to put a staircase inside — which is what a first cut
    /// at ±14 produced, and a tower you cannot climb is not the Eiffel
    /// Tower.
    static let towerSite = (x: 38, z: 10)

    /// The Great Pyramid stands apart, due east, on its own desert apron
    /// outside the plot. Not a matter of taste: an eighty-five-block base
    /// fits nowhere inside the railway loop, and the direction is measured
    /// rather than chosen — a probe of the seed's terrain found east the
    /// driest, flattest ground within sight of the plaza, with the sea
    /// just beyond it, so the pyramid stands against the sunrise. At 140
    /// blocks out its near face is well inside render distance, close
    /// enough to loom over the loop's east side as the cart goes round.
    static let pyramidSite = (x: 140, z: 0)

    /// Atlantis drowns in the south-west, where the bathymetry probe found
    /// the widest stretch of sea within sight of the site — and, decisive
    /// for the walk in, a stretch whose centre lines up in z with a spot on
    /// the deck's own lawn, so the lighthouse, the staircase under it and
    /// a hundred blocks of sea tunnel are one straight line. The city
    /// dredges its own basin: this seed's sea is shallower than a sunken
    /// city needs, so the builder digs the depth the map never offered.
    static let atlantisSite = (x: -135, z: 60)

    /// The city in the sky hangs over the valley due south, past the
    /// loop's south side — the one compass direction still empty, and the
    /// one the plaza's spur already points down. The centre is where
    /// `TerrainProbe` found the valley low (ground 54–73 under the
    /// isles), so thirty blocks of air stay under every keel and the
    /// waterfalls have the whole drop to pour down.
    static let skySite = (x: -12, z: 146)

    /// The Burj Khalifa stands due north, out past the plot, on the one
    /// piece of ground on this seed flat enough to take it: `TerrainProbe`
    /// found a band around x −48…−36, z −158…−146 sitting at a level 60
    /// for its whole width, where everywhere else within reach rolls
    /// between 55 and 75. A tower whose podium is 60 blocks across cares
    /// about that more than any other landmark here does — a podium poured
    /// across a slope is a wall on one side and a cliff on the other.
    ///
    /// A hundred and fifty-two blocks from the plaza, the same as the sky
    /// city and just inside render distance, which is the far edge of
    /// where something can stand and still be a thing you see rather than
    /// a thing that appears. It wants that distance: a hundred and
    /// twenty-seven blocks of tower seen from underneath is a wall.
    static let burjSite = (x: -42, z: -146)

    /// And its twin, two hundred blocks due west: the same tower, the
    /// same code, every block of it dynamite.
    ///
    /// Two hundred rather than nearer, because this is a building made of
    /// explosives and the point of it is that somebody will light it. The
    /// blast radius of one stick is small, but a chain running through a
    /// hundred and twenty-seven blocks of stacked TNT is not, and the
    /// original has to still be standing afterwards. Due west keeps it out
    /// of the sightline from the plaza — you walk out to the real tower and
    /// find the other one on the horizon beside it, which is a better way
    /// to meet it than having it block the first view.
    static let dynamiteBurjSite = (x: burjSite.x - 200, z: burjSite.z)

    /// The rectangle the loop runs on.
    private static let west = -64, east = 64, north = -64, south = 46

    /// Where a cart is waiting when the world opens, on the spur just
    /// outside the plaza. Riding should be one click away rather than a
    /// shopping trip through the creative palette.
    static let cartCell = (x: 0, y: deck + 1, z: 10)

    /// Builds the whole site. Called once, before the world has generated
    /// anything.
    ///
    /// Order matters in one place only: the railway goes down after the
    /// landmarks, so that if a building ever grows far enough to reach the
    /// track, the track wins. A landmark with a rail through its wall is a
    /// cosmetic problem; a loop with a building in it is a ride that stops.
    static func build(in world: World) {
        flattenPlot(in: world)
        Landmarks.neuschwanstein(originX: castleSite.x, groundY: deck, originZ: castleSite.z, in: world)
        Landmarks.hagiaSophia(originX: basilicaSite.x, groundY: deck, originZ: basilicaSite.z, in: world)
        Landmarks.eiffelTower(originX: towerSite.x, groundY: deck, originZ: towerSite.z, in: world)
        Landmarks.greatPyramid(originX: pyramidSite.x, groundY: deck, originZ: pyramidSite.z, in: world)
        Landmarks.atlantis(originX: atlantisSite.x, groundY: deck, originZ: atlantisSite.z, in: world)
        Landmarks.skyCity(originX: skySite.x, groundY: deck, originZ: skySite.z, in: world)
        Landmarks.burjKhalifa(originX: burjSite.x, groundY: deck, originZ: burjSite.z, in: world)
        Landmarks.burjKhalifa(
            originX: dynamiteBurjSite.x, groundY: deck, originZ: dynamiteBurjSite.z,
            in: world, cladding: .dynamite
        )
        buildPath(in: world)
        buildRailway(in: world)
        buildPlaza(in: world)
        buildGlimmer(in: world)
    }

    /// Where the pearl lamps stand: a loose constellation on the lawn
    /// between the plaza and the pyramid path, south of the track. Raised
    /// ones sit on the grass as full shining cubes; the others are sunk
    /// flush, a glowing tile in the lawn. Published so `DemoCheck` counts
    /// the same cells the builder wrote.
    static let glimmerCells: [(x: Int, z: Int, raised: Bool)] = [
        (58, 14, true), (63, 9, false), (66, 17, true), (71, 12, true),
        (75, 19, false), (61, 22, true), (69, 25, true),
    ]

    /// The glimmer patch. Goes down last for the same reason the plaza
    /// does: nothing may build over a lamp, and a lamp may replace only
    /// lawn.
    private static func buildGlimmer(in world: World) {
        for cell in glimmerCells {
            world.setBlock(
                worldX: cell.x, y: cell.raised ? deck + 1 : deck, worldZ: cell.z,
                to: .pearlLight, remesh: false
            )
        }
    }

    /// A sandstone path from the plaza to the pyramid's door: due east
    /// along z = 0, under the tower's arch, across the loop's east side.
    ///
    /// Laid into the ground rather than on it — it recolours the deck's
    /// own surface course, so it cannot collide with anything standing
    /// *on* the deck. It goes down before the railway so that where it
    /// crosses the line, the track's own ground wins and the crossing
    /// reads as a crossing; a path that beat the rails would be a ride
    /// that stops.
    private static func buildPath(in world: World) {
        let doorstep = pyramidSite.x - 43
        for x in 8...doorstep {
            for dz in -1...1 {
                world.setBlock(
                    worldX: x, y: deck, worldZ: pyramidSite.z + dz,
                    to: .sandstone, remesh: false
                )
            }
        }
    }

    /// A flat grass deck for the whole site.
    ///
    /// Both halves of this are sized off the terrain rather than fixed,
    /// because a fixed answer is enormous. The world is 128 blocks tall and
    /// generation can put a peak at 114, so clearing "everything that might
    /// be above the deck" means forty-odd air writes for every column of a
    /// plot twenty-eight thousand columns wide — most of them into empty
    /// sky. Asking the generator how high the ground actually comes turns
    /// that into a handful of writes per column across most of the site.
    ///
    /// Written with `remesh: false` throughout: nothing is meshed yet, and
    /// asking for a remesh per cell would queue tens of thousands of
    /// rebuilds of chunks that do not exist.
    private static func flattenPlot(in world: World) {
        for z in -plotRadius...plotRadius {
            for x in -plotRadius...plotRadius {
                // A round plot rather than a square one, so the edge reads
                // as a clearing rather than as something someone walled.
                guard Double(x * x + z * z).squareRoot() <= Double(plotRadius) else { continue }
                let surface = world.generator.surfaceHeight(x: x, z: z)

                // Down as far as the ground, and no further. The cap turns
                // a site over deep water into a low cliff instead of a
                // sixty-block column of dirt per cell.
                let floor = max(deck - 16, min(surface, deck - 1))
                for y in floor...(deck - 1) {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .dirt, remesh: false)
                }
                world.setBlock(worldX: x, y: deck, worldZ: z, to: .grass, remesh: false)

                // Up as far as the ground came, plus room for whatever the
                // generator planted on it — a tree is about seven blocks
                // and would otherwise be left hanging over the deck.
                let clearTo = min(Landmarks.ceiling, max(deck, surface + 8))
                guard clearTo > deck else { continue }
                for y in (deck + 1)...clearTo {
                    world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                }
            }
        }
    }

    /// The plaza the player starts in: a stone circle with a ring of
    /// torches, so the middle of the site is somewhere rather than a patch
    /// of grass.
    private static func buildPlaza(in world: World) {
        for z in -9...9 {
            for x in -9...9 {
                let distance = Double(x * x + z * z).squareRoot()
                guard distance <= 9 else { continue }
                world.setBlock(
                    worldX: x, y: deck, worldZ: z,
                    to: distance > 7.5 ? .cobblestone : .stone, remesh: false
                )
            }
        }
        for step in 0..<8 {
            let angle = Double(step) / 8 * 2 * .pi
            world.setBlock(
                worldX: Int((8.2 * cos(angle)).rounded()),
                y: deck + 1,
                worldZ: Int((8.2 * sin(angle)).rounded()),
                to: .torch, remesh: false
            )
        }

        // Four radiant panes inlaid in the floor at the compass points —
        // and the compass is honest: yellow glows toward the pyramid's
        // desert, cyan toward the drowned city, so the plaza's own floor
        // tells a newcomer which way the treasure is. Each pane has a sea
        // lantern set beneath it: the pane is transparent, and what makes
        // a transparent tile blaze is what you put on its far side.
        for (dx, dz, lamp): (Int, Int, BlockType) in [
            (8, 0, .radiantYellow), (-8, 0, .radiantCyan),
            (0, -8, .radiantRed), (0, 8, .radiantGreen),
        ] {
            world.setBlock(worldX: dx, y: deck - 1, worldZ: dz, to: .seaLantern, remesh: false)
            world.setBlock(worldX: dx, y: deck, worldZ: dz, to: lamp, remesh: false)
        }
    }

    // MARK: - The railway

    /// Every cell the track occupies, in the order it is laid.
    ///
    /// Shared with `DemoCheck` rather than kept inside the builder, so the
    /// check is asking whether *this* track survived being built rather
    /// than whether some track it described for itself did. A check that
    /// keeps its own copy of the answer stops being a check the first time
    /// the two drift.
    static var trackCells: [(x: Int, y: Int, z: Int)] {
        var cells: [(x: Int, y: Int, z: Int)] = []

        // North side, west to east, carrying the coaster's hill.
        for x in west...east { cells.append((x, hillHeight(atX: x), north)) }
        // Down the east side, back along the south, up the west. The
        // corners are shared cells, so each run starts one past the last.
        for z in (north + 1)...south { cells.append((east, deck + 1, z)) }
        for x in stride(from: east - 1, through: west, by: -1) { cells.append((x, deck + 1, south)) }
        for z in stride(from: south - 1, through: north + 1, by: -1) { cells.append((west, deck + 1, z)) }

        // A spur south out of the plaza, so you can get on without walking
        // to the far side of the site. It runs down the gap between the
        // basilica and the tower, which is the only line out of the middle
        // that does not go through a building.
        for z in 10...(south - 1) { cells.append((0, deck + 1, z)) }
        return cells
    }

    /// A loop right round the site, with a hill on the north side and a
    /// spur in to the plaza.
    ///
    /// Laid as a list of cells and then resolved by `RailNetwork`, exactly
    /// as a player laying it by hand would be. That is deliberate rather
    /// than lazy: if the resolver cannot join this up, it cannot join up
    /// what a player builds either, and at five hundred and twelve cells
    /// this is by far the largest piece of track anything in the repo
    /// makes.
    private static func buildRailway(in world: World) {
        let cells = trackCells

        // The chunks the line runs through, generated before a single rail
        // goes down.
        //
        // `RailNetwork` works out what each cell should join to by reading
        // the world, and an ungenerated chunk reads as air. Laying this
        // track into an empty world resolved all five hundred cells to the
        // same straight rail — no corners, no slopes — and a cart put on it
        // ran to the first corner and stopped, because a straight rail at a
        // bend is the end of the line. Nothing about that was visible until
        // something counted the curves.
        //
        // The journal is already written by this point, so each chunk
        // arrives with the flattened deck and the landmarks in it, and the
        // resolver sees the site as the player will. Neighbours are
        // included because `refresh` reads one cell out in every direction.
        var needed: Set<ChunkCoord> = []
        for cell in cells {
            for dz in -1...1 {
                for dx in -1...1 {
                    needed.insert(World.chunkCoord(forWorldX: cell.x + dx, worldZ: cell.z + dz))
                }
            }
        }
        for coord in needed { world.forceGenerate(coord) }

        // The ground under every cell and the air above it. A rail needs a
        // full block beneath it or it will not be laid at all, and the hill
        // needs its own embankment because it climbs three blocks clear of
        // the deck.
        for cell in cells {
            for y in (deck - 1)...(cell.y - 1) {
                world.setBlock(worldX: cell.x, y: y, worldZ: cell.z, to: .stone, remesh: false)
            }
            for y in cell.y...(cell.y + 4) {
                world.setBlock(worldX: cell.x, y: y, worldZ: cell.z, to: .air, remesh: false)
            }
        }

        for cell in cells {
            world.setBlock(
                worldX: cell.x, y: cell.y, worldZ: cell.z,
                to: RailNetwork.straight(along: .east, powered: isBooster(cell)), remesh: false
            )
            // Every booster runs over glowCrystal, so the strips that pay for
            // the hills read as strips of light: the track tells you where
            // the speed is, and at night the whole loop is legible from the
            // tower as dashes of amber.
            if isBooster(cell) {
                world.setBlock(worldX: cell.x, y: cell.y - 1, worldZ: cell.z,
                               to: .glowCrystal, remesh: false)
            }
        }

        // Resolved only after every rail is down, so each cell sees its
        // real neighbours rather than a line that is still being drawn.
        for cell in cells {
            RailNetwork.refresh(around: cell, preferring: .east, in: world)
        }
    }

    /// The height of the north side's track at a given x — the coaster.
    ///
    /// Three up, a long crest, three down, and symmetric, because on a loop
    /// the cart meets the hill from whichever side it is going round. That
    /// symmetry is the reason there are boosters at both feet: friction
    /// means a rise as tall as the drop that fed it cannot be cleared (see
    /// `Minecart.friction`, which has the measured numbers), so the height
    /// has to be bought at the bottom before the climb rather than borrowed
    /// from the descent before it.
    ///
    /// Three and not four is a margin, not a whim. A booster tops a cart
    /// out at 9.5 blocks a second and clearing four blocks needs 9.4 at the
    /// foot of the slope — true on paper and not true after any run of flat
    /// track between the last powered rail and the hill.
    ///
    /// The heights are laid out so that the first cell of the climb sits at
    /// the height of the flat leading into it. A slope cell spans its own
    /// floor to one above; starting it a block up leaves a step at the foot
    /// of the hill that a cart arrives at and stops dead against.
    private static func hillHeight(atX x: Int) -> Int {
        switch x {
        case (-34)...(-32): return deck + 1 + (x + 34)
        case (-31)...(-12): return deck + 4
        case (-11)...(-9): return deck + 4 - (x + 12)
        default: return deck + 1
        }
    }

    /// How far round the loop a cell is, clockwise from the north-west
    /// corner. Nil for the spur, which is not on the loop.
    ///
    /// Corners belong to two sides; the first match wins, which is
    /// arbitrary and only has to be consistent.
    private static func loopPosition(_ cell: (x: Int, y: Int, z: Int)) -> Int? {
        let width = east - west, depth = south - north
        if cell.z == north { return cell.x - west }
        if cell.x == east { return width + (cell.z - north) }
        if cell.z == south { return width + depth + (east - cell.x) }
        if cell.x == west { return 2 * width + depth + (south - cell.z) }
        return nil
    }

    /// A run of powered rail this long, this often, right round the loop.
    ///
    /// The spacing is not a matter of taste. Friction sheds 12% of a cart's
    /// speed a second, which means a cart leaving a booster at its top
    /// speed of 9.5 blocks a second coasts about seventy-nine blocks and
    /// then stops — and the loop is four hundred and seventy-six cells. The
    /// first cut of this had five runs on it and a cart got about a fifth
    /// of the way round before dying on the straight. Twenty-eight cells of
    /// unpowered track between runs is a comfortable fraction of what a
    /// cart can actually carry.
    private static let boosterSpacing = 36
    private static let boosterRun = 8

    /// Whether a cell gets a powered rail.
    ///
    /// Spaced runs rather than a continuous strip: a track made entirely of
    /// powered rail is a conveyor belt, and the point of a coaster is the
    /// stretches where nothing is pushing.
    private static func isBooster(_ cell: (x: Int, y: Int, z: Int)) -> Bool {
        guard cell.y == deck + 1 else { return false }   // never on the hill

        // Never on a corner. There is no powered curve — a booster that
        // finds itself on a bend is resolved as a straight along one of its
        // links — so a corner with a booster on it points off the end of
        // the loop, and a cart that reaches it stops dead. The spacing
        // happened to land a run on two of the four corners, and the ride
        // ended at whichever one it met first.
        if (cell.x == west || cell.x == east) && (cell.z == north || cell.z == south) {
            return false
        }

        guard let along = loopPosition(cell) else {
            // The spur. Its run starts a few cells down from the waiting
            // cart rather than under it, so the cart is still there when
            // the player walks out to it.
            return cell.x == 0 && (14...21).contains(cell.z)
        }

        // Both feet of the hill, whichever way round the cart is going.
        // These are placed rather than spaced, because a cart has to reach
        // the slope with everything a booster can give it: three blocks of
        // climb costs about half its speed, and any run of plain track
        // between the last powered rail and the foot comes off the top of
        // what it has to spend.
        if cell.z == north, (-42...(-35)).contains(cell.x) || (-7...0).contains(cell.x) {
            return true
        }
        return along % boosterSpacing < boosterRun
    }
}

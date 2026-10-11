import Foundation

extension Landmarks {
    /// The city in the sky: three islands floating over the valley south
    /// of the site, reached by a staircase that climbs out over the drop.
    ///
    /// The composition is read from the lawn, looking south: a great isle
    /// carrying a twin-towered cathedral and a village of half-timbered
    /// houses around a golden crossroads, a lower isle to the west with
    /// the mill and its cottages, a higher one to the east with a
    /// watchtower — and a galleon airship riding at anchor over the
    /// approach. The skyline steps the way the castle's does — crossing
    /// spire, then the west-front towers, then the watchtower, then the
    /// house roofs — because a silhouette with one clear order reads as
    /// a place rather than a pile. The first cut of this was half the
    /// size in every direction and read as a garden ornament; the world
    /// is 192 blocks tall and the deck is at 64, and a city in the sky
    /// should spend that headroom.
    ///
    /// Everything hangs at heights measured against the seed's own
    /// terrain (`TerrainProbe` found the valley floor at 54–77 down
    /// there), high enough that every isle keeps open air under its keel
    /// — a floating island that grazes a hilltop is just a hill with
    /// opinions. The waterfalls are the one thing that reaches all the
    /// way down, on purpose: a ribbon of water falling thirty blocks into
    /// the valley is what tells the eye how high the city hangs.
    ///
    /// The published statics — `skyCityTop`, `skyIslands`, `skyStairRoute`,
    /// `skyFalls`, `skyBalloons`, `skyRoadCells`, `skyHearths` — are the
    /// builder's own numbers, consumed by `DemoCheck` so the checks
    /// measure what was built rather than what a check-file remembered.
    static func skyCity(
        originX: Int, groundY: Int, originZ: Int, in world: World
    ) {
        SkyCity(originX: originX, groundY: groundY, originZ: originZ, world: world).build()
    }

    /// The highest block of the city relative to the deck: the torch on
    /// the crossing spire. Declared so the ceiling check can demand the
    /// spire arrived whole rather than merely "something tall stands".
    static let skyCityTop = 88

    /// Each isle: where it is, its walking surface, and the lowest block
    /// of its keel — with clear air below that, or it is not floating.
    static func skyIslands(
        originX: Int, groundY: Int, originZ: Int
    ) -> [(x: Int, z: Int, top: Int, tip: Int)] {
        [
            (originX, originZ, groundY + 29, groundY + 15),
            (originX - 50, originZ - 4, groundY + 23, groundY + 12),
            (originX + 50, originZ - 8, groundY + 35, groundY + 25),
        ]
    }

    /// The climb from the lawn to the main isle's gate, one flight, as
    /// cells the demo check's body walks: twenty-nine treads out over the
    /// valley and then the flat gangway to the rim. Cell `y` is the tread
    /// block itself on the stairs and the walking level on the gangway —
    /// the walk's standing band accepts either.
    static func skyStairRoute(
        originX: Int, groundY: Int, originZ: Int
    ) -> [[(x: Int, y: Int, z: Int)]] {
        var route: [(x: Int, y: Int, z: Int)] = []
        for step in 0...28 {
            route.append((originX, groundY + 1 + step, originZ - 54 + step))
        }
        for z in (originZ - 25)...(originZ - 22) {
            route.append((originX, groundY + 30, z))
        }
        return [route]
    }

    /// The two waterfalls: the column's cell and the height it pours from.
    static func skyFalls(
        originX: Int, groundY: Int, originZ: Int
    ) -> [(x: Int, z: Int, top: Int)] {
        [
            (originX + 16, originZ + 20, groundY + 29),
            (originX - 62, originZ - 4, groundY + 23),
        ]
    }

    /// The two balloons: a cell inside each canvas canopy, and the solid
    /// deck or basket below it that makes it a vessel rather than a blob.
    static func skyBalloons(
        originX: Int, groundY: Int, originZ: Int
    ) -> [(x: Int, y: Int, z: Int, baseY: Int)] {
        [
            (originX - 13, groundY + 44, originZ - 28, groundY + 36),
            (originX + 64, groundY + 38, originZ - 2, groundY + 32),
        ]
    }

    /// Every cell of the golden road, which is all one rectangle: gate
    /// landing to cathedral doors. The cross-lane and the carpet up the
    /// nave are gold too, but the claim is about the spine.
    static func skyRoadCells(
        originX: Int, groundY: Int, originZ: Int
    ) -> [(x: Int, z: Int)] {
        var cells: [(x: Int, z: Int)] = []
        for z in (originZ - 22)...(originZ - 3) {
            for x in (originX - 1)...(originX + 1) {
                cells.append((x, z))
            }
        }
        return cells
    }

    /// One cell inside each of four dwellings, at standing height, where
    /// a body would warm its hands — the light claim samples here.
    static func skyHearths(
        originX: Int, groundY: Int, originZ: Int
    ) -> [(x: Int, y: Int, z: Int)] {
        [
            (originX - 13, groundY + 30, originZ - 17),
            (originX + 11, groundY + 30, originZ - 16),
            (originX - 23, groundY + 30, originZ - 8),
            (originX - 51, groundY + 24, originZ - 5),
        ]
    }
}

/// The sky city's parts, kept in one type for the same reason the Eiffel
/// Tower's are: the isles, the stair, the bridges and the falls all have
/// to agree about a handful of levels, and passing those levels around a
/// dozen loose helpers would leave the agreement implicit.
private struct SkyCity {
    let originX: Int
    let groundY: Int
    let originZ: Int
    let world: World

    /// The main isle's walking surface — the block under your feet is
    /// `surface`, your feet are at `surface + 1`. The west isle sits six
    /// below it and the east isle six above, so the three read as
    /// terraces of one sky rather than three unrelated altitudes.
    private var surface: Int { groundY + 29 }
    private var westTop: Int { groundY + 23 }
    private var eastTop: Int { groundY + 35 }

    func build() {
        mainIsle()
        westIsle()
        eastIsle()
        cathedral()
        cottages()
        goldenRoad()
        watchtower()
        skyStair()
        bridges()
        waterfalls()
        airship()
        hotAirBalloon()
        clouds()
    }

    // MARK: - The isles

    /// An island is an ellipse of grass with a keel of stone tapering
    /// under it. The taper is what sells "floating": a cylinder reads as
    /// a pillar that lost its ground, a taper reads as a thing torn out
    /// of the earth and carried up.
    private func isle(
        centreX: Int, centreZ: Int, top: Int,
        radiusX: Double, radiusZ: Double, depth: Int
    ) {
        let rx = Int(radiusX.rounded(.up)), rz = Int(radiusZ.rounded(.up))
        for dz in -rz...rz {
            for dx in -rx...rx {
                let fit = pow(Double(dx) / radiusX, 2) + pow(Double(dz) / radiusZ, 2)
                guard fit <= 1.0 else { continue }
                world.setBlock(
                    worldX: centreX + dx, y: top, worldZ: centreZ + dz,
                    to: .grass, remesh: false
                )
            }
        }
        for d in 1...depth {
            let f = 1.0 - pow(Double(d) / Double(depth + 1), 1.5)
            let layerX = radiusX * f, layerZ = radiusZ * f
            let lx = Int(layerX.rounded(.up)), lz = Int(layerZ.rounded(.up))
            guard layerX >= 0.5, layerZ >= 0.5 else { continue }
            for dz in -lz...lz {
                for dx in -lx...lx {
                    let fit = pow(Double(dx) / layerX, 2) + pow(Double(dz) / layerZ, 2)
                    guard fit <= 1.0 else { continue }
                    world.setBlock(
                        worldX: centreX + dx, y: top - d, worldZ: centreZ + dz,
                        to: d <= 2 ? .dirt : .stone, remesh: false
                    )
                }
            }
        }
    }

    private func mainIsle() {
        isle(
            centreX: originX, centreZ: originZ, top: surface,
            radiusX: 34, radiusZ: 22, depth: 14
        )
    }

    private func westIsle() {
        isle(
            centreX: originX - 50, centreZ: originZ - 4, top: westTop,
            radiusX: 11, radiusZ: 11, depth: 11
        )
    }

    private func eastIsle() {
        isle(
            centreX: originX + 50, centreZ: originZ - 8, top: eastTop,
            radiusX: 10, radiusZ: 10, depth: 10
        )
    }

    // MARK: - The cathedral

    /// A proper gothic massing this time: a twin-towered west front
    /// facing the golden road, a tall nave behind it with buttress piers
    /// and lancet windows, and a crossing tower whose spire is the
    /// highest thing in the city. Snow walls like the castle's — across
    /// the site the two whites read as the same imported marble — with
    /// brick roofs and caps so every top reads against the wall below
    /// it, the way the reference painting's orange does.
    private func cathedral() {
        let cx = originX, s = surface

        // The floor plinth first, replacing lawn with pale stone under
        // the whole church, so you step through the doors onto stone.
        Landmarks.fill(
            world,
            x: (cx - 11)...(cx + 11), y: s...s, z: (originZ - 2)...(originZ + 20),
            .stone
        )

        // MARK: The west front — two towers flanking the entrance bay

        for towerX in [cx - 10, cx + 4] {
            Landmarks.fill(
                world,
                x: towerX...(towerX + 6), y: (s + 1)...(s + 39),
                z: (originZ - 2)...(originZ + 4), .snow
            )
            Landmarks.fill(
                world,
                x: (towerX + 1)...(towerX + 5), y: (s + 1)...(s + 38),
                z: (originZ - 1)...(originZ + 3), .air
            )
            // Paired panes at three storeys up the north face.
            for dy in [7, 17, 27] {
                for extraY in [0, 1] {
                    world.setBlock(worldX: towerX + 3, y: s + dy + extraY, worldZ: originZ - 2,
                                   to: .glassPane, remesh: false)
                }
            }
            // The brick cap, gold boss, torch.
            Landmarks.pyramid(world, centreX: towerX + 3, baseY: s + 40, centreZ: originZ + 1, halfWidth: 3, .brick)
            world.setBlock(worldX: towerX + 3, y: s + 44, worldZ: originZ + 1, to: .goldBlock, remesh: false)
            Landmarks.torch(world, x: towerX + 3, y: s + 45, z: originZ + 1)
        }

        // The entrance bay between the towers, lower, so the front reads
        // as two verticals holding a wall rather than one slab.
        Landmarks.fill(
            world,
            x: (cx - 3)...(cx + 3), y: (s + 1)...(s + 26),
            z: (originZ - 2)...(originZ + 4), .snow
        )
        Landmarks.fill(
            world,
            x: (cx - 2)...(cx + 2), y: (s + 1)...(s + 25),
            z: (originZ - 1)...(originZ + 3), .air
        )
        Landmarks.fill(
            world,
            x: (cx - 3)...(cx + 3), y: (s + 27)...(s + 27),
            z: (originZ - 2)...(originZ + 4), .brick
        )
        // The arch and its three doors, at the end of the golden road.
        Landmarks.fill(
            world,
            x: (cx - 2)...(cx + 2), y: (s + 1)...(s + 3),
            z: (originZ - 2)...(originZ - 2), .air
        )
        for doorX in (cx - 1)...(cx + 1) {
            world.setBlock(worldX: doorX, y: s + 1, worldZ: originZ - 2, to: .oakDoorLowerNorth, remesh: false)
            world.setBlock(worldX: doorX, y: s + 2, worldZ: originZ - 2, to: .oakDoorUpperNorth, remesh: false)
        }
        // The west rose, radiant so it burns at dusk down the length of
        // the golden road: a red heart in a cyan cross, glass at the
        // corners.
        rose(x: cx, y: s + 14, z: originZ - 2)
        // Through the bay's back wall into the nave.
        Landmarks.fill(
            world,
            x: (cx - 2)...(cx + 2), y: (s + 1)...(s + 3),
            z: (originZ + 4)...(originZ + 4), .air
        )

        // MARK: The nave

        Landmarks.walls(
            world,
            x: (cx - 10)...(cx + 10), y: (s + 1)...(s + 22),
            z: (originZ + 4)...(originZ + 20), .snow
        )
        Landmarks.fill(
            world,
            x: (cx - 9)...(cx + 9), y: (s + 1)...(s + 21),
            z: (originZ + 5)...(originZ + 19), .air
        )
        // The stepped brick roof, ridge running down the axis.
        for step in 0...9 {
            Landmarks.fill(
                world,
                x: (cx - 10 + step)...(cx + 10 - step), y: (s + 23 + step)...(s + 23 + step),
                z: (originZ + 4)...(originZ + 20), .brick
            )
        }
        // Buttress piers marching down both flanks — the rhythm that
        // says gothic at a distance, and the thing the first, smaller
        // church had no wall long enough to need.
        for dz in [6, 10, 14, 18] {
            for pierX in [cx - 11, cx + 11] {
                Landmarks.fill(
                    world,
                    x: pierX...pierX, y: (s + 1)...(s + 18),
                    z: (originZ + dz)...(originZ + dz), .cobblestone
                )
            }
        }
        // Lancets between the piers, tall and paired.
        for dz in [8, 12, 16] {
            for dy in 3...8 {
                world.setBlock(worldX: cx - 10, y: s + dy, worldZ: originZ + dz, to: .glassPane, remesh: false)
                world.setBlock(worldX: cx + 10, y: s + dy, worldZ: originZ + dz, to: .glassPane, remesh: false)
            }
        }
        // The south gable: three lancets under a second rose, for
        // everything flying in from the valley.
        let back = originZ + 20
        for dx in [-4, 0, 4] {
            for dy in 3...8 {
                world.setBlock(worldX: cx + dx, y: s + dy, worldZ: back, to: .glassPane, remesh: false)
            }
        }
        rose(x: cx, y: s + 16, z: back)

        // MARK: The crossing tower and spire — the city's summit

        Landmarks.walls(
            world,
            x: (cx - 4)...(cx + 4), y: (s + 23)...(s + 52),
            z: (originZ + 8)...(originZ + 16), .snow
        )
        for dy in [30, 40] {
            for (wx, wz) in [(cx, originZ + 8), (cx, originZ + 16), (cx - 4, originZ + 12), (cx + 4, originZ + 12)] {
                world.setBlock(worldX: wx, y: s + dy, worldZ: wz, to: .glassPane, remesh: false)
                world.setBlock(worldX: wx, y: s + dy + 1, worldZ: wz, to: .glassPane, remesh: false)
            }
        }
        Landmarks.pyramid(world, centreX: cx, baseY: s + 53, centreZ: originZ + 12, halfWidth: 4, .brick)
        world.setBlock(worldX: cx, y: s + 58, worldZ: originZ + 12, to: .goldBlock, remesh: false)
        Landmarks.torch(world, x: cx, y: s + 59, z: originZ + 12)

        // MARK: Inside

        // The golden road does not stop at the doors: a carpet of gold
        // runs the length of the nave to the altar.
        Landmarks.fill(
            world,
            x: cx...cx, y: s...s, z: (originZ - 1)...(originZ + 17), .goldBlock
        )
        world.setBlock(worldX: cx, y: s + 1, worldZ: originZ + 18, to: .goldBlock, remesh: false)
        Landmarks.torch(world, x: cx, y: s + 2, z: originZ + 18)
        // Pearl lamps hung high in the vault, and floor torches at the
        // piers, so the hall glows rather than merely encloses.
        world.setBlock(worldX: cx - 3, y: s + 16, worldZ: originZ + 10, to: .pearlLight, remesh: false)
        world.setBlock(worldX: cx + 3, y: s + 16, worldZ: originZ + 14, to: .pearlLight, remesh: false)
        for (dx, dz) in [(-9, 6), (9, 6), (-9, 12), (9, 12), (-9, 18), (9, 18)] {
            Landmarks.torch(world, x: cx + dx, y: s + 1, z: originZ + dz)
        }
    }

    /// A radiant rose window: red heart, cyan cross, glass corners.
    private func rose(x: Int, y: Int, z: Int) {
        world.setBlock(worldX: x, y: y, worldZ: z, to: .radiantRed, remesh: false)
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            world.setBlock(worldX: x + dx, y: y + dy, worldZ: z, to: .radiantCyan, remesh: false)
        }
        for (dx, dy) in [(-1, -1), (1, -1), (-1, 1), (1, 1)] {
            world.setBlock(worldX: x + dx, y: y + dy, worldZ: z, to: .glassPane, remesh: false)
        }
    }

    // MARK: - The cottages

    /// A half-timbered cottage: spruce posts at the corners, plaster
    /// fields crossed with timber framing, and a stair-block gable roof
    /// with an overhang. `doorFacing` names the wall the door is in.
    private func cottage(
        x0: Int, z0: Int, width: Int, depth: Int, floor: Int,
        doorFacing: BlockFacing
    ) {
        let x1 = x0 + width - 1, z1 = z0 + depth - 1
        let s = floor

        Landmarks.fill(world, x: x0...x1, y: s...s, z: z0...z1, .planks)
        for y in (s + 1)...(s + 4) {
            for z in z0...z1 {
                for x in x0...x1 {
                    let onEdge = x == x0 || x == x1 || z == z0 || z == z1
                    guard onEdge else {
                        if y <= s + 4 { world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false) }
                        continue
                    }
                    let corner = (x == x0 || x == x1) && (z == z0 || z == z1)
                    let block: BlockType
                    if corner {
                        block = .spruceLog
                    } else if y == s + 2 || y == s + 3 {
                        // Framing on the show courses, every other stud.
                        block = (x + z) % 2 == 0 ? .timberFrame : .plaster
                    } else {
                        block = .plaster
                    }
                    world.setBlock(worldX: x, y: y, worldZ: z, to: block, remesh: false)
                }
            }
        }

        // The door, centred in its wall, opening onto the lane.
        let doorCell: (x: Int, z: Int)
        switch doorFacing {
        case .east: doorCell = (x1, z0 + depth / 2)
        case .west: doorCell = (x0, z0 + depth / 2)
        case .south: doorCell = (x0 + width / 2, z1)
        case .north: doorCell = (x0 + width / 2, z0)
        }
        world.setBlock(
            worldX: doorCell.x, y: s + 1, worldZ: doorCell.z,
            to: .oakDoor(.lower, facing: doorFacing, open: false), remesh: false
        )
        world.setBlock(
            worldX: doorCell.x, y: s + 2, worldZ: doorCell.z,
            to: .oakDoor(.upper, facing: doorFacing, open: false), remesh: false
        )

        // A window either side of centre on both long walls, skipping
        // whichever cell the door took.
        for z in [z0 + 1, z1 - 1] {
            for x in [x0 + 2, x1 - 2] where (x, z) != doorCell {
                world.setBlock(worldX: x, y: s + 2, worldZ: z, to: .glassPane, remesh: false)
            }
        }

        // The gable roof: stair courses climbing to a planks ridge, with
        // a one-block eave past the walls, and plaster filling the gable
        // ends so the attic is a wall and not a window into the rafters.
        let half = (depth - 1) / 2
        for i in 0...half {
            let y = s + 5 + i
            let zNorth = z0 + i, zSouth = z1 - i
            if i == half {
                Landmarks.fill(world, x: x0...x1, y: y...y, z: zNorth...zSouth, .planks)
            } else {
                for x in (x0 - 1)...(x1 + 1) {
                    world.setBlock(worldX: x, y: y, worldZ: zNorth,
                                   to: .oakStairs(.south), remesh: false)
                    world.setBlock(worldX: x, y: y, worldZ: zSouth,
                                   to: .oakStairs(.north), remesh: false)
                }
                if zNorth + 1 <= zSouth - 1 {
                    for gz in (zNorth + 1)...(zSouth - 1) {
                        world.setBlock(worldX: x0, y: y, worldZ: gz, to: .plaster, remesh: false)
                        world.setBlock(worldX: x1, y: y, worldZ: gz, to: .plaster, remesh: false)
                    }
                }
            }
        }

        // The hearth's torch, inside, opposite the door.
        Landmarks.torch(world, x: x0 + 1, y: s + 1, z: z0 + 1)
    }

    private func cottages() {
        // The village on the main isle: five houses about the golden
        // crossroads, doors toward the lanes.
        cottage(x0: originX - 16, z0: originZ - 19, width: 7, depth: 6,
                floor: surface, doorFacing: .east)
        cottage(x0: originX + 8, z0: originZ - 19, width: 7, depth: 6,
                floor: surface, doorFacing: .west)
        cottage(x0: originX - 26, z0: originZ - 10, width: 7, depth: 6,
                floor: surface, doorFacing: .east)
        cottage(x0: originX + 20, z0: originZ - 12, width: 7, depth: 6,
                floor: surface, doorFacing: .west)
        cottage(x0: originX + 16, z0: originZ + 2, width: 7, depth: 6,
                floor: surface, doorFacing: .west)

        // The mill isle's pair: the mill by its pool, a cottage north.
        cottage(x0: originX - 53, z0: originZ - 7, width: 5, depth: 5,
                floor: westTop, doorFacing: .east)
        cottage(x0: originX - 48, z0: originZ - 12, width: 5, depth: 5,
                floor: westTop, doorFacing: .south)
    }

    // MARK: - The golden road

    /// The reference painting's one unforgettable move: a road of gold
    /// from the gate to the cathedral doors, with a cross-lane through
    /// the village. Inlaid in the lawn like the pyramid path, so nothing
    /// standing on the isle can collide with it — and gold's own gleam
    /// means the road lights itself at dusk.
    private func goldenRoad() {
        for cell in Landmarks.skyRoadCells(originX: originX, groundY: groundY, originZ: originZ) {
            world.setBlock(worldX: cell.x, y: surface, worldZ: cell.z, to: .goldBlock, remesh: false)
        }
        // The cross-lane between the houses, and a plaza at the meeting.
        Landmarks.fill(
            world,
            x: (originX - 22)...(originX + 18), y: surface...surface,
            z: (originZ - 13)...(originZ - 11), .goldBlock
        )
        Landmarks.disc(world, centreX: originX, y: surface, centreZ: originZ - 12, radius: 4.2, .goldBlock)

        // Pearl lamps on painted-column posts along the verges.
        for (dx, dz) in [(-3, -19), (3, -15), (-3, -7), (3, -5), (-18, -9), (12, -9)] {
            world.setBlock(worldX: originX + dx, y: surface + 1, worldZ: originZ + dz,
                           to: .sandstonePillar, remesh: false)
            world.setBlock(worldX: originX + dx, y: surface + 2, worldZ: originZ + dz,
                           to: .pearlLight, remesh: false)
        }
        // Oaks behind the lamps and about the green, because a town is a
        // town when something lives in it.
        for (dx, dz) in [(-20, 2), (-28, -2), (20, -4), (24, 6), (6, -20), (-24, 12)] {
            oak(x: originX + dx, z: originZ + dz, floor: surface)
        }

        // The pool the south fall pours from, sunk into the lawn east of
        // the church, with its channel to the rim.
        Landmarks.fill(
            world,
            x: (originX + 14)...(originX + 18), y: surface...surface,
            z: (originZ + 12)...(originZ + 16), .water
        )
        Landmarks.fill(
            world,
            x: (originX + 16)...(originX + 16), y: surface...surface,
            z: (originZ + 17)...(originZ + 19), .water
        )
    }

    private func oak(x: Int, z: Int, floor: Int) {
        for y in (floor + 1)...(floor + 4) {
            world.setBlock(worldX: x, y: y, worldZ: z, to: .log, remesh: false)
        }
        Landmarks.fill(
            world,
            x: (x - 1)...(x + 1), y: (floor + 4)...(floor + 5), z: (z - 1)...(z + 1),
            .leaves
        )
        world.setBlock(worldX: x, y: floor + 6, worldZ: z, to: .leaves, remesh: false)
    }

    // MARK: - The watchtower

    /// The east isle's whole job: a dark timber tower with a glowCrystal
    /// lantern behind glass, so the city has a lighthouse against the
    /// night sky where the cathedral has a spire against the day's.
    private func watchtower() {
        let cx = originX + 50, cz = originZ - 8, s = eastTop

        Landmarks.fill(world, x: (cx - 3)...(cx + 3), y: s...s, z: (cz - 3)...(cz + 3), .planks)
        for y in (s + 1)...(s + 16) {
            for z in (cz - 3)...(cz + 3) {
                for x in (cx - 3)...(cx + 3) {
                    let onEdge = x == cx - 3 || x == cx + 3 || z == cz - 3 || z == cz + 3
                    guard onEdge else {
                        world.setBlock(worldX: x, y: y, worldZ: z, to: .air, remesh: false)
                        continue
                    }
                    let corner = (x == cx - 3 || x == cx + 3) && (z == cz - 3 || z == cz + 3)
                    world.setBlock(
                        worldX: x, y: y, worldZ: z,
                        to: corner ? .spruceLog : .planks, remesh: false
                    )
                }
            }
        }
        // Window pairs at two storeys, then the lantern room: glass on
        // all four faces with the glowCrystal hung between them.
        for face in 0..<4 {
            let (dx, dz) = [(0, -3), (0, 3), (-3, 0), (3, 0)][face]
            for dy in [5, 6, 10, 11, 14, 15] {
                world.setBlock(worldX: cx + dx, y: s + dy, worldZ: cz + dz, to: .glassPane, remesh: false)
            }
        }
        world.setBlock(worldX: cx, y: s + 14, worldZ: cz, to: .glowCrystal, remesh: false)

        Landmarks.pyramid(world, centreX: cx, baseY: s + 17, centreZ: cz, halfWidth: 4, .stone)
        Landmarks.torch(world, x: cx, y: s + 22, z: cz)

        world.setBlock(worldX: cx - 3, y: s + 1, worldZ: cz, to: .oakDoorLowerWest, remesh: false)
        world.setBlock(worldX: cx - 3, y: s + 2, worldZ: cz, to: .oakDoorUpperWest, remesh: false)
        Landmarks.torch(world, x: cx + 2, y: s + 1, z: cz + 2)
    }

    // MARK: - The stair from the lawn

    /// Twenty-nine treads straight out over the valley, then a flat
    /// gangway to the rim: the one deliberate thrill of the site, a climb
    /// with nothing under it. Three wide, with a planks spine under the
    /// centre column — full-width underside looked like a monolith from
    /// the plaza — and a body two blocks tall walks it, which `DemoCheck`
    /// proves with the player's own physics.
    private func skyStair() {
        // The departure: a cobble landing on the lawn, gate-posted with
        // pearl lamps, so the stair starts at a place and not a guess.
        Landmarks.disc(world, centreX: originX, y: groundY, centreZ: originZ - 57, radius: 3.2, .cobblestone)
        for side in [-3, 3] {
            world.setBlock(worldX: originX + side, y: groundY + 1, worldZ: originZ - 56,
                           to: .sandstonePillar, remesh: false)
            world.setBlock(worldX: originX + side, y: groundY + 2, worldZ: originZ - 56,
                           to: .pearlLight, remesh: false)
        }

        for step in 0...28 {
            let y = groundY + 1 + step
            let z = originZ - 54 + step
            for dx in -1...1 {
                world.setBlock(worldX: originX + dx, y: y, worldZ: z,
                               to: .oakStairs(.south), remesh: false)
            }
            if step < 3 {
                for dx in -1...1 {
                    world.setBlock(worldX: originX + dx, y: y - 1, worldZ: z,
                                   to: .planks, remesh: false)
                }
            } else {
                world.setBlock(worldX: originX, y: y - 1, worldZ: z,
                               to: .planks, remesh: false)
            }
        }

        // The gangway from the stair head to the rim, with torch posts
        // so the climb reads at night from the plaza.
        Landmarks.fill(
            world,
            x: (originX - 1)...(originX + 1), y: (surface)...(surface),
            z: (originZ - 25)...(originZ - 23), .planks
        )
        for dx in [-2, 2] {
            world.setBlock(worldX: originX + dx, y: surface, worldZ: originZ - 24,
                           to: .planks, remesh: false)
            Landmarks.torch(world, x: originX + dx, y: surface + 1, z: originZ - 24)
        }
    }

    // MARK: - The bridges between isles

    /// Flat planks over the gap, then a stairway carved up into the
    /// higher isle's flank — the image every floating-city painting
    /// agrees on, and incidentally the same two-half-block climb the
    /// tower stairs already proved a body can make.
    private func bridges() {
        // West: main isle down to the mill isle.
        Landmarks.fill(
            world,
            x: (originX - 38)...(originX - 34), y: westTop...westTop,
            z: (originZ - 5)...(originZ - 3), .planks
        )
        for step in 0...5 {
            let x = originX - 33 + step
            let y = westTop + 1 + step
            Landmarks.fill(
                world,
                x: x...x, y: (y + 1)...(y + 4), z: (originZ - 5)...(originZ - 3), .air
            )
            for dz in -1...1 {
                world.setBlock(worldX: x, y: y, worldZ: originZ - 4 + dz,
                               to: .oakStairs(.east), remesh: false)
            }
        }
        Landmarks.torch(world, x: originX - 36, y: westTop + 1, z: originZ - 5)

        // East: main isle up to the watch isle.
        Landmarks.fill(
            world,
            x: (originX + 32)...(originX + 39), y: surface...surface,
            z: (originZ - 9)...(originZ - 7), .planks
        )
        for step in 0...5 {
            let x = originX + 40 + step
            let y = surface + 1 + step
            Landmarks.fill(
                world,
                x: x...x, y: (y + 1)...(y + 4), z: (originZ - 9)...(originZ - 7), .air
            )
            for dz in -1...1 {
                world.setBlock(worldX: x, y: y, worldZ: originZ - 8 + dz,
                               to: .oakStairs(.east), remesh: false)
            }
        }
        Landmarks.torch(world, x: originX + 34, y: surface + 1, z: originZ - 9)
    }

    // MARK: - The waterfalls

    /// Two ribbons of standing water from rim pools all the way to the
    /// valley floor, their feet found by asking the generator where the
    /// ground actually is — the same question `flattenPlot` asks — so
    /// the falls always land instead of stopping in the air.
    private func waterfalls() {
        for fall in Landmarks.skyFalls(originX: originX, groundY: groundY, originZ: originZ) {
            let ground = world.generator.surfaceHeight(x: fall.x, z: fall.z)
            guard ground < fall.top else { continue }
            for y in (ground + 1)...fall.top {
                world.setBlock(worldX: fall.x, y: y, worldZ: fall.z, to: .water, remesh: false)
            }
            // The plunge pool, cut into the valley's own turf.
            Landmarks.disc(world, centreX: fall.x, y: ground, centreZ: fall.z, radius: 1.8, .water)
        }
        // The west isle's rim pool and spill channel feeding its column.
        Landmarks.fill(
            world,
            x: (originX - 56)...(originX - 54), y: westTop...westTop,
            z: (originZ - 5)...(originZ - 3), .water
        )
        Landmarks.fill(
            world,
            x: (originX - 60)...(originX - 57), y: westTop...westTop,
            z: (originZ - 4)...(originZ - 4), .water
        )
    }

    // MARK: - The airships

    /// The galleon: a nineteen-block planks hull with a spruce keel and
    /// bowsprit, hung from a striped canvas envelope, moored to the main
    /// isle's rim by a spruce line. It rides north-west of the stair so
    /// the climb happens under its shadow, which is the arrival the
    /// reference painting promises.
    private func airship() {
        let hy = groundY + 36  // hull deck course
        let cz = originZ - 28

        Landmarks.fill(world, x: (originX - 20)...(originX - 6), y: hy...hy, z: (cz - 1)...(cz + 1), .planks)
        Landmarks.fill(world, x: (originX - 22)...(originX - 4), y: (hy + 1)...(hy + 1), z: (cz - 2)...(cz + 2), .planks)
        Landmarks.walls(world, x: (originX - 22)...(originX - 4), y: (hy + 2)...(hy + 2), z: (cz - 2)...(cz + 2), .planks)
        // Keel, bowsprit toward the isle, sternpost behind.
        Landmarks.fill(world, x: (originX - 19)...(originX - 7), y: (hy - 1)...(hy - 1), z: cz...cz, .spruceLog)
        Landmarks.fill(world, x: (originX - 3)...(originX - 1), y: (hy + 1)...(hy + 1), z: cz...cz, .spruceLog)
        world.setBlock(worldX: originX - 23, y: hy + 1, worldZ: cz, to: .spruceLog, remesh: false)
        world.setBlock(worldX: originX - 23, y: hy + 2, worldZ: cz, to: .spruceLog, remesh: false)
        Landmarks.torch(world, x: originX - 23, y: hy + 3, z: cz)

        // Rigging up to the envelope.
        for (dx, dz) in [(-20, -2), (-20, 2), (-6, -2), (-6, 2)] {
            Landmarks.fill(
                world,
                x: (originX + dx)...(originX + dx), y: (hy + 3)...(hy + 5),
                z: (cz + dz)...(cz + dz), .spruceLog
            )
        }

        // The envelope: six canvas courses, fattest amidships.
        Landmarks.fill(world, x: (originX - 18)...(originX - 8), y: (hy + 6)...(hy + 6), z: (cz - 1)...(cz + 1), .balloonCanvas)
        Landmarks.fill(world, x: (originX - 21)...(originX - 5), y: (hy + 7)...(hy + 7), z: (cz - 2)...(cz + 2), .balloonCanvas)
        Landmarks.fill(world, x: (originX - 23)...(originX - 3), y: (hy + 8)...(hy + 8), z: (cz - 2)...(cz + 2), .balloonCanvas)
        Landmarks.fill(world, x: (originX - 23)...(originX - 3), y: (hy + 9)...(hy + 9), z: (cz - 2)...(cz + 2), .balloonCanvas)
        Landmarks.fill(world, x: (originX - 21)...(originX - 5), y: (hy + 10)...(hy + 10), z: (cz - 2)...(cz + 2), .balloonCanvas)
        Landmarks.fill(world, x: (originX - 18)...(originX - 8), y: (hy + 11)...(hy + 11), z: (cz - 1)...(cz + 1), .balloonCanvas)

        // The mooring line, sagging from the bow down to a bollard on
        // the isle's north-west rim. Deliberately clear of the stair and
        // gangway — an earlier draft tied off to the gangway itself, and
        // the check's walking body met a rope at head height and stopped.
        Landmarks.line(
            world,
            from: (x: originX - 5, y: hy, z: cz + 2),
            to: (x: originX - 8, y: surface, z: originZ - 20),
            .spruceLog
        )
    }

    /// The round balloon east of the watch isle: a wool-and-poppy canopy
    /// over a little planks basket, drifting where the airship rides.
    private func hotAirBalloon() {
        let bx = originX + 64, bz = originZ - 2
        let by = groundY + 32  // basket floor

        Landmarks.fill(world, x: (bx - 1)...(bx + 1), y: by...by, z: (bz - 1)...(bz + 1), .planks)
        Landmarks.walls(world, x: (bx - 1)...(bx + 1), y: (by + 1)...(by + 1), z: (bz - 1)...(bz + 1), .planks)
        Landmarks.torch(world, x: bx, y: by + 1, z: bz)
        for (dx, dz) in [(-1, -1), (-1, 1), (1, -1), (1, 1)] {
            Landmarks.fill(
                world,
                x: (bx + dx)...(bx + dx), y: (by + 2)...(by + 3),
                z: (bz + dz)...(bz + dz), .spruceLog
            )
        }
        Landmarks.disc(world, centreX: bx, y: by + 4, centreZ: bz, radius: 1.6, .balloonCanvas)
        Landmarks.disc(world, centreX: bx, y: by + 5, centreZ: bz, radius: 2.8, .balloonCanvas)
        Landmarks.disc(world, centreX: bx, y: by + 6, centreZ: bz, radius: 3.2, .balloonCanvas)
        Landmarks.disc(world, centreX: bx, y: by + 7, centreZ: bz, radius: 2.8, .balloonCanvas)
        Landmarks.disc(world, centreX: bx, y: by + 8, centreZ: bz, radius: 1.6, .balloonCanvas)
        world.setBlock(worldX: bx, y: by + 9, worldZ: bz, to: .balloonCanvas, remesh: false)
    }

    // MARK: - The clouds

    /// Weather, parked. Puffs tucked under every keel, mist where the
    /// falls land, and one flat cloud off the south-east rim big enough
    /// to stand on — because the first thing anyone asks of a cloud
    /// block is whether they can.
    private func clouds() {
        func puff(_ x: Int, _ y: Int, _ z: Int) {
            Landmarks.fill(world, x: x...(x + 1), y: y...y, z: z...(z + 1), .cloud)
            world.setBlock(worldX: x, y: y + 1, worldZ: z, to: .cloud, remesh: false)
        }

        // Under the main isle.
        for (dx, dz) in [(-32, 6), (-27, -12), (-14, 18), (4, 19), (16, 12),
                         (24, -4), (10, -18), (-6, -20), (28, 8), (-20, 14)] {
            puff(originX + dx, surface - 10, originZ + dz)
        }
        // Under the west and east isles.
        for (dx, dz) in [(-54, -10), (-44, -1), (-56, 2)] {
            puff(originX + dx, westTop - 8, originZ + dz)
        }
        for (dx, dz) in [(44, -14), (56, -6), (48, -2)] {
            puff(originX + dx, eastTop - 8, originZ + dz)
        }

        // Mist at the waterfalls' feet.
        for fall in Landmarks.skyFalls(originX: originX, groundY: groundY, originZ: originZ) {
            let ground = world.generator.surfaceHeight(x: fall.x, z: fall.z)
            puff(fall.x - 2, ground + 1, fall.z + 1)
            puff(fall.x + 2, ground + 1, fall.z - 2)
        }

        // The standing cloud, moored to the south-east rim one step
        // below the lawn.
        Landmarks.disc(
            world,
            centreX: originX + 28, y: surface - 1, centreZ: originZ + 16,
            radius: 4.2, .cloud
        )
    }
}

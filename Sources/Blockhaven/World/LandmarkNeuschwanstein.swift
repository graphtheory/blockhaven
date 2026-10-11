import Foundation

extension Landmarks {
    /// Neuschwanstein: a clustered silhouette — a keep set back behind a
    /// forward hall wing, with three round towers pitched at markedly
    /// different heights — meant to be read from the far side of the plaza
    /// rather than inspected up close.
    ///
    /// The real castle's whole character is a jumble of towers standing
    /// clear of one another, seen against a steep keep roof, not a single
    /// flat facade. That drives every choice here: a hall wing is thrown
    /// forward on the keep's west flank so the plan is L-shaped and the
    /// front elevation has mass standing both ahead of (the wing and
    /// gatehouse) and behind (the keep) the line a flat building would
    /// draw; the three towers plant their feet at the front corners — one
    /// fused into the wing's forward corner, one against the gatehouse's
    /// east flank — and at the keep's own back corner, rather than huddled
    /// directly behind the keep where the keep would hide them; and their
    /// spires are built tall and narrow, height at least two and a half
    /// times radius, and staggered hard so the roofline steps down in
    /// three clear stages: the tallest tower, then the keep's own roof,
    /// then the shortest turret. Walls are `.snow` throughout and nothing
    /// else is, every spire and roof is `.stone` so it reads as a dark cap
    /// rather than dissolving into the wall below it. A stepped
    /// cobblestone plinth stands in for the crag the real building sits
    /// on — tall enough to read as raised ground, short enough not to
    /// reach out and take a bite of the railway loop.
    ///
    /// The whole thing is a tall, narrow mass on a crag, so growing it
    /// means growing upward, not outward: the footprint here is the same
    /// one this design started with. The keep's wall gained storeys (and
    /// window rows to show them) rather than girth, the spires were
    /// stretched hardest of all so the tallest clears the keep roof by a
    /// wide margin instead of a narrow one, and the plinth was dug a
    /// little deeper so the extra height still reads as standing on
    /// something.
    static func neuschwanstein(
        originX: Int, groundY: Int, originZ: Int, in world: World
    ) {
        // Crenellations for the gatehouse roof: alternating raised blocks
        // along a rectangle's rim, with an occasional torch on the merlons
        // facing the plaza. A round tower's conical cap needs none of
        // this, which is why only the gatehouse calls it.
        func crenellate(x: ClosedRange<Int>, z: ClosedRange<Int>, y: Int) {
            guard y >= 0, y <= ceiling else { return }
            var i = 0
            for xx in x {
                if i % 2 == 0 {
                    world.setBlock(worldX: xx, y: y, worldZ: z.lowerBound, to: .snow, remesh: false)
                    world.setBlock(worldX: xx, y: y, worldZ: z.upperBound, to: .snow, remesh: false)
                    if i % 4 == 0 {
                        torch(world, x: xx, y: y + 1, z: z.upperBound)
                    }
                }
                i += 1
            }
            i = 0
            for zz in z {
                if i % 2 == 0 {
                    world.setBlock(worldX: x.lowerBound, y: y, worldZ: zz, to: .snow, remesh: false)
                    world.setBlock(worldX: x.upperBound, y: y, worldZ: zz, to: .snow, remesh: false)
                }
                i += 1
            }
        }

        // MARK: Plinth — a crag suggested, not built

        // One wide cobblestone ledge and one narrower slab stacked on it.
        // Two steps read as "raised outcrop" without the footprint (or the
        // height) of an actual hill, which would swallow the railway loop
        // running past this site. The slab is a little deeper than it once
        // was — the building above it grew a storey and a half taller, and
        // a shallow plinth under a tall building starts to look like a
        // building balanced on a curb rather than a crag.
        fill(
            world,
            x: (originX - 17)...(originX + 17), y: (groundY + 1)...(groundY + 1),
            z: (originZ - 13)...(originZ + 13), .cobblestone
        )
        let deckX = (originX - 14)...(originX + 14)
        let deckZ = (originZ - 10)...(originZ + 10)
        fill(world, x: deckX, y: (groundY + 2)...(groundY + 6), z: deckZ, .cobblestone)

        // Walk level for everything that stands on the deck.
        let floorY = groundY + 7

        // MARK: Keep

        // A square plan keeps the roof a true pyramid rather than a
        // lopsided one, and square reads as "tower" at a glance in a way a
        // long rectangle would not. The wall climbs several storeys now —
        // this is the piece of the design that had to grow the most, since
        // a keep is meant to read as the tallest thing standing on its own
        // footprint, not as a plinth for its roof — but its footprint is
        // exactly the one this design started with; height comes from
        // storeys, not girth.
        let keepHalf = 5
        let keepZ = originZ - 5
        let keepWallTop = floorY + 27
        walls(
            world,
            x: (originX - keepHalf)...(originX + keepHalf), y: floorY...keepWallTop,
            z: (keepZ - keepHalf)...(keepZ + keepHalf), .snow
        )
        // Planks underfoot inside, distinct from the cobblestone courtyard
        // outside — a cheap cue that this cell is indoors.
        fill(
            world,
            x: (originX - keepHalf + 1)...(originX + keepHalf - 1),
            y: (groundY + 4)...(groundY + 4),
            z: (keepZ - keepHalf + 1)...(keepZ + keepHalf - 1), .planks
        )
        // Stone, not snow: a white cap on a white tower would blur the one
        // silhouette line — the roof edge — that says "building" instead
        // of "cliff". `pyramid` narrows by one ring a course, so a
        // half-width-5 base gives a full six-course roof — steep, and
        // clearly a roof rather than a hat.
        pyramid(world, centreX: originX, baseY: keepWallTop + 1, centreZ: keepZ, halfWidth: keepHalf, .stone)

        // Vertical pairs of panes, not single dots — two-tall windows
        // repeated at five floor levels are what tell the eye this wall
        // has storeys behind it, and survive being seen from the plaza.
        // Five rows, not the three of the shorter wall this replaced —
        // the wall gained storeys, so it needs more of them lit up.
        let windowFloors = [3, 8, 13, 18, 23].map { floorY + $0 }
        let northZ = keepZ - keepHalf
        let southZ = keepZ + keepHalf
        let eastX = originX + keepHalf
        let westX = originX - keepHalf
        for base in windowFloors {
            for dx in [-3, 0, 3] {
                for dy in [0, 1] {
                    world.setBlock(worldX: originX + dx, y: base + dy, worldZ: northZ, to: .glassPane, remesh: false)
                }
            }
            // The south wall carries the doorway on the centre column, so
            // its window files skip it rather than colliding with it.
            for dx in [-3, 3] {
                for dy in [0, 1] {
                    world.setBlock(worldX: originX + dx, y: base + dy, worldZ: southZ, to: .glassPane, remesh: false)
                }
            }
            for dz in [-3, 0, 3] {
                for dy in [0, 1] {
                    world.setBlock(worldX: eastX, y: base + dy, worldZ: keepZ + dz, to: .glassPane, remesh: false)
                    world.setBlock(worldX: westX, y: base + dy, worldZ: keepZ + dz, to: .glassPane, remesh: false)
                }
            }
        }

        // The keep's own door, opening onto the sliver of courtyard between
        // it and the gatehouse.
        world.setBlock(worldX: originX, y: floorY, worldZ: southZ, to: .oakDoorLowerSouth, remesh: false)
        world.setBlock(worldX: originX, y: floorY + 1, worldZ: southZ, to: .oakDoorUpperSouth, remesh: false)
        torch(world, x: originX - 2, y: floorY, z: southZ)
        torch(world, x: originX + 2, y: floorY, z: southZ)

        // MARK: Gatehouse

        // A solid block bored through by a passage, the way a real
        // barbican is masonry with a tunnel in it rather than a room —
        // simpler to build than a hollow shell and no less a landmark for
        // it, since the tunnel itself is exactly where a person walks in.
        // Standing forward of the keep, this is the mass a flat building
        // would not have — something nearer the plaza than the keep's own
        // wall.
        let gateX = (originX - 6)...(originX + 6)
        let gateNearZ = originZ + 1
        let gateFarZ = originZ + 8
        let gateWallTop = floorY + 13
        fill(world, x: gateX, y: floorY...gateWallTop, z: gateNearZ...gateFarZ, .snow)

        // The passage widens near the ground and tapers above the door
        // lintel, which is as close to an arch as a helper built from
        // boxes gets — and it reads as one at this distance.
        fill(
            world,
            x: (originX - 1)...(originX + 2), y: floorY...(floorY + 1),
            z: gateNearZ...gateFarZ, .air
        )
        fill(
            world,
            x: originX...(originX + 1), y: (floorY + 2)...(floorY + 2),
            z: gateNearZ...gateFarZ, .air
        )
        world.setBlock(worldX: originX, y: floorY, worldZ: gateFarZ, to: .oakDoorLowerSouth, remesh: false)
        world.setBlock(worldX: originX + 1, y: floorY, worldZ: gateFarZ, to: .oakDoorLowerSouth, remesh: false)
        world.setBlock(worldX: originX, y: floorY + 1, worldZ: gateFarZ, to: .oakDoorUpperSouth, remesh: false)
        world.setBlock(worldX: originX + 1, y: floorY + 1, worldZ: gateFarZ, to: .oakDoorUpperSouth, remesh: false)

        crenellate(x: gateX, z: gateNearZ...gateFarZ, y: gateWallTop + 1)
        torch(world, x: originX - 2, y: floorY, z: originZ + 9)
        torch(world, x: originX + 3, y: floorY, z: originZ + 9)

        // MARK: Hall wing

        // A lower range thrown forward on the keep's west flank, sharing
        // the keep's own west wall column so the two read as one mass
        // rather than two boxes side by side. This is what turns the plan
        // from a single rectangle into an L, and it is also where the
        // tallest tower plants its foot — a real corner tower sits at the
        // junction of two ranges, not isolated on a plain wall. One block
        // wider than the tower's own radius, so the wing's square corner
        // shows past the round drum instead of being swallowed by it.
        let wingX = (originX - 13)...(originX - keepHalf)
        let wingZ = (originZ - 2)...(originZ + 6)
        let wingWallTop = floorY + 13
        walls(world, x: wingX, y: floorY...wingWallTop, z: wingZ, .snow)
        fill(
            world,
            x: (wingX.lowerBound + 1)...(wingX.upperBound - 1),
            y: (groundY + 4)...(groundY + 4),
            z: (wingZ.lowerBound + 1)...(wingZ.upperBound - 1), .planks
        )
        // A flat stone cap, deliberately plain — the wing is a subordinate
        // mass and its roof should not compete with the keep's pyramid.
        fill(world, x: wingX, y: (wingWallTop + 1)...(wingWallTop + 1), z: wingZ, .stone)

        // Windows only on the outward (west) face: the east face backs
        // onto the keep and the south corner is about to be consumed by
        // the tallest tower, so a window there would never be seen. Two
        // rows now the wall has the storeys to show for it, where one
        // used to be enough.
        for wingWindowY in [floorY + 4, floorY + 9] {
            for z in [originZ - 1, originZ + 1] {
                for dy in [0, 1] {
                    world.setBlock(worldX: wingX.lowerBound, y: wingWindowY + dy, worldZ: z, to: .glassPane, remesh: false)
                }
            }
        }
        world.setBlock(worldX: originX - 9, y: floorY, worldZ: wingZ.upperBound, to: .oakDoorLowerSouth, remesh: false)
        world.setBlock(worldX: originX - 9, y: floorY + 1, worldZ: wingZ.upperBound, to: .oakDoorUpperSouth, remesh: false)

        // MARK: Round towers

        // Three drums with cone spires, stationed clear of one another at
        // the front corners and the keep's own back corner rather than
        // huddled directly behind the keep, where the keep's own bulk
        // would hide two of the three from anyone standing in the plaza.
        // Each is a markedly different height so the roofline steps down
        // in three stages instead of repeating itself, and every spire is
        // built well past the 2.5x-radius rule of thumb so none of them
        // reads as a squat cap. Radii are unchanged from the shorter
        // design — widening a drum this narrow would blunt it — but every
        // spire was stretched hard, the tallest hardest of all, so the
        // stagger between the three widens as the building grows instead
        // of shrinking into a family of near-equal caps.
        let towers: [(x: Int, z: Int, radius: Double, drum: Int, spire: Int)] = [
            // Tallest: fused into the hall wing's forward corner. Its
            // spire alone is longer than the whole tower used to be,
            // clearing the keep's own roof by a wide margin rather than a
            // narrow one.
            (originX - 9, originZ + 5, 3.0, 26, 25),
            // Medium: against the gatehouse's east flank, peeking above
            // the walls but staying just below the keep's ridge line.
            (originX + 9, originZ + 3, 3.0, 17, 14),
            // Shortest: the keep's own back-east corner, tucked below the
            // keep's own eaves. Set a little wider than the medium tower
            // so the pair reads as two drums side by side rather than one
            // stacked behind the other.
            (originX + 11, originZ - 8, 2.5, 13, 12),
        ]
        for tower in towers {
            cylinder(
                world, centreX: tower.x, baseY: floorY, centreZ: tower.z,
                radius: tower.radius, height: tower.drum, .snow
            )
            cone(
                world, centreX: tower.x, baseY: floorY + tower.drum, centreZ: tower.z,
                radius: tower.radius, height: tower.spire, .stone
            )
        }
    }
}

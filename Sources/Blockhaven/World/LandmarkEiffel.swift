import Foundation

extension Landmarks {
    /// The Eiffel Tower: four splayed lattice legs on a power curve, a
    /// decorative arch under each face, two platforms, and a braced mast
    /// tapering to an antenna at `groundY + 120`.
    ///
    /// The whole point of the silhouette is the arch underneath it. This is
    /// a building people stand under and look up through, so the middle is
    /// left empty from the ground all the way to the second platform: a
    /// thirteen-block square on the axis is cleared outright, and both
    /// decks are rings with that same square left open down the centre.
    /// Every block of density goes into the legs and the faces instead.
    ///
    /// The density is a balance rather than a target, and it has been wrong
    /// in both directions. A thousand-block version is a wireframe of a
    /// tower. Nine thousand, with a girder ring every three courses and
    /// both faces of every leg braced at full rate, is solid brown timber
    /// with an arch cut out of it — which measures as ironwork and does not
    /// read as any. What the openness actually costs is drawn out at
    /// `legPanel` and `outwardFaces`.
    ///
    /// The build order matters and is the reverse of how it reads: frame
    /// first, stairwells last, because the last write to a cell wins and
    /// the treads have to beat the lattice that is drawn through them.
    static func eiffelTower(
        originX: Int, groundY: Int, originZ: Int, in world: World
    ) {
        EiffelTower(originX: originX, groundY: groundY, originZ: originZ, world: world)
            .build()
    }

    /// How far above its ground the tower's antenna tip lands.
    ///
    /// Published because a check that wants to say "half the tower's
    /// height" otherwise has to write 120 down a second time, and a copy
    /// tracks nothing: shorten the spire to eighty and the copy goes on
    /// demanding a climb of sixty the tower can no longer offer.
    ///
    /// It is also what makes the spire's own two blocks of clearance under
    /// `ceiling` safe to leave. `setBlock` drops anything above the ceiling
    /// without a word, so a decapitated tower looks exactly like a short
    /// one; knowing the height it *meant* to reach is what lets that fail
    /// out loud instead.
    static let eiffelHeight = EiffelTower.spikeTop

    /// Half-width of the square cleared straight up the tower's axis, so
    /// the arch under it is something you can walk into and look up.
    ///
    /// Published so the check can ask about the hole the builder actually
    /// cleared rather than about the one column everybody agrees on. The
    /// axis is the least interesting sample of an open middle — it is where
    /// nothing is ever built — and a member drifting two blocks off it
    /// would leave a centreline measurement completely untouched.
    static let eiffelWell = EiffelTower.wellHalf

    /// The six staircases, in world coordinates: for each, the cells the
    /// climb goes through in the order it goes through them — every tread,
    /// and the decked cell the flight steps out onto at the top.
    ///
    /// Published for the same reason. A walk that floods upward and finds
    /// itself high in the air has not shown that the *staircases* carry
    /// anybody — a brace lattice of shallow enough diagonals would do it
    /// too — so the claim worth making is that these particular cells were
    /// walked, and only the builder knows which they are.
    ///
    /// The arrivals are in the list because the treads alone cannot say
    /// where a flight ends up. "The top tread is sixty blocks up" is one
    /// builder's number checked against another builder's number; "the top
    /// tread steps out onto this cell, and this cell is decked platform"
    /// is the claim that was wanted, and it fails the day a flight stops
    /// short of the deck it was aimed at.
    ///
    /// Grouped by flight and kept in order, rather than handed over as one
    /// bag of cells, because the check walks these with the player's own
    /// body and a body has to be steered. An unordered set can only be
    /// asked "is each of these reachable somehow"; a route can be asked the
    /// question that matters, which is whether you can get from each cell
    /// to the next one.
    ///
    /// Every rise along a route is half a block — one stair tread onto the
    /// next, and at the top the step off onto the planking. None of it
    /// leans on a walk being willing to step up a whole block, which
    /// `PlayerController` refuses.
    static func eiffelFlights(
        originX: Int, groundY: Int, originZ: Int
    ) -> [[(x: Int, y: Int, z: Int)]] {
        EiffelTower.flightPlan().map { flight in
            (flight.treads + [flight.arrival]).map { cell in
                (x: originX + cell.dx, y: groundY + cell.yRel, z: originZ + cell.dz)
            }
        }
    }
}

/// The Eiffel Tower's ironwork, kept in its own type because it is the one
/// landmark whose parts have to agree with each other: the arches spring off
/// the leg curve, the platforms are sized off where the legs have got to by
/// that height, and the staircases drift inward at the rate the legs
/// converge. A dozen loose helpers all passing the same curve around would
/// be the same code with the agreement left implicit.
///
/// Everything structural is `.log` — the palette has no wrought iron, and
/// brown-grey timber reads closer to riveted ironwork at voxel scale than
/// `.stone`, which flattens the whole thing into a chimney. `.planks`
/// appears only on decking, so the two stages stand out as datum lines
/// rather than disappearing into the taper.
private struct EiffelTower {
    let originX: Int
    let groundY: Int
    let originZ: Int
    let world: World

    private let iron = BlockType.log

    // MARK: - Proportions

    // Heights above `groundY`, as fractions of the 120 the spire reaches:
    // the platforms land at 25% and 58%, against the real tower's 18% and
    // 36%.
    //
    // The second one cannot be moved down to where the real tower's is, and
    // the reason is the climb rather than the look: the stairs stop at the
    // second platform, as the real tower's do, and the demo check asks that
    // they carry somebody half the tower's height. A platform at 36% would
    // put the top of the stairs at 43 blocks of 120 and the tower would go
    // back to being a thing you look at. The first one is as low as the arch
    // under it can live with — its crown wants clear air above it, or the
    // curve reads as a lintel — and is the one that was moved: at 34 it made
    // a bottom-heavy tower with a stubby waist.
    private static let firstDeck = 30
    private static let secondDeck = 70
    private static let mastTop = 110
    private static let summitDeck = 100
    /// Shared with `Landmarks.eiffelHeight`, which is the one number about
    /// this tower anything outside the file is allowed to know.
    fileprivate static let spikeTop = 120

    // Offsets from the axis. Twenty-two blocks across the base against a
    // hundred and twenty tall is the real tower's 125 m by 330 m, and the
    // railway runs four blocks past the east edge, so it is also the most
    // the site has room for.
    private static let baseOuter = 22.0
    private static let secondOuter = 6.0
    private static let firstDeckEdge = 15
    private static let firstDeckWell = 7
    /// Half the open square under the tower, which is the first deck's own
    /// well: the view up the middle is one shaft from the paving to the
    /// sky rather than two that happen to line up.
    fileprivate static let wellHalf = firstDeckWell - 1
    private static let secondDeckEdge = 8
    private static let secondDeckWell = 3

    /// Courses between one X-braced panel and the next.
    ///
    /// Two big X's per stage read as a wireframe from any distance where
    /// the tower is worth looking at; a panel every six, with a solid
    /// girder ring at each end of it, read as solid brown timber, which is
    /// the other way to get it wrong and the harder one to see coming. A
    /// voxel member is a whole block wide however thin the ironwork it
    /// stands for, so density here costs far more of the see-through than
    /// the arithmetic suggests.
    private static let legPanel = 8
    private static let mastPanel = 4

    /// Where the arch springs off the legs and where its crown sits, well
    /// clear of the first deck so the curve is a curve and not a lintel.
    private static let archSpring = 9
    private static let archCrown = 25
    private static let archHalfSpan = 11.0

    /// Each leg stands on one diagonal corner of the square base.
    private static let corners: [(sx: Int, sz: Int)] = [(1, 1), (1, -1), (-1, 1), (-1, -1)]

    /// The four faces of a leg, as pairs of indices into `legPosts`, split
    /// by which way they look.
    ///
    /// The outward pair carry the silhouette and are braced at every
    /// panel. The inward pair are braced at every other one, and that is
    /// the single biggest thing keeping the legs see-through: from outside
    /// you look through a leg's outward face and its inward face at once,
    /// so bracing both at full rate squares the density and the whole leg
    /// goes over to solid brown. Ironwork is mostly holes.
    private static let outwardFaces = [(2, 3), (1, 3)]
    private static let inwardFaces = [(0, 1), (0, 2)]

    /// The four faces of the mast, as pairs of indices into `corners` that
    /// are neighbours round the square rather than across the diagonal.
    private static let mastFacePairs = [(0, 1), (1, 3), (3, 2), (2, 0)]

    // MARK: - Building

    func build() {
        pave()
        legs()
        waist()
        arches()
        platform(deckY: Self.firstDeck, edge: Self.firstDeckEdge,
                 well: Self.firstDeckWell, skirt: 4)
        platform(deckY: Self.secondDeck, edge: Self.secondDeckEdge,
                 well: Self.secondDeckWell, skirt: 3)
        mast()
        well()
        stairs()
    }

    /// The volume the tower exists to be stood in.
    ///
    /// A guarantee, not a decoration. What gets measured is one column
    /// straight up the centreline, and a single column can stay clear
    /// while the space around it silts up with bracing — so the last word
    /// on the space under the arch is this: a thirteen-block square on the
    /// axis, empty from the paving to the first platform, which is the
    /// same square the platform leaves open above it. Anything a member
    /// wanders into here loses to it.
    ///
    /// Which turns the one measured column into a volume. The worst of the
    /// 169 columns in that square is clear for 42 blocks, against the 25
    /// the check asks of the one on the axis, so a person standing
    /// anywhere under the tower — not only on its exact centreline — is
    /// looking up at sky.
    private func well() {
        for yRel in 1..<Self.firstDeck {
            for dz in -Self.wellHalf...Self.wellHalf {
                for dx in -Self.wellHalf...Self.wellHalf {
                    place((dx, dz), yRel, .air)
                }
            }
        }
    }

    // MARK: - The leg curve

    /// How far a leg's outer face stands from the axis at a height.
    ///
    /// A power curve rather than a straight taper: the real legs bend
    /// hardest just off the ground and are nearly upright by the second
    /// platform, and a straight line between the same two points reads as
    /// an electricity pylon.
    private func legOuter(_ yRel: Int) -> Double {
        let clamped = min(max(yRel, 0), Self.secondDeck)
        let t = 1 - Double(clamped) / Double(Self.secondDeck)
        return Self.secondOuter + (Self.baseOuter - Self.secondOuter) * pow(t, 1.2)
    }

    /// How deep a leg is from its inner face to its outer one. It thins as
    /// it climbs, which is what keeps the four legs from meeting in a lump
    /// where they converge.
    private func legDepth(_ yRel: Int) -> Double {
        if yRel <= Self.firstDeck {
            return 8 - 3 * Double(min(max(yRel, 0), Self.firstDeck)) / Double(Self.firstDeck)
        }
        let above = Double(min(yRel, Self.secondDeck) - Self.firstDeck)
        return 5 - above / Double(Self.secondDeck - Self.firstDeck)
    }

    /// The two faces of a leg, as unsigned offsets from the axis.
    private func legSpan(_ yRel: Int) -> (inner: Int, outer: Int) {
        let outer = legOuter(yRel)
        return (Int((outer - legDepth(yRel)).rounded()), Int(outer.rounded()))
    }

    /// The four corner posts of one leg at one height, as signed offsets:
    /// inner-inner, inner-outer, outer-inner, outer-outer.
    private func legPosts(_ yRel: Int, _ corner: (sx: Int, sz: Int)) -> [(dx: Int, dz: Int)] {
        let span = legSpan(yRel)
        return [
            (corner.sx * span.inner, corner.sz * span.inner),
            (corner.sx * span.inner, corner.sz * span.outer),
            (corner.sx * span.outer, corner.sz * span.inner),
            (corner.sx * span.outer, corner.sz * span.outer),
        ]
    }

    /// Half-width of the mast above the second platform, carrying the leg
    /// curve on in one continuous taper to a three-block square at the top.
    private func mastHalf(_ yRel: Int) -> Int {
        let clamped = min(max(yRel, Self.secondDeck), Self.mastTop)
        let t = Double(Self.mastTop - clamped) / Double(Self.mastTop - Self.secondDeck)
        return max(1, Int((1 + (Self.secondOuter - 1) * pow(t, 0.9)).rounded()))
    }

    // MARK: - Ground

    private func pave() {
        // Repaves the standing ground rather than adding a floor: the point
        // of the base is the open arch, and a deck here would wall it in.
        Landmarks.disc(
            world, centreX: originX, y: groundY, centreZ: originZ,
            radius: 21, .cobblestone
        )
        // A lamp between each pair of feet, because the one thing worth
        // doing under this tower is standing there after dark.
        for (dx, dz) in [(19, 0), (-19, 0), (0, 19), (0, -19)] {
            Landmarks.torch(world, x: originX + dx, y: groundY + 1, z: originZ + dz)
        }
    }

    // MARK: - Legs

    /// The four legs, each a hollow square shaft of four corner posts, with
    /// X-braced lattice on its faces — the outward pair every panel, the
    /// inward pair every other one — a girder belt at each panel joint and
    /// a dashed one between. Nothing here is a single line: a leg drawn as
    /// one diagonal per corner is a sketch of a leg.
    private func legs() {
        for corner in Self.corners {
            // Posts, sampled every second course and joined, so the curve
            // comes out connected rather than as a dotted diagonal where
            // the profile shifts a block.
            for base in stride(from: 0, to: Self.secondDeck, by: 2) {
                let top = min(base + 2, Self.secondDeck)
                let lower = legPosts(base, corner)
                let upper = legPosts(top, corner)
                for index in lower.indices {
                    Landmarks.line(
                        world,
                        from: point(lower[index], base),
                        to: point(upper[index], top),
                        iron
                    )
                }
            }

            for base in stride(from: 0, to: Self.secondDeck, by: Self.legPanel) {
                let top = min(base + Self.legPanel, Self.secondDeck)
                let lower = legPosts(base, corner)
                let upper = legPosts(top, corner)
                let panel = base / Self.legPanel
                let faces = panel % 2 == 0
                    ? Self.outwardFaces + Self.inwardFaces : Self.outwardFaces
                for face in faces {
                    Landmarks.line(
                        world,
                        from: point(lower[face.0], base), to: point(upper[face.1], top),
                        iron
                    )
                    Landmarks.line(
                        world,
                        from: point(lower[face.1], base), to: point(upper[face.0], top),
                        iron
                    )
                }
                belt(at: base, corner, dashed: false)
                // And one more where the X crosses itself, which is where
                // the real tower puts a horizontal too. Half the girders in
                // this thing are the ones nobody would think to draw.
                belt(at: base + Self.legPanel / 2, corner, dashed: true)
            }
            belt(at: Self.secondDeck, corner, dashed: false)
        }
    }

    /// A horizontal girder ringing one leg, tying its four faces together
    /// where one panel of bracing hands over to the next.
    ///
    /// The mid-panel one is dashed — every other cell — because a solid
    /// ring every few courses is what banded the legs into a stack of brown
    /// boxes. Dashed it still reads as a line round the leg from the plaza,
    /// and lets the lattice behind it read at all.
    private func belt(at yRel: Int, _ corner: (sx: Int, sz: Int), dashed: Bool) {
        let span = legSpan(yRel)
        for dz in span.inner...span.outer {
            for dx in span.inner...span.outer {
                let onEdge = dx == span.inner || dx == span.outer
                    || dz == span.inner || dz == span.outer
                guard onEdge, !dashed || (dx + dz) % 2 == 0 else { continue }
                place((corner.sx * dx, corner.sz * dz), yRel, iron)
            }
        }
    }

    /// The lattice between the legs, above the first platform.
    ///
    /// The real tower stops being four legs at the first platform: from
    /// there up to the second it is one tapering trunk, latticed across
    /// all four sides, and four separate legs climbing past each other
    /// instead read as a pylon whatever curve they are on. It goes on the
    /// tower's own outer faces and nowhere near the middle, so the view up
    /// the centre survives it.
    private func waist() {
        for base in stride(from: Self.firstDeck, to: Self.secondDeck, by: Self.legPanel) {
            let top = min(base + Self.legPanel, Self.secondDeck)
            let low = legSpan(base), high = legSpan(top)
            for sign in [1, -1] {
                for alongZ in [true, false] {
                    for (from, to) in [(low.inner, -high.inner), (-low.inner, high.inner)] {
                        Landmarks.line(
                            world,
                            from: point(across(alongZ, plane: sign * low.outer, span: from), base),
                            to: point(across(alongZ, plane: sign * high.outer, span: to), top),
                            iron
                        )
                    }
                    // The horizontal that closes the panel, which is what
                    // makes the four legs read as one trunk rather than as
                    // four legs with bracing hung between them.
                    Landmarks.line(
                        world,
                        from: point(across(alongZ, plane: sign * high.outer, span: -high.inner), top),
                        to: point(across(alongZ, plane: sign * high.outer, span: high.inner), top),
                        iron
                    )
                }
            }
        }
    }

    // MARK: - Arches

    /// The arch under each face, between one pair of legs.
    ///
    /// It is the tower's most recognisable feature and the one thing a
    /// lattice of straight members cannot imply, so it is built as a real
    /// curved girder: two arcs on the leg's own face planes, ribs across
    /// the depth between them, and hangers filling the spandrel up to the
    /// underside of the first platform.
    private func arches() {
        for sign in [1, -1] {
            arch(alongZ: true, sign: sign)
            arch(alongZ: false, sign: sign)
        }
    }

    private func arch(alongZ: Bool, sign: Int) {
        let hangerTop = Self.firstDeck - 3
        let hangerSpan = legSpan(hangerTop)
        let rise = Double(Self.archCrown - Self.archSpring)

        for u in -18...18 {
            let drop = rise * pow(Double(u) / Self.archHalfSpan, 2)
            let y = Self.archCrown - Int(drop.rounded())
            // Stops where the curve runs into the leg it springs from,
            // rather than at a fixed span: the legs lean, so where that is
            // depends on how far up the arc has got.
            guard y >= Self.archSpring else { continue }
            let leg = legSpan(y)
            guard abs(u) <= leg.inner + 1 else { continue }

            for plane in [leg.inner, leg.outer] {
                let cell = across(alongZ, plane: sign * plane, span: u)
                place(cell, y, iron)
                place(cell, y - 1, iron)
            }
            if u % 3 == 0 {
                Landmarks.line(
                    world,
                    from: point(across(alongZ, plane: sign * leg.inner, span: u), y),
                    to: point(across(alongZ, plane: sign * leg.outer, span: u), y),
                    iron
                )
            }

            // Filigree between the crown and the deck above it. Kept to the
            // shallow middle of the span — out near the springing the gap
            // is twenty blocks deep and a row of hangers that long reads as
            // a palisade rather than as ironwork.
            guard abs(u) <= 8, u % 2 == 0 else { continue }
            for (plane, above) in [
                (leg.inner, hangerSpan.inner), (leg.outer, hangerSpan.outer),
            ] {
                Landmarks.line(
                    world,
                    from: point(across(alongZ, plane: sign * plane, span: u), y + 1),
                    to: point(across(alongZ, plane: sign * above, span: u), hangerTop),
                    iron
                )
            }
        }
    }

    // MARK: - Platforms

    /// One platform: a ring deck, an edge girder, the X-braced band that
    /// carries it, a skirt of raking struts down onto a girder ring below,
    /// and a railing on posts.
    ///
    /// A ring rather than a slab. A filled deck is the cheapest way there
    /// is to add a thousand blocks, and it would put a ceiling over the one
    /// view the tower exists for.
    private func platform(deckY: Int, edge: Int, well: Int, skirt: Int) {
        for dz in -edge...edge {
            for dx in -edge...edge where max(abs(dx), abs(dz)) >= well {
                place((dx, dz), deckY, .planks)
            }
        }

        let rim = Self.squareRing(edge)
        let bandBottom = deckY - 3
        for (index, cell) in rim.enumerated() {
            place(cell, deckY - 1, iron)
            place(cell, bandBottom, iron)
            place(cell, deckY + 2, iron)
            if index % 3 == 0 { place(cell, deckY + 1, iron) }

            guard index % 4 == 0 else { continue }
            let far = rim[(index + 4) % rim.count]
            Landmarks.line(
                world, from: point(cell, bandBottom), to: point(far, deckY - 1), iron
            )
            Landmarks.line(
                world, from: point(far, bandBottom), to: point(cell, deckY - 1), iron
            )
            let foot = Self.pulledIn(cell, by: skirt, from: edge)
            Landmarks.line(
                world, from: point(cell, bandBottom), to: point(foot, bandBottom - skirt), iron
            )
        }

        for cell in Self.squareRing(edge - skirt) {
            place(cell, bandBottom - skirt, iron)
        }
        for cell in [(edge, edge), (edge, -edge), (-edge, edge), (-edge, -edge),
                     (edge, 0), (-edge, 0), (0, edge), (0, -edge)] {
            Landmarks.torch(
                world, x: originX + cell.0, y: groundY + deckY + 3, z: originZ + cell.1
            )
        }
    }

    // MARK: - Mast

    /// The mast: the leg curve carried on as a single tapering box, braced
    /// on all four faces and collared at every joint. Four bare parallel
    /// lines up here read as a tuning fork, not an antenna mast.
    private func mast() {
        for base in stride(from: Self.secondDeck, to: Self.mastTop, by: 2) {
            let top = min(base + 2, Self.mastTop)
            let lower = mastHalf(base), upper = mastHalf(top)
            for corner in Self.corners {
                Landmarks.line(
                    world,
                    from: point((corner.sx * lower, corner.sz * lower), base),
                    to: point((corner.sx * upper, corner.sz * upper), top),
                    iron
                )
            }
        }

        for base in stride(from: Self.secondDeck, to: Self.mastTop, by: Self.mastPanel) {
            let top = min(base + Self.mastPanel, Self.mastTop)
            let lower = mastHalf(base), upper = mastHalf(top)
            for face in Self.mastFacePairs {
                let a = Self.corners[face.0], b = Self.corners[face.1]
                Landmarks.line(
                    world,
                    from: point((a.sx * lower, a.sz * lower), base),
                    to: point((b.sx * upper, b.sz * upper), top),
                    iron
                )
                Landmarks.line(
                    world,
                    from: point((b.sx * lower, b.sz * lower), base),
                    to: point((a.sx * upper, a.sz * upper), top),
                    iron
                )
            }
            Landmarks.walls(
                world,
                x: (originX - lower)...(originX + lower),
                y: (groundY + base)...(groundY + base),
                z: (originZ - lower)...(originZ + lower),
                iron
            )
        }

        summit()
        Landmarks.line(
            world,
            from: point((0, 0), Self.mastTop), to: point((0, 0), Self.spikeTop),
            iron
        )
    }

    /// The little deck at the top, where the real tower has Eiffel's own
    /// apartment. It is four blocks of decking and a rail, and it is what
    /// stops the last thirty blocks reading as a stick.
    private func summit() {
        let half = mastHalf(Self.summitDeck)
        let x = (originX - half)...(originX + half)
        let z = (originZ - half)...(originZ + half)
        let deck = groundY + Self.summitDeck
        Landmarks.fill(world, x: x, y: deck...deck, z: z, .planks)
        Landmarks.walls(world, x: x, y: (deck + 2)...(deck + 2), z: z, iron)
        for corner in Self.corners {
            Landmarks.torch(
                world,
                x: originX + corner.sx * half, y: deck + 1, z: originZ + corner.sz * half
            )
        }
    }

    // MARK: - Stairs

    /// One lap of a stair spiral, as offsets from the lap's origin.
    ///
    /// Six treads to a lap, and the seventh is the next lap's origin one
    /// block in on both axes — so the spiral drifts inward at a block every
    /// six courses, which is very nearly the rate the legs converge at.
    /// That is what lets a staircase live inside a leg that leans: a
    /// straight vertical shaft would be out through the wall by half way.
    ///
    /// Consecutive treads are orthogonally adjacent and rise exactly one
    /// block, including across the lap boundary, because a diagonal gap is
    /// not something a player can walk up. No cell is used twice inside
    /// four courses, and the six-tread lap is what makes that true: the
    /// clearance a body needs over a tread is exactly `treadCourses`, so a
    /// five-tread lap would put the next turn's stair through the head of
    /// the climber below it.
    private static let lapPattern: [(dx: Int, dz: Int)] = [
        (0, 0), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0),
    ]

    /// One staircase: the treads it lays, and the cell on the deck above
    /// that its top tread steps out onto.
    fileprivate struct Flight {
        let treads: [(dx: Int, dz: Int, yRel: Int)]
        /// Where the climb finishes — standing on the platform, one course
        /// above the planking it stands on.
        let arrival: (dx: Int, dz: Int, yRel: Int)
    }

    /// Where every flight goes: four staircases from the ground to the
    /// first platform and two on to the second, as the real tower has —
    /// and nothing above the second, which is lifts only up there too.
    ///
    /// Pure arithmetic, and separated from the building for that reason.
    /// `Landmarks.eiffelTreads` hands this same list to the demo check, so
    /// what the check walks up is the list the builder puts down rather
    /// than a second description of it that could drift.
    fileprivate static func flightPlan() -> [Flight] {
        var flights: [Flight] = []
        for corner in corners {
            flights.append(
                flight(startDX: 16, startDZ: 16, from: 1, to: firstDeck, corner: corner)
            )
        }
        for corner in [corners[0], corners[3]] {
            flights.append(
                flight(startDX: 11, startDZ: 8, from: firstDeck + 1, to: secondDeck,
                       corner: corner)
            )
        }
        return flights
    }

    private func stairs() {
        let flights = Self.flightPlan()
        for corner in Self.corners { doorways(corner) }

        // Carved first and laid afterwards, in three passes over all six
        // flights rather than one pass per flight. The lattice, the belts
        // and the decking are all drawn through these cells, and a tread
        // with a girder in the block above it is a tread nobody can stand
        // on — which is exactly how a tower ends up looking climbable and
        // measuring as a dead end. Three passes because one flight's
        // landing would otherwise be planked into the next flight's
        // headroom, the two in a leg passing within a few blocks of each
        // other at the first platform.
        for flight in flights {
            for cell in Self.walkway(flight) { place((cell.dx, cell.dz), cell.yRel, .air) }
        }
        for flight in flights { landing(flight) }
        for flight in flights { lay(flight.treads) }
    }

    /// A staircase from `startY` up to the deck at `deckY`, one tread a
    /// course, in the leg picked out by `corner`. Offsets are worked out
    /// for the corner nearest +x +z and then mirrored, so all four legs get
    /// the same staircase and the mirrored pair simply wind the other way.
    ///
    /// Given the height it has to arrive at rather than a number of treads.
    /// "Thirty treads" and "the first platform" are the same thing only for
    /// as long as nobody moves the platform, and a flight that quietly
    /// stopped short of the deck would still be declared, still be walked,
    /// and still be counted as having got there.
    private static func flight(
        startDX: Int, startDZ: Int, from startY: Int, to deckY: Int, corner: (sx: Int, sz: Int)
    ) -> Flight {
        let treads = (startY...deckY).enumerated().map { index, yRel in
            let lap = index / lapPattern.count
            let step = lapPattern[index % lapPattern.count]
            return (
                dx: corner.sx * (startDX - lap + step.dx),
                dz: corner.sz * (startDZ - lap + step.dz),
                yRel: yRel
            )
        }
        // The last tread is level with the deck, so stepping off it is a
        // half-block rise onto the planking in front of it — the same step
        // as every other tread of the flight, and the one step a player is
        // certain to be able to make.
        let top = treads[treads.count - 1]
        let out = travel(treads, at: treads.count - 1)
        return Flight(
            treads: treads,
            arrival: (dx: top.dx + out.dx, dz: top.dz + out.dz, yRel: deckY + 1)
        )
    }

    /// Which way you are walking as you leave a tread: toward the next one,
    /// and for the top tread the way you came, having nowhere else to
    /// point.
    private static func travel(
        _ treads: [(dx: Int, dz: Int, yRel: Int)], at index: Int
    ) -> (dx: Int, dz: Int) {
        let here = treads[index]
        guard index + 1 < treads.count else {
            let behind = treads[max(index - 1, 0)]
            return (here.dx - behind.dx, here.dz - behind.dz)
        }
        let ahead = treads[index + 1]
        return (ahead.dx - here.dx, ahead.dz - here.dz)
    }

    /// How many courses of a column a body needs over a floor it walks on.
    ///
    /// Not two. `PlayerController.stepUp` lifts the whole body by
    /// `stepHeight` before it moves, so every stride wants that much over
    /// its head as well as `standingHeight` — and starting from a tread's
    /// low half puts the feet half a block up before any of it. Three.
    private static let bodyCourses = Int(
        (0.5 + PlayerController.stepHeight + PlayerController.standingHeight).rounded(.up)
    )

    /// And how many the three columns around a tread need, which is one
    /// more.
    ///
    /// A staircase is climbed in two half-block steps a tread — up onto
    /// the tread's own top step, and up again onto the next tread's low
    /// one — so the body spends part of every tread standing a whole block
    /// above it and is then lifted again from there. Three courses leaves
    /// the head jammed under a girder on the second of those steps, at
    /// every single tread, which is invisible from everywhere except
    /// inside a body. Measured, not reasoned: dropping the two columns
    /// beside a tread to three courses strands both second-stage flights
    /// at their second tread.
    private static let treadCourses = Int(
        (1 + PlayerController.stepHeight + PlayerController.standingHeight).rounded(.up)
    )

    /// Every cell a body climbing this flight has to pass through — which
    /// is emphatically not the same as the cells the treads are in.
    ///
    /// A player is `2 * halfWidth` wide and a stair's low half is half a
    /// block deep, so standing on a tread without fouling its own top step
    /// leaves a tenth of a block hanging over the cell behind, for the
    /// whole height of the body. Inside a leg that cell is full of posts,
    /// bracing and girder belts. Clear only the tread's own column and
    /// every tread is standable by something with no width and reachable
    /// by nobody — a staircase that measures as climbable and cannot be
    /// climbed.
    ///
    /// So three columns a tread: its own, the one behind it as it is left,
    /// and the one behind the tread above. On a straight run those last
    /// two are the same cell; at a turn the second is the corner on the
    /// outside of the turn, which is where the body has to swing to line
    /// itself up with the next tread's step.
    private static func walkway(_ flight: Flight) -> [(dx: Int, dz: Int, yRel: Int)] {
        var cells: [(dx: Int, dz: Int, yRel: Int)] = []
        for index in flight.treads.indices {
            let tread = flight.treads[index]
            let out = travel(flight.treads, at: index)
            let next = travel(flight.treads, at: min(index + 1, flight.treads.count - 1))
            for column in [
                (tread.dx, tread.dz),
                (tread.dx - out.dx, tread.dz - out.dz),
                (tread.dx - next.dx, tread.dz - next.dz),
            ] {
                for lift in 0..<treadCourses {
                    cells.append((column.0, column.1, tread.yRel + lift))
                }
            }
        }
        // The arrival stands on a whole block rather than on a half one,
        // so it needs no room behind it — only its own head height.
        for lift in 0..<bodyCourses {
            cells.append((flight.arrival.dx, flight.arrival.dz, flight.arrival.yRel + lift))
        }
        return cells
    }

    /// Puts the treads down, each turned the way you are walking as you
    /// leave it.
    private func lay(_ treads: [(dx: Int, dz: Int, yRel: Int)]) {
        for index in treads.indices {
            let step = Self.travel(treads, at: index)
            let facing: BlockFacing
            if step.dx > 0 { facing = .east }
            else if step.dx < 0 { facing = .west }
            else if step.dz > 0 { facing = .south }
            else { facing = .north }
            let tread = treads[index]
            place((tread.dx, tread.dz), tread.yRel, .oakStairs(facing))
        }
    }

    /// Decks the cell a flight steps out onto.
    ///
    /// The deck it arrives at is a ring of planking with the stairwell
    /// carved back out of it, and the arrival is the cell in front of the
    /// top tread — outside that hole, so it is still planked, and one
    /// half-block step up from the tread. Planked here explicitly all the
    /// same: it is the cell the tower's climb *claims* to reach, and a
    /// claim that depends on the platform happening to extend this far is
    /// a claim that goes quiet the day it does not.
    private func landing(_ flight: Flight) {
        let cell = (flight.arrival.dx, flight.arrival.dz)
        place(cell, flight.arrival.yRel - 1, .planks)
        for lift in 0..<Self.bodyCourses {
            place(cell, flight.arrival.yRel + lift, .air)
        }
    }

    /// The two ways into a leg: one at its foot, and one where it passes up
    /// through the first platform.
    ///
    /// A leg is a closed box of lattice with a girder belt round it every
    /// few courses, so without these it is sealed at both ends — a
    /// staircase nobody can walk into is scenery, and the belt that lands
    /// two courses above the first deck otherwise turns the whole of the
    /// platform inside the leg into a room with no door.
    ///
    /// Both are `bodyCourses` high, which is a course more than a body
    /// standing still needs. The extra course is the one `stepUp` lifts
    /// into on the last stride of the corridor, mounting the first tread
    /// of the flight beyond it: two courses is a doorway you can stand in
    /// and cannot leave by the stairs.
    private func doorways(_ corner: (sx: Int, sz: Int)) {
        let headroom = Self.bodyCourses
        carve(corner, x: 11...16, z: 15...17, y: 1...headroom)
        let span = legSpan(Self.firstDeck + 2)
        carve(
            corner,
            x: (span.inner - 1)...(span.outer + 1), z: 9...11,
            y: (Self.firstDeck + 1)...(Self.firstDeck + headroom)
        )
    }

    /// Empties a box given in one leg's own unsigned offsets.
    private func carve(
        _ corner: (sx: Int, sz: Int),
        x: ClosedRange<Int>, z: ClosedRange<Int>, y: ClosedRange<Int>
    ) {
        for yRel in y {
            for dz in z {
                for dx in x {
                    place((corner.sx * dx, corner.sz * dz), yRel, .air)
                }
            }
        }
    }

    // MARK: - Cells

    private func point(_ cell: (dx: Int, dz: Int), _ yRel: Int) -> (x: Int, y: Int, z: Int) {
        (originX + cell.dx, groundY + yRel, originZ + cell.dz)
    }

    private func place(_ cell: (dx: Int, dz: Int), _ yRel: Int, _ block: BlockType) {
        let y = groundY + yRel
        guard y >= 0, y <= Landmarks.ceiling else { return }
        world.setBlock(
            worldX: originX + cell.dx, y: y, worldZ: originZ + cell.dz,
            to: block, remesh: false
        )
    }

    /// An offset on a face: `plane` is the fixed axis, `span` the one the
    /// arch runs along.
    private func across(_ alongZ: Bool, plane: Int, span: Int) -> (dx: Int, dz: Int) {
        alongZ ? (plane, span) : (span, plane)
    }

    /// The cells of a square ring, in order right round the perimeter, so a
    /// zigzag drawn along it turns the corners instead of jumping them.
    private static func squareRing(_ half: Int) -> [(dx: Int, dz: Int)] {
        guard half > 0 else { return [(0, 0)] }
        var cells: [(dx: Int, dz: Int)] = []
        for dx in -half..<half { cells.append((dx, -half)) }
        for dz in -half..<half { cells.append((half, dz)) }
        for dx in stride(from: half, to: -half, by: -1) { cells.append((dx, half)) }
        for dz in stride(from: half, to: -half, by: -1) { cells.append((-half, dz)) }
        return cells
    }

    /// The same point on the perimeter, drawn in toward the axis — the foot
    /// of a raking strut under a platform edge.
    private static func pulledIn(
        _ cell: (dx: Int, dz: Int), by amount: Int, from edge: Int
    ) -> (dx: Int, dz: Int) {
        let scale = Double(edge - amount) / Double(edge)
        return (
            Int((Double(cell.dx) * scale).rounded()),
            Int((Double(cell.dz) * scale).rounded())
        )
    }
}

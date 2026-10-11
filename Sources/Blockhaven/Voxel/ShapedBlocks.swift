import Foundation

/// What a shaped block looks like: the handful of boxes it is built from,
/// which atlas tile each one's faces sample, and which of those faces are
/// seams between the boxes and so must not be drawn.
///
/// This is only the *description*. The mesher turns it into quads (see
/// `ChunkMesher.emitShaped`), because that is where the padded neighbour
/// volume, the sky-exposure sweep and the vertex buffers live.
///
/// Two boxes that share a face would otherwise draw two coincident quads
/// there and z-fight, so every seam is named in `hidden`. The one case that
/// is deliberately *not* hidden is a staircase's back half against its
/// front half: only the lower half of that face is buried, the upper half
/// is the riser you look at, and a quad half inside solid geometry costs
/// four vertices and no artefact — the depth buffer does the rest.
struct ShapedPart {
    let box: BlockBox
    let top: AtlasTile
    let bottom: AtlasTile
    let side: AtlasTile
    /// Bit per face index — see `ShapedFace` — that this part does not draw.
    let hidden: UInt8

    init(_ box: BlockBox, top: AtlasTile, bottom: AtlasTile, side: AtlasTile, hidden: UInt8 = 0) {
        self.box = box
        self.top = top
        self.bottom = bottom
        self.side = side
        self.hidden = hidden
    }

    /// The same tile on every face, which is what a door panel and a pane
    /// both want.
    init(_ box: BlockBox, all tile: AtlasTile, hidden: UInt8 = 0) {
        self.init(box, top: tile, bottom: tile, side: tile, hidden: hidden)
    }

    func tile(for kind: FaceKind) -> AtlasTile {
        switch kind {
        case .top: return top
        case .bottom: return bottom
        case .side: return side
        }
    }
}

/// Face numbering shared by the shaped geometry and the mesher's shaped
/// face table. It matches the order of `ChunkMesher`'s cube face table, so
/// the two never have to be translated between.
enum ShapedFace {
    static let up = 0, down = 1, south = 2, north = 3, east = 4, west = 5

    static func mask(_ indices: Int...) -> UInt8 {
        indices.reduce(0) { $0 | (1 << $1) }
    }
}

extension BlockFacing {
    /// Which face of a cell this direction points out of.
    var faceIndex: Int {
        switch self {
        case .north: return ShapedFace.north
        case .south: return ShapedFace.south
        case .east: return ShapedFace.east
        case .west: return ShapedFace.west
        }
    }

    var faceBit: UInt8 { UInt8(1 << faceIndex) }
}

/// Which sides a glass pane has grown an arm toward. Worked out at mesh
/// time from the four horizontal neighbours rather than stored in the cell,
/// which is what keeps a pane to a single `BlockType` case.
struct PaneConnections: OptionSet {
    let rawValue: UInt8
    static let north = PaneConnections(rawValue: 1 << 0)
    static let south = PaneConnections(rawValue: 1 << 1)
    static let east = PaneConnections(rawValue: 1 << 2)
    static let west = PaneConnections(rawValue: 1 << 3)

    static func of(_ facing: BlockFacing) -> PaneConnections {
        PaneConnections(rawValue: 1 << facing.rawValue)
    }

    func has(_ facing: BlockFacing) -> Bool { contains(PaneConnections.of(facing)) }

    /// Whether a pane grows an arm toward this neighbour.
    ///
    /// The question is "does that look like something to meet", not "does
    /// it hide the face behind it". `isOpaque` alone answers the second and
    /// gets the first wrong in both directions the moment there is anything
    /// see-through next door: glass, a door frame, a staircase and another
    /// pane's neighbours are all non-opaque, and a pane that will not reach
    /// any of them leaves a 7/16 gap you can see daylight through. `isSolid`
    /// picks all of those up; `isOpaque` stays in for leaves, which are
    /// flagged opaque as an occluder trick and are the one thing the two
    /// predicates disagree about in the other direction.
    static func connects(to neighbour: BlockType) -> Bool {
        neighbour.isSolid || neighbour.isOpaque
    }
}

enum ShapedBlocks {
    /// The boxes to draw for one shaped cell.
    ///
    /// `connections` is read only by panes; everything else ignores it.
    static func parts(for type: BlockType, connections: PaneConnections = []) -> [ShapedPart] {
        if type.isPlant { return plant(type) }
        if type == .torch { return torch() }
        if type.isRail { return rail(type) }
        if type.isStairs, let facing = type.stairFacing {
            return stairs(type, facing: facing)
        }
        if type.isDoor, let facing = type.doorFacing, let part = type.doorPart {
            return door(facing: facing, part: part, open: type.doorIsOpen)
        }
        if type.isBed, let facing = type.bedFacing, let part = type.bedPart {
            return bed(facing: facing, part: part)
        }
        if type.isPane { return pane(connections) }
        if type.isLever { return lever(type) }
        if type.isWire { return wire(type) }
        if type.isPressurePlate { return pressurePlate(type) }
        if type.isSignalTorch { return signalTorch(type) }
        if type.isSignalRelay { return signalRelay(type) }
        return []
    }

    // MARK: - Plants

    /// Half the thickness of a plant's slabs, as an inset from the middle.
    static let plantHalf: CGFloat = 1.0 / 16

    /// Two thin slabs crossed at the middle of the cell, both drawn from
    /// the plant's one mostly-transparent tile.
    ///
    /// The original draws its plants as two quads on the *diagonals*, which
    /// this cannot do: every shape in this file is an axis-aligned box, and
    /// the mesher's whole shaped path is built on that. A `+` instead of an
    /// `×` costs a rotation of forty-five degrees nobody notices on a tuft
    /// of grass, and buys the entire existing pipeline — the padded
    /// neighbour volume, the per-direction tint, the collision table —
    /// unchanged.
    ///
    /// Each slab draws only its two broad faces and its top. The four
    /// remaining faces are its *ends* — two texels wide, edge-on to the
    /// eye, and hidden behind the other slab from every bearing that could
    /// see them square. They are 40% of a plant's vertices for a sliver
    /// nothing looks at, and plants are the only block in the game that
    /// there are tens of thousands of. The top is kept: it is the same two
    /// texels, but it is what you see from directly above, which is where
    /// a player in creative flight spends their time.
    ///
    /// The two slabs cross, so there is a small column of doubled geometry
    /// in the middle of every plant. At two texels across, against
    /// alpha-cut foliage, it shows nothing — and hiding it would be wrong
    /// rather than cheap: those are the faces you see through the gap in
    /// the blades when you stand beside it.
    ///
    /// The slabs stop short of full height. A plant that reached the top of
    /// its cell would be sliced flat by the block above it whenever one was
    /// placed, and grass grown to exactly one metre reads as a hedge.
    private static func plant(_ type: BlockType) -> [ShapedPart] {
        let lo = 0.5 - plantHalf, hi = 0.5 + plantHalf
        let top: CGFloat = type == .deadBush ? 0.75 : 0.86
        let tile = type.plantTile
        return [
            ShapedPart(
                BlockBox(0, 0, lo, 1, top, hi), all: tile,
                hidden: ShapedFace.mask(ShapedFace.down, ShapedFace.east, ShapedFace.west)
            ),
            ShapedPart(
                BlockBox(lo, 0, 0, hi, top, 1), all: tile,
                hidden: ShapedFace.mask(ShapedFace.down, ShapedFace.north, ShapedFace.south)
            ),
        ]
    }

    /// Half the thickness of a torch post.
    private static let torchHalf: CGFloat = 1.0 / 16

    /// A torch: two crossed slabs like a plant, but narrow and stopping at
    /// 10/16 rather than spanning the cell.
    ///
    /// Crossed rather than a single box on purpose. A box would be a post
    /// with four flat sides, and the tile is drawn as one view of a torch
    /// seen face-on — wrapped round a box it reads as four torches stuck
    /// together. Crossed slabs show the same face-on picture from every
    /// angle, which is the trick the plants are already using and the
    /// reason a block-game torch looks right from all sides too.
    private static func torch() -> [ShapedPart] {
        let lo = 0.5 - torchHalf, hi = 0.5 + torchHalf
        let top: CGFloat = 10.0 / 16
        return [
            ShapedPart(
                BlockBox(0.5 - 4.0 / 16, 0, lo, 0.5 + 4.0 / 16, top, hi), all: .torch,
                hidden: ShapedFace.mask(ShapedFace.down, ShapedFace.east, ShapedFace.west)
            ),
            ShapedPart(
                BlockBox(lo, 0, 0.5 - 4.0 / 16, hi, top, 0.5 + 4.0 / 16), all: .torch,
                hidden: ShapedFace.mask(ShapedFace.down, ShapedFace.north, ShapedFace.south)
            ),
        ]
    }

    /// How thick a rail plate is.
    private static let railHeight: CGFloat = 1.0 / 16

    /// A rail: a plate on the floor of the cell.
    ///
    /// A flat one is a single thin box. A slope is four steps of one, each
    /// a quarter of the cell along and a quarter of a block higher, which
    /// is a staircase pretending to be a ramp — and at sixteen pixels a
    /// block, with a cart gliding smoothly up it on the real slope the
    /// physics uses, that is what a ramp looks like.
    ///
    /// The down faces are kept rather than masked: a rail can be laid on
    /// the lip of a drop and its underside is then visible from below.
    private static func rail(_ type: BlockType) -> [ShapedPart] {
        let tile: AtlasTile = type.isBooster ? .railBooster
            : type.isDetectorRail ? .railDetector
            : (type.railEnds.map(isCurve) == true ? .railCurve : .railStraight)

        guard let rise = type.railRise else {
            return [ShapedPart(BlockBox(0, 0, 0, 1, railHeight, 1), all: tile)]
        }

        // Four treads climbing toward `rise`.
        var parts: [ShapedPart] = []
        for step in 0..<4 {
            let low = CGFloat(step) / 4
            let high = low + railHeight + CGFloat(step) / 4 * 0
            let near = CGFloat(step) / 4, far = near + 0.25
            let box: BlockBox
            switch rise {
            case .north: box = BlockBox(0, low, 0.75 - near, 1, high, 1.0 - near)
            case .south: box = BlockBox(0, low, near, 1, high, far)
            case .east: box = BlockBox(near, low, 0, far, high, 1)
            case .west: box = BlockBox(0.75 - near, low, 0, 1.0 - near, high, 1)
            }
            parts.append(ShapedPart(box, all: tile))
        }
        return parts
    }

    /// True when a rail's two ends are perpendicular — a corner rather than
    /// a straight or a slope.
    private static func isCurve(_ ends: (BlockFacing, BlockFacing)) -> Bool {
        ends.0 != ends.1.opposite && ends.0 != ends.1
    }

    // MARK: - The switch and the wire it feeds
    //
    // One box each, on and off drawn from the same box with a different
    // tile — the geometry never changes, so a player reads a circuit's
    // state entirely from colour, the same language the furnace's fire
    // already speaks.

    /// A stub standing on a low base — the whole switch, one box.
    private static func lever(_ type: BlockType) -> [ShapedPart] {
        let tile: AtlasTile = type == .leverOn ? .leverOn : .leverOff
        return [ShapedPart(BlockBox(3.0 / 16, 0, 3.0 / 16, 13.0 / 16, 13.0 / 16, 13.0 / 16), all: tile)]
    }

    /// A plate on the floor of the cell, exactly the shape a flat rail is.
    private static func wire(_ type: BlockType) -> [ShapedPart] {
        let tile: AtlasTile = type == .wireOn ? .wireOn : .wireOff
        return [ShapedPart(BlockBox(0, 0, 0, 1, railHeight, 1), all: tile)]
    }

    /// Inset from the cell edge, unlike wire's flush plate — the border is
    /// what tells the two flat things on the floor apart at a glance, the
    /// same job colour does between a lever's two states. Pressed sits a
    /// hair lower than unpressed, so stepping on one reads as *give* even
    /// before the colour catches up.
    private static func pressurePlate(_ type: BlockType) -> [ShapedPart] {
        let tile: AtlasTile = type == .pressurePlateOn ? .pressurePlateOn : .pressurePlateOff
        let height: CGFloat = type == .pressurePlateOn ? railHeight * 0.5 : railHeight
        let inset: CGFloat = 1.0 / 16
        return [ShapedPart(BlockBox(inset, 0, inset, 1 - inset, height, 1 - inset), all: tile)]
    }

    /// The same crossed-slab shape `torch()` draws, standing free on the
    /// floor rather than needing a wall — it is a torch, just one the
    /// network reads and lights on its own.
    private static func signalTorch(_ type: BlockType) -> [ShapedPart] {
        let tile: AtlasTile = type == .signalTorchOn ? .signalTorchOn : .signalTorchOff
        let lo = 0.5 - torchHalf, hi = 0.5 + torchHalf
        let top: CGFloat = 10.0 / 16
        return [
            ShapedPart(
                BlockBox(0.5 - 4.0 / 16, 0, lo, 0.5 + 4.0 / 16, top, hi), all: tile,
                hidden: ShapedFace.mask(ShapedFace.down, ShapedFace.east, ShapedFace.west)
            ),
            ShapedPart(
                BlockBox(lo, 0, 0.5 - 4.0 / 16, hi, top, 0.5 + 4.0 / 16), all: tile,
                hidden: ShapedFace.mask(ShapedFace.down, ShapedFace.north, ShapedFace.south)
            ),
        ]
    }

    /// The same flat plate `wire()` draws, with a small block standing on
    /// it — the shape that says "something sits in this wire and resets
    /// it" at a glance, rather than a length that only ever carries current
    /// through unchanged.
    private static func signalRelay(_ type: BlockType) -> [ShapedPart] {
        let tile: AtlasTile = type == .signalRelayOn ? .signalRelayOn : .signalRelayOff
        let inset: CGFloat = 5.0 / 16
        return [
            ShapedPart(BlockBox(0, 0, 0, 1, railHeight, 1), all: tile),
            ShapedPart(BlockBox(inset, railHeight, inset, 1 - inset, railHeight + 4.0 / 16, 1 - inset), all: tile),
        ]
    }

    // MARK: - Stairs

    /// Two boxes rather than three: the low front half you step onto, and
    /// the full-height back half against the facing edge. The front half's
    /// face into the back one is a seam and is dropped; the back half's
    /// face into the front one is the riser, and is kept whole (its lower
    /// half simply ends up inside the front box).
    private static func stairs(_ type: BlockType, facing: BlockFacing) -> [ShapedPart] {
        let material = type.stairMaterial ?? .planks
        let top = material.tile(for: .top)
        let bottom = material.tile(for: .bottom)
        let side = material.tile(for: .side)
        return [
            ShapedPart(BlockBox.half(facing, toward: false, yMin: 0, yMax: 0.5),
                       top: top, bottom: bottom, side: side,
                       hidden: facing.faceBit),
            ShapedPart(BlockBox.half(facing, toward: true, yMin: 0, yMax: 1),
                       top: top, bottom: bottom, side: side),
        ]
    }

    // MARK: - Doors

    /// A single thin panel standing against one edge of the cell. Opening
    /// it swings the panel a quarter turn onto the neighbouring edge — the
    /// same turn every time, so closing it puts the door back where it was.
    private static func door(facing: BlockFacing, part: DoorPart, open: Bool) -> [ShapedPart] {
        let edge = open ? facing.turnedLeft : facing
        let face: AtlasTile = part == .upper ? .doorTop : .doorBottom
        return [
            ShapedPart(BlockBox.edge(edge, thickness: BlockType.doorThickness),
                       top: .planks, bottom: .planks, side: face)
        ]
    }

    // MARK: - Beds

    /// One 9/16-high box per cell, with the face into the other half of the
    /// bed dropped so the two read as one piece of furniture.
    private static func bed(facing: BlockFacing, part: BedPart) -> [ShapedPart] {
        let joint = part == .foot ? facing : facing.opposite
        return [
            ShapedPart(BlockBox(0, 0, 0, 1, BlockType.bedHeight, 1),
                       top: part == .head ? .bedPillow : .bedBlanket,
                       bottom: .planks,
                       side: .bedSide,
                       hidden: joint.faceBit)
        ]
    }

    // MARK: - Panes

    /// The arms a pane in this cell has grown, read out of the world.
    ///
    /// The mesher asks the same question of its padded neighbour volume and
    /// the player's collision test asks it here, both through
    /// `PaneConnections.connects(to:)` — so the pane you walk into is the
    /// pane you can see. A collision table indexed by raw value cannot
    /// answer this, because the answer is not in the cell.
    static func paneConnections(atX x: Int, y: Int, z: Int, world: World) -> PaneConnections {
        var connections: PaneConnections = []
        for facing in BlockFacing.allCases {
            let neighbour = world.block(worldX: x + facing.dx, y: y, worldZ: z + facing.dz)
            if PaneConnections.connects(to: neighbour) { connections.insert(.of(facing)) }
        }
        return connections
    }

    /// The boxes a pane fills, which are exactly the boxes it is drawn
    /// from. Taking them from the same description the mesher uses is what
    /// keeps a pane from stopping the player with a bar that is not there:
    /// a lone pane is a flat panel, and a pane in an east-west run has no
    /// north-south extent at all.
    static func paneBoxes(connections: PaneConnections) -> [BlockBox] {
        pane(connections).map(\.box)
    }

    /// A thin centre post plus an arm toward every neighbour a pane
    /// connects to — see `PaneConnections.connects(to:)` — so a run of
    /// panes reads as one sheet of glass and a pane against a wall, a
    /// window frame or a door meets it.
    ///
    /// An arm drops both of its end faces: the inner one is the seam with
    /// the post, and the outer one sits exactly on the cell boundary the
    /// arm was grown to meet, where either the neighbouring pane's own arm
    /// or the wall it butts against is already.
    private static func pane(_ connections: PaneConnections) -> [ShapedPart] {
        let lo = BlockType.paneHalf, hi = 1 - BlockType.paneHalf

        // A pane with nothing to hold on to is a flat panel across the cell
        // rather than a two-pixel post, which from any angle would read as
        // a stray splinter of glass.
        guard !connections.isEmpty else {
            return [ShapedPart(BlockBox(0, 0, lo, 1, 1, hi), all: .glass)]
        }

        var hiddenOnPost: UInt8 = 0
        var parts: [ShapedPart] = []
        for facing in BlockFacing.allCases where connections.has(facing) {
            hiddenOnPost |= facing.faceBit
            let arm: BlockBox
            switch facing {
            case .north: arm = BlockBox(lo, 0, 0, hi, 1, lo)
            case .south: arm = BlockBox(lo, 0, hi, hi, 1, 1)
            case .east: arm = BlockBox(hi, 0, lo, 1, 1, hi)
            case .west: arm = BlockBox(0, 0, lo, lo, 1, hi)
            }
            parts.append(
                ShapedPart(arm, all: .glass,
                           hidden: facing.faceBit | facing.opposite.faceBit)
            )
        }
        parts.insert(
            ShapedPart(BlockBox(lo, 0, lo, hi, 1, hi), all: .glass, hidden: hiddenOnPost),
            at: 0
        )
        return parts
    }
}

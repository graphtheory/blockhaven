import Foundation

extension Landmarks {
    /// The Hagia Sophia: a sandstone narthex carrying a vast grey dome on a
    /// tall drum, flanked by two lower half-domes and guarded by four
    /// slender minarets at the corners.
    ///
    /// The real building's whole trick is that nothing above the walls
    /// competes with the great dome — the half-domes step down from it,
    /// the drum is a plain collar for windows, and even the minarets are
    /// kept needle-thin so height reads as "tall and separate" rather than
    /// "another mass fighting the dome for attention". Stone (grey) is
    /// reserved for the domes alone; everything else is sandstone, so the
    /// eye finds the dome first at any distance. At this taller scale the
    /// drum does most of the added work: it is now the single tallest
    /// stretch of the building, lifting the dome clear of the roofline and
    /// giving the window ring a proper collar to sit in instead of a sliver
    /// jammed against the roof.
    static func hagiaSophia(originX: Int, groundY: Int, originZ: Int, in world: World) {
        // Footprint: a 35x35 narthex block, well inside the 24-block/axis
        // limit, leaving room for the half-domes and corner minarets to
        // reach outward without crossing it.
        let halfWidth = 17
        let bodyX = (originX - halfWidth)...(originX + halfWidth)
        let bodyZ = (originZ - halfWidth)...(originZ + halfWidth)

        let floorY = groundY + 1
        // Taller than before so the nave has real height under the dome
        // rather than being a low slab the dome merely caps.
        let wallHeight = 14
        let wallTopY = floorY + wallHeight
        let roofY = wallTopY + 1
        let drumRadius = 11.0
        // The drum absorbs most of the building's added height: it is what
        // lifts the dome clear of the roof and gives the window ring room
        // to breathe instead of being crammed against the roofline.
        let drumHeight = 14
        let drumBaseY = roofY + 1
        let drumTopY = drumBaseY + drumHeight - 1
        let domeRadius = 11.0
        let domeBaseY = drumTopY + 1

        // MARK: - Narthex body

        fill(world, x: bodyX, y: floorY...floorY, z: bodyZ, .sandstone)
        walls(world, x: bodyX, y: floorY...wallTopY, z: bodyZ, .sandstone)

        // The real building is banded in courses; two rows of brick just
        // under the roofline breaks the wall into "base" and "cornice" so
        // it doesn't read as one uninterrupted cream slab from the plaza.
        walls(world, x: bodyX, y: (wallTopY - 1)...wallTopY, z: bodyZ, .brick)

        // Roof the aisles, but punch a hole exactly the drum's width so the
        // nave stands open under the dome instead of capped by a ceiling —
        // the drum and dome pick up the opening immediately above.
        fill(world, x: bodyX, y: roofY...roofY, z: bodyZ, .sandstone)
        disc(world, centreX: originX, y: roofY, centreZ: originZ, radius: drumRadius, .air)

        // A brick roundel on the nave floor, under the centre of the dome —
        // the spot every visitor's eye is drawn to, worth marking.
        disc(world, centreX: originX, y: floorY, centreZ: originZ, radius: 3, .brick)

        // MARK: - Narthex doors, south front

        // Three doors rather than one: a single door under this much
        // sandstone reads as a slot, not an entrance.
        let doorXs = [originX - 5, originX, originX + 5]
        let doorZ = originZ + halfWidth
        for doorX in doorXs {
            world.setBlock(worldX: doorX, y: floorY, worldZ: doorZ, to: .oakDoorLowerSouth, remesh: false)
            world.setBlock(worldX: doorX, y: floorY + 1, worldZ: doorZ, to: .oakDoorUpperSouth, remesh: false)
            // The nave floor sits one block above the plaza; a stair at
            // the threshold turns that ledge into a step instead of a
            // wall to walk into.
            world.setBlock(worldX: doorX, y: floorY, worldZ: doorZ + 1, to: .cobbleStairsSouth, remesh: false)
        }

        // MARK: - Drum

        cylinder(world, centreX: originX, baseY: drumBaseY, centreZ: originZ, radius: drumRadius, height: drumHeight, .sandstone)

        // A single brick belt at the drum's midpoint echoes the wall's own
        // banding below and stops fourteen blocks of plain sandstone from
        // reading as a blank tube — it also lands right where the
        // half-domes' curve tops out, so it reads as capping them rather
        // than as an arbitrary stripe.
        let drumBeltY = drumBaseY + drumHeight / 2
        ring(world, centreX: originX, y: drumBeltY, centreZ: originZ, radius: drumRadius, .brick)

        // A ring of tall slit windows right at the dome's foot — the top
        // of the drum, immediately below where the dome springs — is the
        // most imitated feature in the building, and the thing that makes
        // the dome look like it is floating on light rather than resting
        // on wall. Sitting them at the very top (rather than low on the
        // drum, as the squatter version of this building once did) is
        // what the taller drum buys: a plain collar of plain wall below,
        // then a band of light right under the dome.
        let windowBandHeight = 4
        let windowTopY = drumTopY
        let windowBottomY = windowTopY - windowBandHeight + 1
        let windowCount = 20
        for i in 0..<windowCount {
            let angle = 2 * Double.pi * Double(i) / Double(windowCount)
            let wx = originX + Int((drumRadius * cos(angle)).rounded())
            let wz = originZ + Int((drumRadius * sin(angle)).rounded())
            for y in windowBottomY...windowTopY {
                world.setBlock(worldX: wx, y: y, worldZ: wz, to: .glassPane, remesh: false)
            }
        }

        // Torches just below the window band, so the famous underside of
        // the dome is not a black pit the moment the sun sets.
        let torchCount = 10
        for i in 0..<torchCount {
            let angle = 2 * Double.pi * (Double(i) + 0.5) / Double(torchCount)
            let tx = originX + Int((drumRadius * cos(angle)).rounded())
            let tz = originZ + Int((drumRadius * sin(angle)).rounded())
            torch(world, x: tx, y: windowBottomY - 1, z: tz)
        }

        // MARK: - The great dome

        // This is 80% of the silhouette. Everything else in this function
        // is built to stay smaller, lower, or thinner than this call.
        dome(world, centreX: originX, baseY: domeBaseY, centreZ: originZ, radius: domeRadius, .stone)

        // MARK: - Half-domes, east and west

        // A true semi-dome is a hemisphere sliced through its centre; the
        // curved half is built exactly like `dome`'s shell, and the flat
        // cut is closed with a solid tympanum wall so it reads as a lobe
        // rather than a hollow eggshell shard. Based at the drum's foot
        // and sized to clear the roofline well below the window band, it
        // steps down from the great dome without competing with it or
        // colliding with the ring of light above.
        let halfDomeRadius = 7.0
        let halfDomeOffset = 10
        let halfDomeR = Int(halfDomeRadius.rounded(.up))
        func halfDome(sign: Int) {
            let cutX = originX + halfDomeOffset * sign
            for dy in 0...halfDomeR {
                let y = drumBaseY + dy
                guard y >= 0, y <= ceiling else { continue }
                for dz in -halfDomeR...halfDomeR {
                    let flat = Double(dy * dy + dz * dz).squareRoot()
                    if flat <= halfDomeRadius {
                        world.setBlock(worldX: cutX, y: y, worldZ: originZ + dz, to: .sandstone, remesh: false)
                    }
                    for dxMag in 0...halfDomeR {
                        let distance = Double(dxMag * dxMag + dy * dy + dz * dz).squareRoot()
                        guard distance <= halfDomeRadius + 0.35, distance >= halfDomeRadius - 0.9 else { continue }
                        world.setBlock(
                            worldX: cutX + dxMag * sign, y: y, worldZ: originZ + dz,
                            to: .stone, remesh: false
                        )
                    }
                }
            }
        }
        halfDome(sign: 1)
        halfDome(sign: -1)

        // MARK: - Minarets

        // Kept to a radius of under 2: anything fatter reads as a
        // chimney standing next to a mosque, not a minaret. All the added
        // height goes into the shaft, not the girth.
        let minaretOffset = 16
        let minaretRadius = 1.75
        let minaretShaftLength = 45
        let minaretShaftTopY = floorY + minaretShaftLength
        let minaretCapHeight = 6
        // Two şerefe balconies rather than one: a single break was enough
        // to stop a 32-block shaft reading as a flagpole, but this shaft
        // is half again as long, so it gets a second one to match.
        let minaretBalconyOffsets = [15, 32]
        for xSign in [-1, 1] {
            for zSign in [-1, 1] {
                let mx = originX + xSign * minaretOffset
                let mz = originZ + zSign * minaretOffset
                cylinder(
                    world, centreX: mx, baseY: floorY, centreZ: mz,
                    radius: minaretRadius, height: minaretShaftTopY - floorY + 1, .sandstone
                )
                for balconyOffset in minaretBalconyOffsets {
                    ring(world, centreX: mx, y: floorY + balconyOffset, centreZ: mz, radius: minaretRadius + 1.0, .sandstone)
                }
                cone(world, centreX: mx, baseY: minaretShaftTopY + 1, centreZ: mz, radius: 2.0, height: minaretCapHeight, .sandstone)
                torch(world, x: mx, y: minaretShaftTopY + minaretCapHeight + 1, z: mz)
            }
        }
    }
}

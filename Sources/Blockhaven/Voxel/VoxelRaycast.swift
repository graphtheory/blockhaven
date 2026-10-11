import Foundation

struct VoxelRayHit {
    /// Integer coordinates of the block that was hit.
    let blockX: Int
    let blockY: Int
    let blockZ: Int
    /// The empty cell just before the hit — where a placed block goes.
    let placeX: Int
    let placeY: Int
    let placeZ: Int
    /// Which face was entered, as a unit normal.
    let normal: (x: Int, y: Int, z: Int)
    let block: BlockType
    let distance: CGFloat
}

enum VoxelRaycast {
    /// Amanatides & Woo 3D DDA: walks the ray one voxel boundary at a time
    /// and returns the first occupied cell within `maxDistance`. Water is
    /// transparent to picking, exactly as in the original.
    ///
    /// The test is `occupiesCell` rather than `isSolid` on purpose: an open
    /// door is passable but is still there to be aimed at, and picking by
    /// "does it stop me walking" would let the ray sail through the one
    /// block the player most needs to click on again.
    static func cast(from origin: Vector3, direction: Vector3, maxDistance: CGFloat, world: World) -> VoxelRayHit? {
        cast(from: origin, direction: direction, maxDistance: maxDistance, world: world) {
            $0.occupiesCell
        }
    }

    /// The same walk, stopping at whatever the caller counts as opaque.
    ///
    /// Sight is not picking: a mob looking for the player is stopped by a
    /// wall and not by the tall grass in front of it, where a click has to
    /// be able to land on that grass. One DDA rather than two, because two
    /// would be two places to fix the day a block starts or stops blocking
    /// the way through a cell.
    static func cast(
        from origin: Vector3, direction: Vector3, maxDistance: CGFloat, world: World,
        stoppingAt blocks: (BlockType) -> Bool
    ) -> VoxelRayHit? {
        // Test the raw vector: normalized() maps zero onto +z, so a guard on
        // the normalized components can never fire.
        guard abs(direction.x) + abs(direction.y) + abs(direction.z) > 0.0001 else { return nil }
        let d = direction.normalized()

        var x = Int(floor(origin.x)), y = Int(floor(origin.y)), z = Int(floor(origin.z))
        let stepX: Int = d.x > 0 ? 1 : (d.x < 0 ? -1 : 0)
        let stepY: Int = d.y > 0 ? 1 : (d.y < 0 ? -1 : 0)
        let stepZ: Int = d.z > 0 ? 1 : (d.z < 0 ? -1 : 0)

        func tMaxAndDelta(_ originComponent: CGFloat, _ dirComponent: CGFloat, _ cell: Int, _ step: Int) -> (CGFloat, CGFloat) {
            guard abs(dirComponent) > 0.0001 else { return (.infinity, .infinity) }
            let boundary = CGFloat(step > 0 ? cell + 1 : cell)
            return (abs((boundary - originComponent) / dirComponent), abs(1 / dirComponent))
        }

        var (tMaxX, tDeltaX) = tMaxAndDelta(origin.x, d.x, x, stepX)
        var (tMaxY, tDeltaY) = tMaxAndDelta(origin.y, d.y, y, stepY)
        var (tMaxZ, tDeltaZ) = tMaxAndDelta(origin.z, d.z, z, stepZ)

        var traveled: CGFloat = 0
        var enteredNormal = (x: 0, y: 0, z: 0)

        while traveled <= maxDistance {
            let block = world.block(worldX: x, y: y, worldZ: z)
            if blocks(block) {
                return VoxelRayHit(
                    blockX: x, blockY: y, blockZ: z,
                    placeX: x + enteredNormal.x,
                    placeY: y + enteredNormal.y,
                    placeZ: z + enteredNormal.z,
                    normal: enteredNormal,
                    block: block,
                    distance: traveled
                )
            }
            if tMaxX < tMaxY, tMaxX < tMaxZ {
                x += stepX; traveled = tMaxX; tMaxX += tDeltaX
                enteredNormal = (x: -stepX, y: 0, z: 0)
            } else if tMaxY < tMaxZ {
                y += stepY; traveled = tMaxY; tMaxY += tDeltaY
                enteredNormal = (x: 0, y: -stepY, z: 0)
            } else {
                z += stepZ; traveled = tMaxZ; tMaxZ += tDeltaZ
                enteredNormal = (x: 0, y: 0, z: -stepZ)
            }
        }
        return nil
    }
}

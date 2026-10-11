import Foundation

/// Spatial occupancy queries against voxel block cells for players, mobs, and animals.
/// Used by `SignalNetwork.updatePlates` to determine whether any living entity is
/// standing on or intersecting a pressure plate block cell.
enum OccupancyQuery {

    /// Tests whether an axis-aligned bounding box defined by `position`, `halfWidth`, and `height`
    /// overlaps the unit voxel cube at `(x, y, z)`.
    @inline(__always)
    static func overlaps(
        position: Vector3,
        halfWidth: CGFloat,
        height: CGFloat,
        blockX x: Int,
        y: Int,
        z: Int
    ) -> Bool {
        let minX = position.x - halfWidth
        let maxX = position.x + halfWidth
        let minZ = position.z - halfWidth
        let maxZ = position.z + halfWidth
        return CGFloat(x) < maxX && CGFloat(x + 1) > minX
            && CGFloat(z) < maxZ && CGFloat(z + 1) > minZ
            && CGFloat(y) < position.y + height && CGFloat(y + 1) > position.y
    }

    /// Tests whether the given block cell (e.g. pressure plate key) is occupied by the player,
    /// any hostile mob (fizzler, skeleton), or any friendly animal.
    ///
    /// Short-circuits on the first occupant found to minimize computation. Dead or exploding
    /// entities are excluded.
    static func isOccupied(
        cell: SignalNetwork.Key,
        player: PlayerController?,
        fizzlers: FizzlerManager? = nil,
        skeletons: SkeletonManager? = nil,
        animals: AnimalManager? = nil
    ) -> Bool {
        isOccupied(
            blockX: cell.x,
            y: cell.y,
            z: cell.z,
            player: player,
            fizzlers: fizzlers,
            skeletons: skeletons,
            animals: animals
        )
    }

    /// Overload taking integer coordinates (blockX, y, z) and entity managers.
    static func isOccupied(
        blockX x: Int,
        y: Int,
        z: Int,
        player: PlayerController?,
        fizzlers: FizzlerManager? = nil,
        skeletons: SkeletonManager? = nil,
        animals: AnimalManager? = nil
    ) -> Bool {
        // 1. Player check (fastest, most common case in gameplay)
        if let player, player.overlaps(blockX: x, y: y, z: z) {
            return true
        }

        // 2. Hostile fizzlers
        if let fizzlers, fizzlers.occupies(blockX: x, y: y, z: z) {
            return true
        }

        // 3. Hostile skeletons
        if let skeletons, skeletons.occupies(blockX: x, y: y, z: z) {
            return true
        }

        // 4. Passive animals
        if let animals, animals.occupies(blockX: x, y: y, z: z) {
            return true
        }

        return false
    }

    /// Overload taking a `SignalNetwork.Key` and explicit entity arrays/lists (used by headless checks).
    static func isOccupied(
        key: SignalNetwork.Key,
        player: PlayerController? = nil,
        fizzlers: [Fizzler] = [],
        skeletons: [Skeleton] = [],
        animals: [Animal] = []
    ) -> Bool {
        isOccupied(
            blockX: key.x,
            y: key.y,
            z: key.z,
            player: player,
            fizzlers: fizzlers,
            skeletons: skeletons,
            animals: animals
        )
    }

    /// Overload taking (blockX, y, z) and explicit entity arrays.
    static func isOccupied(
        blockX x: Int,
        y: Int,
        z: Int,
        player: PlayerController? = nil,
        fizzlers: [Fizzler] = [],
        skeletons: [Skeleton] = [],
        animals: [Animal] = []
    ) -> Bool {
        if let player, player.overlaps(blockX: x, y: y, z: z) {
            return true
        }
        for fizzler in fizzlers where !fizzler.isDead && !fizzler.hasExploded {
            if fizzler.overlaps(blockX: x, y: y, z: z) {
                return true
            }
        }
        for skeleton in skeletons where !skeleton.isDead {
            if skeleton.overlaps(blockX: x, y: y, z: z) {
                return true
            }
        }
        for animal in animals where !animal.isDead {
            if animal.overlaps(blockX: x, y: y, z: z) {
                return true
            }
        }
        return false
    }
}

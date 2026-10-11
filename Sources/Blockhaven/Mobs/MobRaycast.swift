import Foundation

/// One mob offered up to the raycast: an axis-aligned box standing on
/// `position`, `halfWidth` to either side in x and z and `height` tall.
///
/// Deliberately says nothing about what kind of mob it is — a fizzler and
/// a future animal are both just a box with an id, and both populations can
/// be handed to the same cast in one array.
struct MobRayTarget {
    let id: Int
    let position: Vector3
    let halfWidth: CGFloat
    let height: CGFloat
}

struct MobRayHit {
    let id: Int
    /// Distance along the ray at which it entered the box, on the same
    /// scale as `VoxelRayHit.distance` so the two can be compared.
    let distance: CGFloat
}

enum MobRaycast {
    /// Returns the nearest box the ray enters within `maxDistance`, or nil.
    ///
    /// Simulation-space, like `VoxelRaycast`: mob entities carry no
    /// collision component, so RealityKit has nothing to hit-test against
    /// and the maths has to live here.
    static func cast(
        from origin: Vector3,
        direction: Vector3,
        maxDistance: CGFloat,
        targets: [MobRayTarget]
    ) -> MobRayHit? {
        // `Vector3.normalized()` answers +z for a degenerate direction, so
        // without this a zero vector would cast a real ray down the z axis
        // and report a hit nobody aimed at. Same guard `VoxelRaycast.cast`
        // carries, tested on the direction as given.
        guard abs(direction.x) + abs(direction.y) + abs(direction.z) > 0.0001 else { return nil }

        let d = direction.normalized()
        var nearest: MobRayHit?
        for target in targets {
            guard let distance = entryDistance(
                origin: origin,
                direction: d,
                target: target,
                maxDistance: maxDistance
            ) else { continue }
            if let found = nearest, found.distance <= distance { continue }
            nearest = MobRayHit(id: target.id, distance: distance)
        }
        return nearest
    }

    /// The slab test: clip the ray against each pair of opposing faces in
    /// turn and see whether an interval survives. `direction` must already
    /// be a unit vector, so the result is a real distance.
    private static func entryDistance(
        origin: Vector3,
        direction: Vector3,
        target: MobRayTarget,
        maxDistance: CGFloat
    ) -> CGFloat? {
        let slabs = [
            (origin.x, direction.x, target.position.x - target.halfWidth, target.position.x + target.halfWidth),
            (origin.y, direction.y, target.position.y, target.position.y + target.height),
            (origin.z, direction.z, target.position.z - target.halfWidth, target.position.z + target.halfWidth),
        ]

        // Starting the near edge at zero means a ray that begins inside the
        // box hits it at distance zero rather than behind the eye.
        var near: CGFloat = 0
        var far = maxDistance

        for (start, step, low, high) in slabs {
            guard abs(step) > 0.0001 else {
                // Parallel to this pair of faces: only a miss if it starts
                // outside them, since it can never cross either one.
                guard start >= low, start <= high else { return nil }
                continue
            }
            let first = (low - start) / step
            let second = (high - start) / step
            near = max(near, min(first, second))
            far = min(far, max(first, second))
            guard near <= far else { return nil }
        }
        return near
    }
}

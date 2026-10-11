import Foundation

/// Whether a mob can actually see the player.
///
/// A fizzler used to light its fuse on distance alone, and distance goes
/// through walls. Standing inside a house with one on the other side of
/// the wall — or on the roof, where they spawn, because a roof is the
/// first solid block under the sky — was enough to set it off, and a
/// three-block crater took the wall with it. Houses were being eaten by
/// fizzlers that had never seen anybody.
///
/// So sight is a real question now, asked of the world: a ray from the
/// mob's eye to the player's, stopped by anything solid. Glass counts as
/// solid here, which is the rule a player can actually reason about —
/// they cannot see you through anything you build.
enum MobSight {
    /// Clear line from one eye to the other.
    static func canSee(from eye: Vector3, to target: Vector3, world: World) -> Bool {
        let delta = target - eye
        let distance = delta.length()
        guard distance > 0.001 else { return true }
        // Plants and water do not block sight; anything you can stand on
        // or walk into does.
        guard let hit = VoxelRaycast.cast(
            from: eye, direction: delta, maxDistance: distance, world: world,
            stoppingAt: { $0.isSolid }
        ) else { return true }
        // A wall *behind* the player is not a wall between: the DDA reports
        // the first solid cell along the ray, and only one closer than the
        // target is in the way.
        return hit.distance >= distance - 0.001
    }
}

import Foundation

/// Where a compass needle points, and how far it is — pulled out of
/// `GameViewController` the same way `BucketInteraction` was, so the
/// bearing math can be proven without a window.
///
/// Exploring anywhere without a bed nearby to sleep in is a one-way trip in
/// this game already: the only way back is retracing every turn from
/// memory. A compass doesn't change what's out there to find — it changes
/// whether finding it is worth the risk of not finding the way back.
enum Compass {
    /// Radians, screen-relative rather than world-relative: 0 means home is
    /// dead ahead of however the player is currently facing, positive turns
    /// the same direction `camera.yaw` does. That's what lets the HUD just
    /// draw a needle at this angle without knowing which way is north.
    static func needleAngle(from position: Vector3, home: Vector3, cameraYaw: CGFloat) -> CGFloat {
        let dx = home.x - position.x
        let dz = home.z - position.z
        guard dx != 0 || dz != 0 else { return 0 }
        // Matches `compassDirection`'s convention: forward at yaw 0 is
        // (sin 0, cos 0) = +Z, so bearing is atan2(dx, dz), not atan2(dz, dx).
        let worldBearing = atan2(dx, dz)
        return worldBearing - cameraYaw
    }

    /// Flat distance to home, ignoring height — how far there is to walk,
    /// not how far there is to climb.
    static func distance(from position: Vector3, home: Vector3) -> CGFloat {
        let dx = home.x - position.x
        let dz = home.z - position.z
        return (dx * dx + dz * dz).squareRoot()
    }
}

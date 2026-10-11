import Foundation

/// Farmland hydration queries and mechanics for Milestone 2.
///
/// Farmland is hydrated by standing water within reach (default 4 blocks).
/// Frozen water (ice) does NOT hydrate farmland.
enum FarmlandHydration {
    /// Classic farmland hydration reach (4 blocks in Chebyshev distance).
    static let reach: Int = 4

    /// Whether standing water sits anywhere within reach of the given farmland cell.
    static func isHydrated(worldX: Int, y: Int, worldZ: Int, world: World, reach: Int = reach) -> Bool {
        world.isFarmlandHydrated(worldX: worldX, y: y, worldZ: worldZ, reach: reach)
    }

    /// Ticks a farmland cell: if unhydrated and untended (no crop above), reverts to dirt.
    @discardableResult
    static func tick(worldX: Int, y: Int, worldZ: Int, world: World) -> Bool {
        world.tickFarmland(worldX: worldX, y: y, worldZ: worldZ)
    }
}

import Foundation

/// Thermal radiance query engine for Milestone 2: Thermal Microclimates & Subterranean Farming.
/// Evaluates active heat sources (.torch, .furnaceLit, .lava, .signalLampLit) and determines
/// whether world block cells fall within thermal radiance boundaries.
enum ThermalQuery {

    /// Default thermal radiation radius in block cells.
    static let defaultRadius: Int = 3

    /// Distance metrics supported for thermal radiance checks.
    enum Metric {
        /// Manhattan distance (|dx| + |dy| + |dz| <= radius).
        /// Fast and physically aligned with taxicab heat diffusion.
        case manhattan

        /// Chebyshev distance (max(|dx|, |dy|, |dz|) <= radius).
        /// Axis-aligned bounding box.
        case chebyshev
    }

    /// Determines whether a given block type is an active thermal source.
    @inline(__always)
    static func isHeatSource(_ block: BlockType) -> Bool {
        switch block {
        case .torch, .furnaceLit, .lava, .signalLampLit:
            return true
        default:
            return false
        }
    }

    /// Checks whether the cell at (worldX, y, worldZ) is within `radius` of any active heat source.
    ///
    /// - Parameters:
    ///   - world: The world containing voxel chunk data.
    ///   - x: Center world X coordinate.
    ///   - y: Center world Y coordinate.
    ///   - z: Center world Z coordinate.
    ///   - radius: Search radius (default 3).
    ///   - metric: Distance metric to use (.chebyshev by default).
    /// - Returns: True if at least one heat source is found within the radius; false otherwise.
    static func isNearHeatSource(
        world: World,
        worldX x: Int,
        y: Int,
        worldZ z: Int,
        radius: Int = defaultRadius,
        metric: Metric = .chebyshev
    ) -> Bool {
        guard radius > 0 else { return isHeatSource(world.block(worldX: x, y: y, worldZ: z)) }

        switch metric {
        case .manhattan:
            for dy in -radius...radius {
                let ny = y + dy
                guard ny >= 0, ny < Chunk.height else { continue }
                let remY = radius - abs(dy)
                for dz in -remY...remY {
                    let remZ = remY - abs(dz)
                    for dx in -remZ...remZ {
                        if dx == 0 && dy == 0 && dz == 0 { continue }
                        let block = world.block(worldX: x + dx, y: ny, worldZ: z + dz)
                        if isHeatSource(block) {
                            return true
                        }
                    }
                }
            }
            return false

        case .chebyshev:
            for dy in -radius...radius {
                let ny = y + dy
                guard ny >= 0, ny < Chunk.height else { continue }
                for dz in -radius...radius {
                    for dx in -radius...radius {
                        if dx == 0 && dy == 0 && dz == 0 { continue }
                        let block = world.block(worldX: x + dx, y: ny, worldZ: z + dz)
                        if isHeatSource(block) {
                            return true
                        }
                    }
                }
            }
            return false
        }
    }
}

// MARK: - BlockType Thermal Extension
extension BlockType {
    /// True if this block actively emits heat/thermal radiance.
    @inline(__always)
    var isHeatSource: Bool {
        ThermalQuery.isHeatSource(self)
    }

    /// Alias for isHeatSource.
    @inline(__always)
    var isThermalSource: Bool {
        isHeatSource
    }
}

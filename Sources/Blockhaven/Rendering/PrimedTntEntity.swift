#if canImport(AppKit)
import Foundation
import AppKit
import RealityKit

/// A lit stick of TNT, sitting where the block was.
///
/// It flashes, and the flashing is not decoration. A fuse you cannot see
/// is a fuse that reads as the game having eaten your block — you place
/// TNT, touch it with a torch, the block vanishes and four seconds later
/// something explodes somewhere. The flash is what connects those.
///
/// The rate climbs as the fuse runs down, which is the whole language of
/// this: you can tell from across a room how long you have without
/// counting. At the end it is strobing every few frames.
@MainActor
final class PrimedTntEntity {
    let root = Entity()
    private let model: ModelEntity

    /// Slightly over a block, so it sits proud of the crater's rim and
    /// cannot z-fight with a neighbouring block face.
    private static let size: Float = 1.02

    /// The two colours it alternates between: the block's own red, and the
    /// white overexposure of something about to go off.
    private static let dark = unlit(NSColor(calibratedRed: 0.62, green: 0.16, blue: 0.13, alpha: 1))
    private static let bright = unlit(NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.94, alpha: 1))

    /// Unlit like the blocks and like every mob, so it sits in the same
    /// lighting model as the crater it is about to make.
    private static func unlit(_ tint: NSColor) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: tint)
        return material
    }

    init() {
        model = ModelEntity(
            mesh: .generateBox(size: PrimedTntEntity.size),
            materials: [PrimedTntEntity.dark]
        )
        root.addChild(model)
    }

    /// Places it and sets the flash for how much fuse is left.
    ///
    /// `fraction` is how much of the fuse remains, 1 at the moment it is
    /// lit and 0 as it goes off. The period shortens from a lazy half
    /// second down to a strobe, and the swell is the original's — it puffs up
    /// a little just before it goes.
    func update(centre: Vector3, fraction: Double) {
        root.position = SIMD3<Float>(
            Float(centre.x), Float(centre.y), Float(centre.z)
        )

        let urgency = 1 - max(0, min(1, fraction))
        let period = 0.5 - 0.42 * urgency
        // A square wave off the fuse's own remaining time, so two sticks
        // lit a moment apart flash out of step with each other rather than
        // pulsing together like one object.
        let phase = (1 - fraction).truncatingRemainder(dividingBy: period) / period
        let lit = phase < 0.5
        model.model?.materials = [lit ? PrimedTntEntity.bright : PrimedTntEntity.dark]

        let swell = Float(1 + 0.16 * urgency * urgency)
        model.scale = SIMD3<Float>(repeating: swell)
    }

    func removeFromParent() {
        root.removeFromParent()
    }
}
#endif

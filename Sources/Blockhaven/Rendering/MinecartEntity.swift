#if canImport(AppKit)
import AppKit
import Foundation
import RealityKit

/// The cart you ride in: an open box on the rail.
///
/// Four thin walls and a floor rather than a solid block, because the one
/// angle everybody sees a minecart from is standing beside it about to get
/// in, and a solid box at that angle is a crate. The walls are low enough
/// to see over from the seat, which matters more here than it sounds:
/// riding is the whole feature and the ride is what you look at.
@MainActor
final class MinecartEntity {
    let root = Entity()
    /// Turned to face along the track; separate from `root` so the yaw does
    /// not fight the position.
    private let body = Entity()

    private static let wallHeight: Float = 0.32
    private static let half: Float = 0.42
    private static let thickness: Float = 0.06

    private static let iron = unlit(NSColor(calibratedRed: 0.44, green: 0.45, blue: 0.48, alpha: 1))
    private static let ironDark = unlit(NSColor(calibratedRed: 0.31, green: 0.32, blue: 0.35, alpha: 1))

    private static func unlit(_ tint: NSColor) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: tint)
        return material
    }

    init() {
        root.addChild(body)

        // The floor.
        add(
            size: SIMD3(MinecartEntity.half * 2, MinecartEntity.thickness, MinecartEntity.half * 2),
            at: SIMD3(0, MinecartEntity.thickness / 2, 0),
            material: MinecartEntity.ironDark
        )

        // Four walls, open at the top.
        let h = MinecartEntity.wallHeight
        let s = MinecartEntity.half
        let t = MinecartEntity.thickness
        for (offset, size) in [
            (SIMD3<Float>(0, h / 2, s - t / 2), SIMD3<Float>(s * 2, h, t)),
            (SIMD3<Float>(0, h / 2, -s + t / 2), SIMD3<Float>(s * 2, h, t)),
            (SIMD3<Float>(s - t / 2, h / 2, 0), SIMD3<Float>(t, h, s * 2)),
            (SIMD3<Float>(-s + t / 2, h / 2, 0), SIMD3<Float>(t, h, s * 2)),
        ] {
            add(size: size, at: offset, material: MinecartEntity.iron)
        }
    }

    private func add(size: SIMD3<Float>, at position: SIMD3<Float>, material: UnlitMaterial) {
        let part = ModelEntity(
            mesh: .generateBox(size: size),
            materials: [material]
        )
        part.position = position
        body.addChild(part)
    }

    func update(_ cart: Minecart) {
        root.position = SIMD3<Float>(
            Float(cart.position.x), Float(cart.position.y), Float(cart.position.z)
        )
        // Turned along the track. Yaw only: a cart on a slope stays level
        // in this model, which is a simplification you would notice on a
        // long ramp and not at all on the short ones a coaster is made of.
        let yaw: Float
        switch cart.heading {
        case .north: yaw = .pi
        case .south: yaw = 0
        case .east: yaw = .pi / 2
        case .west: yaw = -.pi / 2
        }
        body.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        // The ridden one is hidden: you are sitting in it, and its near wall
        // fills the screen from the inside.
        body.isEnabled = !cart.isRidden
    }

    func removeFromParent() {
        root.removeFromParent()
    }
}
#endif

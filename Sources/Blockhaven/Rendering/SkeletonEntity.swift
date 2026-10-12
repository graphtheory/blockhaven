#if canImport(AppKit)
import RealityKit
import AppKit

/// The visible skeleton: tall, thin, two-legged — a silhouette a player can
/// tell apart from a fizzler before they're close enough to see the face.
///
/// One of these is kept per live skeleton and moved each frame; the
/// simulation in `Skeleton` never touches RealityKit. Same split as
/// `FizzlerEntity`.
@MainActor
final class SkeletonEntity {
    private static let bodyWidth: Float = 0.45
    private static let bodyHeight: Float = 0.85
    private static let bodyDepth: Float = 0.25
    private static let headSize: Float = 0.42
    private static let legWidth: Float = 0.2
    private static let legHeight: Float = 0.65

    let root = Entity()
    private let body = Entity()
    private var parts: [ModelEntity] = []
    /// The Moon's maintenance sentry wears the same frame in dark metal.
    private let sentry: Bool

    init(sentry: Bool = false) {
        self.sentry = sentry
        root.addChild(body)
        build()
    }

    private func build() {
        let skin = sentry ? SkeletonEntity.sentryMaterial : SkeletonEntity.skinMaterial
        let legY = SkeletonEntity.legHeight / 2
        let bodyY = SkeletonEntity.legHeight + SkeletonEntity.bodyHeight / 2
        let headY = SkeletonEntity.legHeight + SkeletonEntity.bodyHeight + SkeletonEntity.headSize / 2

        addBox(
            size: SIMD3(SkeletonEntity.bodyWidth, SkeletonEntity.bodyHeight, SkeletonEntity.bodyDepth),
            at: SIMD3(0, bodyY, 0), materials: [skin]
        )
        addBox(
            size: SIMD3(repeating: SkeletonEntity.headSize),
            at: SIMD3(0, headY, 0),
            materials: sentry ? SkeletonEntity.sentryHeadMaterials : SkeletonEntity.headFaceMaterials,
            splitFaces: true
        )

        // Two legs, narrow, directly under the body — no splay, unlike a
        // fizzler's four: this stands like something that used to walk
        // upright, not like something built to amble.
        let legX = (SkeletonEntity.bodyWidth - SkeletonEntity.legWidth) / 2
        for dx in [-legX, legX] {
            addBox(
                size: SIMD3(SkeletonEntity.legWidth, SkeletonEntity.legHeight, SkeletonEntity.legWidth),
                at: SIMD3(dx, legY, 0), materials: [skin]
            )
        }
    }

    private func addBox(
        size: SIMD3<Float>, at position: SIMD3<Float>, materials: [any Material],
        splitFaces: Bool = false
    ) {
        let mesh = splitFaces
            ? MeshResource.generateBox(width: size.x, height: size.y, depth: size.z, splitFaces: true)
            : MeshResource.generateBox(size: size)
        let part = ModelEntity(mesh: mesh, materials: materials)
        part.position = position
        body.addChild(part)
        parts.append(part)
    }

    /// Moves the entity to match one frame of simulation.
    func apply(_ skeleton: Skeleton) {
        place(position: skeleton.position, facing: skeleton.facing, hurt: skeleton.isHurt)
    }

    /// The posing primitive `apply` is built on, also used by the snapshot
    /// harness to pose a skeleton without running the AI.
    func place(position: Vector3, facing: CGFloat, hurt: Bool = false) {
        root.position = SIMD3(Float(position.x), Float(position.y), Float(position.z))
        root.orientation = simd_quatf(angle: Float(facing), axis: SIMD3(0, 1, 0))
        setTint(hurt ? .hurt : .plain)
    }

    private enum Tint { case plain, hurt }
    private var tint = Tint.plain

    private func setTint(_ next: Tint) {
        guard next != tint else { return }
        tint = next
        for (index, part) in parts.enumerated() {
            part.model?.materials = SkeletonEntity.materials(for: next, partIndex: index, sentry: sentry)
        }
    }

    private static func materials(for tint: Tint, partIndex: Int, sentry: Bool) -> [any Material] {
        let isHead = partIndex == 1
        switch tint {
        case .plain:
            if sentry { return isHead ? sentryHeadMaterials : [sentryMaterial] }
            return isHead ? headFaceMaterials : skinMaterials
        case .hurt: return isHead ? headHurtMaterials : hurtMaterials
        }
    }

    private static let sentryMaterial: UnlitMaterial = unlit(texture(SkeletonSkin.sentryBody), tint: .white)
    private static let sentryHeadMaterials: [any Material] = {
        var faces: [any Material] = Array(repeating: sentryMaterial, count: 6)
        faces[frontFaceIndex] = unlit(texture(SkeletonSkin.sentryFace), tint: .white)
        return faces
    }()

    private static let skinMaterials: [any Material] = [skinMaterial]
    private static let hurtMaterials: [any Material] = [hurtMaterial]

    /// Measured the same way `FizzlerEntity.frontFaceIndex` was: empirically,
    /// off the snapshot harness, not assumed from `generateBox`'s
    /// undocumented face order.
    private static let frontFaceIndex = 0

    private static let headFaceMaterials: [any Material] = {
        var faces: [any Material] = Array(repeating: skinMaterial, count: 6)
        faces[frontFaceIndex] = faceMaterial
        return faces
    }()
    private static let headHurtMaterials: [any Material] = Array(repeating: hurtMaterial, count: 6)

    // MARK: - Materials

    private static func unlit(_ texture: TextureResource?, tint: NSColor) -> UnlitMaterial {
        var material = UnlitMaterial()
        if let texture {
            material.color = .init(tint: tint, texture: .init(texture, sampler: nearestSampler))
        } else {
            material.color = .init(tint: tint)
        }
        return material
    }

    private static let nearestSampler: MaterialParameters.Texture.Sampler = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .nearest
        descriptor.magFilter = .nearest
        descriptor.mipFilter = .notMipmapped
        return MaterialParameters.Texture.Sampler(descriptor)
    }()

    private static let skinMaterial: UnlitMaterial =
        unlit(texture(SkeletonSkin.body), tint: .white)

    private static let faceMaterial: UnlitMaterial =
        unlit(texture(SkeletonSkin.face), tint: .white)

    private static let hurtMaterial: UnlitMaterial =
        unlit(texture(SkeletonSkin.flash), tint: NSColor(calibratedRed: 1, green: 0.28, blue: 0.24, alpha: 1))

    private static func texture(_ image: NSImage) -> TextureResource? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return try? TextureResource(
            image: cgImage,
            options: .init(semantic: .color, mipmapsMode: .none)
        )
    }
}
#endif

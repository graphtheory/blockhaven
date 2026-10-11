#if canImport(AppKit)
import RealityKit
import AppKit

/// The visible fizzler: a squat stone golem — a wide body on two thick
/// legs, short arms hanging at its sides, and a small flat head sunk into
/// its shoulders — built from boxes like every other mob.
///
/// One of these is kept per live fizzler and moved each frame; the
/// simulation in `Fizzler` never touches RealityKit. `SDLMobModels` builds
/// the same boxes for the Windows renderer; keep the two in step.
@MainActor
final class FizzlerEntity {
    /// Sizes are in blocks.
    static let legSize = SIMD3<Float>(0.26, 0.5, 0.3)
    static let legX: Float = 0.18
    static let bodySize = SIMD3<Float>(0.76, 0.68, 0.46)
    static let armSize = SIMD3<Float>(0.2, 0.56, 0.24)
    static let headSize = SIMD3<Float>(0.46, 0.42, 0.42)
    /// How far the head sinks into the shoulders, and leans forward.
    static let headSink: Float = 0.04
    static let headForward: Float = 0.03

    let root = Entity()
    /// Scaled and tinted as the fuse burns; separate from `root` so the
    /// swell doesn't fight the position and yaw set on the root.
    private let body = Entity()
    private var parts: [ModelEntity] = []

    init() {
        root.addChild(body)
        build()
    }

    private func build() {
        let skin = FizzlerEntity.skinMaterial
        let leg = FizzlerEntity.legSize, torso = FizzlerEntity.bodySize
        let arm = FizzlerEntity.armSize, head = FizzlerEntity.headSize
        let bodyY = leg.y + torso.y / 2

        addBox(size: torso, at: SIMD3(0, bodyY, 0), materials: [skin])
        addBox(
            size: head,
            at: SIMD3(0, leg.y + torso.y + head.y / 2 - FizzlerEntity.headSink, FizzlerEntity.headForward),
            materials: FizzlerEntity.headFaceMaterials, splitFaces: true
        )
        for side: Float in [-1, 1] {
            addBox(size: leg, at: SIMD3(side * FizzlerEntity.legX, leg.y / 2, 0), materials: [skin])
            addBox(
                size: arm,
                at: SIMD3(side * (torso.x + arm.x) / 2, leg.y + torso.y - 0.02 - arm.y / 2, 0),
                materials: [skin]
            )
        }
    }

    /// `splitFaces` gives each of the six faces its own material slot
    /// instead of stretching one texture over the whole box — only the head
    /// needs that, so the face lands on the front and nowhere else. Body
    /// and legs stay single-material boxes: six materials per part, times
    /// every part, would multiply draw calls for a distinction nothing
    /// there needs.
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
    func apply(_ fizzler: Fizzler) {
        place(
            position: fizzler.position,
            facing: fizzler.facing,
            swell: fizzler.swell,
            hurt: fizzler.isHurt
        )
    }

    /// The posing primitive `apply` is built on, also used by the snapshot
    /// harness to capture a fizzler mid-fuse without running the AI.
    func place(position: Vector3, facing: CGFloat, swell rawSwell: Double, hurt: Bool = false) {
        root.position = SIMD3(Float(position.x), Float(position.y), Float(position.z))
        root.orientation = simd_quatf(angle: Float(facing), axis: SIMD3(0, 1, 0))

        // Its tell: it swells a little and its cracks blaze just before it
        // goes off. The pulse is fast enough to read as panic.
        let swell = Float(rawSwell)
        guard swell > 0 else {
            if body.scale.x != 1 { body.scale = .one }
            setTint(hurt ? .hurt : .plain)
            return
        }

        body.scale = SIMD3(repeating: 1 + 0.1 * swell)
        // Blink rate accelerates with the fuse, so the last half-second is
        // unmistakable. A hit outranks the blink, so a sword landing on a
        // fizzler mid-fuse still reads as a hit rather than as more fuse.
        setTint(hurt ? .hurt : (sin(swell * swell * 46) > 0 ? .fuse : .plain))
    }

    private enum Tint { case plain, fuse, hurt }
    private var tint = Tint.plain

    /// Swaps the whole model between its normal skin, the whitened fuse
    /// blink and the red hurt flash.
    ///
    /// A fusing fizzler blinks several times a second and this rewrites six
    /// `ModelComponent`s each time, so the material arrays are built once
    /// and shared rather than allocated per part per blink: the swap is now
    /// six retains and six component writes with nothing new on the heap.
    private func setTint(_ next: Tint) {
        guard next != tint else { return }
        tint = next
        for (index, part) in parts.enumerated() {
            // Index 1 is the head, which keeps its face unless flashing.
            part.model?.materials = FizzlerEntity.materials(for: next, partIndex: index)
        }
    }

    /// Index 1 is the head for every tint, not just `.plain`: the split-face
    /// head box always needs six material slots, even under the fuse blink
    /// or the hurt flash, where all six just repeat the same texture (it
    /// carries no face either way, so there's nothing to put on a "front").
    private static func materials(for tint: Tint, partIndex: Int) -> [any Material] {
        let isHead = partIndex == 1
        switch tint {
        case .plain: return isHead ? headFaceMaterials : skinMaterials
        case .fuse: return isHead ? headFlashMaterials : flashMaterials
        case .hurt: return isHead ? headHurtMaterials : hurtMaterials
        }
    }

    private static let skinMaterials: [any Material] = [skinMaterial]
    private static let flashMaterials: [any Material] = [flashMaterial]
    private static let hurtMaterials: [any Material] = [hurtMaterial]

    /// The box's local +Z face — the one the head's untouched local frame
    /// points along, and the one `place`'s yaw turns to face the camera —
    /// measured empirically off a six-colour test box rendered through the
    /// snapshot harness rather than assumed: `generateBox`'s face order is
    /// not documented. Shared with `AnimalEntity`, whose heads are built the
    /// same way.
    private static let frontFaceIndex = 0

    /// Six materials for the split-face head box: the face on the front,
    /// the plain mottled skin (no face) on the other five.
    private static let headFaceMaterials: [any Material] = {
        var faces: [any Material] = Array(repeating: skinMaterial, count: 6)
        faces[frontFaceIndex] = faceMaterial
        return faces
    }()
    private static let headFlashMaterials: [any Material] = Array(repeating: flashMaterial, count: 6)
    private static let headHurtMaterials: [any Material] = Array(repeating: hurtMaterial, count: 6)

    // MARK: - Materials

    /// Unlit like the blocks, so the fizzler sits in the same lighting
    /// model as everything else in the scene.
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
        unlit(texture(FizzlerSkin.body), tint: .white)

    private static let faceMaterial: UnlitMaterial =
        unlit(texture(FizzlerSkin.face), tint: .white)

    /// The whitened skin used for the pre-detonation blink. Kept as its own
    /// texture rather than a tint, because an unlit tint can only darken.
    private static let flashMaterial: UnlitMaterial =
        unlit(texture(FizzlerSkin.flash), tint: .white)

    /// The hurt flash, built on the same whitened texture: a tint can only
    /// multiply, so red over the pale skin lands on red, while red over the
    /// green one would land on mud.
    private static let hurtMaterial: UnlitMaterial =
        unlit(texture(FizzlerSkin.flash), tint: NSColor(calibratedRed: 1, green: 0.28, blue: 0.24, alpha: 1))

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

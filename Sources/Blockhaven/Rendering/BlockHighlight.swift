#if canImport(AppKit)
import RealityKit
import simd

/// The two bits of feedback drawn on the block under the crosshair: a thin
/// dark wireframe box, and — while the player is mining — a crack overlay
/// that advances through ten stages.
@MainActor
final class BlockHighlight {
    let root = Entity()
    private let outlineEntity = ModelEntity()
    private let crackEntity = ModelEntity()
    private var currentStage = -1

    init() {
        outlineEntity.model = ModelComponent(
            mesh: BlockHighlight.outlineMesh(),
            materials: [MaterialLibrary.selectionOutline]
        )
        // Slightly larger than the block so the crack faces sit just
        // outside the block's own, avoiding z-fighting.
        crackEntity.model = ModelComponent(
            mesh: BlockHighlight.crackMesh(),
            materials: [MaterialLibrary.breakOverlay(stage: 0)]
        )
        crackEntity.isEnabled = false

        root.addChild(outlineEntity)
        root.addChild(crackEntity)
        root.isEnabled = false
    }

    func attach(to parent: Entity) {
        parent.addChild(root)
    }

    /// Places the highlight on a block, or hides it when nothing is
    /// targeted. `progress` 0…1 drives the crack stage; 0 hides the cracks.
    func update(target: (x: Int, y: Int, z: Int)?, progress: Double) {
        guard let target else {
            root.isEnabled = false
            return
        }
        root.isEnabled = true
        // Block coordinates address the cell's minimum corner; the meshes
        // are centred, so offset by half a block.
        root.position = SIMD3<Float>(
            Float(target.x) + 0.5,
            Float(target.y) + 0.5,
            Float(target.z) + 0.5
        )

        if progress <= 0 {
            crackEntity.isEnabled = false
            currentStage = -1
            return
        }
        crackEntity.isEnabled = true
        let stage = max(0, min(9, Int(progress * 10)))
        if stage != currentStage {
            currentStage = stage
            crackEntity.model?.materials = [MaterialLibrary.breakOverlay(stage: stage)]
            // The crack tiles live in the atlas, so the stage is selected
            // by re-UVing the box rather than by swapping textures.
            crackEntity.model?.mesh = BlockHighlight.crackMesh(stage: stage)
        }
    }

    /// A unit cube's twelve edges as thin boxes. RealityKit has no line
    /// primitive, so the outline is built from slivers — which also means
    /// it stays visible at a distance instead of thinning to nothing.
    private static func outlineMesh() -> MeshResource {
        let half: Float = 0.5015
        let thickness: Float = 0.012
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        // Twelve edges: for each axis, four bars at the four combinations
        // of the other two axes' signs.
        for axis in 0..<3 {
            let otherA = (axis + 1) % 3
            let otherB = (axis + 2) % 3
            for signA in [Float(-1), 1] {
                for signB in [Float(-1), 1] {
                    var minCorner = SIMD3<Float>(repeating: 0)
                    var maxCorner = SIMD3<Float>(repeating: 0)
                    minCorner[axis] = -half
                    maxCorner[axis] = half
                    minCorner[otherA] = signA * half - thickness
                    maxCorner[otherA] = signA * half + thickness
                    minCorner[otherB] = signB * half - thickness
                    maxCorner[otherB] = signB * half + thickness
                    appendBox(
                        min: minCorner, max: maxCorner,
                        positions: &positions, normals: &normals, uvs: &uvs, indices: &indices
                    )
                }
            }
        }

        var descriptor = MeshDescriptor(name: "block-outline")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? MeshResource.generateBox(size: 0.01)
    }

    /// A slightly oversized cube UV-mapped to one crack tile in the atlas.
    private static func crackMesh(stage: Int = 0) -> MeshResource {
        let half: Float = 0.5015
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        appendBox(
            min: SIMD3<Float>(repeating: -half),
            max: SIMD3<Float>(repeating: half),
            positions: &positions, normals: &normals, uvs: &uvs, indices: &indices
        )
        let rect = TextureAtlas.crackUVRect(stage: stage)
        // Every face of the box gets the same crack tile.
        let cornerUVs: [SIMD2<Float>] = [
            SIMD2(rect.u0, rect.v1), SIMD2(rect.u1, rect.v1),
            SIMD2(rect.u1, rect.v0), SIMD2(rect.u0, rect.v0),
        ]
        for index in uvs.indices {
            uvs[index] = cornerUVs[index % 4]
        }

        var descriptor = MeshDescriptor(name: "block-cracks")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? MeshResource.generateBox(size: 1.0)
    }

    /// Appends an axis-aligned box as six independent quads.
    private static func appendBox(
        min minCorner: SIMD3<Float>,
        max maxCorner: SIMD3<Float>,
        positions: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        uvs: inout [SIMD2<Float>],
        indices: inout [UInt32]
    ) {
        let corners: [SIMD3<Float>] = [
            SIMD3(minCorner.x, minCorner.y, minCorner.z),
            SIMD3(maxCorner.x, minCorner.y, minCorner.z),
            SIMD3(maxCorner.x, maxCorner.y, minCorner.z),
            SIMD3(minCorner.x, maxCorner.y, minCorner.z),
            SIMD3(minCorner.x, minCorner.y, maxCorner.z),
            SIMD3(maxCorner.x, minCorner.y, maxCorner.z),
            SIMD3(maxCorner.x, maxCorner.y, maxCorner.z),
            SIMD3(minCorner.x, maxCorner.y, maxCorner.z),
        ]
        // Each face lists its four corners counter-clockwise from outside,
        // paired with its outward normal.
        let faces: [(indices: [Int], normal: SIMD3<Float>)] = [
            ([4, 5, 6, 7], SIMD3(0, 0, 1)),
            ([1, 0, 3, 2], SIMD3(0, 0, -1)),
            ([5, 1, 2, 6], SIMD3(1, 0, 0)),
            ([0, 4, 7, 3], SIMD3(-1, 0, 0)),
            ([3, 7, 6, 2], SIMD3(0, 1, 0)),
            ([0, 1, 5, 4], SIMD3(0, -1, 0)),
        ]
        let faceUVs: [SIMD2<Float>] = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
        for face in faces {
            let base = UInt32(positions.count)
            for (slot, cornerIndex) in face.indices.enumerated() {
                positions.append(corners[cornerIndex])
                normals.append(face.normal)
                uvs.append(faceUVs[slot])
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
    }
}
#endif

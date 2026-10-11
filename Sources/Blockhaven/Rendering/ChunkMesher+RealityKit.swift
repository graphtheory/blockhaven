#if canImport(AppKit)
import RealityKit

extension ChunkMesher {
    // MARK: - RealityKit resources

    /// Turns one accumulated buffer into a `MeshResource`.
    ///
    /// `MeshResource(from: LowLevelMesh)` has a synchronous overload, so
    /// the per-frame meshing budget stays the straight-line loop it was —
    /// no task hop, no window where a chunk is half-built.
    @MainActor
    static func makeMesh(from buffer: Buffer) -> MeshResource? {
        guard !buffer.isEmpty else { return nil }

        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = buffer.vertices.count
        descriptor.indexCapacity = buffer.indices.count
        descriptor.indexType = .uint32
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3,
                  layoutIndex: 0, offset: MemoryLayout<Vertex>.offset(of: \.px)!),
            .init(semantic: .normal, format: .float3,
                  layoutIndex: 0, offset: MemoryLayout<Vertex>.offset(of: \.nx)!),
            .init(semantic: .uv0, format: .float2,
                  layoutIndex: 0, offset: MemoryLayout<Vertex>.offset(of: \.u)!),
            .init(semantic: .color, format: .uchar4Normalized,
                  layoutIndex: 0, offset: MemoryLayout<Vertex>.offset(of: \.shade)!),
        ]
        descriptor.vertexLayouts = [
            .init(bufferIndex: 0, bufferOffset: 0, bufferStride: MemoryLayout<Vertex>.stride)
        ]

        guard let mesh = try? LowLevelMesh(descriptor: descriptor) else { return nil }

        mesh.withUnsafeMutableBytes(bufferIndex: 0) { destination in
            buffer.vertices.withUnsafeBytes { source in
                guard let from = source.baseAddress, let to = destination.baseAddress else { return }
                to.copyMemory(from: from, byteCount: source.count)
            }
        }
        mesh.withUnsafeMutableIndices { destination in
            buffer.indices.withUnsafeBytes { source in
                guard let from = source.baseAddress, let to = destination.baseAddress else { return }
                to.copyMemory(from: from, byteCount: source.count)
            }
        }
        mesh.parts.replaceAll([
            LowLevelMesh.Part(
                indexOffset: 0,
                indexCount: buffer.indices.count,
                topology: .triangle,
                materialIndex: 0,
                bounds: BoundingBox(min: buffer.minimum, max: buffer.maximum)
            )
        ])

        return try? MeshResource(from: mesh)
    }
}
#endif

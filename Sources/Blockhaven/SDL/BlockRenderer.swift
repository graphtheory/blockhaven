#if canImport(CSDL3)
import Foundation

/// One `ChunkMesher.Buffer` on the GPU.
final class GPUMesh {
    private var vao: GLuint = 0
    private var vbo: GLuint = 0
    private var ebo: GLuint = 0
    let indexCount: Int

    init(_ buffer: ChunkMesher.Buffer) {
        indexCount = buffer.indices.count
        glGenVertexArrays(1, &vao)
        glBindVertexArray(vao)
        glGenBuffers(1, &vbo)
        glBindBuffer(GL_ARRAY_BUFFER, vbo)
        buffer.vertices.withUnsafeBytes { raw in
            glBufferData(GL_ARRAY_BUFFER, raw.count, raw.baseAddress, GL_STATIC_DRAW)
        }
        glGenBuffers(1, &ebo)
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo)
        buffer.indices.withUnsafeBytes { raw in
            glBufferData(GL_ELEMENT_ARRAY_BUFFER, raw.count, raw.baseAddress, GL_STATIC_DRAW)
        }
        // The layout `ChunkMesher.Vertex` declares, offsets read off the
        // struct itself so this cannot drift from it.
        typealias V = ChunkMesher.Vertex
        let stride = GLsizei(MemoryLayout<V>.stride)
        func offset(_ path: PartialKeyPath<V>) -> UnsafeRawPointer? {
            UnsafeRawPointer(bitPattern: MemoryLayout<V>.offset(of: path)!)
        }
        glEnableVertexAttribArray(0)
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, stride, offset(\V.px))
        glEnableVertexAttribArray(1)
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, stride, offset(\V.nx))
        glEnableVertexAttribArray(2)
        glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, stride, offset(\V.u))
        glEnableVertexAttribArray(3)
        glVertexAttribPointer(3, 4, GL_UNSIGNED_BYTE, GL_TRUE, stride, offset(\V.shade))
        glBindVertexArray(0)
    }

    func draw() {
        glBindVertexArray(vao)
        glDrawElements(GL_TRIANGLES, GLsizei(indexCount), GL_UNSIGNED_INT, nil)
    }

    deinit {
        glDeleteBuffers(1, &vbo)
        glDeleteBuffers(1, &ebo)
        glDeleteVertexArrays(1, &vao)
    }
}

/// Everything drawing one chunk: hung on `Chunk.renderHandle`, so it goes
/// when the chunk does.
final class ChunkGPU {
    var opaque: GPUMesh?
    var translucent: GPUMesh?
    var buried: GPUMesh?
}

/// Draws the terrain: the opaque pass, then water and glass over it.
final class BlockRenderer {
    let program: GLProgram
    let atlas: GLTexture

    init(atlas: GLTexture) {
        self.atlas = atlas
        program = GLProgram(
            name: "blocks",
            vertex: BlockShaderSource.vertex,
            fragment: BlockShaderSource.fragment,
            attributes: ["aPosition", "aNormal", "aUV", "aShade"]
        )
    }

    /// Hangs freshly built geometry on a chunk, replacing only the halves
    /// the build covers — the same rule `GameViewController.install` keeps.
    func install(_ data: ChunkMesher.MeshData, into chunk: Chunk) {
        let gpu = (chunk.renderHandle as? ChunkGPU) ?? ChunkGPU()
        chunk.renderHandle = gpu
        if data.faces.contains(.surface) {
            gpu.opaque = data.opaque.map(GPUMesh.init)
            gpu.translucent = data.translucent.map(GPUMesh.init)
        }
        if data.faces.contains(.buried) {
            gpu.buried = data.buried.map(GPUMesh.init)
            chunk.showsBuriedHalf = gpu.buried != nil
        }
    }

    /// The per-frame lighting a block needs, all in linear light.
    struct Lighting {
        var daylight: SIMD3<Float>
        var horizon: SIMD3<Float>
        var zenith: SIMD3<Float>
        var sunDirection: SIMD3<Float>
        var fogRange: SIMD2<Float>
        var time: Float
    }

    func draw(
        world: World,
        view: Matrix4,
        projection: Matrix4,
        eye: SIMD3<Float>,
        lighting: Lighting
    ) {
        let viewProjection = projection * view
        let frustum = Frustum(viewProjection)

        // Every chunk worth drawing, with how far its centre is — the
        // translucent pass is drawn far to near, so water seen through water
        // blends the right way round.
        var visible: [(chunk: Chunk, gpu: ChunkGPU, distance: Float)] = []
        visible.reserveCapacity(world.chunks.count)
        for chunk in world.chunks.values {
            guard let gpu = chunk.renderHandle as? ChunkGPU else { continue }
            let minimum = SIMD3<Float>(Float(chunk.originX), 0, Float(chunk.originZ))
            let maximum = minimum + SIMD3<Float>(Float(Chunk.width), Float(Chunk.height), Float(Chunk.depth))
            guard frustum.intersects(minimum: minimum, maximum: maximum) else { continue }
            let centre = (minimum + maximum) * 0.5
            let d = centre - eye
            visible.append((chunk, gpu, d.x * d.x + d.z * d.z))
        }

        program.use()
        atlas.bind(unit: 0)
        program.set("uAtlas", Int32(0))
        program.set("uViewProjection", viewProjection)
        program.set("uView", view)
        program.set("uEye", eye)
        program.set("uDaylight", lighting.daylight)
        program.set("uHorizon", lighting.horizon)
        program.set("uZenith", lighting.zenith)
        program.set("uSunDirection", lighting.sunDirection)
        program.set("uFogRange", lighting.fogRange)
        program.set("uTime", lighting.time)

        // Opaque, near to far, so the depth test throws away as much as it
        // can before the fragment shader runs.
        visible.sort { $0.distance < $1.distance }
        glEnable(GL_DEPTH_TEST)
        glDepthMask(GL_TRUE)
        glDisable(GL_BLEND)
        glEnable(GL_CULL_FACE)
        program.set("uTranslucentPass", Int32(0))
        for entry in visible {
            program.set("uChunkOrigin", SIMD3<Float>(Float(entry.chunk.originX), 0, Float(entry.chunk.originZ)))
            entry.gpu.opaque?.draw()
            entry.gpu.buried?.draw()
        }

        // Water and glass: two-sided, blended, depth-tested but not written,
        // far to near.
        glDisable(GL_CULL_FACE)
        glEnable(GL_BLEND)
        glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA)
        glDepthMask(GL_FALSE)
        program.set("uTranslucentPass", Int32(1))
        for entry in visible.reversed() {
            guard let translucent = entry.gpu.translucent else { continue }
            program.set("uChunkOrigin", SIMD3<Float>(Float(entry.chunk.originX), 0, Float(entry.chunk.originZ)))
            translucent.draw()
        }
        glDepthMask(GL_TRUE)
        glDisable(GL_BLEND)
        glEnable(GL_CULL_FACE)
        glBindVertexArray(0)
    }
}

/// The six planes of a view-projection, for throwing away chunks the
/// camera cannot see before any of their geometry is submitted.
struct Frustum {
    private var planes: [SIMD4<Float>] = []

    init(_ m: Matrix4) {
        // Rows of the matrix, from its columns.
        let c = m.columns
        let row0 = SIMD4(c.0.x, c.1.x, c.2.x, c.3.x)
        let row1 = SIMD4(c.0.y, c.1.y, c.2.y, c.3.y)
        let row2 = SIMD4(c.0.z, c.1.z, c.2.z, c.3.z)
        let row3 = SIMD4(c.0.w, c.1.w, c.2.w, c.3.w)
        planes = [row3 + row0, row3 - row0, row3 + row1, row3 - row1, row3 + row2, row3 - row2]
    }

    /// False only when the box is wholly outside one plane.
    func intersects(minimum: SIMD3<Float>, maximum: SIMD3<Float>) -> Bool {
        for plane in planes {
            // The corner furthest along the plane's normal.
            let corner = SIMD3<Float>(
                plane.x >= 0 ? maximum.x : minimum.x,
                plane.y >= 0 ? maximum.y : minimum.y,
                plane.z >= 0 ? maximum.z : minimum.z
            )
            if plane.x * corner.x + plane.y * corner.y + plane.z * corner.z + plane.w < 0 { return false }
        }
        return true
    }
}

/// sRGB components to linear light — the conversion RealityKit makes for
/// every colour handed to it, made here by hand so the GL path lights in
/// the same space.
@inline(__always)
func linearFromSRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
    func channel(_ v: Float) -> Float {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }
    return SIMD3(channel(c.x), channel(c.y), channel(c.z))
}
#endif

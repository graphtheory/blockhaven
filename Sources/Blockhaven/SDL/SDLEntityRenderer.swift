#if canImport(CSDL3)
import Foundation

/// Everything in the world that is not terrain: mobs, carts, lit TNT, and
/// the outline round the block the crosshair is on.
///
/// Mobs are built from boxes, the way the Mac builds them from RealityKit
/// cubes — see `SDLMobModels` for the shapes.
final class SDLEntityRenderer {
    private let program: GLProgram
    private let lineProgram: GLProgram
    private var cubeVAO: GLuint = 0
    private var cubeVBO: GLuint = 0
    private var lineVAO: GLuint = 0
    private var lineVBO: GLuint = 0
    private let models: SDLMobModels
    private let atlas: GLTexture

    init(app: SDLApp) {
        atlas = app.assets.atlas
        models = SDLMobModels(assets: app.assets)
        program = GLProgram(
            name: "entity",
            vertex: """
            #version 330 core
            in vec3 aPosition;
            in vec3 aNormal;
            in vec2 aUV;
            uniform mat4 uViewProjection;
            uniform mat4 uView;
            uniform mat4 uModel;
            uniform vec4 uUVRect[6];
            out vec3 vNormal;
            out vec2 vUV;
            out float vDistance;
            out float vHeight;
            flat out int vFace;
            void main() {
                vec4 world = uModel * vec4(aPosition, 1.0);
                vNormal = normalize(mat3(uModel) * aNormal);
                // Which face of the unit cube this vertex is on, from its
                // normal: +X -X +Y -Y +Z -Z.
                int face = aNormal.x > 0.5 ? 0 : aNormal.x < -0.5 ? 1 : aNormal.y > 0.5 ? 2 : aNormal.y < -0.5 ? 3 : aNormal.z > 0.5 ? 4 : 5;
                vFace = face;
                vec4 r = uUVRect[face];
                vUV = mix(r.xy, r.zw, aUV);
                vDistance = length((uView * world).xyz);
                vHeight = world.y;
                gl_Position = uViewProjection * world;
            }
            """,
            fragment: """
            #version 330 core
            in vec3 vNormal;
            in vec2 vUV;
            in float vDistance;
            in float vHeight;
            flat in int vFace;
            uniform sampler2D uTexture;
            uniform vec4 uTint;
            uniform vec3 uDaylight;
            uniform vec3 uHorizon;
            uniform vec2 uFogRange;
            uniform vec3 uFlash;
            uniform float uFlashAmount;
            out vec4 fragColor;
            void main() {
                vec4 texel = texture(uTexture, vUV) * uTint;
                if (texel.a < 0.5) { discard; }
                // The same fixed per-direction tint the terrain bakes in.
                vec3 n = normalize(vNormal);
                float shade = n.y > 0.5 ? 1.0 : (n.y < -0.5 ? 0.6 : (abs(n.x) > 0.5 ? 0.76 : 0.88));
                vec3 color = texel.rgb * shade * uDaylight;
                color = mix(color, uFlash, uFlashAmount);
                float fog = clamp((vDistance - uFogRange.x) / max(1.0, uFogRange.y - uFogRange.x), 0.0, 1.0);
                fog = pow(fog, 3.0);
                fragColor = vec4(mix(color, uHorizon, fog), 1.0);
            }
            """,
            attributes: ["aPosition", "aNormal", "aUV"]
        )
        lineProgram = GLProgram(
            name: "lines",
            vertex: """
            #version 330 core
            in vec3 aPosition;
            uniform mat4 uViewProjection;
            void main() { gl_Position = uViewProjection * vec4(aPosition, 1.0); }
            """,
            fragment: """
            #version 330 core
            uniform vec4 uColor;
            out vec4 fragColor;
            void main() { fragColor = uColor; }
            """,
            attributes: ["aPosition"]
        )
        buildCube()
        glGenVertexArrays(1, &lineVAO)
        glBindVertexArray(lineVAO)
        glGenBuffers(1, &lineVBO)
        glBindBuffer(GL_ARRAY_BUFFER, lineVBO)
        glEnableVertexAttribArray(0)
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 12, nil)
        glBindVertexArray(0)
    }

    /// A unit cube from (0,0,0) to (1,1,1): position, normal, face UV.
    private func buildCube() {
        var data: [Float] = []
        // Each face: normal, then four corners in counter-clockwise order
        // seen from outside, with their UVs (u right, v down the texture).
        let faces: [(SIMD3<Float>, [SIMD3<Float>])] = [
            (SIMD3(1, 0, 0), [SIMD3(1, 1, 1), SIMD3(1, 0, 1), SIMD3(1, 0, 0), SIMD3(1, 1, 0)]),
            (SIMD3(-1, 0, 0), [SIMD3(0, 1, 0), SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 1)]),
            (SIMD3(0, 1, 0), [SIMD3(0, 1, 0), SIMD3(0, 1, 1), SIMD3(1, 1, 1), SIMD3(1, 1, 0)]),
            (SIMD3(0, -1, 0), [SIMD3(0, 0, 1), SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 1)]),
            (SIMD3(0, 0, 1), [SIMD3(0, 1, 1), SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1)]),
            (SIMD3(0, 0, -1), [SIMD3(1, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 1, 0)]),
        ]
        let uvs: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0)]
        for (normal, corners) in faces {
            for index in [0, 1, 2, 0, 2, 3] {
                let p = corners[index], uv = uvs[index]
                data += [p.x, p.y, p.z, normal.x, normal.y, normal.z, uv.x, uv.y]
            }
        }
        glGenVertexArrays(1, &cubeVAO)
        glBindVertexArray(cubeVAO)
        glGenBuffers(1, &cubeVBO)
        glBindBuffer(GL_ARRAY_BUFFER, cubeVBO)
        data.withUnsafeBytes { raw in
            glBufferData(GL_ARRAY_BUFFER, raw.count, raw.baseAddress, GL_STATIC_DRAW)
        }
        glEnableVertexAttribArray(0)
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 32, nil)
        glEnableVertexAttribArray(1)
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 32, UnsafeRawPointer(bitPattern: 12))
        glEnableVertexAttribArray(2)
        glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, 32, UnsafeRawPointer(bitPattern: 24))
        glBindVertexArray(0)
    }

    /// One box of a model, ready to draw.
    struct Box {
        var transform: Matrix4
        var texture: GLTexture
        /// Per face, +X -X +Y -Y +Z -Z: (u0, v0, u1, v1) on `texture`.
        var faces: [SIMD4<Float>]
        var tint = SIMD4<Float>(1, 1, 1, 1)
    }

    func draw(
        session: GameSession,
        view: Matrix4,
        projection: Matrix4,
        lighting: BlockRenderer.Lighting,
        dt: Double,
        highlight: (x: Int, y: Int, z: Int)?,
        miningProgress: Double
    ) {
        let viewProjection = projection * view
        let boxes = models.boxes(for: session, dt: dt)

        glEnable(GL_DEPTH_TEST)
        glEnable(GL_CULL_FACE)
        program.use()
        program.set("uViewProjection", viewProjection)
        program.set("uView", view)
        program.set("uDaylight", lighting.daylight)
        program.set("uHorizon", lighting.horizon)
        program.set("uFogRange", lighting.fogRange)
        program.set("uTexture", Int32(0))
        program.set("uFlash", SIMD3<Float>(0.9, 0.12, 0.08))
        glBindVertexArray(cubeVAO)
        var bound: GLTexture?
        let rectLocation = program.location("uUVRect")
        for item in boxes {
            if bound !== item.box.texture {
                item.box.texture.bind(unit: 0)
                bound = item.box.texture
            }
            program.set("uModel", item.box.transform)
            program.set("uTint", item.box.tint)
            program.set("uFlashAmount", item.flash)
            var rects = item.box.faces
            rects.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: Float.self, capacity: 24) { floats in
                    glUniform4fv(rectLocation, 6, floats)
                }
            }
            glDrawArrays(GL_TRIANGLES, 0, 36)
        }
        glBindVertexArray(0)

        if let highlight { drawHighlight(highlight, progress: miningProgress, viewProjection: viewProjection, session: session) }
    }

    /// A thin dark outline round the targeted block, and the crack overlay
    /// over it while it is being mined.
    private func drawHighlight(_ cell: (x: Int, y: Int, z: Int), progress: Double, viewProjection: Matrix4, session: GameSession) {
        let e: Float = 0.002
        let lo = SIMD3<Float>(Float(cell.x) - e, Float(cell.y) - e, Float(cell.z) - e)
        let hi = SIMD3<Float>(Float(cell.x) + 1 + e, Float(cell.y) + 1 + e, Float(cell.z) + 1 + e)
        let c = [
            SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z), SIMD3(hi.x, lo.y, hi.z), SIMD3(lo.x, lo.y, hi.z),
            SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z), SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z),
        ]
        let edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
        var data: [Float] = []
        for (a, b) in edges { data += [c[a].x, c[a].y, c[a].z, c[b].x, c[b].y, c[b].z] }
        lineProgram.use()
        lineProgram.set("uViewProjection", viewProjection)
        lineProgram.set("uColor", SIMD4<Float>(0, 0, 0, 0.75))
        glEnable(GL_BLEND)
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        glBindVertexArray(lineVAO)
        glBindBuffer(GL_ARRAY_BUFFER, lineVBO)
        data.withUnsafeBytes { raw in glBufferData(GL_ARRAY_BUFFER, raw.count, raw.baseAddress, GL_STREAM_DRAW) }
        glDrawArrays(GL_LINES, 0, GLsizei(data.count / 3))
        glBindVertexArray(0)

        // The crack: the atlas's crack overlay, on every face, a hair
        // outside the block.
        guard progress > 0 else {
            glDisable(GL_BLEND)
            return
        }
        let stage = min(9, Int(progress * 10))
        let r = TextureAtlas.crackUVRect(stage: stage)
        let rect = SIMD4<Float>(r.u0, 1 - r.v0, r.u1, 1 - r.v1)
        let box = Box(
            transform: Matrix4.translation(lo) * Matrix4.scale(hi - lo),
            texture: atlas,
            faces: Array(repeating: rect, count: 6),
            tint: SIMD4(1, 1, 1, 1)
        )
        program.use()
        program.set("uModel", box.transform)
        program.set("uTint", SIMD4<Float>(1, 1, 1, 1))
        program.set("uFlashAmount", Float(0))
        atlas.bind(unit: 0)
        var rects = box.faces
        rects.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: Float.self, capacity: 24) { floats in
                glUniform4fv(program.location("uUVRect"), 6, floats)
            }
        }
        glPolygonOffsetFill(enabled: true)
        glBindVertexArray(cubeVAO)
        glDrawArrays(GL_TRIANGLES, 0, 36)
        glBindVertexArray(0)
        glPolygonOffsetFill(enabled: false)
        glDisable(GL_BLEND)
    }
}

/// Pulls a quad toward the camera in depth, so an overlay drawn exactly on
/// a surface wins the depth test against it.
private func glPolygonOffsetFill(enabled: Bool) {
    if enabled {
        glEnable(GL_POLYGON_OFFSET_FILL)
        glPolygonOffset(-1, -1)
    } else {
        glDisable(GL_POLYGON_OFFSET_FILL)
    }
}
#endif

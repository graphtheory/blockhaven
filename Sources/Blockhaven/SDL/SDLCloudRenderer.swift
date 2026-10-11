#if canImport(CSDL3)
import Foundation

/// The drifting cloud deck: `CloudLayer` and `CloudShaders.metal`'s
/// `cloudSurface`, in GL.
///
/// The geometry is `CloudMesh.field` itself, uploaded once; the drift and
/// re-centring are `CloudLayer.update`'s, the per-face grade is
/// `CloudLayer.regrade`'s and the shader is `cloudSurface` line for line.
/// Read those for why. Like every sky thing it writes no depth, so the god
/// rays' sky test still sees through it.
final class SDLCloudRenderer {
    private static let windSpeed: Double = 0.9
    private static let fadeRange = SIMD2<Float>(190, 330)
    private static let baseOpacity: Float = 0.86
    private static let nightThinning: Float = 0.4
    private static let sunsetTint = SIMD3<Float>(1.0, 0.58, 0.56)
    private static let nightTint = SIMD3<Float>(0.24, 0.30, 0.46)
    /// `CloudMesh.Face`'s brightness and warmth, top / side / bottom.
    private static let brightness = SIMD3<Float>(1.0, 0.79, 0.60)
    private static let warmth: [Float] = [0.5, 0.85, 1.0]

    private let program: GLProgram
    private var vao: GLuint = 0
    private var vbo: GLuint = 0
    private var ebo: GLuint = 0
    private var indexCount = 0
    private var drift: Double = 0

    private struct Vertex {
        var px, py, pz: Float
        var nx, ny, nz: Float
        var lift: Float
        var face: Float
    }

    init() {
        program = GLProgram(name: "clouds", vertex: """
            #version 330 core
            in vec3 aPosition;
            in vec3 aNormal;
            in float aLift;
            in float aFace;
            uniform mat4 uViewProjection;
            uniform mat4 uView;
            uniform vec3 uOffset;
            out vec3 vNormal;
            out float vLift;
            out float vDistance;
            flat out int vFace;
            void main() {
                vec3 world = aPosition + uOffset;
                vNormal = aNormal;
                vLift = aLift;
                vFace = int(aFace + 0.5);
                vDistance = length((uView * vec4(world, 1.0)).xyz);
                gl_Position = uViewProjection * vec4(world, 1.0);
            }
            """, fragment: """
            #version 330 core
            in vec3 vNormal;
            in float vLift;
            in float vDistance;
            flat in int vFace;
            uniform vec3 uTint[3];
            uniform vec3 uBrightness;
            uniform vec3 uHorizon;
            uniform vec3 uSunDirection;
            uniform vec2 uFadeRange;
            uniform float uOpacity;
            out vec4 fragColor;
            const vec3 kCloudSunGlow = vec3(1.0, 0.84, 0.58);
            const float kCloudSunGain = 0.34;
            const float kCloudShadeDrop = 0.14;
            const float kCloudRecedeHaze = 0.85;
            const float kCloudDepthShade = 0.30;
            void main() {
                float recede = smoothstep(uFadeRange.x, uFadeRange.y, vDistance);
                vec3 sunDirection = uSunDirection;
                float golden = 1.0 - abs(sunDirection.y);
                golden *= golden;
                float sunUp = smoothstep(-0.35, 0.0, sunDirection.y);
                vec3 normal = normalize(vNormal);
                float ndl = dot(normal, normalize(sunDirection));
                float lit = kCloudSunGain * sunUp * golden * max(0.0, ndl);
                float away = kCloudShadeDrop * sunUp * golden * max(0.0, -ndl);
                float depthShade = kCloudDepthShade * (1.0 - clamp(vLift, 0.0, 1.0));
                float faceBrightness = uBrightness[vFace];
                vec3 light = vec3(faceBrightness - away - depthShade)
                           + mix(vec3(1.0), kCloudSunGlow, golden) * lit;
                vec3 color = uTint[vFace] * max(vec3(0.0), light);
                color = mix(color, uHorizon, recede * kCloudRecedeHaze);
                fragColor = vec4(color, uOpacity * (1.0 - recede));
            }
            """, attributes: ["aPosition", "aNormal", "aLift", "aFace"])
        upload()
    }

    private func upload() {
        let field = CloudMesh.field
        var vertices: [Vertex] = []
        vertices.reserveCapacity(field.positions.count)
        for index in field.positions.indices {
            let p = field.positions[index], n = field.normals[index]
            let face: Float = n.y > 0.5 ? 0 : (n.y < -0.5 ? 2 : 1)
            vertices.append(Vertex(px: p.x, py: p.y, pz: p.z, nx: n.x, ny: n.y, nz: n.z,
                                   lift: field.uvs[index].x, face: face))
        }
        indexCount = field.indices.count

        glGenVertexArrays(1, &vao)
        glBindVertexArray(vao)
        glGenBuffers(1, &vbo)
        glBindBuffer(GL_ARRAY_BUFFER, vbo)
        vertices.withUnsafeBytes { raw in
            glBufferData(GL_ARRAY_BUFFER, raw.count, raw.baseAddress, GL_STATIC_DRAW)
        }
        glGenBuffers(1, &ebo)
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo)
        field.indices.withUnsafeBytes { raw in
            glBufferData(GL_ELEMENT_ARRAY_BUFFER, raw.count, raw.baseAddress, GL_STATIC_DRAW)
        }
        let stride = GLsizei(MemoryLayout<Vertex>.stride)
        func offset(_ path: PartialKeyPath<Vertex>) -> UnsafeRawPointer? {
            UnsafeRawPointer(bitPattern: MemoryLayout<Vertex>.offset(of: path)!)
        }
        glEnableVertexAttribArray(0)
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, stride, offset(\Vertex.px))
        glEnableVertexAttribArray(1)
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, stride, offset(\Vertex.nx))
        glEnableVertexAttribArray(2)
        glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, stride, offset(\Vertex.lift))
        glEnableVertexAttribArray(3)
        glVertexAttribPointer(3, 1, GL_FLOAT, GL_FALSE, stride, offset(\Vertex.face))
        glBindVertexArray(0)
    }

    /// Drifts, re-centres on the camera and draws, after the opaque world.
    /// `horizon` is linear; `sunDirection` is the world vector to the sun.
    func draw(view: Matrix4, projection: Matrix4, eye: SIMD3<Float>, horizonSRGB: SIMD3<Float>,
              sunDirection: SIMD3<Float>, dt: Double) {
        let period = Double(CloudMesh.tilePeriod)
        drift = (drift + dt * Self.windSpeed).truncatingRemainder(dividingBy: period)
        if drift < 0 { drift += period }
        let tile = CloudMesh.tilePeriod
        let shift = Float(drift)
        let offset = SIMD3<Float>(
            shift + tile * ((eye.x - shift) / tile).rounded(),
            0,
            tile * (eye.z / tile).rounded()
        )

        // `CloudLayer.regrade`, every frame: it is a handful of mixes.
        let low = powf(max(0, 1 - abs(sunDirection.y)), 2)
        let night = min(1, max(0, (-sunDirection.y - 0.05) / 0.55))
        let opacity = Self.baseOpacity * (1 - Self.nightThinning * night)

        glEnable(GL_DEPTH_TEST)
        glDepthMask(GL_FALSE)
        glEnable(GL_CULL_FACE)
        glEnable(GL_BLEND)
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        program.use()
        program.set("uViewProjection", projection * view)
        program.set("uView", view)
        program.set("uOffset", offset)
        for face in 0..<3 {
            var tint = blend(SIMD3(repeating: 1), Self.sunsetTint, low * Self.warmth[face])
            tint = blend(tint, Self.nightTint, night)
            program.set("uTint[\(face)]", linearFromSRGB(tint))
        }
        program.set("uBrightness", Self.brightness)
        program.set("uHorizon", linearFromSRGB(horizonSRGB))
        program.set("uSunDirection", sunDirection)
        program.set("uFadeRange", Self.fadeRange)
        program.set("uOpacity", opacity)
        glBindVertexArray(vao)
        glDrawElements(GL_TRIANGLES, GLsizei(indexCount), GL_UNSIGNED_INT, nil)
        glBindVertexArray(0)
        glDisable(GL_BLEND)
        glDepthMask(GL_TRUE)
    }

    private func blend(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * max(0, min(1, t))
    }
}
#endif

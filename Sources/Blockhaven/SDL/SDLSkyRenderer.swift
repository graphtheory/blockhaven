#if canImport(CSDL3)
import Foundation

/// The sky behind the world: the gradient, the sun and the moon, drawn as
/// one full-screen pass that evaluates the sky along every pixel's ray.
///
/// The gradient is `SkyEntities.gradientImage`'s rule — the same one the
/// block shader already evaluates for water reflections — so the sky, the
/// fog and the mirrored sky in a lake all agree.
final class SDLSkyRenderer {
    private let program: GLProgram
    private var vao: GLuint = 0

    /// The unit vector toward the sun — `SkyEntities.sunDirection`.
    static func sunDirection(timeOfDay: Double) -> SIMD3<Float> {
        let angle = Float((timeOfDay - 0.25) * 2 * .pi)
        return SIMD3(sin(angle), cos(angle), 0)
    }

    init() {
        program = GLProgram(
            name: "sky",
            vertex: """
            #version 330 core
            out vec2 vNDC;
            void main() {
                // One triangle that covers the screen, no buffer needed.
                vec2 corner = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
                vNDC = corner * 2.0 - 1.0;
                gl_Position = vec4(vNDC, 1.0, 1.0);
            }
            """,
            fragment: """
            #version 330 core
            in vec2 vNDC;
            uniform vec3 uRight;
            uniform vec3 uUp;
            uniform vec3 uForward;
            uniform vec2 uTanHalf;
            uniform vec3 uZenith;
            uniform vec3 uHorizon;
            uniform vec3 uSun;
            uniform float uLow;
            uniform float uNight;
            uniform float uBeacon;
            uniform float uLunar;
            out vec4 fragColor;

            const vec3 kSunGlow = vec3(1.0, 0.84, 0.58);

            float hash(vec3 p) {
                p = fract(p * 0.3183099 + 0.1);
                p *= 17.0;
                return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
            }

            void main() {
                vec3 dir = normalize(uForward + vNDC.x * uTanHalf.x * uRight + vNDC.y * uTanHalf.y * uUp);
                float above = clamp(asin(clamp(dir.y, 0.0, 1.0)) * (2.0 / 3.14159265), 0.0, 1.0);
                float lift = 1.0 - pow(1.0 - above, 2.2);
                vec3 band = mix(uHorizon, uZenith, lift);
                float hug = pow(1.0 - above, 3.0);
                vec2 sunFlat = uSun.xz;
                float toward = 0.0;
                float flatLength = length(dir.xz);
                if (length(sunFlat) > 1e-3 && flatLength > 1e-4) {
                    toward = max(0.0, dot(dir.xz / flatLength, normalize(sunFlat)));
                }
                float strength = min(1.0, pow(toward, 2.5) * hug * uLow * 0.7);
                vec3 color = mix(band, mix(uHorizon, kSunGlow, 0.5), strength);
                // Below the horizon the sky is the horizon: the fog wall the
                // terrain fades into.
                if (dir.y < 0.0) { color = uHorizon; }

                // Stars, faint, only once the night is in.
                if (uNight > 0.0 && dir.y > 0.0) {
                    vec3 cell = floor(dir * 180.0);
                    float star = step(0.9965, hash(cell));
                    color += vec3(star * uNight * 0.55 * smoothstep(0.0, 0.25, dir.y));
                }

                // The sun: a hot disc with a soft glow, warmer and bigger low.
                float sunCos = dot(dir, normalize(uSun));
                vec3 sunTint = mix(vec3(1.0, 1.0, 0.95), vec3(1.0, 0.83, 0.56), uLow);
                float disc = smoothstep(0.99935 - uLow * 0.0004, 0.99960 - uLow * 0.0004, sunCos);
                float glow = pow(max(0.0, sunCos), 220.0) * 0.55 + pow(max(0.0, sunCos), 24.0) * 0.18 * uLow;
                color += sunTint * (disc * 1.6 + glow) * smoothstep(-0.10, 0.02, uSun.y);

                // The moon, opposite the sun.
                float moonCos = dot(dir, -normalize(uSun));
                float moonDisc = smoothstep(0.99955, 0.99975, moonCos);
                float moonGlow = pow(max(0.0, moonCos), 400.0) * 0.25;
                vec3 moonTint = mix(vec3(0.86, 0.90, 1.0), vec3(0.42, 0.68, 1.0), uLunar);
                color += moonTint * (moonDisc * 0.95 + moonGlow) * smoothstep(-0.10, 0.02, -uSun.y);
                // The point of light on the other body: the garden asking,
                // seen from home, or home answering, seen from the Moon.
                vec3 beaconDir = normalize(-normalize(uSun) + vec3(0.0, 0.0105, 0.0));
                float beaconCos = dot(dir, beaconDir);
                color += vec3(1.0, 0.86, 0.45) * uBeacon * (smoothstep(0.999988, 0.999995, beaconCos) * 2.0
                    + pow(max(0.0, beaconCos), 30000.0) * 0.8);

                if (uLunar > 0.5) { color = max(color, vec3(0.0)); }
                fragColor = vec4(color, 1.0);
            }
            """
        )
        glGenVertexArrays(1, &vao)
    }

    func draw(view: Matrix4, projection: Matrix4, grade: SkyClock.Grade, timeOfDay: Double, eye: SIMD3<Float>, time: Float,
              beacon: Float = 0, lunar: Bool = false) {
        // The camera's basis is the rows of the view matrix's rotation.
        let c = view.columns
        let right = SIMD3(c.0.x, c.1.x, c.2.x)
        let up = SIMD3(c.0.y, c.1.y, c.2.y)
        let back = SIMD3(c.0.z, c.1.z, c.2.z)
        let p = projection.columns
        let tanHalf = SIMD2(1 / p.0.x, 1 / p.1.y)

        let sun = SDLSkyRenderer.sunDirection(timeOfDay: timeOfDay)
        let low = pow(max(0, 1 - abs(sun.y)), 2)
        let night = min(1, max(0, (-sun.y - 0.05) / 0.55))

        glDisable(GL_DEPTH_TEST)
        glDepthMask(GL_FALSE)
        glDisable(GL_CULL_FACE)
        glDisable(GL_BLEND)
        program.use()
        program.set("uRight", right)
        program.set("uUp", up)
        program.set("uForward", -back)
        program.set("uTanHalf", tanHalf)
        program.set("uZenith", linearFromSRGB(grade.zenith))
        program.set("uHorizon", linearFromSRGB(grade.horizon))
        program.set("uSun", sun)
        program.set("uLow", low)
        program.set("uNight", lunar ? 1 : night)
        program.set("uBeacon", beacon)
        program.set("uLunar", Float(lunar ? 1 : 0))
        glBindVertexArray(vao)
        glDrawArrays(GL_TRIANGLES, 0, 3)
        glBindVertexArray(0)
        glDepthMask(GL_TRUE)
        glEnable(GL_DEPTH_TEST)
    }
}
#endif

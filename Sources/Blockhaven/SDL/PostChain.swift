#if canImport(CSDL3)
import Foundation

/// `PostProcess.metal` and `PostProcessing.swift`, in GL: bloom, god rays,
/// the highlight shoulder and the vignette, then the sRGB encode.
///
/// The same passes, constants and order — read those files for why each one
/// is the way it is. What differs:
///   - fragment passes into small framebuffers instead of compute kernels;
///   - the blur is a separable Gaussian of our own instead of MPS's;
///   - depth is standard GL depth (1 = nothing drawn) rather than
///     RealityKit's reversed Z, so the sky test is `depth > kSkyDepth`;
///   - the scene arrives as half floats, and is clamped to 0…1 on the way
///     in: the Mac's grade was tuned on an 8-bit frame, and the thresholds
///     only mean the same thing on the same range.
final class PostChain {
    /// `PostProcessing.Tuning`'s defaults.
    struct Tuning {
        var threshold: Float = 0.52
        var knee: Float = 0.10
        var warmth: Float = 2.4
        var intensity: Float = 0.8
        var vignette: Float = 0.13
        var shoulder: Float = 0.72
        var sigma: Float = 3.4
        var rays: Float = 0.45
        var rayFalloff: Float = 0.30
        var rayDensity: Float = 0.96
        var rayDecay: Float = 0.972
        var rayPower: Float = 3.5
        var rayCore: Float = 0.075
    }

    /// Where the sun is this frame, worked out by the game screen.
    struct Sun {
        /// Unit vector toward the sun in camera space, -Z ahead.
        var viewDirection: SIMD3<Float>
        /// The sun's height in the world: 1 overhead, -1 at midnight.
        var elevation: Float
        var projection: Matrix4
    }

    private static let rayTint = SIMD3<Float>(1.00, 0.74, 0.44)
    private static let referenceWidth: Float = 1600

    /// `BLOCKHAVEN_POSTFX=0` skips everything but the encode, for comparing.
    static let isEnabled = ProcessInfo.processInfo.environment["BLOCKHAVEN_POSTFX"] != "0"

    let tuning = Tuning()
    private let bright: GLProgram
    private let blur: GLProgram
    private let rayMask: GLProgram
    private let rays: GLProgram
    private let composite: GLProgram
    private var vertexArray: GLuint = 0

    private var quarter = [Target(), Target()]
    private var bloomOut = Target()
    private var eighth = [Target(), Target()]
    private var width = 0, height = 0

    /// One colour texture and the framebuffer that draws into it.
    private struct Target {
        var framebuffer: GLuint = 0
        var texture: GLuint = 0
        var width = 0, height = 0
    }

    private static let fullScreen = """
        #version 330 core
        out vec2 vUV;
        void main() {
            vec2 corner = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
            vUV = corner;
            gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
        }
        """

    init() {
        bright = GLProgram(name: "post.bright", vertex: Self.fullScreen, fragment: """
            #version 330 core
            in vec2 vUV;
            uniform sampler2D uScene;
            uniform vec2 uSourceTexel;
            uniform vec3 uParams; // threshold, knee, warmth
            out vec4 fragColor;
            vec3 brightOnly(vec3 color) {
                float threshold = uParams.x, knee = uParams.y, warmth = uParams.z;
                float level = max(color.r, max(color.g, color.b));
                float soft = clamp(level - threshold + knee, 0.0, 2.0 * knee);
                soft = soft * soft / (4.0 * knee + 1e-4);
                float weight = max(soft, level - threshold) / max(level, 1e-4);
                float warm = 1.0 + warmth * clamp((color.r - color.b) * 2.0, 0.0, 1.0);
                return color * max(0.0, weight) * warm;
            }
            vec3 tap(vec2 offset) {
                return brightOnly(clamp(texture(uScene, vUV + uSourceTexel * offset).rgb, 0.0, 1.0));
            }
            void main() {
                vec3 sum = tap(vec2(-1, -1)) + tap(vec2(1, -1)) + tap(vec2(-1, 1)) + tap(vec2(1, 1));
                fragColor = vec4(sum * 0.25, 1.0);
            }
            """)
        blur = GLProgram(name: "post.blur", vertex: Self.fullScreen, fragment: """
            #version 330 core
            in vec2 vUV;
            uniform sampler2D uSource;
            uniform vec2 uStep;   // one texel along the blur's axis
            uniform float uSigma;
            out vec4 fragColor;
            void main() {
                int radius = int(ceil(uSigma * 3.0));
                float twoSigma2 = 2.0 * uSigma * uSigma;
                vec3 sum = texture(uSource, vUV).rgb;
                float total = 1.0;
                for (int i = 1; i <= radius; ++i) {
                    float w = exp(-float(i * i) / twoSigma2);
                    sum += (texture(uSource, vUV + uStep * float(i)).rgb
                          + texture(uSource, vUV - uStep * float(i)).rgb) * w;
                    total += 2.0 * w;
                }
                fragColor = vec4(sum / total, 1.0);
            }
            """)
        rayMask = GLProgram(name: "post.raymask", vertex: Self.fullScreen, fragment: """
            #version 330 core
            in vec2 vUV;
            uniform sampler2D uDepth;
            uniform vec2 uBlock;  // one mask texel, in full-frame uv
            uniform vec3 uSun;    // u, v, aspect
            uniform float uFalloff;
            out vec4 fragColor;
            const float kSkyDepth = 0.99999;
            void main() {
                vec2 base = vUV - uBlock * 0.5;
                float sky = 0.0;
                for (int i = 0; i < 4; ++i) {
                    vec2 offset = vec2((i & 1) != 0 ? 0.72 : 0.28, (i & 2) != 0 ? 0.72 : 0.28) * uBlock;
                    sky += texture(uDepth, base + offset).r > kSkyDepth ? 0.25 : 0.0;
                }
                vec2 toSun = vec2((vUV.x - uSun.x) * uSun.z, vUV.y - uSun.y);
                float near = exp(-dot(toSun, toSun) / (2.0 * uFalloff * uFalloff));
                fragColor = vec4(sky * near, 0.0, 0.0, 1.0);
            }
            """)
        rays = GLProgram(name: "post.rays", vertex: Self.fullScreen, fragment: """
            #version 330 core
            in vec2 vUV;
            uniform sampler2D uMask;
            uniform vec2 uSunUV;
            uniform vec3 uMarch; // density, decay, power
            out vec4 fragColor;
            const int kSamples = 40;
            void main() {
                vec2 advance = (uSunUV - vUV) * (uMarch.x / float(kSamples));
                vec2 walk = vUV;
                float illumination = 1.0;
                float sum = 0.0;
                for (int i = 0; i < kSamples; ++i) {
                    walk += advance;
                    // Off the frame reads as zero, as Metal's clamp_to_zero.
                    bool inside = all(greaterThanEqual(walk, vec2(0.0))) && all(lessThanEqual(walk, vec2(1.0)));
                    sum += (inside ? texture(uMask, walk).r : 0.0) * illumination;
                    illumination *= uMarch.y;
                }
                float ceiling = float(kSamples);
                if (uMarch.y < 0.9999) {
                    ceiling = (1.0 - pow(uMarch.y, float(kSamples))) / (1.0 - uMarch.y);
                }
                float value = clamp(sum / max(ceiling, 1e-4), 0.0, 1.0);
                fragColor = vec4(pow(value, uMarch.z), 0.0, 0.0, 1.0);
            }
            """)
        composite = GLProgram(name: "post.composite", vertex: Self.fullScreen, fragment: """
            #version 330 core
            in vec2 vUV;
            uniform sampler2D uScene;
            uniform sampler2D uBloom;
            uniform sampler2D uRays;
            uniform vec3 uGrade;     // intensity, vignette, shoulder
            uniform float uRayStrength;
            uniform vec3 uRayTint;
            uniform vec3 uSun;       // u, v, aspect
            uniform vec2 uCore;      // inner, outer
            uniform int uEffects;
            out vec4 fragColor;
            vec3 shoulderTonemap(vec3 color, float shoulder) {
                float headroom = max(1.0 - shoulder, 1e-3);
                vec3 over = max(color - shoulder, 0.0);
                return min(color, vec3(shoulder)) + headroom * (1.0 - exp(-over / headroom));
            }
            vec3 encodeSRGB(vec3 linear) {
                linear = clamp(linear, 0.0, 1.0);
                vec3 low = linear * 12.92;
                vec3 high = 1.055 * pow(linear, vec3(1.0 / 2.4)) - 0.055;
                return mix(low, high, step(vec3(0.0031308), linear));
            }
            void main() {
                vec3 color = clamp(texture(uScene, vUV).rgb, 0.0, 1.0);
                if (uEffects != 0) {
                    color += texture(uBloom, vUV).rgb * uGrade.x;
                    if (uRayStrength > 0.0) {
                        vec2 toSun = vec2((vUV.x - uSun.x) * uSun.z, vUV.y - uSun.y);
                        float core = smoothstep(uCore.x, uCore.y, length(toSun));
                        color += uRayTint * texture(uRays, vUV).r * uRayStrength * core;
                    }
                    vec2 offset = vUV - 0.5;
                    float radius = dot(offset, offset) * 4.0;
                    float falloff = clamp((radius - 0.45) / 1.55, 0.0, 1.0);
                    color *= 1.0 - uGrade.y * falloff * falloff;
                    color = shoulderTonemap(color, uGrade.z);
                }
                fragColor = vec4(encodeSRGB(color), 1.0);
            }
            """)
        glGenVertexArrays(1, &vertexArray)
    }

    /// Runs the chain from the resolved scene into the window.
    func run(scene: GLuint, depth: GLuint, width: Int, height: Int, sun: Sun?) {
        if width != self.width || height != self.height { rebuild(width: width, height: height) }
        glDisable(GL_DEPTH_TEST)
        glDisable(GL_BLEND)
        glDisable(GL_CULL_FACE)
        glBindVertexArray(vertexArray)

        let placement = Self.isEnabled ? rayPlacement(sun, width: width, height: height) : nil
        if Self.isEnabled {
            // 1. Bright pass, a quarter size on each axis.
            draw(into: quarter[0], bright) { p in
                bind(scene, unit: 0); p.set("uScene", Int32(0))
                p.set("uSourceTexel", SIMD2(1 / Float(width), 1 / Float(height)))
                p.set("uParams", SIMD3(tuning.threshold, tuning.knee, tuning.warmth))
            }
            // 2. Separable Gaussian, scaled with the frame like the Mac's.
            let sigma = tuning.sigma * Float(width) / Self.referenceWidth
            let q = quarter[0]
            draw(into: quarter[1], blur) { p in
                bind(q.texture, unit: 0); p.set("uSource", Int32(0))
                p.set("uStep", SIMD2(1 / Float(q.width), 0)); p.set("uSigma", sigma)
            }
            draw(into: bloomOut, blur) { [quarter] p in
                bind(quarter[1].texture, unit: 0); p.set("uSource", Int32(0))
                p.set("uStep", SIMD2(0, 1 / Float(q.height))); p.set("uSigma", sigma)
            }
            // 3. God rays, an eighth size, when the sun calls for them.
            if let placement {
                let mask = eighth[0]
                draw(into: mask, rayMask) { p in
                    bind(depth, unit: 0); p.set("uDepth", Int32(0))
                    p.set("uBlock", SIMD2(1 / Float(mask.width), 1 / Float(mask.height)))
                    p.set("uSun", SIMD3(placement.u, placement.v, placement.aspect))
                    p.set("uFalloff", tuning.rayFalloff)
                }
                draw(into: eighth[1], rays) { p in
                    bind(mask.texture, unit: 0); p.set("uMask", Int32(0))
                    p.set("uSunUV", SIMD2(placement.u, placement.v))
                    p.set("uMarch", SIMD3(tuning.rayDensity, tuning.rayDecay, tuning.rayPower))
                }
            }
        }

        // 4. Composite into the window.
        glBindFramebuffer(GL_FRAMEBUFFER, 0)
        glViewport(0, 0, GLsizei(width), GLsizei(height))
        composite.use()
        bind(scene, unit: 0); composite.set("uScene", Int32(0))
        bind(bloomOut.texture, unit: 1); composite.set("uBloom", Int32(1))
        bind(eighth[1].texture, unit: 2); composite.set("uRays", Int32(2))
        composite.set("uEffects", Int32(Self.isEnabled ? 1 : 0))
        composite.set("uGrade", SIMD3(tuning.intensity, tuning.vignette, tuning.shoulder))
        composite.set("uRayStrength", placement?.strength ?? 0)
        composite.set("uRayTint", Self.rayTint)
        composite.set("uSun", SIMD3(placement?.u ?? 0.5, placement?.v ?? 0.5, placement?.aspect ?? 1))
        composite.set("uCore", SIMD2(tuning.rayCore * 0.25, tuning.rayCore))
        glDrawArrays(GL_TRIANGLES, 0, 3)
        glBindVertexArray(0)
        glActiveTexture(GL_TEXTURE0)
    }

    private struct RayPlacement {
        var u: Float, v: Float, strength: Float, aspect: Float
    }

    /// `PostProcessing.rayPlacement`, with GL's uv: v runs up, as clip y does.
    private func rayPlacement(_ sun: Sun?, width: Int, height: Int) -> RayPlacement? {
        guard tuning.rays > 0, let sun else { return nil }
        let above = Self.smoothRamp(-0.22, 0.02, sun.elevation)
        let low = powf(max(0, 1 - sun.elevation), 1.6)
        var strength = tuning.rays * above * low
        guard strength > 0.002 else { return nil }
        let clip = sun.projection * SIMD4<Float>(sun.viewDirection, 0)
        guard clip.w > 1e-4 else { return nil }
        let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w
        strength *= 1 - Self.smoothRamp(1.0, 2.0, max(abs(ndc.x), abs(ndc.y)))
        guard strength > 0.002 else { return nil }
        return RayPlacement(u: ndc.x * 0.5 + 0.5, v: ndc.y * 0.5 + 0.5,
                            strength: strength, aspect: Float(width) / Float(max(1, height)))
    }

    private static func smoothRamp(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private func draw(into target: Target, _ program: GLProgram, _ setup: (GLProgram) -> Void) {
        glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer)
        glViewport(0, 0, GLsizei(target.width), GLsizei(target.height))
        program.use()
        setup(program)
        glDrawArrays(GL_TRIANGLES, 0, 3)
    }

    private func bind(_ texture: GLuint, unit: Int) {
        glActiveTexture(GL_TEXTURE0 + GLenum(unit))
        glBindTexture(GL_TEXTURE_2D, texture)
    }

    private func rebuild(width: Int, height: Int) {
        release()
        self.width = width
        self.height = height
        let qw = max(1, width / 4), qh = max(1, height / 4)
        let ew = max(1, width / 8), eh = max(1, height / 8)
        quarter = [Self.makeTarget(qw, qh), Self.makeTarget(qw, qh)]
        bloomOut = Self.makeTarget(qw, qh)
        eighth = [Self.makeTarget(ew, eh), Self.makeTarget(ew, eh)]
    }

    private static func makeTarget(_ width: Int, _ height: Int) -> Target {
        var target = Target(width: width, height: height)
        glGenTextures(1, &target.texture)
        glBindTexture(GL_TEXTURE_2D, target.texture)
        glTexImage2D(GL_TEXTURE_2D, 0, GLint(GL_RGBA16F), GLsizei(width), GLsizei(height), 0, GL_RGBA, GL_FLOAT, nil)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
        glGenFramebuffers(1, &target.framebuffer)
        glBindFramebuffer(GL_FRAMEBUFFER, target.framebuffer)
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, target.texture, 0)
        glClearColor(0, 0, 0, 1)
        glClear(GL_COLOR_BUFFER_BIT)
        glBindFramebuffer(GL_FRAMEBUFFER, 0)
        return target
    }

    private func release() {
        for var target in quarter + [bloomOut] + eighth where target.framebuffer != 0 {
            glDeleteFramebuffers(1, &target.framebuffer)
            glDeleteTextures(1, &target.texture)
        }
        quarter = [Target(), Target()]
        bloomOut = Target()
        eighth = [Target(), Target()]
    }

    deinit { release() }
}
#endif

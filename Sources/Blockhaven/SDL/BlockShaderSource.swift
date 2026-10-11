/// `BlockShaders.metal`'s `blockSurface`, in GLSL 3.30.
///
/// The same rules, constants and order of operations — read that file for
/// why each one is the way it is; the comments here only mark where GLSL
/// had to say something differently. The parameters the Metal shader dug
/// out of borrowed material slots arrive here as plain uniforms.
enum BlockShaderSource {
    static let vertex = """
    #version 330 core
    in vec3 aPosition;
    in vec3 aNormal;
    in vec2 aUV;
    in vec4 aShade;

    uniform mat4 uViewProjection;
    uniform mat4 uView;
    uniform vec3 uChunkOrigin;

    out vec3 vWorld;
    out vec3 vNormal;
    out vec2 vUV;
    out vec4 vShade;
    out float vDistance;

    void main() {
        vec3 world = aPosition + uChunkOrigin;
        vWorld = world;
        vNormal = aNormal;
        vUV = aUV;
        vShade = aShade;
        vDistance = length((uView * vec4(world, 1.0)).xyz);
        gl_Position = uViewProjection * vec4(world, 1.0);
    }
    """

    static let fragment = """
    #version 330 core
    in vec3 vWorld;
    in vec3 vNormal;
    in vec2 vUV;
    in vec4 vShade;
    in float vDistance;

    uniform sampler2D uAtlas;
    uniform vec3 uDaylight;
    uniform vec3 uHorizon;
    uniform vec3 uZenith;
    uniform vec3 uSunDirection;
    uniform vec2 uFogRange;
    uniform vec3 uEye;
    uniform float uTime;
    uniform int uTranslucentPass;

    out vec4 fragColor;

    const float kSeaLevel = 62.0;
    const float kFogScaleHeight = 30.0;
    const float kFogHighAltitude = 0.68;
    const float kFogCurve = 3.0;
    const vec3 kSunGlow = vec3(1.0, 0.84, 0.58);
    const float kSunGlowStrength = 0.7;
    const float kVertexShadeScale = 1.6;

    const float kSunGain = 0.46;
    const float kSkyLift = 0.30;
    const float kShadeDrop = 0.34;
    const float kMoonGain = 0.09;
    const vec3 kSunWarm = vec3(1.00, 0.72, 0.40);
    const vec3 kShadeCool = vec3(0.74, 0.80, 1.06);
    const float kShadeCoolStrength = 0.50;
    const vec3 kTorchColor = vec3(1.00, 0.62, 0.29);
    const float kTorchStrength = 1.45;
    const vec3 kLuminance = vec3(0.299, 0.587, 0.114);
    const float kTorchMaxBoost = 4.0;
    const vec3 kMoonLight = vec3(0.62, 0.74, 1.00);
    const vec3 kCanopyShade = vec3(0.52, 0.57, 0.68);

    const float kWaterF0 = 0.02;
    const float kFresnelPower = 2.4;
    const float kMirrorOpacity = 0.95;
    const float kWaveSlope = 0.038;
    const float kWaveDistance = 46.0;
    const vec3 kWaterDeep = vec3(0.74, 0.85, 1.0);

    float bakedFaceTint(vec3 normal) {
        if (normal.y > 0.5) { return 1.00; }
        if (normal.y < -0.5) { return 0.60; }
        if (abs(normal.x) > 0.5) { return 0.76; }
        return 0.88;
    }

    vec3 skyAlong(vec3 direction, vec3 horizon, vec3 zenith, vec2 sunFlat, float sunFlatLength, float glowStrength) {
        float above = clamp(asin(clamp(direction.y, 0.0, 1.0)) * (2.0 / 3.14159265), 0.0, 1.0);
        float lift = 1.0 - pow(1.0 - above, 2.2);
        vec3 band = mix(horizon, zenith, lift);
        float hug = pow(1.0 - above, 3.0);
        vec2 flat2 = direction.xz;
        float flatLength = length(flat2);
        float toward = 0.0;
        if (sunFlatLength > 1e-3 && flatLength > 1e-4) {
            toward = max(0.0, dot(flat2 / flatLength, sunFlat / sunFlatLength));
        }
        float strength = min(1.0, pow(toward, 2.5) * hug * glowStrength);
        return mix(band, mix(horizon, kSunGlow, 0.5), strength);
    }

    void main() {
        // The mesher's v runs bottom-up, as RealityKit wants; the atlas is
        // uploaded top row first, so the sample flips it exactly as the
        // Metal shader does.
        vec4 texel = texture(uAtlas, vec2(vUV.x, 1.0 - vUV.y));
        float vertexShade = vShade.r * kVertexShadeScale;
        bool translucentPass = uTranslucentPass != 0;

        if (!translucentPass && texel.a < 0.5) { discard; }

        bool isWater = translucentPass && vShade.b > 0.5;
        float shade = isWater ? mix(vertexShade, 1.0, 0.85) : vertexShade;
        vec3 color = texel.rgb * uDaylight * shade;

        vec3 sunDirection = uSunDirection;
        float golden = 1.0 - abs(sunDirection.y);
        golden *= golden;

        // Two-sided faces: unlike RealityKit, GL hands over the normal the
        // mesher wrote whichever side is seen. The Metal shader relies on
        // that normal having been turned toward the eye, so this does it.
        vec3 surfaceNormal = normalize(vNormal);
        if (!gl_FrontFacing) { surfaceNormal = -surfaceNormal; }

        float graded = dot(uDaylight, kLuminance);
        float lampBoost = min(1.0 / max(graded, 0.04), kTorchMaxBoost);

        if (!translucentPass) {
            float baked = bakedFaceTint(surfaceNormal);
            vec3 sunUnit = normalize(sunDirection);
            float ndl = dot(surfaceNormal, sunUnit);
            float sunUp = smoothstep(-0.35, 0.0, sunDirection.y);

            float lit = kSunGain * sunUp * max(0.0, ndl);
            float dim = kSunGain * sunUp * max(0.0, surfaceNormal.y);
            float lift = kSkyLift * sunUp * golden * max(0.0, surfaceNormal.y);
            float away = kShadeDrop * sunUp * golden * max(0.0, -ndl);
            float moon = kMoonGain * (1.0 - sunUp) * max(0.0, -ndl);

            vec3 warmLight = mix(vec3(1.0), kSunWarm, golden);
            vec3 ambientTint = mix(vec3(1.0), kShadeCool, golden * sunUp * kShadeCoolStrength);
            float ambient = max(0.05, baked - dim + lift - away);
            vec3 light = ambientTint * ambient + warmLight * lit + kMoonLight * moon;

            float openness = vShade.g;
            light *= mix(vec3(1.0), kCanopyShade, 1.0 - openness);

            float torch = vShade.a;
            light += kTorchColor * (torch * torch) * kTorchStrength * lampBoost;
            if (torch > 0.995) {
                light = max(light, vec3(baked / max(graded, 0.04)));
            }
            color *= light * (1.0 / baked);
        } else if (!isWater) {
            float torch = vShade.a;
            color += texel.rgb * (torch * torch * kTorchStrength * lampBoost);
        }

        vec3 toEye = normalize(uEye - vWorld);
        float distance = vDistance;
        float fog = clamp((distance - uFogRange.x) / max(1.0, uFogRange.y - uFogRange.x), 0.0, 1.0);
        fog = pow(fog, kFogCurve);
        float aboveSea = max(0.0, vWorld.y - kSeaLevel);
        fog *= mix(1.0, kFogHighAltitude, 1.0 - exp2(-aboveSea / kFogScaleHeight));

        vec3 horizonColor = uHorizon;
        vec2 sunFlat = sunDirection.xz;
        float sunFlatLength = length(sunFlat);
        vec2 awayFlat = -toEye.xz;
        float awayLength = length(awayFlat);
        float toward = 0.0;
        if (sunFlatLength > 1e-3 && awayLength > 1e-4) {
            toward = max(0.0, dot(awayFlat / awayLength, sunFlat / sunFlatLength));
        }
        float warmth = pow(toward, 2.5) * golden * kSunGlowStrength;
        vec3 fogColor = mix(horizonColor, mix(horizonColor, kSunGlow, 0.5), warmth);

        float opacity = texel.a;

        if (isWater) {
            float t = uTime;
            float phaseX = vWorld.x * 1.15 + t * 1.6;
            float phaseZ = vWorld.z * 0.95 - t * 1.25;
            float swell = 0.5 * (sin(phaseX) + sin(phaseZ));
            float calm = 1.0 - fog;
            swell *= calm;
            color *= kWaterDeep * (1.0 + 0.10 * swell);

            bool horizontal = abs(surfaceNormal.y) > 0.5;
            bool fromAbove = horizontal && toEye.y > 0.0;

            vec3 waveNormal = surfaceNormal;
            if (horizontal) {
                float tilt = kWaveSlope * calm * clamp(1.0 - distance / kWaveDistance, 0.0, 1.0);
                vec3 lifted = vec3(-tilt * cos(phaseX), 1.0, -tilt * cos(phaseZ));
                waveNormal = normalize(surfaceNormal.y < 0.0 ? -lifted : lifted);
            }

            float facing = clamp(dot(waveNormal, toEye), 0.0, 1.0);
            float fresnel = kWaterF0 + (1.0 - kWaterF0) * pow(1.0 - facing, kFresnelPower);

            if (fromAbove) {
                vec3 mirrored = reflect(-toEye, waveNormal);
                vec3 reflection = skyAlong(mirrored, horizonColor, uZenith, sunFlat, sunFlatLength, golden * kSunGlowStrength);

                float sunUp = smoothstep(-0.12, 0.06, sunDirection.y);
                if (sunUp > 0.0) {
                    vec3 sunUnit = normalize(sunDirection);
                    vec3 offset = mirrored - sunUnit;
                    float vertical = offset.y;
                    float across = max(0.0, dot(offset, offset) - vertical * vertical);
                    float core = exp2(-(across * 900.0 + vertical * vertical * 40.0));
                    float halo = exp2(-(across * 26.0 + vertical * vertical * 6.0));
                    float streak = core + 0.42 * halo;

                    vec2 alongSun = sunFlatLength > 1e-3 ? sunFlat / sunFlatLength : vec2(1.0, 0.0);
                    vec2 acrossSun = vec2(-alongSun.y, alongSun.x);
                    vec2 cell = vec2(dot(vWorld.xz, alongSun) * 2.4, dot(vWorld.xz, acrossSun) * 5.2);
                    float sparkle = sin(cell.x * 1.7 + t * 0.9)
                                  * sin(cell.y * 2.3 - t * 1.1)
                                  * sin((cell.x + cell.y) * 1.13 + t * 0.55);
                    sparkle = smoothstep(0.42, 0.90, sparkle);
                    float near = clamp(1.0 - distance / 58.0, 0.0, 1.0);
                    streak *= mix(1.0, 0.35 + 0.95 * sparkle, near);

                    vec3 sunColor = mix(vec3(1.0, 0.98, 0.92), kSunGlow, golden);
                    reflection += sunColor * (streak * sunUp * calm);
                }
                color = mix(color, reflection * 0.94, fresnel);
            }

            opacity = clamp(opacity * (1.0 + 0.18 * swell), 0.0, 1.0);
            opacity += fresnel * kMirrorOpacity * (1.0 - opacity);
            opacity = clamp(opacity, 0.0, 1.0);
        }

        fragColor = vec4(mix(color, fogColor, fog), opacity);
    }
    """
}

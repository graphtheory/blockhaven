#include <metal_stdlib>

using namespace metal;

/// Screen-space post-processing: bloom, crepuscular rays, a filmic shoulder
/// and a vignette.
///
/// These are compute kernels driven from `Rendering/PostProcessing.swift`
/// through `ARView.renderCallbacks.postProcess`, not RealityKit surface
/// shaders — so unlike `blockSurface` they need no `[[visible]]` attribute
/// and are looked up by name with `makeComputePipelineState`. They still
/// live in the same `default.metallib`, because a bundle gets exactly one
/// default library and RealityKit insists the block shader come from it.
///
/// Everything here works in linear light. `sourceColorTexture` arrives as
/// `bgra8Unorm_srgb` (measured — see the `[postfx]` line the Swift side
/// logs), so Metal decodes sRGB on every read and re-encodes on every write
/// and these kernels never have to think about gamma. Linear is also the
/// right space to threshold in: it pushes midtones down and leaves lights
/// near the top, so "the sun" and "lit grass" sit far apart on the scale
/// where in display-encoded values they do not.

// MARK: - Parameters

/// Bright-pass shape. `threshold` is where bloom starts, in max-channel
/// linear intensity; `knee` is the half width of the soft ramp around it,
/// so a pixel just under the line fades in instead of popping; `warmth` is
/// how much harder warm light blooms than cool.
struct BrightParams {
    float threshold;
    float knee;
    float warmth;
};

/// Everything the final pass needs.
struct CompositeParams {
    /// How much of the blurred bright pass is added back.
    float intensity;
    /// Corner darkening, 0…1. A whisper; this is not a lens effect.
    float vignette;
    /// Where the highlight roll-off begins. Below this the tonemap is the
    /// identity, so ordinary daylight is passed through byte for byte.
    float shoulder;
    /// How much of the god-ray buffer is added back. Zero switches the
    /// whole effect off — which is what noon, night and an off-screen sun
    /// all reduce to, and the Swift side skips the two ray dispatches
    /// entirely when it is going to pass zero.
    float rayStrength;
    float rayTintR;
    float rayTintG;
    float rayTintB;
    /// Where the sun is, in this frame's own uv.
    float sunU;
    float sunV;
    /// Frame width over height, so a "distance from the sun" in uv is a
    /// round distance rather than an ellipse.
    float aspect;
    /// The soft hole punched in the ray add around the sun's own disc.
    /// Bloom already owns that pixel; the rays converging on it as well
    /// stack two glows on one spot and blow it to flat white.
    float coreInner;
    float coreOuter;
};

/// Shape of the god-ray source mask and of the march that smears it.
struct GodRayParams {
    float sunU;
    float sunV;
    float aspect;
    /// Standard deviation, in aspect-corrected uv, of the glow around the
    /// sun that the rays are made of. Without it every patch of sky in the
    /// frame emits and the whole sky turns into a fan.
    float falloff;
    /// What fraction of the distance to the sun one march covers. Just
    /// under 1, so the last tap stops short of the sun's own texel.
    float density;
    /// Per-tap attenuation along the march — this is what makes a shaft
    /// fade out as it gets further from the sun.
    float decay;
    /// Contrast curve on the finished, normalised march. A small occluder
    /// near the sun only takes a few of the forty taps away, so a clear ray
    /// and a partly blocked one come out of the sum a few percent apart and
    /// the beams are invisible. Raising the whole thing to a power pulls
    /// those apart: at 3, 1.00 and 0.90 become 1.00 and 0.73.
    float power;
};

constexpr sampler kLinearClamp(coord::normalized, address::clamp_to_edge, filter::linear);

/// Reads outside the image come back as zero rather than as a smeared edge
/// texel — the god-ray march walks off the frame whenever the sun is near
/// or past an edge, and `clamp_to_edge` would drag that edge row all the
/// way across the screen.
constexpr sampler kLinearZero(coord::normalized, address::clamp_to_zero, filter::linear);

/// Depth below which a pixel counts as sky.
///
/// Measured, not assumed (`BLOCKHAVEN_POSTFX_DUMP_DEPTH=1` dumps the buffer
/// and prints its range): RealityKit hands over a **reversed-Z**
/// `depth32Float` buffer — 1 at the near plane, 0 at the far one, and the
/// value for a fragment `z` blocks away is `near·far/((far−near)·z) −
/// near/(far−near)`, which for this camera's 0.08 and 400 is
/// `0.0800/z − 0.0002`. So bigger means nearer, and *nothing drawn at all*
/// is exactly 0.
///
/// 2e-5 is everything past 364 blocks — beyond the render distance in every
/// direction, so in practice this says "no terrain was drawn here". It can
/// say that only because nothing in the sky writes depth: see the note at
/// the top of SkyEntities.swift, where the cloud dome, the sun and the moon
/// were all taken out of the depth buffer for exactly this reason.
constant float kSkyDepth = 2e-5;

/// Taps along one god ray. A compile-time constant so the loop unrolls, and
/// the whole march is one dispatch rather than a chain of ping-ponged
/// half-length blurs.
constant int kGodRaySamples = 40;

// MARK: - Bright pass

/// Keeps only what is brighter than the threshold, with a soft knee, and
/// lets warm light through harder than cool.
///
/// The brightness test uses the strongest channel rather than luminance: a
/// saturated gold sun low in the sky has a modest luminance and a red
/// channel at the ceiling, and it is the thing in the frame that most needs
/// to bloom.
///
/// The warm bias is not physics — real bloom does not care what colour the
/// light is — and it is here because of a hard measurement: whatever
/// RealityKit hands to `postProcess` has already been flattened into an
/// 8-bit sRGB texture, and nothing in this game's frames ever gets past
/// about 0.69 in linear intensity. There is no headroom, so a golden-hour
/// horizon (0.60) and a midday blue sky (0.66) are *the same brightness*,
/// and no threshold on its own can bloom one and spare the other. Hue can:
/// the horizon at dusk is deep in the red, the midday sky is deep in the
/// blue, and `r - b` separates them cleanly. Lit grass sits far below the
/// threshold either way and never blooms at all.
static inline float3 brightOnly(float3 color, float threshold, float knee, float warmth) {
    float level = max(color.r, max(color.g, color.b));
    float soft = clamp(level - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float weight = max(soft, level - threshold) / max(level, 1e-4);
    float warm = 1.0 + warmth * saturate((color.r - color.b) * 2.0);
    return color * max(0.0, weight) * warm;
}

/// Bright-pass and downsample in one dispatch.
///
/// The destination is a quarter size on each axis, and each output pixel is
/// an exact 4x4 box average of the source — taken as four bilinear samples
/// sitting at the centres of the four 2x2 quads, so the whole 16-texel
/// footprint costs four fetches. Thresholding happens per tap rather than on
/// the average, which keeps a small, very bright thing (the sun's disc
/// against the sky) from being averaged down below the line before it is
/// ever tested.
kernel void postBrightPass(texture2d<float, access::sample> source [[texture(0)]],
                           texture2d<float, access::write> bright [[texture(1)]],
                           constant BrightParams &params [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint width = bright.get_width();
    uint height = bright.get_height();
    if (gid.x >= width || gid.y >= height) { return; }

    float2 centre = (float2(gid) + 0.5) / float2(width, height);
    float2 texel = 1.0 / float2(source.get_width(), source.get_height());

    float3 sum = brightOnly(source.sample(kLinearClamp, centre + texel * float2(-1, -1)).rgb,
                            params.threshold, params.knee, params.warmth);
    sum += brightOnly(source.sample(kLinearClamp, centre + texel * float2(1, -1)).rgb,
                      params.threshold, params.knee, params.warmth);
    sum += brightOnly(source.sample(kLinearClamp, centre + texel * float2(-1, 1)).rgb,
                      params.threshold, params.knee, params.warmth);
    sum += brightOnly(source.sample(kLinearClamp, centre + texel * float2(1, 1)).rgb,
                      params.threshold, params.knee, params.warmth);

    bright.write(float4(sum * 0.25, 1.0), gid);
}

// MARK: - God rays

/// What the rays are made of: how much of the sky around the sun this pixel
/// can see.
///
/// One value per eighth-size pixel, and — deliberately — **not a function of
/// what colour the frame is there**. The obvious mask is "bright sky near
/// the sun", and it was tried first; it does not work in this game, and the
/// reason is the same ceiling every threshold in this file is built around.
/// Measured off a golden-hour frame: the sun's own glow peaks at 0.638 in
/// linear intensity, the sky a hundred pixels beside it is 0.58, and open
/// sky across the frame is 0.47. The light source is *ten percent* brighter
/// than its background. A god-ray pass in a game with real HDR gets a sun
/// fifty times brighter than the sky, which is exactly why an occluder
/// crossing it removes almost all the light and the beams read; here the
/// same arithmetic removes a tenth of a tenth and the whole effect comes out
/// as a milky wash. Isolating the sun with a threshold instead just trades
/// the wash for nothing at all — there is a 0.06 gap to work in, and every
/// number in it moves with the time of day.
///
/// So the mask is pure visibility: 1 where the sky is open, 0 where terrain
/// is in the way, times a Gaussian around the sun. That is the one quantity
/// in the frame with real contrast in it — a leaf is not 10% darker than
/// the sky behind it, it is *absent* — and it is also, physically, the thing
/// crepuscular rays actually measure. The warmth comes from the tint at
/// composite time and the strength from where the sun is in the sky, both of
/// which are known exactly rather than inferred from pixels.
///
/// `sky` is averaged over four depth taps spread across the 8x8 block rather
/// than taken once, so a canopy edge lands as a gradient and a one-block gap
/// between two leaves still lets a thread of light through.
///
/// The Gaussian is not physics — light shafts really do come from every
/// bright thing in the sky — but without it the mask is the whole sky and
/// the march turns the frame into a starburst centred on the sun.
kernel void postGodRayMask(depth2d<float, access::read> depth [[texture(0)]],
                           texture2d<float, access::write> mask [[texture(1)]],
                           constant GodRayParams &params [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint width = mask.get_width();
    uint height = mask.get_height();
    if (gid.x >= width || gid.y >= height) { return; }

    float2 uv = (float2(gid) + 0.5) / float2(width, height);

    float2 full = float2(depth.get_width(), depth.get_height());
    float2 scale = full / float2(width, height);
    float2 base = float2(gid) * scale;
    float sky = 0.0;
    for (int i = 0; i < 4; ++i) {
        float2 offset = float2((i & 1) ? 0.72 : 0.28, (i & 2) ? 0.72 : 0.28) * scale;
        uint2 texel = uint2(min(base + offset, full - 1.0));
        sky += depth.read(texel) < kSkyDepth ? 0.25 : 0.0;
    }

    float2 toSun = float2((uv.x - params.sunU) * params.aspect, uv.y - params.sunV);
    float near = exp(-dot(toSun, toSun) / (2.0 * params.falloff * params.falloff));

    mask.write(float4(sky * near, 0.0, 0.0, 1.0), gid);
}

/// Radial blur toward the sun — the whole of the effect, in one loop.
///
/// Every pixel walks a fixed number of steps along the straight line from
/// itself to the sun's screen position, summing what the mask holds and
/// attenuating as it goes. A pixel with clear sky all the way to the sun
/// accumulates the full sum; one whose line crosses a hill accumulates
/// nothing over that stretch, so the hill's silhouette is carved out of the
/// fan. That is the occlusion, and it costs no extra pass.
kernel void postGodRays(texture2d<float, access::sample> mask [[texture(0)]],
                        texture2d<float, access::write> rays [[texture(1)]],
                        constant GodRayParams &params [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint width = rays.get_width();
    uint height = rays.get_height();
    if (gid.x >= width || gid.y >= height) { return; }

    float2 uv = (float2(gid) + 0.5) / float2(width, height);
    float2 advance = (float2(params.sunU, params.sunV) - uv)
        * (params.density / float(kGodRaySamples));

    float2 walk = uv;
    float illumination = 1.0;
    float sum = 0.0;
    for (int i = 0; i < kGodRaySamples; ++i) {
        walk += advance;
        sum += mask.sample(kLinearZero, walk).r * illumination;
        illumination *= params.decay;
    }

    // Normalise by what an unobstructed march through a mask of 1 would
    // have summed to, so the buffer is a 0…1 visibility and `power` below
    // means the same thing whatever `decay` is set to.
    float ceiling = float(kGodRaySamples);
    if (params.decay < 0.9999) {
        ceiling = (1.0 - pow(params.decay, float(kGodRaySamples))) / (1.0 - params.decay);
    }
    float value = saturate(sum / max(ceiling, 1e-4));
    rays.write(float4(pow(value, params.power), 0.0, 0.0, 1.0), gid);
}

// MARK: - Composite

/// Compresses highlights and leaves everything else exactly where it was.
///
/// Below `shoulder` this is the identity — that is the whole point, because
/// the world's colours were already graded by hand and a real filmic curve
/// would re-grade all of them. Above it the curve bends over towards 1 along
/// an exponential with slope 1 at the join, so bloom pushing a pixel past
/// the ceiling reads as a hot core rather than a flat clipped patch.
static inline float3 shoulderTonemap(float3 color, float shoulder) {
    float headroom = max(1.0 - shoulder, 1e-3);
    float3 over = max(color - shoulder, 0.0);
    return min(color, shoulder) + headroom * (1.0 - exp(-over / headroom));
}

kernel void postComposite(texture2d<float, access::read> source [[texture(0)]],
                          texture2d<float, access::sample> bloom [[texture(1)]],
                          texture2d<float, access::write> target [[texture(2)]],
                          texture2d<float, access::sample> rays [[texture(3)]],
                          constant CompositeParams &params [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    uint width = target.get_width();
    uint height = target.get_height();
    if (gid.x >= width || gid.y >= height) { return; }

    float4 base = source.read(gid);
    float2 uv = (float2(gid) + 0.5) / float2(width, height);
    float3 color = base.rgb + bloom.sample(kLinearClamp, uv).rgb * params.intensity;

    // God rays, added warm, with a hole where the sun's own disc is: bloom
    // has already made that pixel as bright as it should get.
    if (params.rayStrength > 0.0) {
        float2 toSun = float2((uv.x - params.sunU) * params.aspect, uv.y - params.sunV);
        float core = smoothstep(params.coreInner, params.coreOuter, length(toSun));
        float shaft = rays.sample(kLinearClamp, uv).r * params.rayStrength * core;
        color += float3(params.rayTintR, params.rayTintG, params.rayTintB) * shaft;
    }

    // Radial falloff in uv space: 1 at the edge midpoints, 2 in the corners,
    // and nothing at all across the middle half of the frame.
    float2 offset = uv - 0.5;
    float radius = dot(offset, offset) * 4.0;
    float falloff = saturate((radius - 0.45) / 1.55);
    color *= 1.0 - params.vignette * falloff * falloff;

    target.write(float4(shoulderTonemap(color, params.shoulder), base.a), gid);
}

// MARK: - Plain copy

/// A straight texel-for-texel copy, across pixel formats.
///
/// Two callers, neither of them the effect itself: `BLOCKHAVEN_POSTFX=copy`,
/// which is the do-nothing baseline the effect's GPU cost is measured
/// against, and `BLOCKHAVEN_POSTFX_DUMP`, which copies a frame into a
/// CPU-readable float texture so it can be written to disk.
kernel void postCopy(texture2d<float, access::read> source [[texture(0)]],
                     texture2d<float, access::write> destination [[texture(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
    destination.write(source.read(gid), gid);
}

/// The same, for the frame's depth buffer — which is a `depth2d` and cannot
/// be read through a `texture2d` binding. `BLOCKHAVEN_POSTFX_DUMP_DEPTH=1`
/// uses this to get the depth buffer onto the CPU, which is the only honest
/// way to find out what convention RealityKit hands it over in.
kernel void postCopyDepth(depth2d<float, access::read> source [[texture(0)]],
                          texture2d<float, access::write> destination [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) { return; }
    float d = source.read(gid);
    destination.write(float4(d, d, d, 1.0), gid);
}

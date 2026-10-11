#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

/// Where the world's water sits (`WorldGenerator.seaLevel`). The haze is at
/// full strength here and thins with height, so mountains rise out of it.
constant float kSeaLevel = 62.0;
/// Height above sea level at which the thinning has done half its work.
constant float kFogScaleHeight = 30.0;
/// How much of the haze a fragment high above the sea keeps.
constant float kFogHighAltitude = 0.68;
/// How sharply the haze piles up between `fogStart` and `fogEnd`. Cubed
/// rather than squared: the far edge still dissolves into the skyline
/// (both curves reach 1 there), but the middle distance keeps its
/// contrast. At the shipped range — 71.7 to 112 blocks, `fogStartFraction`
/// of a seven-chunk view — 80 blocks is 0.009 of the way to the horizon
/// colour where squaring made it 0.043, and halfway along the band, at 92
/// blocks, it is 0.125 against 0.25. The wide shot this grade is built
/// around is mostly middle distance, and it was reading as milk.
constant float kFogCurve = 3.0;

/// The warm end of the sun's glow. `SkyEntities.regrade` mixes the same
/// colour, half and half, into the horizon band of the sky dome — this is
/// the terrain half of that one glow, so the haze near the sun and the sky
/// behind it warm together.
constant float3 kSunGlow = float3(1.0, 0.84, 0.58);
/// Matches `gradientImage`'s `glowStrength`: the sky's horizon glow tops out
/// at 0.7 of the way to `kSunGlow`, and so does the fog's.
constant float kSunGlowStrength = 0.7;

/// Range of the per-corner shade ratio packed into the vertex colour.
/// Must equal `ChunkMesher.shadeScale`: the mesher stores
/// `ratio / kVertexShadeScale` in a normalised byte and this undoes it.
constant float kVertexShadeScale = 1.6;

// MARK: - Directional light

/// Brightness a face pointed straight at the sun gains over the flat tint
/// the mesher baked. It is also what an *upward* face gives back as the sun
/// leaves the zenith, which is what makes the whole term cancel at noon.
constant float kSunGain = 0.46;
/// How much of that loss the sky hands back at a low sun. At golden hour
/// the entire sky is a lamp, which is why a sunset landscape reads dim
/// rather than black. Zero at noon, where the term must not exist at all.
constant float kSkyLift = 0.30;
/// Brightness a face turned *away* from a low sun loses on top of that —
/// its own shadow. Weighted by `golden`, so noon keeps the mesher's tints.
constant float kShadeDrop = 0.34;
/// Faint cool light from the moon, which sits at the sun's angle plus pi.
constant float kMoonGain = 0.09;
/// Hue of direct sunlight at its lowest. Neutral overhead — anything else
/// would re-grade noon, which the day tint already owns.
constant float3 kSunWarm = float3(1.00, 0.72, 0.40);
/// Hue of ambient light at a low sun: what a violet sky puts into shade.
constant float3 kShadeCool = float3(0.74, 0.80, 1.06);
/// How far toward that the ambient goes at golden hour.
constant float kShadeCoolStrength = 0.50;
/// Colour of torchlight: a warm orange with very little blue in it, so a
/// lit cave reads as firelight against the blue-grey of the shade the
/// canopy term produces rather than as a second, dimmer sun.
constant float3 kTorchColor = float3(1.00, 0.62, 0.29);

/// How bright a torch is at its own cell, in the same units the sun's
/// contribution uses. Tuned so a torch reads clearly in a pitch-dark
/// mineshaft without blowing out to white at point-blank range, and so
/// that a torch outdoors at noon is a warm smudge rather than invisible.
constant float kTorchStrength = 1.45;

/// Rec. 601 luma weights, for reading one brightness off the daylight
/// grade without letting its colour into what is divided by it.
constant float3 kLuminance = float3(0.299, 0.587, 0.114);

/// The most a lamp may be scaled up to cancel a dark grade.
///
/// The grade at the darkest part of the night is well under a quarter, so
/// an uncapped division makes a torch a flashbulb and every lit face pure
/// white. Four brings a torch-lit wall back to roughly its daytime
/// brightness, which is the intent, and stops there.
constant float kTorchMaxBoost = 4.0;

/// Colour of moonlight.
constant float3 kMoonLight = float3(0.62, 0.74, 1.00);
/// What a corner with no open sky above it multiplies its light by: the
/// pool of shade under a canopy or an overhang, cooled as well as darkened
/// because the light that does reach it is skylight. See
/// `ChunkMesher.skyCover` for how the exposure is measured.
constant float3 kCanopyShade = float3(0.52, 0.57, 0.68);

/// The fixed per-direction tint the mesher already baked into the atlas
/// variant this face samples. Must match `ChunkMesher.faces`' `tint`.
///
/// This is what lets one mesh serve both paths. The mesher goes on picking
/// a pre-darkened atlas tile from `tint * occlusion`, so the stock
/// `UnlitMaterial` fallback renders exactly what it always did; the shader,
/// which knows the normal, divides the constant back out and puts a moving
/// sun where it was.
static inline float bakedFaceTint(float3 normal)
{
    if (normal.y > 0.5) { return 1.00; }
    if (normal.y < -0.5) { return 0.60; }
    if (abs(normal.x) > 0.5) { return 0.76; }
    return 0.88;
}

// MARK: - Water

/// Reflectance of water seen head-on. The real number, which is why looking
/// straight down into a lake still shows the bed.
constant float kWaterF0 = 0.02;
/// How fast reflectance climbs toward grazing. Schlick's own exponent is 5;
/// this brings the mirror in earlier than physics would, which is the whole
/// difference between a lake and a puddle in a wide shot. At 3 degrees off
/// the surface it is 0.9 (a mirror), at 30 degrees 0.19 (the sky's colour
/// laid over the bed), at 45 degrees 0.07 (the bed, as before).
constant float kFresnelPower = 2.4;
/// How much of the gap to fully opaque a full mirror closes. A reflection
/// hides what is under it, so the same ramp that reflects also thickens.
constant float kMirrorOpacity = 0.95;
/// Slope of the swell, as a height gradient: a couple of degrees of tilt,
/// and a mirror tilted two degrees moves what it reflects by four. That is
/// what makes the reflected sun wobble instead of sitting on the water like
/// a decal.
constant float kWaveSlope = 0.038;
/// How far the tilt survives, in blocks. Near-grazing water magnifies the
/// slope enormously — a wave two degrees high swings the reflection through
/// several degrees of sky — so a sine field that is honest at ten blocks is
/// a corduroy of stripes at sixty. Past this the surface is mirror-flat,
/// which is what distance does to chop anyway.
constant float kWaveDistance = 46.0;
/// What the day's tint is worth on water. The grade is authored for lit
/// ground; water keeps the blue end of it and little of the warm end.
constant half3 kWaterDeep = half3(0.74h, 0.85h, 1.0h);

/// Unpacks three 8-bit channels from one float lane.
///
/// `CustomMaterial` has exactly four free float lanes (`custom.value`) and
/// this shader needs five numbers out of them, so the sky's zenith colour
/// travels as one packed integer. The lane is a genuine float32 — verified
/// in a render, by shading half a scene from an unpacked colour and the
/// other half from the same colour written as a literal and diffing — and
/// 2^24-1 is exactly representable, so the round trip is lossless.
static inline float3 unpackColor888(float packed)
{
    float scaled = packed * 16777216.0;
    float blue = fmod(scaled, 256.0);
    float green = fmod(floor(scaled / 256.0), 256.0);
    float red = floor(scaled / 65536.0);
    return float3(red, green, blue) * (1.0 / 255.0);
}

/// The sky, evaluated in one direction, with no texture lookup.
///
/// This is `SkyEntities.gradientImage`'s rule written as arithmetic: a
/// zenith-to-horizon ramp weighted toward the horizon, plus a warm glow
/// banked around the sun's bearing and hugging the skyline. The dome paints
/// it into a 64x128 lookup; the water evaluates the same thing per fragment,
/// because a reflected ray does not land anywhere the dome's UVs can be
/// asked about. Keeping one rule in two places is deliberate — the mirror
/// has to agree with the thing it is mirroring, and every constant here is
/// the one over there.
///
/// `glowStrength` is the sky's `low * 0.7`, which the caller already has as
/// `golden * kSunGlowStrength`.
static inline float3 skyAlong(float3 direction,
                              float3 horizon,
                              float3 zenith,
                              float2 sunFlat,
                              float sunFlatLength,
                              float glowStrength)
{
    // Elevation the way the lookup's rows are spaced: by angle, 0 at the
    // horizon and anywhere below it, 1 straight up.
    float above = saturate(asin(saturate(direction.y)) * (2.0 / M_PI_F));
    float lift = 1.0 - powr(1.0 - above, 2.2);
    float3 band = mix(horizon, zenith, lift);

    float hug = powr(1.0 - above, 3.0);
    float2 flat = direction.xz;
    float flatLength = length(flat);
    float toward = 0.0;
    if (sunFlatLength > 1e-3 && flatLength > 1e-4) {
        toward = max(0.0, dot(flat / flatLength, sunFlat / sunFlatLength));
    }
    float strength = min(1.0, powr(toward, 2.5) * hug * glowStrength);
    return mix(band, mix(horizon, kSunGlow, 0.5), strength);
}

/// Surface shader for every block face.
///
/// The atlas already carries baked brightness, so this runs under the
/// `.unlit` lighting model and does the things RealityKit's stock
/// `UnlitMaterial` cannot:
///
///   1. Samples the atlas with explicit nearest-neighbour filtering, which
///      keeps blocks crisp at any distance.
///   2. Multiplies in the day/night grade, and the per-corner ambient
///      occlusion the mesher wrote into the vertex colour — the atlas only
///      stores eight brightness steps per face, so the smooth gradient
///      across a quad has to arrive this way.
///   3. Replaces the mesher's fixed per-direction tint with a moving sun:
///      it divides out the constant baked into the atlas variant and puts
///      `dot(normal, sunDirection)` in its place, plus the pool of shade
///      under whatever the mesher found standing over each corner.
///   4. Blends toward the sky colour with distance — thinning with height,
///      and warming toward the sun at dawn and dusk.
///   5. Turns water into a mirror at grazing angles: a swell that tilts the
///      surface, an analytic sky evaluated along the reflected ray, the
///      sun's reflection stretched into a streak down it, and a Fresnel
///      ramp that decides between that mirror and the lake bed underneath.
///
/// Parameters arrive through the stock material slots rather than a custom
/// uniform buffer, which `CustomMaterial` does not offer:
///   custom texture      — the block atlas
///   base colour tint    — the daylight grade
///   emissive colour     — the fog/sky colour, i.e. the horizon
///   custom parameter    — (fogStart, fogEnd) in metres, then 1 on the
///                         two-sided translucent material and 0 on the
///                         opaque one, then the sky's zenith colour as
///                         three 8-bit channels in one lane
///   roughness/metallic/ — the unit vector pointing at the sun, in world
///   specular              space, one component each, packed 0…1. See
///                         `MaterialLibrary.encodeSunComponent`.
///
/// Under `.unlit` nothing reads roughness, metallic or specular, which is
/// exactly why they are free to carry the sun. `clearcoat` and
/// `clearcoatRoughness` are free the same way and are still spare.
[[visible]]
void blockSurface(realitykit::surface_parameters params)
{
    constexpr sampler atlasSampler(filter::nearest,
                                   mip_filter::none,
                                   address::clamp_to_edge);

    auto geometry = params.geometry();
    auto constants = params.material_constants();
    auto uniforms = params.uniforms();
    auto surface = params.surface();

    // `uv0()` hands back the atlas rect the mesher wrote, but the texture
    // reaches the shader with v mirrored, so the sample flips it and
    // anything comparing against the atlas layout must not. Sampling
    // unflipped reads a different row per tile: logs come out as snow.
    float2 meshUV = geometry.uv0();
    half4 texel = params.textures().custom().sample(
        atlasSampler, float2(meshUV.x, 1.0 - meshUV.y));

    // Smooth ambient occlusion. The atlas variant the mesher picked already
    // carries the face's *average* occlusion; the vertex colour carries each
    // corner's ratio to that average, interpolated across the quad. A face
    // whose four corners are equally open comes back as exactly 1 and this
    // multiply is a no-op — which is why the flat-lit fallback and this path
    // agree on everything except the gradient.
    half vertexShade = half(geometry.color().r * kVertexShadeScale);

    float4 tuning = uniforms.custom_parameter();
    float2 fogRange = tuning.xy;
    // 1 on the two-sided translucent material — water and glass — and 0 on
    // the opaque one. A material constant, so it is exact: unlike anything
    // interpolated it cannot drift at a triangle's edge.
    bool translucentPass = tuning.z > 0.5;
    float3 zenithColor = unpackColor888(tuning.w);

    // Cutout, done here rather than left to the material.
    //
    // `CustomMaterial.opacityThreshold` is set to 0.5 on the opaque
    // material and it does not discard anything on this path: with a
    // surface shader the opacity RealityKit tests is not the one
    // `set_opacity` writes at the bottom of this function, so a fully
    // transparent texel came through as an opaque fragment. Nothing
    // noticed until the cross plants arrived, because until then every
    // tile in the opaque pass was opaque in every texel — glass and water
    // are the translucent pass, which blends and needs no test at all. A
    // tuft of grass drew as a solid rectangle of whatever the fog colour
    // was: sky blue at noon, navy at midnight.
    //
    // The threshold matches the one on the material, so the two agree if
    // RealityKit's ever starts working. Only the opaque pass tests: the
    // translucent one wants its partial alphas, which is the whole of how
    // glass is glass.
    if (!translucentPass && texel.a < 0.5h) { discard_fragment(); }

    // Water and glass are drawn by one shared translucent material, and the
    // mesher separates them in the blue channel of the vertex colour: 255
    // on water, 0 on everything else.
    //
    // This used to be read off the atlas coordinate — is `meshUV.y` inside
    // the water tile's row — and that was the dark hairline grid ruled
    // across the whole lake. With MSAA a pixel whose centre falls outside
    // the triangle covering it is still shaded, and its attributes are
    // *extrapolated* past every value the triangle's corners hold. Half a
    // pixel of the `v` gradient is thousandths of `v` in the middle
    // distance and far more at range, so along every block seam `meshUV.y`
    // landed outside the row, the fragment took the terrain path instead of
    // the water one, and it drew dark and unreflected. A per-corner flag
    // that is 1 at all four corners of every water quad extrapolates to
    // exactly 1 — there is no value between quads for it to slide to.
    // Measured on a 600x400 patch of open water in the benchmark shot:
    // 1,093 pixels drew darker than the median of their eight neighbours,
    // the worst by 28 of 255. After this, none do.
    //
    // The pass flag only separates this material from the opaque one; it is
    // not a guard against the flat-lit fallback's `neutralShade` vertices,
    // which are 255 in every channel and would sail through `b > 0.5` —
    // reading the whole translucent pass, glass included, as water. What
    // actually keeps those two apart is upstream and worth naming here,
    // because nothing at this line implies it: a mesh is built with white
    // vertices exactly when `MaterialLibrary.usesCustomShader` is false, and
    // this shader only runs when it is true. Both the game and the snapshot
    // harness derive their `smoothShading` from that one expression, so a
    // white-vertex mesh and this code can never meet. Split them and the
    // lake turns to glass.
    bool isWater = translucentPass && geometry.color().b > 0.5;

    // The per-corner occlusion gradient is a contact shadow — the darkening
    // where a face meets a wall. A lake has no such thing, so the mesher
    // emits the whole translucent pass with `applyAO: false` and every
    // corner's ratio is already 1. Flattening here as well is belt and
    // braces: if ambient occlusion is ever turned on for that pass, water
    // keeps a tenth of it rather than a grazing lake growing block-sized
    // cells of shade.
    half shade = isWater ? mix(vertexShade, 1.0h, 0.85h) : vertexShade;
    half3 color = texel.rgb * half3(constants.base_color_tint()) * shade;

    // Unpack the sun. Components arrive remapped from [-1,1] into [0,1],
    // because these slots are nominally material scales and there is no
    // promise anywhere that a negative one survives the trip.
    float3 sunDirection = float3(constants.roughness_scale(),
                                 constants.metallic_scale(),
                                 constants.specular_scale()) * 2.0 - 1.0;
    // The same golden-hour weight `SkyEntities.lowSun` uses — 1 with the sun
    // on the horizon, 0 overhead or fully down. Derived here rather than
    // passed, so the sky's warmth and the ground's can never drift apart.
    float golden = 1.0 - abs(sunDirection.y);
    golden *= golden;

    // The normal, which for the opaque pass is the face's own: those quads
    // are back-face culled, so the eye-facing normal RealityKit hands over
    // and the normal the mesher wrote are the same vector.
    float3 surfaceNormal = normalize(geometry.normal());

    // MARK: Directional light
    //
    // The whole translucent pass is excluded, water and glass alike.
    //
    // Water, because its top face is baked at tint 1.0 with nothing to
    // divide out and a mirror takes its brightness from what it reflects,
    // not from what falls on it.
    //
    // Glass, because that pass is drawn two-sided and the normal above has
    // already been turned to face the viewer — established by shading every
    // fragment whose normal pointed away bright red and finding no red
    // pixel anywhere. `bakedFaceTint` is symmetric in x and z, so a flipped
    // side wall divides out the right constant by luck; a flipped
    // horizontal one does not. The underside of a glass pane seen from
    // above came back divided by 1.00 where the mesher had baked 0.60, and
    // the top of one seen from below by 0.60 where 1.00 was baked — a
    // brightening of 1.67x on one and a darkening to 0.6 on the other, plus
    // an `ndl` taken against a normal pointing the wrong way. There is no
    // front-facing bit in `surface_parameters` to undo it with, so the
    // true face direction is simply not recoverable here. Glass keeps the
    // flat baked tint instead, which is exactly what the `UnlitMaterial`
    // fallback shows it as.
    if (!translucentPass) {
        float baked = bakedFaceTint(surfaceNormal);
        float3 sunUnit = normalize(sunDirection);
        float ndl = dot(surfaceNormal, sunUnit);
        // Direct sun fades out over the first few degrees below the horizon
        // and the moon fades in across the same span, so dusk crossfades
        // rather than switching. At `sunDirection.y == 0` — exactly the
        // golden hour this is aimed at — the sun is still at full strength.
        float sunUp = smoothstep(-0.35, 0.0, sunDirection.y);

        // The direct sun this face catches, and the overhead sun the baked
        // tint assumed it was catching. At noon `sunUnit` *is* up, so `ndl`
        // is `normal.y`, the two are equal on every face, and the whole
        // term cancels: the render is the one the mesher baked, to the
        // byte. Everything below is what happens as the sun leaves the
        // zenith, which is why the effect peaks at golden hour by
        // construction rather than by a hand-tuned weight.
        float lit = kSunGain * sunUp * max(0.0, ndl);
        float dim = kSunGain * sunUp * max(0.0, surfaceNormal.y);
        float lift = kSkyLift * sunUp * golden * max(0.0, surfaceNormal.y);
        float away = kShadeDrop * sunUp * golden * max(0.0, -ndl);
        // The moon rides the sun's axis, half a turn round it.
        float moon = kMoonGain * (1.0 - sunUp) * max(0.0, -ndl);

        float3 warmLight = mix(float3(1.0), kSunWarm, golden);
        float3 ambientTint = mix(float3(1.0), kShadeCool,
                                 golden * sunUp * kShadeCoolStrength);
        float ambient = max(0.05, baked - dim + lift - away);
        float3 light = ambientTint * ambient + warmLight * lit + kMoonLight * moon;

        // How much open sky this corner has above it, marched up the column
        // at mesh time and interpolated across the quad. Ground under a
        // canopy, the floor of an overhang and the inside of a cave fall
        // into a cool pool of shade; open ground is exactly 1 and untouched.
        float openness = float(geometry.color().g);
        light *= mix(float3(1.0), kCanopyShade, 1.0 - openness);

        // Torchlight, added rather than multiplied, and added after the
        // canopy shade rather than before it. A lamp is not a modifier on
        // the daylight already reaching a surface — it is its own light,
        // and it is the only light there is at the bottom of a mineshaft
        // where every term above this line has gone to nearly zero.
        //
        // Squared, because the propagation falls off linearly in *levels*
        // and a linear ramp in brightness reads as a flat disc with a hard
        // rim. Squaring puts the knee near the lamp, which is where a real
        // one is, and lets the last few levels trail off into the dark.
        float torch = float(geometry.color().a);

        // The day/night grade does not get to dim a flame.
        //
        // That grade arrives as `base_color_tint`, multiplied into the texel
        // above — so `light` is a *multiplier* on an already-darkened
        // colour, and a term merely added to it is scaled down along with
        // everything else. The result was exactly backwards: a torch read as
        // a warm tint on sunlit stone at noon, and at midnight lit
        // essentially nothing. Measured before this, stone one block from a
        // torch at midnight came back 1.2x the brightness of stone twenty
        // blocks away, with no warmth in it at all.
        //
        // Dividing the grade back out gives a lamp the same brightness at
        // any hour, which is what a flame does and what makes it worth
        // carrying one. At noon the grade is near 1 and this changes
        // nothing, so every daylight capture in the battery is untouched.
        //
        // Capped, because the grade goes very dark indeed and an uncapped
        // division turns a torch into a flashbulb. Taken off the grade's
        // luminance rather than per channel, so undoing it cannot tint the
        // lamp some colour of its own.
        float graded = dot(float3(constants.base_color_tint().rgb), kLuminance);
        float lampBoost = min(1.0 / max(graded, 0.04), kTorchMaxBoost);
        light += kTorchColor * (torch * torch) * kTorchStrength * lampBoost;

        // A face whose torch byte is saturated is not lit by a lamp — it
        // *is* one. The mesher writes exactly 1.0 only for the faces of
        // full-strength emitters (a wall beside a lamp tops out at 14 of
        // 15), and such a face keeps its daylight look at any hour: the
        // grade is divided back out whole, in the face's own colour, not
        // the torch-warm cap above. This is what makes a pearl lamp blaze
        // at midnight instead of reading as pink stone.
        if (torch > 0.995) {
            light = max(light, float3(baked / max(graded, 0.04)));
        }

        // Back out the constant, in with the moving one.
        color *= half3(light * (1.0 / baked));
    } else if (!isWater) {
        // Lamp light on glass. The exclusion above keeps the *sun* off the
        // translucent pass, for the two-sided-normal reasons it explains —
        // but block light needs no normal, and a pane one block from a
        // lamp has lamp light arriving at it whatever its faces are doing.
        // Without this the whole pass rides `base_color_tint` alone and
        // every pane goes black at midnight — including the radiant lamps,
        // which *are* panes and are the light source they then failed to
        // show. In the pane's own colour rather than torch-warm: a lamp
        // seen through stained glass is the colour of the glass.
        float torch = float(geometry.color().a);
        float graded = dot(float3(constants.base_color_tint().rgb), kLuminance);
        float lampBoost = min(1.0 / max(graded, 0.04), kTorchMaxBoost);
        color += texel.rgb * half(torch * torch * kTorchStrength * lampBoost);
    }

    float3 world = geometry.world_position();
    // World-space direction from this fragment back to the eye.
    float3 toEye = normalize(geometry.view_direction());

    // There is no camera position in the surface parameters, but view space
    // is centred on the camera, so the length of the view-space position is
    // the distance to the eye.
    float4 viewPosition = uniforms.world_to_view() * float4(world, 1.0);
    float distance = length(viewPosition.xyz);
    // Cubed falloff: the near two-thirds of the view distance stays clear
    // and the haze piles up close to the horizon, which is how the original's
    // fog reads.
    float fog = saturate((distance - fogRange.x) / max(1.0, fogRange.y - fogRange.x));
    fog = powr(fog, kFogCurve);
    // Haze is a thing the air near the ground does. Thinning it with height
    // lets a distant ridge climb out of the murk instead of dissolving into
    // it uniformly, which is most of what reads as depth in a wide shot.
    float above = max(0.0, world.y - kSeaLevel);
    fog *= mix(1.0, kFogHighAltitude, 1.0 - exp2(-above / kFogScaleHeight));

    // The horizon colour of the moment, straight from `SkyController` — the
    // bottom of the sky gradient, so terrain dissolves into the exact colour
    // of the sky it meets and the water mirrors the same sky the dome is
    // painted with.
    float3 horizonColor = float3(constants.emissive_color());

    // How nearly this fragment lies on the bearing of the sun, judged flat:
    // both directions projected onto the ground plane. `toward` is the same
    // `max(0, cos(azimuth - sunAzimuth))` the sky dome's lookup is banked
    // with, so the warm band in the haze lines up with the warm band in the
    // sky above it.
    float2 sunFlat = sunDirection.xz;
    float sunFlatLength = length(sunFlat);
    float2 awayFlat = -toEye.xz;
    float awayLength = length(awayFlat);
    float toward = 0.0;
    if (sunFlatLength > 1e-3 && awayLength > 1e-4) {
        toward = max(0.0, dot(awayFlat / awayLength, sunFlat / sunFlatLength));
    }
    // Scaled by `golden`, so midday haze stays the neutral grade it has
    // always been and only a low sun sets the air alight.
    float warmth = powr(toward, 2.5) * golden * kSunGlowStrength;
    float3 fogColor = mix(horizonColor, mix(horizonColor, kSunGlow, 0.5), warmth);

    half opacity = texel.a;

    if (isWater) {
        float t = uniforms.time();
        // Two waves at unrelated wavelengths and speeds, so a stretch of
        // water drifts rather than pulsing in step with itself. Fading the
        // swell out with the fog keeps the far surface still: at a few
        // blocks per wave it would otherwise sparkle once one wave stops
        // covering a whole pixel.
        float phaseX = world.x * 1.15 + t * 1.6;
        float phaseZ = world.z * 0.95 - t * 1.25;
        float swell = 0.5 * (sin(phaseX) + sin(phaseZ));
        float calm = 1.0 - fog;
        swell *= calm;
        // Brightness of the body of the water, which is what the trough of
        // a wave shows through the reflection sitting on top of it. Deepened
        // and cooled first: the daylight grade is a warm multiply meant for
        // ground, and applied to a lake it turned the unreflected part of
        // the surface the same peach as the sand next to it. A mirror needs
        // something dark to be a mirror *of*.
        color *= kWaterDeep * half(1.0 + 0.10 * swell);

        // Which side of the surface the eye is on. It cannot come from the
        // normal: water faces are drawn two-sided, and the normal this
        // shader is handed has already been turned to face the viewer —
        // shading every fragment whose normal pointed away bright red
        // produced no red pixel anywhere, above the lake or under it. So the
        // geometry answers instead. View space is centred on the camera, so
        // the eye sits at `world + toEye * distance` and stands
        // `toEye.y * distance` above this fragment; for the flat top of a
        // lake that sign is the whole question, and `distance` is positive.
        // Everything a reflection is — the mirrored sky, the sun's streak,
        // the sparkle — belongs to the top of a lake. Read from underneath
        // they were a ceiling of twinkling dots with a sun in it.
        bool horizontal = abs(surfaceNormal.y) > 0.5;
        bool fromAbove = horizontal && toEye.y > 0.0;

        // The swell as a height field, differentiated. Only a roughly
        // horizontal face gets it: the vertical side of a water block at a
        // shoreline is not a wave. The normal is already eye-facing, so the
        // tilt is applied in whichever direction it already points.
        float3 waveNormal = surfaceNormal;
        if (horizontal) {
            float tilt = kWaveSlope * calm * saturate(1.0 - distance / kWaveDistance);
            float3 lifted = float3(-tilt * cos(phaseX), 1.0, -tilt * cos(phaseZ));
            waveNormal = normalize(surfaceNormal.y < 0.0 ? -lifted : lifted);
        }

        // Grazing is grazing from either side, so the Fresnel magnitude
        // rides the eye-facing normal and is the one part of this a
        // submerged camera keeps: from below a shallow angle still thickens
        // the surface toward opaque, it just has nothing to mirror.
        float facing = saturate(dot(waveNormal, toEye));
        float fresnel = kWaterF0 + (1.0 - kWaterF0) * powr(1.0 - facing, kFresnelPower);

        if (fromAbove) {
            // What the eye would see if it carried on past the surface —
            // the sky, evaluated along the ray the wave-tilted mirror sends
            // it down. No terrain in it: reflecting the shoreline needs a
            // screen-space trace, and this is the half of the reflection
            // that carries the shot.
            float3 mirrored = reflect(-toEye, waveNormal);
            float3 reflection = skyAlong(mirrored, horizonColor, zenithColor,
                                         sunFlat, sunFlatLength,
                                         golden * kSunGlowStrength);

            float sunUp = smoothstep(-0.12, 0.06, sunDirection.y);
            if (sunUp > 0.0) {
                // The sun's own reflection, stretched. Measured as an
                // angular offset from the sun and then weighted far more
                // heavily across the sun's bearing than up and down it: a
                // wavy mirror scatters a low sun into a column running from
                // the horizon toward the viewer, and a round highlight is
                // the one thing that never happens on open water.
                float3 sunUnit = normalize(sunDirection);
                float3 offset = mirrored - sunUnit;
                float vertical = offset.y;
                float across = max(0.0, dot(offset, offset) - vertical * vertical);
                float core = exp2(-(across * 900.0 + vertical * vertical * 40.0));
                float halo = exp2(-(across * 26.0 + vertical * vertical * 6.0));
                float streak = core + 0.42 * halo;

                // Cells stretched along the sun's bearing and packed tight
                // across it, which is what turns a specular reflection on
                // moving water into a track of separate glints rather than
                // one smooth smear. They *modulate* the streak instead of
                // adding light of their own — that is the difference
                // between glitter on a reflection and confetti floating
                // over a lake, which is what the first render of this was.
                float2 alongSun = sunFlatLength > 1e-3 ? sunFlat / sunFlatLength : float2(1.0, 0.0);
                float2 acrossSun = float2(-alongSun.y, alongSun.x);
                float2 cell = float2(dot(world.xz, alongSun) * 2.4,
                                     dot(world.xz, acrossSun) * 5.2);
                // Three sines multiplied: sparse, because a product only
                // gets near 1 where all three peak together, and
                // irrational-ish frequency ratios keep the pattern from
                // looking like a grid.
                float sparkle = sin(cell.x * 1.7 + t * 0.9)
                              * sin(cell.y * 2.3 - t * 1.1)
                              * sin((cell.x + cell.y) * 1.13 + t * 0.55);
                sparkle = smoothstep(0.42, 0.90, sparkle);
                // Held to the foreground: a glint is a sub-block highlight,
                // and past fifty-odd blocks the cells stop covering whole
                // pixels and start crawling. Far water keeps the smooth
                // streak, which is what distance does to glitter anyway.
                float near = saturate(1.0 - distance / 58.0);
                streak *= mix(1.0, 0.35 + 0.95 * sparkle, near);

                // Near-white overhead, gold at the horizon — the sun's own
                // tint in `SkyEntities.regrade`.
                float3 sunColor = mix(float3(1.0, 0.98, 0.92), kSunGlow, golden);
                reflection += sunColor * (streak * sunUp * calm);
            }

            // A shade under the sky it mirrors: a lake is never brighter
            // than what is above it, and at these angles the reflection
            // would otherwise out-glare the horizon it meets.
            color = mix(color, half3(reflection * 0.94), half(fresnel));
        }

        // A reflection hides what is underneath it, so grazing water also
        // thickens — and it thickens from either side, which is why this
        // sits outside the branch above. Added into the gap left rather
        // than multiplied, so it approaches opaque without overshooting.
        opacity = clamp(opacity * half(1.0 + 0.18 * swell), 0.0h, 1.0h);
        opacity += half(fresnel * kMirrorOpacity) * (1.0h - opacity);
        opacity = clamp(opacity, 0.0h, 1.0h);
    }

    // The unlit lighting model takes its output colour from the emissive
    // channel and ignores base colour entirely.
    surface.set_emissive_color(mix(color, half3(fogColor), half(fog)));
    surface.set_opacity(opacity);
}

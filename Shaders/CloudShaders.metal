#include <metal_stdlib>
#include <RealityKit/RealityKit.h>

using namespace metal;

/// The warm end of the sun's glow — the same constant `BlockShaders` warms
/// the haze with and `SkyEntities.regrade` mixes into the horizon band. One
/// sunset, three surfaces.
constant float3 kCloudSunGlow = float3(1.0, 0.84, 0.58);
/// Brightness a cloud face pointed straight at a low sun gains over the flat
/// per-direction tint the mesh was built with. Scaled by `golden`, so it is
/// exactly zero at noon and the layer is then pure plain per-face shading.
constant float kCloudSunGain = 0.34;
/// What a face turned away from that same low sun loses. Smaller than the
/// gain: a cloud is a translucent thing and its shadowed side still glows.
constant float kCloudShadeDrop = 0.14;
/// How far a receding cloud goes toward the horizon colour before its
/// opacity has finished dropping. Short of 1 on purpose — the last of the
/// layer should thin out, not turn into a band of flat horizon paint.
constant float kCloudRecedeHaze = 0.85;
/// How much darker the foot of a cloud mass is than its crown.
///
/// The deck is a stack of levels, so one mass has faces at five different
/// heights and the per-face constants cannot tell them apart — a wall two
/// levels down in a crevice takes exactly the tint of the wall on the
/// sunlit crown above it. This is what separates them: light falls on a
/// cloud from above, so the deeper into the mass a fragment sits the less
/// of it there is. Vertical, not directional, because the light that
/// reaches into the folds of a cumulus is skylight and skylight comes from
/// the whole dome.
constant float kCloudDepthShade = 0.30;

/// Surface shader for the volumetric cloud layer.
///
/// The layer is a field of extruded boxes (see `CloudMesh`), split into three
/// material slots by face direction — top, side, bottom — and this runs once
/// per slot. Everything that varies per *face* is therefore a constant here;
/// what this shader adds over a plain `UnlitMaterial` is the two things that
/// vary per *fragment*:
///
///   1. A distance fade. The field is a fixed disc of geometry recentred on
///      the camera in whole tile periods, so its rim jumps by a tile whenever
///      the player crosses a half-tile line. Fading the layer out well inside
///      the guaranteed coverage radius (`CloudMesh.coverageRadius`) is what
///      makes that jump — and the camera's own far plane — invisible, and it
///      is also what lets the far clouds settle into the same haze the
///      terrain below them dissolves into.
///   2. A sun kicker. The reference this grade is built toward has strong
///      directional light: cloud flanks facing the low sun are bright and
///      warm, the ones facing away are dusk-dark. `golden` weights it, so
///      noon renders the flat per-face tints and nothing else.
///
/// Parameters ride the stock material slots, the same way `blockSurface`'s
/// do — this material is its own `CustomMaterial`, so its lanes are its own
/// and share nothing with the block one:
///   custom parameter — (fadeStart, fadeEnd, face brightness, layer opacity)
///   base colour tint — the graded cloud colour for this face direction
///   emissive colour  — the horizon colour the layer recedes into
///   roughness/metallic/specular — the unit vector pointing at the sun,
///                    one component each, packed 0…1 exactly as
///                    `MaterialLibrary.encodeSunComponent` packs it.
[[visible]]
void cloudSurface(realitykit::surface_parameters params)
{
    auto geometry = params.geometry();
    auto constants = params.material_constants();
    auto uniforms = params.uniforms();
    auto surface = params.surface();

    float4 tuning = uniforms.custom_parameter();
    float2 fadeRange = tuning.xy;
    float faceBrightness = tuning.z;
    float layerOpacity = tuning.w;

    // View space is centred on the camera, so the length of the view-space
    // position is the distance to the eye — the same trick `blockSurface`
    // uses for its fog, and for the same reason: there is no camera position
    // in the surface parameters.
    float3 world = geometry.world_position();
    float4 viewPosition = uniforms.world_to_view() * float4(world, 1.0);
    float distance = length(viewPosition.xyz);
    float recede = smoothstep(fadeRange.x, fadeRange.y, distance);

    // Unpack the sun. Components arrive remapped from [-1,1] into [0,1];
    // these slots are nominally material scales and nothing promises a
    // negative one survives the trip.
    float3 sunDirection = float3(constants.roughness_scale(),
                                 constants.metallic_scale(),
                                 constants.specular_scale()) * 2.0 - 1.0;
    // `SkyEntities.lowSun` and `blockSurface` compute this identically: 1
    // with the sun on the horizon, 0 overhead or fully down.
    float golden = 1.0 - abs(sunDirection.y);
    golden *= golden;
    // Direct sun fades out over the first few degrees below the horizon,
    // matching the block shader's convention exactly.
    float sunUp = smoothstep(-0.35, 0.0, sunDirection.y);

    float3 normal = normalize(geometry.normal());
    float3 sunUnit = normalize(sunDirection);
    float ndl = dot(normal, sunUnit);
    float lit = kCloudSunGain * sunUp * golden * max(0.0, ndl);
    float away = kCloudShadeDrop * sunUp * golden * max(0.0, -ndl);

    // How high up the mass this fragment sits, 0 at the deck's flat base
    // and 1 at the tallest a column may stand. `CloudMesh` writes it into
    // the u channel, which is otherwise unused — this mesh samples no
    // texture at all.
    float lift = saturate(geometry.uv0().x);
    float depthShade = kCloudDepthShade * (1.0 - lift);

    float3 tint = float3(constants.base_color_tint());
    float3 light = float3(faceBrightness - away - depthShade)
                 + mix(float3(1.0), kCloudSunGlow, golden) * lit;
    float3 color = tint * max(float3(0.0), light);

    float3 horizonColor = float3(constants.emissive_color());
    color = mix(color, horizonColor, recede * kCloudRecedeHaze);

    surface.set_emissive_color(half3(color));
    surface.set_opacity(half(layerOpacity * (1.0 - recede)));
}

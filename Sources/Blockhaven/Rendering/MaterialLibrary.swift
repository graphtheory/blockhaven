#if canImport(AppKit)
import RealityKit
import AppKit
import Metal

/// The materials every chunk shares.
///
/// Blocks are drawn with the `.unlit` lighting model: brightness is already
/// baked into the texture atlas (see `TextureAtlas`), so letting RealityKit
/// light the geometry again would double up the shading.
///
/// The default path is a `CustomMaterial` running `BlockShaders.metal`,
/// which adds distance fog — terrain dissolving into the sky at the render
/// limit rather than ending at a hard edge — a sun-warmed haze, and a swell,
/// a sky reflection and sun glints across water. If the compiled shader
/// library is missing (see `make shaders`), everything falls back to
/// `UnlitMaterial`, which loses all of that but renders correctly otherwise.
///
/// The two materials are built once and then *edited* for the time of day,
/// never rebuilt. That is not a micro-optimisation: measured on this Mac,
/// `CustomMaterial(surfaceShader:lightingModel:)` costs 2–5 ms a call and
/// turning one transparent costs another 2 ms, so reassembling both is
/// most of a 10 ms frame. Assigning the grade fields onto materials that
/// already exist costs 0.05 ms.
@MainActor
enum MaterialLibrary {
    /// Nearest-neighbour sampling with no mipmaps — the chunky look, and
    /// the only sampler that keeps atlas tiles from bleeding into each
    /// other at distance. The custom shader hard-codes the equivalent.
    private static let blockSampler: MaterialParameters.Texture.Sampler = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .nearest
        descriptor.magFilter = .nearest
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return MaterialParameters.Texture.Sampler(descriptor)
    }()

    private static var atlasResource: TextureResource? = {
        guard let cgImage = TextureAtlas.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return try? TextureResource(
            image: cgImage,
            options: .init(semantic: .color, mipmapsMode: .none)
        )
    }()

    /// The compiled Metal library every custom surface shader is linked out
    /// of, or nil when this render is meant to use the stock-material
    /// fallback instead.
    ///
    /// Shared rather than private because the sky has surface shaders of its
    /// own now (`CloudLayer`): one gate, so a frame can never come out half
    /// custom-shaded and half not.
    static let shaderLibrary: MTLLibrary? = {
        // On unless `BLOCKHAVEN_CUSTOM_SHADER=0` turns it off. This used to
        // be off by default because a scene containing a `CustomMaterial`
        // rendered zero frames — but that was the offscreen snapshot
        // harness, not RealityKit. The live app runs the shader at 100 fps.
        //
        // Offscreen snapshots still default to the `UnlitMaterial` fallback,
        // since most existing checks (atlas addressing, mob geometry, UI
        // overlays) want a plain, shader-independent render. Set
        // `BLOCKHAVEN_SNAPSHOT_CUSTOM_SHADER=1` to opt a snapshot into the
        // real block shader instead, for verifying fog/water/lighting work.
        let environment = ProcessInfo.processInfo.environment
        guard environment["BLOCKHAVEN_CUSTOM_SHADER"] != "0",
              !OffscreenSnapshot.isRequested || environment["BLOCKHAVEN_SNAPSHOT_CUSTOM_SHADER"] == "1"
        else { return nil }

        // RealityKit links `[[visible]]` functions out of the *default*
        // library of a bundle, so the compiled shader has to be named
        // `default.metallib` and loaded this way rather than by URL.
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeDefaultLibrary(bundle: Bundle.shaders) else {
            StandardError.write(Data("[render] default.metallib not loaded — fog disabled\n".utf8))
            return nil
        }
        return library
    }()

    /// The block surface shader, or nil when the library could not be
    /// loaded — which is the signal to fall back to `UnlitMaterial`.
    private static let blockSurfaceShader: CustomMaterial.SurfaceShader? = {
        guard let shaderLibrary else { return nil }
        return CustomMaterial.SurfaceShader(named: "blockSurface", in: shaderLibrary)
    }()

    /// True when the custom shader is in use, for the debug overlay.
    static var usesCustomShader: Bool { blockSurfaceShader != nil }

    /// Where fog starts and finishes, in blocks. Set from the world's
    /// render distance so the haze always lands at the visible edge.
    ///
    /// Derived from the default distance rather than written out. Nothing
    /// is graded before `GameViewController` calls `setRenderDistance`, so
    /// a stale literal here was never *visible* — which is exactly why it
    /// would have gone on being wrong: it sat at the 112-block pair while
    /// the world moved to 160 and no capture could have caught it.
    private static var fogRange: SIMD2<Float> = fogRange(
        forRenderDistance: World.defaultRenderDistance
    )

    private static func fogRange(forRenderDistance chunks: Int) -> SIMD2<Float> {
        let blocks = Float(chunks * Chunk.width)
        return SIMD2(blocks * fogStartFraction, blocks)
    }

    /// Where the haze begins, as a fraction of the render distance. The
    /// shader's own curve does the rest of the pullback (`kFogCurve`); this
    /// end just stops the near field from being touched at all.
    private static let fogStartFraction: Float = 0.64

    // MARK: - The grade

    /// Current daylight grade and the sky colour the fog blends toward.
    private static var currentTint: NSColor = .white
    private static var currentFog: NSColor = NSColor(calibratedRed: 0.47, green: 0.71, blue: 0.98, alpha: 1)
    /// The colour straight overhead — the top of the sky gradient. Terrain
    /// never needs it; water does, because a reflected ray climbs away from
    /// the horizon and has to arrive somewhere. Raw sRGB components rather
    /// than an `NSColor`, since the only thing done to it is packing.
    private static var currentZenith: SIMD3<Float> = SIMD3(0.30, 0.58, 0.99)
    /// Unit vector from the eye toward the sun, in world space. The shader
    /// warms the haze along this bearing and hangs the water's glints off
    /// it; see `encodeSunComponent` for how it gets there.
    private static var currentSun: SIMD3<Float> = SIMD3(0, 1, 0)

    /// Packs one component of the sun direction into a nominally-PBR scalar
    /// slot.
    ///
    /// `CustomMaterial` offers exactly one `SIMD4<Float>` of free storage
    /// (`custom.value`), and all four of its lanes are spent on the fog
    /// range and the water band. Everything else has to ride in a slot that
    /// means something to a lit material and nothing at all to an unlit one:
    /// roughness, metallic and specular are three such slots, and the block
    /// materials are unlit.
    ///
    /// They are scales, though, and nothing documents what a negative or
    /// out-of-range scale does on the way to the shader — so the [-1,1] of a
    /// direction component is folded into [0,1] here and unfolded in
    /// `blockSurface`. `cloudSurface` reads the sun through the same three
    /// slots and unfolds it the same way, which is why this is shared.
    static func encodeSunComponent(_ value: Float) -> Float {
        value * 0.5 + 0.5
    }

    /// Packs a colour into one `custom.value` lane as three 8-bit channels.
    ///
    /// The lane is a real float32 — checked in a render rather than assumed,
    /// by shading half a scene from an unpacked colour and the other half
    /// from the same colour as a shader literal and diffing the two (they
    /// came out identical to the byte) — and every integer below 2^24 is
    /// exactly representable, so this round-trips losslessly. Dividing by
    /// 2^24 keeps the lane inside 0…1, which is the range every other
    /// number the material carries lives in.
    ///
    /// Eight bits a channel is exactly what the sky dome's own lookup
    /// stores, so the water cannot mirror a colour finer than the sky it is
    /// mirroring anyway. Unpacked by `unpackColor888` in `BlockShaders`.
    private static func packColor(_ rgb: SIMD3<Float>) -> Float {
        let clamped = rgb.clamped(lowerBound: .zero, upperBound: .one) * 255
        let red = clamped.x.rounded(), green = clamped.y.rounded(), blue = clamped.z.rounded()
        return (red * 65536 + green * 256 + blue) / 16_777_216
    }

    // MARK: - The two materials

    /// Nil when the shader library did not load; the `UnlitMaterial` pair
    /// below then stands in.
    private static var opaqueCustom: CustomMaterial? = makeCustom(translucent: false)
    private static var translucentCustom: CustomMaterial? = makeCustom(translucent: true)
    private static var opaqueUnlit: UnlitMaterial = makeUnlit(translucent: false)
    private static var translucentUnlit: UnlitMaterial = makeUnlit(translucent: true)

    static var opaqueBlocks: any Material { opaqueCustom ?? opaqueUnlit }
    static var translucentBlocks: any Material { translucentCustom ?? translucentUnlit }

    private static func makeCustom(translucent: Bool) -> CustomMaterial? {
        guard let shader = blockSurfaceShader, let atlasResource,
              var material = try? CustomMaterial(surfaceShader: shader, lightingModel: .unlit)
        else { return nil }

        // No sampler here: the shader declares its own nearest-neighbour
        // sampler, which is what actually reads this texture.
        material.custom.texture = .init(atlasResource)
        // Water and glass read through to what's behind them and are drawn
        // two-sided; opaque blocks use a cutout threshold so the pass never
        // pays for blending while still discarding fully transparent texels.
        // Both of these are set once and never touched again — switching a
        // material to transparent blending is the single most expensive
        // assignment in this file.
        if translucent {
            material.blending = .transparent(opacity: 1.0)
            material.opacityThreshold = nil
            material.faceCulling = .none
        } else {
            material.opacityThreshold = 0.5
            material.faceCulling = .back
        }
        // Two slots the shader does not read yet, pinned rather than left
        // at whatever the default is, so the next thing to smuggle
        // something through them starts from a known value.
        material.clearcoat = .init(scale: 0)
        material.clearcoatRoughness = .init(scale: 0)
        grade(&material, translucent: translucent)
        return material
    }

    private static func makeUnlit(translucent: Bool) -> UnlitMaterial {
        var material = UnlitMaterial()
        grade(&material)
        if translucent {
            material.blending = .transparent(opacity: 1.0)
            material.opacityThreshold = nil
            material.faceCulling = .none
        } else {
            material.opacityThreshold = 0.5
            material.faceCulling = .back
        }
        return material
    }

    /// (fogStart, fogEnd, which pass this is, packed zenith colour) — every
    /// free lane the custom parameter has, and one more number than it has
    /// lanes, which is why the colour travels as a compressed integer; see
    /// `packColor` for why that is lossless.
    ///
    /// Lane z is 1 on the translucent material and 0 on the opaque one. The
    /// shader needs it because the translucent pass is drawn two-sided:
    /// RealityKit hands a surface shader a normal that has already been
    /// turned to face the viewer, so on that pass the mesher's own face
    /// direction — and with it the tint baked into the atlas variant — is
    /// not recoverable, and the directional relight has to be skipped.
    private static func customValue(translucent: Bool) -> SIMD4<Float> {
        SIMD4(
            fogRange.x,
            fogRange.y,
            translucent ? 1 : 0,
            packColor(currentZenith)
        )
    }

    /// Writes the current time of day into a material. Everything here is
    /// cheap; nothing here reallocates the material.
    private static func grade(_ material: inout CustomMaterial, translucent: Bool) {
        material.baseColor = .init(tint: currentTint)
        // The shader writes the emissive output itself, which leaves this
        // constant free to carry the fog colour in.
        material.emissiveColor = .init(color: currentFog)
        material.roughness = .init(scale: encodeSunComponent(currentSun.x))
        material.metallic = .init(scale: encodeSunComponent(currentSun.y))
        material.specular = .init(scale: encodeSunComponent(currentSun.z))
        // The zenith rides in a lane of this, so the grade has to rewrite it
        // — it is four floats in the material's constant block, not a
        // texture or a blend mode, and costs what the assignments above do.
        material.custom.value = customValue(translucent: translucent)
    }

    /// The fallback carries the daylight tint and nothing else — no fog, no
    /// sun, since a stock `UnlitMaterial` has nowhere to put them.
    private static func grade(_ material: inout UnlitMaterial) {
        if let atlasResource {
            material.color = .init(tint: currentTint, texture: .init(atlasResource, sampler: blockSampler))
        } else {
            material.color = .init(tint: currentTint)
        }
    }

    /// Moves the haze to a new horizon.
    ///
    /// Fog end *is* the render distance — the haze has to be opaque by the
    /// time the last chunk stops, or the render edge shows through it as a
    /// hard rim of terrain against the sky. Everything the sky is built out
    /// of has to stay outside this: the cloud deck's fade finishes at 330
    /// blocks, the dome sits at 340, and the camera's far plane is at 400,
    /// against 160 at the default distance. The tighter of those is the far
    /// plane, because the *corner* of the render square is √2 further out
    /// than the radius — 226 blocks at the default. `World.renderDistanceLimits`
    /// is what keeps that ordering true.
    static func setRenderDistance(blocks: Float) {
        let range = SIMD2(blocks * fogStartFraction, blocks)
        guard range != fogRange else { return }
        fogRange = range
        opaqueCustom?.custom.value = customValue(translucent: false)
        translucentCustom?.custom.value = customValue(translucent: true)
        pushToChunks()
    }

    /// Re-grades every block in the world for the time of day. `fog` is the
    /// sky colour at the horizon, so distant terrain dissolves into the same
    /// skyline the background is painted with; `zenith` is the other end of
    /// that gradient, which only the water reads; and `sunDirection` points
    /// at the sun.
    ///
    /// Callers are expected to quantise: `SkyController` only calls this a
    /// few times a second, because every call walks every chunk on screen.
    static func applyDaylight(
        tint: NSColor,
        fog: NSColor,
        zenith: SIMD3<Float>,
        sunDirection: SIMD3<Float>
    ) {
        guard tint != currentTint || fog != currentFog
                || zenith != currentZenith || sunDirection != currentSun else { return }
        currentTint = tint
        currentFog = fog
        currentZenith = zenith
        currentSun = sunDirection

        if var material = opaqueCustom { grade(&material, translucent: false); opaqueCustom = material }
        if var material = translucentCustom { grade(&material, translucent: true); translucentCustom = material }
        grade(&opaqueUnlit)
        grade(&translucentUnlit)
        pushToChunks()
    }

    // MARK: - Keeping the world in step

    /// Every chunk entity currently drawn with these materials.
    ///
    /// RealityKit materials are values, not references: a `ModelEntity`
    /// keeps a copy of whatever material it was built with, so editing the
    /// materials above reaches nothing that is already on screen. Left at
    /// that, the world stays frozen at the daylight it was meshed under
    /// while the sky above it goes on moving — verified in a render, not
    /// assumed (`BLOCKHAVEN_SNAPSHOT_REGRADE` in `OffscreenSnapshot` exists
    /// to reproduce it). Chunks register here instead and have the new
    /// material pushed onto them.
    ///
    /// The references are weak, so unloading a chunk is still all it takes
    /// to forget one; dead entries are swept out on the next push. The
    /// sweep measured 1.4 ms over the ~200 chunks that were live when the
    /// render distance was 7; at 10 it is 317 surface entities on the
    /// benchmark capture, and the cost goes with that count. It is still
    /// worth doing outright rather than amortising — it runs on the grade
    /// quantum, a few times a second, not every frame — but it is the one
    /// per-frame cost that scales with render distance *outside* the
    /// streaming loop, so it is the thing to look at first if the distance
    /// is pushed further.
    private struct TrackedChunk {
        weak var entity: ModelEntity?
        let translucent: Bool
    }

    private static var trackedChunks: [TrackedChunk] = []

    /// Registers a freshly meshed chunk entity for re-grading. It should
    /// already be carrying `opaqueBlocks` or `translucentBlocks`.
    static func track(_ entity: ModelEntity, translucent: Bool) {
        trackedChunks.append(TrackedChunk(entity: entity, translucent: translucent))
    }

    private static func pushToChunks() {
        let opaque = opaqueBlocks
        let translucent = translucentBlocks
        var live: [TrackedChunk] = []
        live.reserveCapacity(trackedChunks.count)
        for tracked in trackedChunks {
            guard let entity = tracked.entity else { continue }
            entity.model?.materials = [tracked.translucent ? translucent : opaque]
            live.append(tracked)
        }
        trackedChunks = live
    }

    /// The dark wireframe drawn around the targeted block.
    static let selectionOutline: UnlitMaterial = {
        var material = UnlitMaterial()
        material.color = .init(tint: NSColor(calibratedWhite: 0.02, alpha: 1))
        material.faceCulling = .none
        return material
    }()

    /// The crack overlay stretched over the block being mined.
    static func breakOverlay(stage: Int) -> UnlitMaterial {
        let clamped = max(0, min(9, stage))
        if let cached = breakCache[clamped] { return cached }
        var material = UnlitMaterial()
        if let atlasResource {
            material.color = .init(
                tint: .white,
                texture: .init(atlasResource, sampler: blockSampler)
            )
        }
        material.blending = .transparent(opacity: 1.0)
        material.faceCulling = .none
        breakCache[clamped] = material
        return material
    }

    private static var breakCache: [Int: UnlitMaterial] = [:]
}
#endif

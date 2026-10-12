#if canImport(AppKit)
import RealityKit
import AppKit
import CoreGraphics
import simd

/// Everything the sky is made of: a gradient dome, the sun, the moon, and
/// one drifting cloud layer — nested shells, all unlit, all carrying their
/// own tiny procedural skins. Nothing here reads the block atlas or the
/// daylight tint, which is what keeps the moon bright after
/// `MaterialLibrary.applyDaylight` has darkened every block in the world.
///
/// The shells are positioned relative to the camera every frame at fixed
/// radii, so walking never gets closer to them and they never run out as
/// the player roams:
///
///   dome   340  the gradient sky itself — the farthest thing drawn
///   sun    220  on a camera-centred orbit
///   moon   220  the same orbit, half a turn behind
///
/// The clouds are the exception and live in `CloudLayer`: a real field of
/// extruded boxes at a fixed world altitude, re-centred on the camera in
/// whole tile periods rather than hung on a shell.
///
/// Draw order falls out of that nesting for free. The dome is opaque, so it
/// renders in the opaque pass — before every transparent thing in the scene,
/// which is all three of the others — and it writes no depth, so it cannot
/// occlude anything even if the renderer decides to draw it first.
///
/// **Nothing in the sky writes depth.** The dome never did; the clouds, the
/// sun and the moon were changed to match when the god-ray pass started
/// reading the depth buffer, because they were filling it with shells 70 to
/// 260 blocks away and a screen-space effect asking "is this pixel sky?"
/// got "no" for every pixel of sky in the frame. They are all camera-
/// following shells that can never legitimately occlude anything, so the
/// rule is worth stating as a rule: the depth buffer this game hands to a
/// post pass contains terrain and mobs and nothing else. The only visible
/// consequence is that a cloud behind the sun's glow tile is no longer cut
/// out of the layer by a hard 150-block square, which is a fix, not a
/// regression — see the `sky-depth` captures behind the god-ray commit.
///
/// `SkyController` owns the one instance of this and drives it from
/// `apply(view:dt:)`.
@MainActor
final class SkyEntities {
    /// The sky shell. Comfortably outside every other shell and inside the
    /// camera's 400-block far plane, with room to spare for the sun quad's
    /// corners.
    private static let domeRadius: Float = 340
    /// Orbit radius for the sun and moon, in blocks.
    private static let orbitRadius: Float = 220
    /// Quad sizes, which are now mostly glow: the sun's disc is the inner
    /// ~16% of its tile and the moon's the inner ~18%, so these are roughly
    /// 6x the size of the body they carry. See `CelestialSkin`.
    private static let sunSize: Float = 150
    private static let moonSize: Float = 104
    /// How much bigger the sun gets at dawn and dusk. Low sun through thick
    /// air is both larger and softer, and it is the shot the whole grade is
    /// built around, so it earns the extra half.
    private static let sunHorizonSwell: Float = 0.5

    /// How finely the day is sliced for re-tinting. Colours are recomputed
    /// only when the slice changes: at a 600-second day that is about three
    /// times a second, which is far below the rate any of these colours can
    /// visibly move (a whole dusk spans ~160 slices) and keeps material and
    /// texture churn off the frame budget entirely.
    ///
    /// `SkyController` re-grades the block materials on the same slice, for
    /// the same reason — there it also means walking every chunk on screen.
    static let gradeSlices: Double = 2048

    /// Which slice of the day a time falls in. Everything graded off the
    /// clock quantises through this, so nothing re-grades per frame.
    static func gradeSlice(of timeOfDay: Double) -> Int {
        Int(timeOfDay * gradeSlices)
    }

    /// The same quantisation, deliberately *half a slice out of phase* with
    /// it.
    ///
    /// The sky's own repaint and `MaterialLibrary.applyDaylight`'s walk over
    /// every chunk entity are both a few-times-a-second burst, and keyed on
    /// the same slice they landed on the same frame — one frame paying for
    /// both, three times a second, which is exactly the shape of a visible
    /// hitch. Offsetting the sky by half a slice interleaves them: each
    /// still runs at its own rate, but never on the same frame as the
    /// other. Half a slice is 0.15 s of a 600 s day, far below anything
    /// either of these colours can visibly move in.
    static func skyGradeSlice(of timeOfDay: Double) -> Int {
        gradeSlice(of: timeOfDay + 0.5 / gradeSlices)
    }

    /// The unit vector from the eye toward the sun, for a point on its
    /// orbit. 0 is noon (straight up), `.pi` is midnight (straight down).
    ///
    /// One definition, shared by the orbit that places the sun quad and by
    /// the sun channel the block shader reads — so the glint on the water
    /// and the disc in the sky can never disagree about where the light is.
    static func sunDirection(angle: Float) -> SIMD3<Float> {
        SIMD3(sin(angle), cos(angle), 0)
    }

    /// The angle on that orbit for a time of day.
    static func sunAngle(at timeOfDay: Double) -> Float {
        Float((timeOfDay - 0.25) * 2 * .pi)
    }

    /// A fixed-at-origin anchor: children's local positions are world
    /// positions, same convention as `GameViewController.worldAnchor`.
    let anchor = AnchorEntity(world: .zero)

    private let dome = ModelEntity(mesh: SkyEntities.domeMesh(), materials: [SkyEntities.domeMaterial])

    /// The two transparent materials the grade moves, built once and then
    /// *edited*.
    ///
    /// They used to be rebuilt from scratch on every grade slice — six fresh
    /// `UnlitMaterial`s, three times a second — which measured 5.3–10 ms of
    /// synchronous main-thread work per slice, dominated by the `blending`
    /// setter. `MaterialLibrary` learned the same lesson about the block
    /// materials; this is that lesson applied to the sky. Only `color`
    /// changes per slice now.
    private var sunMaterial = SkyEntities.makeSunMaterial(tint: .one)
    private var moonMaterial = SkyEntities.makeMoonMaterial(tint: .one)

    private lazy var sun = ModelEntity(mesh: SkyEntities.quadMesh(size: SkyEntities.sunSize), materials: [sunMaterial])
    private lazy var moon = ModelEntity(mesh: SkyEntities.quadMesh(size: SkyEntities.moonSize), materials: [moonMaterial])
    /// The point of light on the other body: the garden's beacon seen from
    /// home, or home's own light seen from the Moon. A plain square, so at
    /// this distance it reads as a spark rather than a shape.
    private lazy var beaconDot = ModelEntity(
        mesh: SkyEntities.quadMesh(size: 7),
        materials: [SkyEntities.skinMaterial(nil, tint: SIMD3(1.0, 0.86, 0.45), opacity: 1,
                                             sampler: SkyEntities.smoothSampler, writesDepth: false)]
    )
    /// Whether the moon disc is currently tinted as the home world.
    private var tintedAsHome = false
    private let clouds = CloudLayer()

    /// Which slice of the day the current tints were built for, or -1 when
    /// nothing has been graded yet.
    private var gradedSlice = -1

    init() {
        // With no gradient texture there is nothing to paint the dome with,
        // so it stays out of the scene and the flat background colour
        // `SkyController` sets shows through instead.
        if SkyEntities.domeTexture != nil { anchor.addChild(dome) }
        anchor.addChild(sun)
        anchor.addChild(moon)
        anchor.addChild(beaconDot)
        anchor.addChild(clouds.entity)
    }

    /// Repositions everything around `cameraPosition` and re-grades it for
    /// the time of day. Called once a frame from `SkyController.apply`, and
    /// also (with `dt` 0) whenever the grade is applied without a tick, so a
    /// time-of-day set from the debug HUD or the snapshot harness still
    /// shows the right sky immediately.
    func update(
        timeOfDay: Double,
        zenith: SIMD3<Float>,
        horizon: SIMD3<Float>,
        cameraPosition: SIMD3<Float>,
        dt: Double,
        beacon: Float = 0,
        lunar: Bool = false
    ) {
        // 0.25 (noon) -> angle 0 -> straight up. 0.75 (midnight) -> angle
        // pi -> straight down. The moon runs the same arc, offset by half a
        // turn, so it always rises as the sun sets and vice versa.
        let sunAngle = SkyEntities.sunAngle(at: timeOfDay)
        place(sun, around: cameraPosition, angle: sunAngle)
        place(moon, around: cameraPosition, angle: sunAngle + .pi)
        // A little off the disc's centre, toward its upper edge, and a
        // little nearer than the disc so it always draws in front of it.
        let moonDirection = SkyEntities.sunDirection(angle: sunAngle + .pi + 0.035)
        beaconDot.position = cameraPosition + moonDirection * (SkyEntities.orbitRadius - 3)
        beaconDot.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: -moonDirection)
        beaconDot.isEnabled = beacon > 0.5
        // From the Moon, what hangs in the sky is home — and there are no
        // clouds to drift across it.
        clouds.entity.isEnabled = !lunar
        if lunar != tintedAsHome {
            tintedAsHome = lunar
            gradedSlice = -1
        }
        // Transform-only, so this can move every frame for free.
        sun.scale = .init(repeating: 1 + SkyEntities.sunHorizonSwell * SkyEntities.lowSun(sunAngle))

        dome.position = cameraPosition
        // The cloud field carries its own absolute altitude, so only the
        // horizontal re-centring and the wind go into its position.
        clouds.update(cameraPosition: cameraPosition, dt: dt)

        let slice = SkyEntities.skyGradeSlice(of: timeOfDay)
        if slice != gradedSlice {
            gradedSlice = slice
            regrade(zenith: zenith, horizon: horizon, sunAngle: sunAngle)
        }
    }

    /// Drops the memory of which slice the sky is graded for, so the next
    /// `update` re-grades whatever it lands on.
    ///
    /// A time jump — loading a save, the debug clock, the snapshot harness —
    /// can land inside the slice the sky is already graded for, and without
    /// this the sky would keep the colours of the time that was jumped away
    /// from while the terrain around it re-graded. `SkyController` forgets
    /// its own slice for the same reason and calls this alongside it.
    func forgetGrade() {
        gradedSlice = -1
    }

    /// Places a celestial quad on the arc and turns it to face back along
    /// the same radius it sits on — correct regardless of camera rotation,
    /// since the offset direction never depends on it.
    private func place(_ entity: ModelEntity, around center: SIMD3<Float>, angle: Float) {
        let offset = SkyEntities.sunDirection(angle: angle) * SkyEntities.orbitRadius
        entity.position = center + offset
        entity.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: -normalize(offset))
    }

    // MARK: - Grading

    /// How much of a golden hour this is: 1 with the sun on the horizon,
    /// falling to 0 with it overhead or fully down. Everything warm — the
    /// horizon glow, the swollen sun, the peach cloud bellies — is scaled
    /// by this one number, so they all arrive and leave together.
    private static func lowSun(_ sunAngle: Float) -> Float {
        powf(max(0, 1 - abs(cos(sunAngle))), 2)
    }

    /// Rebuilds every colour the sky carries. Runs a few times a second
    /// (see `gradeSlices`), never per frame: one texture upload of 32 KB
    /// and six small materials.
    private func regrade(zenith zenithRGB: SIMD3<Float>, horizon horizonRGB: SIMD3<Float>, sunAngle: Float) {
        // 1 at noon, 0 at the horizon, -1 at midnight.
        let sunHeight = cos(sunAngle)
        let low = SkyEntities.lowSun(sunAngle)
        // How far into the night: 0 while the sun is still up, 1 once it is
        // well down. Ramped rather than switched, so nothing pops.
        let night = min(1, max(0, (-sunHeight - 0.05) / 0.55))

        // The glow is a hotter, paler relative of the horizon band it sits
        // inside, so it reads as the same light source rather than a
        // second colour pasted over the sky.
        let glow = blend(horizonRGB, SIMD3(1.0, 0.84, 0.58), 0.5)
        // The sun is always on the world X axis, so its bearing is one of
        // two directions; deriving it from the orbit anyway keeps this
        // honest if the orbit is ever tilted.
        let sunAzimuth: Float = sin(sunAngle) >= 0 ? 0 : .pi

        if let image = SkyEntities.gradientImage(
            zenith: zenithRGB,
            horizon: horizonRGB,
            glow: glow,
            glowStrength: low * 0.7,
            sunAzimuth: sunAzimuth
        ) {
            try? SkyEntities.domeTexture?.replace(
                withImage: image,
                options: .init(semantic: .color, mipmapsMode: .none)
            )
        }

        // White-yellow overhead, gold on the horizon — and no darker than
        // that, because the sky it has to stand out against is at its
        // brightest exactly when the sun is lowest. A deeper amber disc
        // disappears into its own glow.
        retint(
            &sunMaterial,
            SkyEntities.sunTexture,
            blend(SIMD3(1, 1, 1), SIMD3(1.0, 0.83, 0.56), low),
            sampler: SkyEntities.smoothSampler
        )
        sun.model?.materials = [sunMaterial]
        // The moon only ever cools slightly, into the deep blue of a sky it
        // is the only light in.
        retint(
            &moonMaterial,
            SkyEntities.moonTexture,
            tintedAsHome ? SIMD3(0.42, 0.68, 1.0) : blend(SIMD3(1, 1, 1), SIMD3(0.86, 0.90, 1.0), night),
            sampler: SkyEntities.smoothSampler
        )
        moon.model?.materials = [moonMaterial]

        // White by day, peach in the golden hour — more of it underneath
        // than on top — dim blue at night, and thinner at night so the moon
        // stays the thing being looked at. `CloudLayer` owns the split
        // between its three face directions.
        clouds.regrade(
            low: low,
            night: night,
            horizon: horizonRGB,
            sunDirection: SkyEntities.sunDirection(angle: sunAngle)
        )
    }

    /// The one edit a grade slice makes to a sky material: its tint. The
    /// texture, sampler, blending and face culling it was built with are
    /// left exactly as they were — re-setting those is what used to cost
    /// milliseconds.
    private func retint(
        _ material: inout UnlitMaterial,
        _ resource: TextureResource?,
        _ tint: SIMD3<Float>,
        sampler: MaterialParameters.Texture.Sampler
    ) {
        let color = SkyEntities.nsColor(tint)
        if let resource {
            material.color = .init(tint: color, texture: .init(resource, sampler: sampler))
        } else {
            material.color = .init(tint: color)
        }
    }

    // MARK: - Meshes

    /// A flat square in the local XY plane, normal +Z. Sized once per body
    /// and reoriented per frame rather than rebuilt.
    private static func quadMesh(size: Float) -> MeshResource {
        let half = size / 2
        var descriptor = MeshDescriptor(name: "sky-quad")
        descriptor.positions = MeshBuffers.Positions([
            SIMD3(-half, -half, 0), SIMD3(half, -half, 0), SIMD3(half, half, 0), SIMD3(-half, half, 0),
        ])
        let normal = SIMD3<Float>(0, 0, 1)
        descriptor.normals = MeshBuffers.Normals([normal, normal, normal, normal])
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates([
            SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0),
        ])
        descriptor.primitives = .triangles([0, 1, 2, 0, 2, 3])
        return (try? MeshResource.generate(from: [descriptor])) ?? MeshResource.generateBox(size: 1)
    }

    private static let domeRings = 24
    private static let domeSegments = 32

    /// The sky shell: a full sphere around the eye, seen from the inside.
    ///
    /// UVs address `gradientImage`'s lookup directly — u is the compass
    /// bearing, v runs from the zenith to the nadir by elevation *angle*,
    /// which is what the lookup's rows are spaced by. Textures reach the
    /// sampler with v mirrored (the block shader flips its own atlas reads
    /// for the same reason), so the coordinate written here is mirrored
    /// too: `1 - v` at the zenith reads the lookup's first row. Verified in
    /// a render, not assumed — unflipped, the whole visible sky came out
    /// the flat horizon colour.
    ///
    /// The seam column is duplicated (`0...segments`, not a wrap-around
    /// index) so the last quad interpolates u from 31/32 up to 1 instead of
    /// running backwards across the whole texture.
    private static func domeMesh() -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var normals: [SIMD3<Float>] = []
        for ring in 0...domeRings {
            let v = Float(ring) / Float(domeRings)
            let polar = v * .pi
            let y = cos(polar), radius = sin(polar)
            for segment in 0...domeSegments {
                let u = Float(segment) / Float(domeSegments)
                let theta = u * 2 * .pi
                let direction = SIMD3<Float>(cos(theta) * radius, y, sin(theta) * radius)
                positions.append(direction * domeRadius)
                uvs.append(SIMD2(u, 1 - v))
                // Inward, toward the eye. Unlit ignores this, but a mesh
                // with normals pointing away from every viewer it can ever
                // have is a trap for whatever reads them next.
                normals.append(-direction)
            }
        }

        var indices: [UInt32] = []
        let stride = UInt32(domeSegments + 1)
        for ring in 0..<domeRings {
            let inner = UInt32(ring) * stride
            let outer = inner + stride
            for segment in 0..<domeSegments {
                let current = UInt32(segment)
                let next = current + 1
                indices += [inner + current, outer + current, outer + next]
                indices += [inner + current, outer + next, inner + next]
            }
        }

        var descriptor = MeshDescriptor(name: "sky-dome")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor])) ?? MeshResource.generateBox(size: 1)
    }

    // MARK: - The gradient lookup

    /// One column per compass bearing, one row per elevation. Small on
    /// purpose: it is stretched over the whole sky and sampled with linear
    /// filtering, so its resolution sets nothing but how finely the horizon
    /// glow is shaped.
    private static let lutWidth = 64
    private static let lutHeight = 128
    /// Reused between rebuilds rather than reallocated three times a second.
    private static var lutBytes = [UInt8](repeating: 255, count: lutWidth * lutHeight * 4)

    /// Paints the sky into the lookup: a vertical zenith-to-horizon ramp,
    /// with a warm glow banked around the sun's bearing near the horizon.
    ///
    /// Rows run zenith (v=0) to nadir (v=1) by elevation angle, matching
    /// `domeMesh`'s UVs, and everything at or below the horizon is the flat
    /// horizon colour — which is also the colour distant terrain fogs into,
    /// so the two meet without a seam.
    private static func gradientImage(
        zenith: SIMD3<Float>,
        horizon: SIMD3<Float>,
        glow: SIMD3<Float>,
        glowStrength: Float,
        sunAzimuth: Float
    ) -> CGImage? {
        for y in 0..<lutHeight {
            let v = (Float(y) + 0.5) / Float(lutHeight)
            // 1 at the zenith, 0 at the horizon and anywhere below it.
            let above = max(0, 1 - 2 * v)
            // Weighted toward the horizon: the band of horizon colour hugs
            // the skyline and the zenith colour owns most of the dome,
            // which is what a real sky does and what makes a sunset read as
            // a fire on the horizon rather than an orange ceiling.
            let lift = 1 - powf(1 - above, 2.2)
            let band = blend(horizon, zenith, lift)
            let hug = powf(1 - above, 3.0)
            for x in 0..<lutWidth {
                let azimuth = (Float(x) + 0.5) / Float(lutWidth) * 2 * .pi
                let toward = max(0, cos(azimuth - sunAzimuth))
                let strength = min(1, powf(toward, 2.5) * hug * glowStrength)
                let color = blend(band, glow, strength)
                let index = (y * lutWidth + x) * 4
                lutBytes[index] = channel(color.x)
                lutBytes[index + 1] = channel(color.y)
                lutBytes[index + 2] = channel(color.z)
                lutBytes[index + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(lutBytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: lutWidth,
            height: lutHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: lutWidth * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Created once and then rewritten in place by `regrade`, so the dome's
    /// material and the mesh it hangs on never change after startup.
    private static let domeTexture: TextureResource? = {
        guard let image = gradientImage(
            zenith: SIMD3(0.32, 0.60, 0.98),
            horizon: SIMD3(0.66, 0.84, 1.0),
            glow: SIMD3(1, 1, 1),
            glowStrength: 0,
            sunAzimuth: 0
        ) else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .none))
    }()

    // MARK: - Materials

    /// The sun and moon are the one place the chunky look is wrong: their
    /// glow is a smooth falloff stretched over 150 blocks of sky, and
    /// nearest sampling would step it into visible rings.
    private static let smoothSampler: MaterialParameters.Texture.Sampler = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return MaterialParameters.Texture.Sampler(descriptor)
    }()

    /// Wraps around the compass, clamps at the poles, and interpolates —
    /// the gradient's smoothness comes from this filtering, not from the
    /// size of the lookup.
    private static let domeSampler: MaterialParameters.Texture.Sampler = {
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .clampToEdge
        return MaterialParameters.Texture.Sampler(descriptor)
    }()

    /// Opaque, and deliberately depth-blind: it reads depth so terrain
    /// covers it, and writes none so it can never cover anything itself.
    /// That, plus being opaque while the sun, moon and clouds are
    /// transparent, is the whole of the sky's draw ordering.
    private static let domeMaterial: UnlitMaterial = {
        var material = UnlitMaterial()
        if let domeTexture {
            material.color = .init(tint: .white, texture: .init(domeTexture, sampler: domeSampler))
        }
        material.faceCulling = .none
        material.writesDepth = false
        return material
    }()

    private static let sunTexture = texture(CelestialSkin.sun)
    private static let moonTexture = texture(CelestialSkin.moon)

    private static func texture(_ image: CGImage?) -> TextureResource? {
        guard let image else { return nil }
        return try? TextureResource(image: image, options: .init(semantic: .color, mipmapsMode: .none))
    }

    /// Unlit and two-sided: the skin's own alpha carries the shape, and
    /// facing math only needs to be approximately right since either side
    /// of the quad still draws.
    private static func skinMaterial(
        _ resource: TextureResource?,
        tint: SIMD3<Float>,
        opacity: Float,
        sampler: MaterialParameters.Texture.Sampler,
        writesDepth: Bool = true
    ) -> UnlitMaterial {
        var material = UnlitMaterial()
        let color = nsColor(tint)
        if let resource {
            material.color = .init(tint: color, texture: .init(resource, sampler: sampler))
        } else {
            material.color = .init(tint: color)
        }
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.faceCulling = .none
        material.writesDepth = writesDepth
        return material
    }

    private static func makeSunMaterial(tint: SIMD3<Float>) -> UnlitMaterial {
        skinMaterial(sunTexture, tint: tint, opacity: 1, sampler: smoothSampler, writesDepth: false)
    }

    private static func makeMoonMaterial(tint: SIMD3<Float>) -> UnlitMaterial {
        skinMaterial(moonTexture, tint: tint, opacity: 1, sampler: smoothSampler, writesDepth: false)
    }

    // MARK: - Colour plumbing

    // Colours arrive here as raw sRGB components and only become `NSColor`s
    // where AppKit or RealityKit demands one — `SkyController` keeps its
    // keys the same way, so nothing round-trips through ColorSync on a
    // frame.
    private static func nsColor(_ rgb: SIMD3<Float>) -> NSColor {
        NSColor(
            srgbRed: CGFloat(max(0, min(1, rgb.x))),
            green: CGFloat(max(0, min(1, rgb.y))),
            blue: CGFloat(max(0, min(1, rgb.z))),
            alpha: 1
        )
    }
}

/// Linear blend, `t` 0 for `a` and 1 for `b`.
private func blend(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    a + (b - a) * max(0, min(1, t))
}

/// One colour component, 0…1, as a byte.
private func channel(_ value: Float) -> UInt8 {
    UInt8(max(0, min(255, value * 255 + 0.5)))
}

/// Hermite ramp between two edges, in either direction.
private func smoothRamp(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    guard edge0 != edge1 else { return x < edge0 ? 0 : 1 }
    let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)
}

/// Procedural skins for the sun and moon. Both are a small body sitting in
/// the middle of a much larger tile of glow: the body is the inner sixth or
/// so, and everything outside it is a radial falloff to nothing at the tile
/// edge. That long tail is the point — it is what a bloom pass has to grab
/// hold of later, and what makes a low sun read as light rather than a
/// sticker.
private enum CelestialSkin {
    static let sun: CGImage? = sunImage()
    static let moon: CGImage? = moonImage()

    /// Where the sun's disc ends, as a fraction of the tile's half-width.
    private static let sunDisc: Float = 0.185
    private static let moonDisc: Float = 0.18

    private static func sunImage() -> CGImage? {
        let core = SIMD3<Float>(1.0, 0.97, 0.84)
        let rim = SIMD3<Float>(1.0, 0.86, 0.52)
        let far = SIMD3<Float>(1.0, 0.66, 0.28)
        return render(size: 128) { radius, _, _ in
            let disc = smoothRamp(sunDisc + 0.03, sunDisc - 0.02, radius)
            // Two falloffs: a tight one that keeps the light packed against
            // the disc, and a long one that carries a wash most of the way
            // out to the tile edge.
            let halo = 0.62 * powf(max(0, 1 - radius), 5.0) + 0.34 * powf(max(0, 1 - radius), 1.8)
            let warmth = smoothRamp(0.05, 0.55, radius)
            let color = blend(blend(core, rim, warmth), far, smoothRamp(0.35, 0.95, radius))
            return (color, min(1, disc + halo))
        }
    }

    private static func moonImage() -> CGImage? {
        let bright = SIMD3<Float>(0.93, 0.94, 0.99)
        let limb = SIMD3<Float>(0.74, 0.78, 0.90)
        let crater = SIMD3<Float>(0.72, 0.76, 0.86)
        let craterDeep = SIMD3<Float>(0.63, 0.67, 0.79)
        let haze = SIMD3<Float>(0.56, 0.66, 0.92)
        // Craters as placed circles — (x, y, radius) with the disc's own
        // radius as 1 — because craters drawn from a noise lattice were the
        // bug this fixed: at seventeen pixels of disc, noise reads as grey
        // squiggles on a white circle, not as a moon. A handful of round
        // ones and a shaded limb read as a picture-book moon at any size.
        let craters: [(x: Float, y: Float, r: Float)] = [
            (-0.38, -0.12, 0.30), (0.34, 0.36, 0.24), (0.28, -0.44, 0.17),
            (-0.18, 0.48, 0.14), (0.54, -0.08, 0.11), (-0.58, 0.26, 0.10),
        ]
        let tile: Float = 192
        return render(size: Int(tile)) { (radius: Float, x: Int, y: Int) -> (SIMD3<Float>, Float) in
            let disc: Float = smoothRamp(moonDisc + 0.02, moonDisc - 0.01, radius)
            // This texel's place on the face, disc radius as 1.
            let unitX: Float = (Float(x) + 0.5) / tile * 2 - 1
            let unitY: Float = (Float(y) + 0.5) / tile * 2 - 1
            let fx: Float = unitX / moonDisc
            let fy: Float = unitY / moonDisc
            var body = bright
            for pit in craters {
                let dx: Float = fx - pit.x
                let dy: Float = fy - pit.y
                let d: Float = sqrt(dx * dx + dy * dy)
                if d < pit.r { body = d < pit.r * 0.55 ? craterDeep : crater }
            }
            // Darkened toward the rim, which is what turns a flat circle
            // into a ball.
            body = blend(body, limb, smoothRamp(0.72, 1.05, radius / moonDisc))
            // A quarter of the sun's glow, and cooler: enough to sit in the
            // night sky as a light source, not enough to grey it out.
            let tail: Float = max(0, 1 - radius)
            let halo: Float = 0.26 * powf(tail, 3.2)
            return (blend(haze, body, disc), min(1, disc + halo))
        }
    }

    /// Walks every texel of a square tile, handing back its distance from
    /// the centre (0 in the middle, 1 at the edge midpoints) alongside its
    /// coordinates, and packs the colour and alpha it gets back into a
    /// premultiplied RGBA image.
    private static func render(
        size: Int,
        _ shade: (Float, Int, Int) -> (SIMD3<Float>, Float)
    ) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            let dy = (Float(y) + 0.5) / Float(size) * 2 - 1
            for x in 0..<size {
                let dx = (Float(x) + 0.5) / Float(size) * 2 - 1
                let (color, alpha) = shade(sqrt(dx * dx + dy * dy), x, y)
                guard alpha > 0.002 else { continue }
                let index = (y * size + x) * 4
                bytes[index] = channel(color.x * alpha)
                bytes[index + 1] = channel(color.y * alpha)
                bytes[index + 2] = channel(color.z * alpha)
                bytes[index + 3] = channel(alpha)
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
#endif

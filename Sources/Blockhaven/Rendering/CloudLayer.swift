#if canImport(AppKit)
import RealityKit
import AppKit
import simd

/// The field as a RealityKit mesh, its triangles split into the three
/// face materials.
extension CloudMesh {
    static let meshResource: MeshResource? = {
        let field = CloudMesh.field
        var descriptor = MeshDescriptor(name: "cloud-field")
        descriptor.positions = MeshBuffers.Positions(field.positions)
        descriptor.normals = MeshBuffers.Normals(field.normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(field.uvs)
        descriptor.primitives = .triangles(field.indices)
        descriptor.materials = .perFace(field.faceMaterials)
        return try? MeshResource.generate(from: [descriptor])
    }()
}

/// The drifting cloud deck: one static mesh of extruded boxes, three
/// materials, and a transform.
///
/// ## Drift, and why it no longer snaps
///
/// The layer this replaced translated the whole entity by an accumulating
/// wind offset and subtracted one texture repeat whenever the offset grew
/// past it. That is right for the *pattern* — the texture wrapped, so the
/// sky looked the same either side of the subtraction — but it was wrong for
/// the *dome*, which was a finite shell: it slid up to 120 blocks off-centre
/// before the wrap yanked it back, so the far rim swung through the sky
/// twice a minute and the near clouds were never overhead.
///
/// Here the drift and the centring are two separate numbers that are added:
///
///     x = drift + tilePeriod * round((cameraX - drift) / tilePeriod)
///
/// The first term is where the wind has pushed the pattern to, taken modulo
/// one tile. The second snaps the mesh to whichever multiple of a tile lands
/// nearest the camera, and a whole tile is exactly one period of the blob
/// field, so it moves the geometry without moving one cloud. The camera
/// therefore never sits more than half a tile from the middle of the disc,
/// the wind never accumulates, and the two corrections cannot fight: when
/// `drift` wraps from just under a tile back to zero the `round` term steps
/// the other way by exactly the same amount, so `x` is continuous through
/// the wrap.
@MainActor
final class CloudLayer {
    /// `BLOCKHAVEN_CLOUD_LOG=1` reports the deck's size, coverage, fade and
    /// build time to stderr once, at startup.
    ///
    /// Behind a flag for the same reason `PostProcessing.logsGPUTime` is:
    /// it is a measurement, not a warning. The numbers are worth having —
    /// the fade has to finish inside `CloudMesh.coverageRadius` and this
    /// line is what makes that relation checkable — but they are worth
    /// having when someone asks for them, not on every launch of a game a
    /// child is playing.
    private static let logsBuild =
        ProcessInfo.processInfo.environment["BLOCKHAVEN_CLOUD_LOG"] == "1"

    /// Blocks per second the deck drifts along +x.
    private static let windSpeed: Double = 0.9

    /// Where the layer starts thinning and where it is gone, in blocks.
    ///
    /// The far end has to sit inside `CloudMesh.coverageRadius` (336 blocks:
    /// the rim jumps by a tile as the player moves) and inside the camera's
    /// 400-block far plane, which would otherwise slice the deck along a
    /// hard horizontal line. It is a long ramp on purpose: the layer
    /// dissolves into the horizon haze the way the terrain under it does.
    ///
    /// 330 blocks puts the bottom edge of the deck eight degrees above the
    /// horizon, and there is no way to get it lower — the far plane alone
    /// caps it at 6.6. A deck that curved down toward the rim would, but the
    /// curve would have to be a function of distance from the *mesh*, and
    /// that is the one thing the re-centring may not move: unlike the blob
    /// field, a bowl is not periodic, so every tile snap would jump the
    /// clouds vertically. Flat deck, honest horizon.
    private static let fadeRange = SIMD2<Float>(190, 330)

    /// How see-through the deck is. Classic block-game clouds are slightly
    /// translucent and it matters: it is what lets the sun's glow warm the
    /// cloud that crosses it instead of being switched off by it.
    private static let baseOpacity: Float = 0.86
    /// How much of that is given up at full night, so the deck reads as dark
    /// shapes against the stars rather than a lit ceiling.
    private static let nightThinning: Float = 0.4

    /// The golden hour's colour on a cloud, and the night's.
    ///
    /// Pink rather than the orange the horizon band is: blue held level with
    /// green is what stops it sliding into the sky's own colour and turning
    /// the deck invisible at exactly the hour it should be the loudest thing
    /// up there.
    private static let sunsetTint = SIMD3<Float>(1.0, 0.58, 0.56)
    private static let nightTint = SIMD3<Float>(0.24, 0.30, 0.46)

    let entity: ModelEntity

    /// Populated when the shader library loaded; `flat` stands in otherwise.
    private var shaded: [CustomMaterial] = []
    private var flat: [UnlitMaterial] = []

    /// Blocks of wind travelled, kept inside one tile period so a long
    /// session cannot walk it out of single-precision range.
    private var drift: Double = 0

    init() {
        let field = CloudMesh.field
        if let shader = CloudLayer.surfaceShader {
            shaded = CloudMesh.Face.allCases.compactMap { CloudLayer.makeShaded(shader, face: $0) }
            // All three or none: the mesh addresses its slots by face, and a
            // short array would leave one direction unpainted.
            if shaded.count != CloudMesh.Face.allCases.count { shaded = [] }
        }
        if shaded.isEmpty {
            flat = CloudMesh.Face.allCases.map { CloudLayer.makeFlat(face: $0) }
        }
        entity = ModelEntity(
            mesh: CloudMesh.meshResource ?? MeshResource.generateBox(size: 0.01),
            materials: shaded.isEmpty ? flat.map { $0 as any Material } : shaded.map { $0 as any Material }
        )
        if CloudLayer.logsBuild {
            let note = String(
                format: "[clouds] %d tris · %d vertices · %.0f%% of the disc covered"
                    + " · fade ends %.0f of %.0f blocks covered · built once in %.1f ms · %@\n",
                field.triangles, field.vertices, field.coverage * 100,
                CloudLayer.fadeRange.y, CloudMesh.coverageRadius, field.buildMilliseconds,
                shaded.isEmpty ? "flat materials" : "cloudSurface"
            )
            StandardError.write(Data(note.utf8))
        }
    }

    /// Re-centres the deck on the camera and pushes it downwind. Transform
    /// only — nothing here touches the mesh or a material, so it is free to
    /// run every frame.
    func update(cameraPosition: SIMD3<Float>, dt: Double) {
        let period = Double(CloudMesh.tilePeriod)
        drift = (drift + dt * CloudLayer.windSpeed).truncatingRemainder(dividingBy: period)
        if drift < 0 { drift += period }

        let tile = CloudMesh.tilePeriod
        let offset = Float(drift)
        entity.position = SIMD3(
            offset + tile * ((cameraPosition.x - offset) / tile).rounded(),
            0,
            tile * (cameraPosition.z / tile).rounded()
        )
    }

    /// Writes the time of day onto the three face materials.
    ///
    /// `low` is `SkyEntities.lowSun` — 1 with the sun on the horizon — and
    /// `night` ramps 0 to 1 once it is down. `horizon` is the colour the sky
    /// meets the ground at, which the shader recedes the far clouds into.
    func regrade(low: Float, night: Float, horizon: SIMD3<Float>, sunDirection: SIMD3<Float>) {
        let opacity = CloudLayer.baseOpacity * (1 - CloudLayer.nightThinning * night)
        for face in CloudMesh.Face.allCases {
            // Undersides take all of the golden hour's warmth, tops about
            // half: a low sun lights a deck from beneath, and the top of a
            // cloud at dusk is facing a violet zenith instead. That split is
            // where the reference's pink bellies come from.
            var tint = cloudBlend(.one, CloudLayer.sunsetTint, low * face.warmth)
            tint = cloudBlend(tint, CloudLayer.nightTint, night)

            if !shaded.isEmpty {
                var material = shaded[face.rawValue]
                material.baseColor = .init(tint: cloudColor(tint))
                material.emissiveColor = .init(color: cloudColor(horizon))
                material.roughness = .init(scale: MaterialLibrary.encodeSunComponent(sunDirection.x))
                material.metallic = .init(scale: MaterialLibrary.encodeSunComponent(sunDirection.y))
                material.specular = .init(scale: MaterialLibrary.encodeSunComponent(sunDirection.z))
                material.custom.value = SIMD4(
                    CloudLayer.fadeRange.x, CloudLayer.fadeRange.y, face.brightness, opacity
                )
                shaded[face.rawValue] = material
            } else {
                // No shader to multiply the face brightness in, so it is
                // folded into the tint. `blending` is deliberately left
                // alone: it is the single most expensive property on a
                // RealityKit material and this path runs a few times a
                // second. The night dimming rides the tint instead.
                flat[face.rawValue].color = .init(tint: cloudColor(tint * face.brightness))
            }
        }
        entity.model?.materials = shaded.isEmpty
            ? flat.map { $0 as any Material }
            : shaded.map { $0 as any Material }
    }

    // MARK: - Materials

    /// The cloud surface shader, or nil when the library did not load or
    /// `BLOCKHAVEN_CUSTOM_SHADER=0` turned it off — the same gate the block
    /// shader is behind, so the two paths never disagree about which
    /// renderer a frame is being drawn with.
    private static let surfaceShader: CustomMaterial.SurfaceShader? = {
        guard let library = MaterialLibrary.shaderLibrary else { return nil }
        return CustomMaterial.SurfaceShader(named: "cloudSurface", in: library)
    }()

    private static func makeShaded(
        _ shader: CustomMaterial.SurfaceShader, face: CloudMesh.Face
    ) -> CustomMaterial? {
        guard var material = try? CustomMaterial(surfaceShader: shader, lightingModel: .unlit) else {
            return nil
        }
        // The shader owns the opacity, so `blending` is set once here at
        // full strength and never touched again; the grade writes a lane of
        // `custom.value` instead.
        material.blending = .transparent(opacity: 1.0)
        material.opacityThreshold = nil
        // Boxes seen from outside, so the far side of every cloud is culled
        // — which is also what keeps a deck of translucent slabs from
        // double-compositing itself into a solid ceiling.
        material.faceCulling = .back
        // Camera-following sky: it may never occlude anything in the depth
        // buffer, or every screen-space pass that reads depth breaks. See
        // the note at the top of `SkyEntities`.
        material.writesDepth = false
        material.clearcoat = .init(scale: 0)
        material.clearcoatRoughness = .init(scale: 0)
        // A whole day's grade at noon, so the material is never briefly
        // carrying a default it was not given. `regrade` runs on the first
        // frame the layer is in a scene, so this is belt and braces — but a
        // material with an unwritten emissive slot would render its distant
        // clouds black, which is a bad thing to leave one frame away.
        material.baseColor = .init(tint: cloudColor(.one))
        material.emissiveColor = .init(color: cloudColor(SIMD3(0.63, 0.82, 0.99)))
        material.roughness = .init(scale: MaterialLibrary.encodeSunComponent(0))
        material.metallic = .init(scale: MaterialLibrary.encodeSunComponent(1))
        material.specular = .init(scale: MaterialLibrary.encodeSunComponent(0))
        material.custom.value = SIMD4(fadeRange.x, fadeRange.y, face.brightness, baseOpacity)
        return material
    }

    private static func makeFlat(face: CloudMesh.Face) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: cloudColor(SIMD3(repeating: face.brightness)))
        material.blending = .transparent(opacity: .init(floatLiteral: baseOpacity))
        material.faceCulling = .back
        material.writesDepth = false
        return material
    }
}

extension CloudMesh.Face {
    /// The classic cloud lighting model: a fixed brightness per face
    /// direction with no light source in it at all. Tops full, undersides
    /// darkest, sides between — which is what makes a white box read as a
    /// solid rather than a flat silhouette.
    /// Widened from the classic 1.0 / 0.86 / 0.74 once the deck grew terraces
    /// to put those faces on. With a flat sheet the only side faces in the
    /// sky are the rim of each blob, and how dark they are barely matters;
    /// with a stack, every step in every mass is a wall, and the contrast
    /// between the lit tops and the shaded flanks is the entire read of
    /// volume. A cloud base is genuinely dark — it is the one part of a
    /// cumulus in its own shadow.
    var brightness: Float {
        switch self {
        case .top: return 1.0
        case .side: return 0.79
        case .bottom: return 0.60
        }
    }

    /// How much of the golden hour's warmth this face takes.
    var warmth: Float {
        switch self {
        case .top: return 0.5
        case .side: return 0.85
        case .bottom: return 1.0
        }
    }
}

/// Linear blend, `t` 0 for `a` and 1 for `b`.
private func cloudBlend(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    a + (b - a) * max(0, min(1, t))
}

/// Raw sRGB components become an `NSColor` only here, where RealityKit
/// demands one — same convention as `SkyEntities` and `SkyController`.
private func cloudColor(_ rgb: SIMD3<Float>) -> NSColor {
    NSColor(
        srgbRed: CGFloat(max(0, min(1, rgb.x))),
        green: CGFloat(max(0, min(1, rgb.y))),
        blue: CGFloat(max(0, min(1, rgb.z))),
        alpha: 1
    )
}
#endif

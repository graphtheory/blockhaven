#if canImport(AppKit)
import AppKit
import Metal
import MetalPerformanceShaders
import RealityKit
import simd

/// The screen-space pass that runs after RealityKit has drawn the frame:
/// bloom, crepuscular rays, a highlight roll-off and a whisper of vignette.
///
/// RealityKit hands the whole frame over through
/// `ARView.renderCallbacks.postProcess` — a source colour texture, a depth
/// texture, a target colour texture and the frame's command buffer. Whatever
/// is in the target when the callback returns is what reaches the screen, so
/// this must always write it, including on every failure path.
///
/// The work is three to five dispatches on the frame's own command buffer:
///
///   1. `postBrightPass` — quarter-size downsample keeping only what is
///      above the threshold.
///   2. `MPSImageGaussianBlur` — separable, on the quarter-size image.
///   2b. `postGodRayMask` and `postGodRays` — eighth-size, and only on the
///      frames where the sun is up, low and roughly on screen. The two of
///      them together are the crepuscular rays; everything about where the
///      sun is comes from `publishSun` below and `context.projection`.
///   3. `postComposite` — source + blurred bloom + rays, vignette, tonemap.
///
/// The tuning is deliberately restrained. The sun's disc and its long halo,
/// the golden-hour horizon and the glints on water sit above the threshold;
/// lit grass at midday does not, so noon is very nearly untouched.
///
/// That is checkable two ways, and the first one was a genuine question
/// worth measuring rather than assuming. `ARView.snapshot` *does* capture
/// this pass: shooting the offscreen harness with `BLOCKHAVEN_POSTFX=0` and
/// again with it on gives images that differ, and the corner pixels differ
/// by exactly the vignette's arithmetic. So the ordinary
/// `BLOCKHAVEN_SNAPSHOT` + `BLOCKHAVEN_SNAPSHOT_CUSTOM_SHADER=1` route is
/// enough to see the effect offscreen. `BLOCKHAVEN_POSTFX_DUMP=<path.png>`
/// is the belt-and-braces second way — it writes a frame from inside the
/// callback, so it stays honest if RealityKit ever changes its mind about
/// what `snapshot` renders — and `BLOCKHAVEN_POSTFX_DUMP_SOURCE=1` writes
/// the same frame from *before* the pass, for differencing.
/// `BLOCKHAVEN_POSTFX_DUMP_DEPTH=1` dumps the depth buffer instead of the
/// colour, log-encoded so a reversed-Z buffer is actually legible; that is
/// how the god-ray mask's `kSkyDepth` was settled and how the sky's stray
/// depth writes were found.
///
/// Threading: everything below runs on RealityKit's render thread, not the
/// main thread, and touches nothing outside this object.
final class PostProcessing: @unchecked Sendable {

    // MARK: - Switches

    private static let environment = ProcessInfo.processInfo.environment

    /// On unless `BLOCKHAVEN_POSTFX=0`.
    static var isEnabled: Bool { environment["BLOCKHAVEN_POSTFX"] != "0" }

    /// `BLOCKHAVEN_POSTFX=copy` installs the callback but only copies source
    /// to target. That is the honest baseline for measuring what the effect
    /// costs: the display is 100 Hz and the game is vsync-bound either way,
    /// so comparing frame rates proves nothing, and comparing GPU frame time
    /// against *no callback at all* would also be measuring RealityKit's
    /// own fast path for having none.
    private static var isCopyOnly: Bool { environment["BLOCKHAVEN_POSTFX"] == "copy" }

    /// `BLOCKHAVEN_POSTFX_TIME=1` reports mean GPU time per frame to stderr
    /// once a second.
    ///
    /// Also read by the snapshot harness, which normally captures on frame
    /// twelve and exits — a fifth of a second, so the report below would
    /// never fire once. A timing capture renders for several seconds first.
    /// That route matters because it is the *only* one that can point the
    /// camera at the sun: the sun orbits the world's X–Y plane, the live
    /// game starts the player facing +Z, and there is no way to turn a
    /// running game's head from a script — so a live run measures the
    /// god-ray pass in exactly the state where it skips itself.
    static var logsGPUTime: Bool { environment["BLOCKHAVEN_POSTFX_TIME"] == "1" }

    /// Where a one-frame debug capture goes, if one was asked for.
    private static var dumpPath: String? { environment["BLOCKHAVEN_POSTFX_DUMP"] }

    /// True when a dump was requested — read by the snapshot harness, which
    /// hands the capture over to this file rather than running its own.
    static var isDumpRequested: Bool { dumpPath != nil }

    // MARK: - Tuning

    /// Shape of the effect. Every field can be overridden at runtime with
    /// `BLOCKHAVEN_POSTFX_TUNE="intensity=0.4,threshold=0.8"`, which is how
    /// these numbers were found — each one is a render that was looked at,
    /// not a guess.
    struct Tuning {
        /// Max-channel intensity where bloom starts, in the linear values
        /// the frame actually arrives in. Measured, not assumed: lit grass
        /// reads about 0.25, a golden-hour horizon 0.60, a midday sky 0.66,
        /// and the sun's disc 0.64 — so this line sits well clear of the
        /// terrain and just under the sky.
        var threshold: Float = 0.52
        /// Half-width of the soft ramp around the threshold.
        var knee: Float = 0.10
        /// How much harder fully warm light blooms than cool. See
        /// `brightOnly` in PostProcess.metal for why this exists.
        var warmth: Float = 2.4
        /// How much blurred bright pass is added back.
        var intensity: Float = 0.8
        /// Corner darkening.
        var vignette: Float = 0.13
        /// Where the highlight roll-off starts; below it the tonemap is the
        /// identity and the hand-graded daylight passes through untouched.
        var shoulder: Float = 0.72
        /// Gaussian radius, in quarter-size pixels *at a 1600-pixel-wide
        /// frame*. It is scaled with the drawable below, so the glow covers
        /// the same fraction of the screen in a window and fullscreen.
        var sigma: Float = 3.4

        // MARK: God rays

        /// Peak strength of the crepuscular rays, at a sun on the horizon.
        /// `rays=0` switches them off without a rebuild.
        var rays: Float = 0.45
        /// Radius, in screen heights, of the patch of sky around the sun
        /// the rays are drawn from.
        var rayFalloff: Float = 0.30
        /// How far along the line to the sun one march travels.
        var rayDensity: Float = 0.96
        /// Per-tap attenuation along that march.
        var rayDecay: Float = 0.972
        /// Contrast curve on the finished march — see `power` in
        /// PostProcess.metal, which is what makes a beam a beam.
        var rayPower: Float = 3.5
        /// Radius, in screen heights, of the hole in the ray add around the
        /// sun's disc — see `coreInner`/`coreOuter` in PostProcess.metal.
        var rayCore: Float = 0.075

        static func fromEnvironment() -> Tuning {
            var tuning = Tuning()
            guard let spec = PostProcessing.environment["BLOCKHAVEN_POSTFX_TUNE"] else { return tuning }
            for pair in spec.split(separator: ",") {
                let halves = pair.split(separator: "=")
                guard halves.count == 2, let value = Float(halves[1]) else { continue }
                switch halves[0].trimmingCharacters(in: .whitespaces) {
                case "threshold": tuning.threshold = value
                case "knee": tuning.knee = value
                case "warmth": tuning.warmth = value
                case "intensity": tuning.intensity = value
                case "vignette": tuning.vignette = value
                case "shoulder": tuning.shoulder = value
                case "sigma": tuning.sigma = value
                case "rays": tuning.rays = value
                case "rayFalloff": tuning.rayFalloff = value
                case "rayDensity": tuning.rayDensity = value
                case "rayDecay": tuning.rayDecay = value
                case "rayPower": tuning.rayPower = value
                case "rayCore": tuning.rayCore = value
                default: break
                }
            }
            return tuning
        }
    }

    /// How much smaller the bloom chain is than the frame, on each axis.
    /// Four is the sweet spot here: the blur costs a sixteenth of the pixels
    /// and a modest sigma still reaches a long way across the screen.
    private static let downscale = 4

    /// And how much smaller the god-ray chain is. Eight, not four: a shaft
    /// of light is the lowest-frequency thing in the frame, the march costs
    /// forty taps a pixel so the pixel count is what the whole effect is
    /// priced in, and the upsample's softness is welcome rather than a
    /// compromise. At 3440x1440 that is 430x180 threads instead of 860x360.
    private static let rayDownscale = 8

    // MARK: - Where the sun is

    /// The sun as the post pass needs it, published from the main thread
    /// once a frame and read on the render thread.
    ///
    /// The split is deliberate. Only the main thread may ask an `Entity`
    /// where it is, and only the render callback is handed the projection
    /// matrix, so the two halves of "where is the sun on screen" live on
    /// different threads. What crosses between them is the sun's direction
    /// *in the camera's own space* — a rotation the main thread already has
    /// — leaving the render thread one matrix multiply.
    struct SunSighting {
        /// Unit vector toward the sun in camera space: -Z is ahead.
        var viewDirection: SIMD3<Float>
        /// Height of the sun in the world, 1 overhead and -1 at midnight.
        /// This is what decides how strong the rays are.
        var elevation: Float
    }

    private static let sunLock = NSLock()
    private static var sighting: SunSighting?

    /// Called once a frame from wherever the camera is driven. Cheap: one
    /// transform query and a 3x3 multiply.
    @MainActor
    static func publishSun(timeOfDay: Double, camera: Entity) {
        let world = SkyEntities.sunDirection(angle: SkyEntities.sunAngle(at: timeOfDay))
        let matrix = camera.transformMatrix(relativeTo: nil)
        // The camera rig is a chain of rotations with no scale anywhere in
        // it, so the inverse of its rotation is its transpose.
        let rotation = simd_float3x3(
            SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
            SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
            SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        )
        let sighting = SunSighting(
            viewDirection: normalize(rotation.transpose * world),
            elevation: world.y
        )
        sunLock.lock()
        Self.sighting = sighting
        sunLock.unlock()
    }

    private static func currentSighting() -> SunSighting? {
        sunLock.lock()
        defer { sunLock.unlock() }
        return sighting
    }

    /// The frame width `Tuning.sigma` is quoted at — the snapshot harness's,
    /// which is where the tuning was looked at.
    private static let referenceWidth: Float = 1600

    // MARK: - Installation

    /// Hangs the pass off a view's render callbacks. Does nothing if the
    /// effect is switched off or the compute pipelines will not build — in
    /// either case the view keeps rendering exactly as it did before, since
    /// an unset callback means RealityKit presents its own output.
    /// Returns whether the callback was actually installed. Callers that
    /// hand their output over to this pass — the snapshot harness's
    /// `BLOCKHAVEN_POSTFX_DUMP` path — need to know, because with the pass
    /// switched off nothing here will ever write their file.
    @MainActor
    @discardableResult
    static func install(on view: ARView) -> Bool {
        guard isEnabled else { return false }
        let pass = PostProcessing()
        view.renderCallbacks.postProcess = { context in
            pass.run(context)
        }
        return true
    }

    // MARK: - State

    private let tuning = Tuning.fromEnvironment()

    /// Built on the first frame, from the device the context hands over —
    /// `prepareWithDevice` would arrive earlier but is not guaranteed to,
    /// and this way there is exactly one place that can fail.
    private var brightPass: (any MTLComputePipelineState)?
    private var composite: (any MTLComputePipelineState)?
    private var copyKernel: (any MTLComputePipelineState)?
    private var copyDepthKernel: (any MTLComputePipelineState)?
    private var rayMaskPass: (any MTLComputePipelineState)?
    private var rayPass: (any MTLComputePipelineState)?
    private var blur: MPSImageGaussianBlur?
    private var setupAttempted = false
    private var setupFailed = false

    /// The bloom chain, re-allocated only when the drawable changes size —
    /// which is a window resize, a display change, or the first frame.
    private var chainWidth = 0
    private var chainHeight = 0
    private var brightTexture: (any MTLTexture)?
    private var blurredTexture: (any MTLTexture)?

    /// The god-ray chain, on the same never-per-frame discipline.
    private var rayWidth = 0
    private var rayHeight = 0
    private var rayMaskTexture: (any MTLTexture)?
    private var raysTexture: (any MTLTexture)?
    /// One line the first time a placement is computed, so "is the sun
    /// where the shader thinks it is" is answerable from a log rather than
    /// by squinting at where the fan converges.
    private var loggedPlacement = false

    private var frameIndex = 0
    private var dumpDone = false

    private let timingLock = NSLock()
    private var gpuTimeTotal: Double = 0
    private var gpuTimeFrames = 0
    private var gpuTimeLastReport: Double = 0

    // MARK: - The frame

    private func run(_ context: ARView.PostProcessContext) {
        frameIndex += 1
        prepare(device: context.device)

        if Self.isCopyOnly || setupFailed {
            copySourceToTarget(context)
        } else {
            render(context)
        }

        dumpIfAsked(context)
        if Self.logsGPUTime { recordGPUTime(context) }
    }

    private func render(_ context: ARView.PostProcessContext) {
        guard let brightPass, let composite,
              let (bright, blurred, blur) = bloomChain(context: context)
        else {
            copySourceToTarget(context)
            return
        }

        // 1. Bright pass and downsample.
        if let encoder = context.commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "postfx.bright"
            encoder.setComputePipelineState(brightPass)
            encoder.setTexture(context.sourceColorTexture, index: 0)
            encoder.setTexture(bright, index: 1)
            // Laid out to match `BrightParams` in PostProcess.metal.
            var params: [Float] = [tuning.threshold, tuning.knee, tuning.warmth]
            encoder.setBytes(&params, length: MemoryLayout<Float>.size * params.count, index: 0)
            dispatch(encoder, brightPass, width: bright.width, height: bright.height)
            encoder.endEncoding()
        }

        // 2. Separable Gaussian, on a sixteenth of the pixels.
        blur.encode(commandBuffer: context.commandBuffer, sourceTexture: bright, destinationTexture: blurred)

        // 2b. God rays, when the sun is up, low and roughly on screen. Two
        // more dispatches at an eighth size, or none at all.
        let placement = rayPlacement(context)
        let rays = placement.flatMap { encodeGodRays(context, placement: $0) }

        // 3. Composite, tonemap, vignette.
        if let encoder = context.commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "postfx.composite"
            encoder.setComputePipelineState(composite)
            encoder.setTexture(context.sourceColorTexture, index: 0)
            encoder.setTexture(blurred, index: 1)
            encoder.setTexture(context.targetColorTexture, index: 2)
            // A texture has to be bound whether or not the rays ran, so on
            // the frames they did not this slot gets the bloom buffer and a
            // strength of zero, which the kernel branches around entirely.
            encoder.setTexture(rays ?? blurred, index: 3)
            let sun = rays != nil ? placement : nil
            // Laid out to match `CompositeParams` in PostProcess.metal.
            var params: [Float] = [
                tuning.intensity, tuning.vignette, tuning.shoulder,
                sun?.strength ?? 0,
                Self.rayTint.x, Self.rayTint.y, Self.rayTint.z,
                sun?.sunU ?? 0.5, sun?.sunV ?? 0.5, sun?.aspect ?? 1,
                tuning.rayCore * 0.25, tuning.rayCore,
            ]
            encoder.setBytes(&params, length: MemoryLayout<Float>.size * params.count, index: 0)
            dispatch(
                encoder, composite,
                width: context.targetColorTexture.width,
                height: context.targetColorTexture.height
            )
            encoder.endEncoding()
        }
    }

    // MARK: - God rays

    /// The colour the shafts are added in. Warm on purpose and not sampled
    /// from the sky: what the rays are is sunlight scattered out of the
    /// beam, which is redder than the disc it left, and the whole effect
    /// only ever runs while the sun is low enough for that to be true.
    private static let rayTint = SIMD3<Float>(1.00, 0.74, 0.44)

    /// Where the sun lands on this frame, and how hard to push the rays.
    /// `nil` means don't run the pass at all — the sun is down, overhead,
    /// behind the camera, or too far outside the frame to matter.
    private struct RayPlacement {
        var sunU: Float
        var sunV: Float
        var strength: Float
        var aspect: Float
    }

    private func rayPlacement(_ context: ARView.PostProcessContext) -> RayPlacement? {
        guard tuning.rays > 0, let sighting = Self.currentSighting() else { return nil }

        // Full strength with the sun on the horizon and nothing at all with
        // it overhead — the same shape as the sky's own golden-hour ramp, so
        // the rays arrive with the warm horizon and leave with it. The lower
        // edge is deliberately below zero: `t = 0.5` puts the sun exactly on
        // the horizon and that is the shot this whole grade is built around,
        // so it gets the peak rather than half of it.
        let above = Self.smoothRamp(-0.22, 0.02, sighting.elevation)
        let low = powf(max(0, 1 - sighting.elevation), 1.6)
        var strength = tuning.rays * above * low
        guard strength > 0.002 else { return nil }

        // View space to clip. `w` is the distance ahead of the camera, so a
        // sun behind it is the one case the divide cannot describe.
        let clip = context.projection * SIMD4<Float>(sighting.viewDirection, 0)
        guard clip.w > 1e-4 else { return nil }
        let ndc = SIMD2<Float>(clip.x, clip.y) / clip.w

        // Fade by how far off screen the sun is rather than cutting at the
        // edge, or the whole fan would switch off in one frame as the player
        // turns. 1 is the frame edge; by 2 there is nothing left. Past that
        // the projection stretches toward infinity anyway, so the ramp is
        // over long before the divide gets interesting.
        strength *= 1 - Self.smoothRamp(1.0, 2.0, max(abs(ndc.x), abs(ndc.y)))
        guard strength > 0.002 else { return nil }

        let width = context.targetColorTexture.width
        let height = max(1, context.targetColorTexture.height)
        let placement = RayPlacement(
            sunU: ndc.x * 0.5 + 0.5,
            // Clip space has y up, a texture has it down.
            sunV: 0.5 - ndc.y * 0.5,
            strength: strength,
            aspect: Float(width) / Float(height)
        )
        if Self.logsGPUTime, !loggedPlacement {
            loggedPlacement = true
            let note = String(
                format: "[postfx] sun at uv %.3f,%.3f — pixel %.0f,%.0f of %dx%d,"
                    + " elevation %.3f, ray strength %.3f\n",
                placement.sunU, placement.sunV,
                placement.sunU * Float(width), placement.sunV * Float(height),
                width, context.targetColorTexture.height,
                sighting.elevation, strength
            )
            StandardError.write(Data(note.utf8))
        }
        return placement
    }

    /// Encodes the mask and the march, and hands back the buffer the
    /// composite should add. Nil if either pipeline or texture is missing,
    /// in which case the frame simply has no rays in it.
    private func encodeGodRays(
        _ context: ARView.PostProcessContext,
        placement: RayPlacement
    ) -> (any MTLTexture)? {
        guard let rayMaskPass, let rayPass, let (mask, rays) = rayChain(context: context) else {
            return nil
        }

        // Laid out to match `GodRayParams` in PostProcess.metal.
        var params: [Float] = [
            placement.sunU, placement.sunV, placement.aspect,
            tuning.rayFalloff, tuning.rayDensity, tuning.rayDecay, tuning.rayPower,
        ]
        let length = MemoryLayout<Float>.size * params.count

        if let encoder = context.commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "postfx.raymask"
            encoder.setComputePipelineState(rayMaskPass)
            encoder.setTexture(context.sourceDepthTexture, index: 0)
            encoder.setTexture(mask, index: 1)
            encoder.setBytes(&params, length: length, index: 0)
            dispatch(encoder, rayMaskPass, width: mask.width, height: mask.height)
            encoder.endEncoding()
        }

        if let encoder = context.commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "postfx.godrays"
            encoder.setComputePipelineState(rayPass)
            encoder.setTexture(mask, index: 0)
            encoder.setTexture(rays, index: 1)
            encoder.setBytes(&params, length: length, index: 0)
            dispatch(encoder, rayPass, width: rays.width, height: rays.height)
            encoder.endEncoding()
        }

        return rays
    }

    /// Hermite ramp between two edges — `smoothstep`, which Foundation does
    /// not have and which both ends of the ray strength need.
    private static func smoothRamp(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// The target has to be written every frame no matter what, or the
    /// screen shows whatever was last in that texture.
    private func copySourceToTarget(_ context: ARView.PostProcessContext) {
        let source = context.sourceColorTexture
        let target = context.targetColorTexture
        if let copyKernel, let encoder = context.commandBuffer.makeComputeCommandEncoder() {
            encoder.label = "postfx.copy"
            encoder.setComputePipelineState(copyKernel)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(target, index: 1)
            dispatch(encoder, copyKernel, width: target.width, height: target.height)
            encoder.endEncoding()
        } else if source.pixelFormat == target.pixelFormat,
                  source.width == target.width, source.height == target.height,
                  let blit = context.commandBuffer.makeBlitCommandEncoder() {
            blit.label = "postfx.blit"
            blit.copy(from: source, to: target)
            blit.endEncoding()
        }
    }

    private func dispatch(
        _ encoder: any MTLComputeCommandEncoder,
        _ pipeline: any MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
    }

    // MARK: - Cached resources

    private func prepare(device: any MTLDevice) {
        guard !setupAttempted else { return }
        setupAttempted = true

        guard let library = try? device.makeDefaultLibrary(bundle: Bundle.shaders) else {
            fail("default.metallib not loaded")
            return
        }
        do {
            brightPass = try makePipeline(named: "postBrightPass", device: device, library: library)
            composite = try makePipeline(named: "postComposite", device: device, library: library)
            copyKernel = try makePipeline(named: "postCopy", device: device, library: library)
            copyDepthKernel = try makePipeline(named: "postCopyDepth", device: device, library: library)
        } catch {
            fail("\(error)")
            return
        }

        // The god-ray kernels are deliberately not in that block. They are
        // the newest thing in the library and the one part of this file a
        // stale checked-in `default.metallib` can be missing; losing the
        // rays because of that is a shame, losing bloom and the tonemap with
        // them would be a bug. The composite branches on a zero strength, so
        // a frame with no ray pipelines is just a frame with no rays.
        do {
            rayMaskPass = try makePipeline(named: "postGodRayMask", device: device, library: library)
            rayPass = try makePipeline(named: "postGodRays", device: device, library: library)
        } catch {
            rayMaskPass = nil
            rayPass = nil
            StandardError.write(Data("[postfx] god rays off — \(error)\n".utf8))
        }
    }

    private func makePipeline(
        named name: String,
        device: any MTLDevice,
        library: any MTLLibrary
    ) throws -> any MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw NSError(
                domain: "Blockhaven.PostProcessing", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(name) missing from default.metallib"]
            )
        }
        return try device.makeComputePipelineState(function: function)
    }

    private func fail(_ reason: String) {
        setupFailed = true
        StandardError.write(Data("[postfx] disabled — \(reason)\n".utf8))
    }

    /// The two quarter-size bloom textures and the blur that runs between
    /// them, rebuilt only when the drawable changes size — a window resize,
    /// a display change, or the first frame. Never allocated per frame.
    private func bloomChain(
        context: ARView.PostProcessContext
    ) -> ((any MTLTexture), (any MTLTexture), MPSImageGaussianBlur)? {
        let width = max(1, context.sourceColorTexture.width / Self.downscale)
        let height = max(1, context.sourceColorTexture.height / Self.downscale)
        if width != chainWidth || height != chainHeight {
            chainWidth = width
            chainHeight = height
            brightTexture = nil
            blurredTexture = nil
            // The glow should cover the same slice of the screen whatever
            // the window size, so the radius travels with the frame rather
            // than staying a fixed number of pixels.
            let scale = Float(context.sourceColorTexture.width) / Self.referenceWidth
            let gaussian = MPSImageGaussianBlur(device: context.device, sigma: tuning.sigma * scale)
            gaussian.edgeMode = .clamp
            blur = gaussian
        }
        guard let blur else { return nil }
        if let bright = brightTexture, let blurred = blurredTexture { return (bright, blurred, blur) }

        // Always float, whatever the frame's format is: the bright pass is
        // where values above 1 live, and an 8-bit chain would clip the sun's
        // core flat before it ever reached the blur.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let bright = context.device.makeTexture(descriptor: descriptor),
              let blurred = context.device.makeTexture(descriptor: descriptor) else { return nil }
        bright.label = "postfx.bright"
        blurred.label = "postfx.blurred"
        // One line per drawable size, so "did it reallocate every frame?" is
        // answerable from a log, and so the pixel format the whole tuning
        // assumes is on the record rather than assumed. Behind the same flag
        // as the rest of this file's instrumentation: it is a measurement,
        // not a warning, and it used to print on every single launch.
        if Self.logsGPUTime {
            let depth = context.sourceDepthTexture
            let note = "[postfx] bloom chain \(width)x\(height) for a"
                + " \(context.sourceColorTexture.width)x\(context.sourceColorTexture.height)"
                + " frame, format \(context.sourceColorTexture.pixelFormat.rawValue)"
                + "→\(context.targetColorTexture.pixelFormat.rawValue)"
                + "; depth \(depth.width)x\(depth.height) type \(depth.textureType.rawValue)"
                + " format \(depth.pixelFormat.rawValue) usage \(depth.usage.rawValue)\n"
            StandardError.write(Data(note.utf8))
        }
        brightTexture = bright
        blurredTexture = blurred
        return (bright, blurred, blur)
    }

    /// The two eighth-size single-channel buffers the ray march runs
    /// through, on the same discipline as the bloom chain: allocated on the
    /// first frame at a given drawable size and never again.
    private func rayChain(
        context: ARView.PostProcessContext
    ) -> ((any MTLTexture), (any MTLTexture))? {
        let width = max(1, context.sourceColorTexture.width / Self.rayDownscale)
        let height = max(1, context.sourceColorTexture.height / Self.rayDownscale)
        if width != rayWidth || height != rayHeight {
            rayWidth = width
            rayHeight = height
            rayMaskTexture = nil
            raysTexture = nil
        }
        if let mask = rayMaskTexture, let rays = raysTexture { return (mask, rays) }

        // One channel is all a shaft is. Half float rather than 8-bit
        // because the march sums forty taps and the mask's useful range
        // sits well under 1.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let mask = context.device.makeTexture(descriptor: descriptor),
              let rays = context.device.makeTexture(descriptor: descriptor) else { return nil }
        mask.label = "postfx.raymask"
        rays.label = "postfx.rays"
        rayMaskTexture = mask
        raysTexture = rays
        return (mask, rays)
    }

    // MARK: - Debug capture

    /// Writes one frame straight out of the render callback: copied into a
    /// shared float texture and encoded to PNG from the command buffer's
    /// completion handler.
    ///
    /// Not strictly needed — `ARView.snapshot` turns out to capture this
    /// pass, so the normal harness sees it — but it is the only capture that
    /// cannot be wrong about that, it can shoot the *source* as well as the
    /// target for a same-frame before/after, and it reports the frame's peak
    /// channel value, which is how the ceiling that the whole tuning is
    /// built around got measured in the first place.
    private func dumpIfAsked(_ context: ARView.PostProcessContext) {
        guard let path = Self.dumpPath, !dumpDone else { return }
        // Let the scene settle first, the same way the snapshot harness
        // waits for a dozen frames before capturing.
        guard frameIndex >= 12 else { return }

        let wantsSource = Self.environment["BLOCKHAVEN_POSTFX_DUMP_SOURCE"] == "1"
        // `BLOCKHAVEN_POSTFX_DUMP_DEPTH=1` dumps the frame's depth buffer
        // instead of its colour, and needs its own kernel: a depth texture
        // cannot be bound to a `texture2d`. The PNG it writes is mostly
        // useless to look at — the interesting output is the min/max line
        // `writeDump` prints, which is what settled whether RealityKit's
        // depth is reversed (it is; see `farDepth` in PostProcess.metal).
        let wantsDepth = Self.environment["BLOCKHAVEN_POSTFX_DUMP_DEPTH"] == "1"
        let subject = wantsDepth
            ? context.sourceDepthTexture
            : (wantsSource ? context.sourceColorTexture : context.targetColorTexture)
        let kernel = wantsDepth ? copyDepthKernel : copyKernel
        guard let kernel else { return }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: subject.width,
            height: subject.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let readback = context.device.makeTexture(descriptor: descriptor),
              let encoder = context.commandBuffer.makeComputeCommandEncoder() else {
            StandardError.write(Data("[postfx] could not stage the dump\n".utf8))
            exit(1)
        }
        dumpDone = true
        encoder.label = "postfx.dump"
        encoder.setComputePipelineState(kernel)
        encoder.setTexture(subject, index: 0)
        encoder.setTexture(readback, index: 1)
        dispatch(encoder, kernel, width: subject.width, height: subject.height)
        encoder.endEncoding()

        // The source is linear whatever its format says (Metal decodes an
        // sRGB texture on read), so display encoding is this side's job.
        let isLinear = !Self.isDisplayEncoded(subject.pixelFormat)
        context.commandBuffer.addCompletedHandler { [weak self] _ in
            self?.writeDump(readback, to: path, encodeSRGB: isLinear)
        }
    }

    private static func isDisplayEncoded(_ format: MTLPixelFormat) -> Bool {
        switch format {
        case .bgra8Unorm, .rgba8Unorm, .bgr10a2Unorm: return true
        default: return false
        }
    }

    private func writeDump(_ texture: any MTLTexture, to path: String, encodeSRGB: Bool) {
        let width = texture.width, height = texture.height
        var floats = [Float](repeating: 0, count: width * height * 4)
        floats.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: width * 16,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        // A reversed-Z depth buffer is useless to look at through an sRGB
        // ramp: everything past a few blocks lands under 1/255 and the whole
        // sky quantises to black. A depth dump is log-encoded instead, so
        // "sky dome", "cloud dome" and "terrain" come out as separate greys.
        let isDepth = Self.environment["BLOCKHAVEN_POSTFX_DUMP_DEPTH"] == "1"

        var peak: Float = 0
        var floor: Float = .greatestFiniteMagnitude
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                let value = floats[index * 4 + channel]
                peak = max(peak, value)
                floor = min(floor, value)
            }
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let logFloor = log10(max(peak, 1e-8)) - 6
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                let value = floats[index * 4 + channel]
                let display: Float
                if isDepth {
                    display = min(max((log10(max(value, 1e-12)) - logFloor) / 6, 0), 1)
                } else {
                    display = encodeSRGB ? PostProcessing.srgb(value) : min(max(value, 0), 1)
                }
                pixels[index * 4 + channel] = UInt8((display * 255).rounded())
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width, height: height,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else {
            StandardError.write(Data("[postfx] could not encode the dump\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            let note = "[postfx] dumped \(width)x\(height) to \(path)"
                + " — channel range \(floor)…\(peak)\n"
            StandardError.write(Data(note.utf8))
        } catch {
            StandardError.write(Data("[postfx] dump write failed: \(error)\n".utf8))
            exit(1)
        }
        // A dump run inside the snapshot harness owns the exit: the harness
        // stands its own capture down when one was asked for.
        if OffscreenSnapshot.isRequested { exit(0) }
    }

    private static func srgb(_ value: Float) -> Float {
        let clamped = min(max(value, 0), 1)
        return clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * powf(clamped, 1 / 2.4) - 0.055
    }

    private func recordGPUTime(_ context: ARView.PostProcessContext) {
        context.commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            let elapsed = buffer.gpuEndTime - buffer.gpuStartTime
            timingLock.lock()
            gpuTimeTotal += elapsed
            gpuTimeFrames += 1
            let now = buffer.gpuEndTime
            var report: String?
            if gpuTimeLastReport == 0 { gpuTimeLastReport = now }
            if now - gpuTimeLastReport >= 1, gpuTimeFrames > 0 {
                let mean = gpuTimeTotal / Double(gpuTimeFrames) * 1000
                report = String(format: "[postfx] GPU %.3f ms/frame over %d frames\n", mean, gpuTimeFrames)
                gpuTimeTotal = 0
                gpuTimeFrames = 0
                gpuTimeLastReport = now
            }
            timingLock.unlock()
            if let report { StandardError.write(Data(report.utf8)) }
        }
    }
}
#endif
